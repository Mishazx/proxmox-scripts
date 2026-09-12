#!/usr/bin/env bash
# OpenWrt-on-Proxmox helper: enables IOMMU/VFIO passthrough and provisions
# an OpenWrt VM (x86_64) from the official upstream image.
set -Eeuo pipefail

# ---------- output helpers ----------
if [[ -t 1 ]]; then
  C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
  C_INFO=$'\033[1;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_INFO=''; C_BOLD=''; C_RESET=''
fi

say()   { printf '%s\n' "$*"; }
info()  { printf '%s[*] %s%s\n' "$C_INFO" "$*" "$C_RESET"; }
ok()    { printf '%s[+] %s%s\n' "$C_OK" "$*" "$C_RESET"; }
warn()  { printf '%s[!] %s%s\n' "$C_WARN" "$*" "$C_RESET"; }
fail()  { printf '%s[x] %s%s\n' "$C_ERR" "$*" "$C_RESET"; }
title() { printf '\n%s%s==> %s%s\n' "$C_BOLD" "$C_INFO" "$*" "$C_RESET"; }

ask_yes_no() {
  local prompt="$1" default="${2:-Y}" reply hint="Y/n"
  [[ "$default" == "N" ]] && hint="y/N"
  read -rp " $prompt [$hint]: " reply
  reply=${reply:-$default}
  [[ "$reply" =~ ^[Yy]$ ]]
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

prompt_uint() {
  local prompt="$1" default="$2" val
  while true; do
    read -rp " $prompt [$default]: " val
    val=${val:-$default}
    if is_uint "$val" && (( val > 0 )); then
      echo "$val"
      return 0
    fi
    warn "Введите положительное целое число." >&2
  done
}

prompt_vmid() {
  local default="$1" val
  while true; do
    read -rp " VMID [$default]: " val
    val=${val:-$default}
    if ! is_uint "$val"; then
      warn "VMID должен быть числом." >&2
      continue
    fi
    if qm status "$val" >/dev/null 2>&1; then
      warn "VMID $val уже занят." >&2
      continue
    fi
    echo "$val"
    return 0
  done
}

prompt_storage() {
  local default="$1" val
  while true; do
    read -rp " Storage [$default]: " val
    val=${val:-$default}
    if pvesm status -content images 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$val"; then
      echo "$val"
      return 0
    fi
    warn "Storage \"$val\" не найден или не поддерживает images." >&2
  done
}

# Общие флаги curl: не виснуть навечно при плохой сети, повторить пару раз.
CURL_OPTS=(--connect-timeout 10 --max-time 1800 --retry 3 --retry-delay 2)

WORKDIR=""
SELF="$(realpath "$0" 2>/dev/null || echo "$0")"

cleanup_workdir() { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup_workdir EXIT INT TERM

banner() {
  clear
  cat <<'EOF'
+-------------------------------------------------------+
|            OpenWrt Passthrough Installer              |
|                 for Proxmox VE 7.x/8.x                |
+-------------------------------------------------------+
EOF
  echo
}

require_root() {
  [[ $EUID -eq 0 ]] || { fail "Нужны права root (запустите через sudo)."; exit 1; }
}

require_pve() {
  command -v qm >/dev/null 2>&1 || { fail "Это окружение не похоже на Proxmox VE (нет команды qm)."; exit 1; }
}

require_local_file() {
  # При запуске через "curl | bash" $0 указывает на /dev/fd/N, и работать
  # с файлом скрипта (например, предложить его удаление) невозможно.
  if [[ ! -f "$SELF" ]]; then
    banner
    fail "Похоже, скрипт запущен через 'curl | bash'."
    say  "Сначала сохраните файл, затем запустите его напрямую:"
    say  "  ${C_OK}wget -qO openwrt-pve-installer.sh <ссылка> && bash openwrt-pve-installer.sh${C_RESET}"
    exit 1
  fi
}

# =====================================================
# IOMMU / VFIO
# =====================================================
configure_iommu() {
  banner
  title "Настройка IOMMU / VFIO"

  local vendor flag changed=0
  vendor=$(awk -F': ' '/vendor_id/{print $2; exit}' /proc/cpuinfo)
  case "$vendor" in
    GenuineIntel) flag="intel_iommu=on"; ok "CPU: Intel" ;;
    AuthenticAMD) flag="amd_iommu=on"; ok "CPU: AMD" ;;
    *) fail "Не удалось определить производителя CPU ($vendor), пропускаю."; return 1 ;;
  esac

  if command -v proxmox-boot-tool >/dev/null 2>&1 && [[ -f /etc/kernel/cmdline ]]; then
    if ! grep -q "$flag" /etc/kernel/cmdline; then
      info "Обновляю /etc/kernel/cmdline (systemd-boot)"
      sed -i "s/\$/ $flag iommu=pt/" /etc/kernel/cmdline
      proxmox-boot-tool refresh >/dev/null
      changed=1
    fi
  elif [[ -f /etc/default/grub ]]; then
    if ! grep -q "$flag" /etc/default/grub; then
      info "Обновляю /etc/default/grub"
      sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$flag iommu=pt /" /etc/default/grub
      update-grub >/dev/null
      changed=1
    fi
  else
    warn "Не нашёл ни /etc/kernel/cmdline, ни /etc/default/grub."
  fi

  local mod
  for mod in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
    if ! grep -qx "$mod" /etc/modules 2>/dev/null; then
      echo "$mod" >> /etc/modules
      changed=1
    fi
  done

  if (( changed )); then
    info "Пересобираю initramfs"
    update-initramfs -u -k all >/dev/null 2>&1 || true
    warn "Для активации IOMMU требуется перезагрузка."
    if ask_yes_no "Перезагрузить сейчас?" Y; then
      reboot
    else
      warn "Не забудьте перезагрузить сервер вручную перед установкой VM."
    fi
  else
    ok "IOMMU уже настроен, изменений не требуется."
  fi
}

show_iommu_status() {
  banner
  title "Текущий статус IOMMU / VFIO"

  if grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline 2>/dev/null; then
    ok "IOMMU активен в текущей загрузке."
  else
    warn "IOMMU не активен в текущей загрузке (нужна настройка и перезагрузка)."
  fi

  echo
  say " Загруженные модули VFIO:"
  local found=0
  while read -r mod _; do
    [[ "$mod" == vfio* ]] || continue
    say "  - $mod"
    found=1
  done < <(lsmod)
  (( found )) || warn "  (модули vfio не загружены)"
}

list_iommu_groups() {
  banner
  title "IOMMU-группы PCI-устройств"

  if [[ ! -d /sys/kernel/iommu_groups ]] || [[ -z "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
    warn "Группы IOMMU не видны — похоже, IOMMU ещё не активен (см. пункты 1 и 3)."
    return 0
  fi

  local group dev devs desc count color label
  for group in $(ls /sys/kernel/iommu_groups | sort -n); do
    devs=(/sys/kernel/iommu_groups/"$group"/devices/*)
    count=${#devs[@]}

    if (( count == 1 )); then
      color="$C_OK"; label="можно пробрасывать отдельно"
    else
      color="$C_WARN"; label="общая группа, риск при passthrough"
    fi

    printf '%s[группа %s | %s]%s\n' "$color" "$group" "$label" "$C_RESET"
    for dev in "${devs[@]}"; do
      dev=$(basename "$dev")
      desc=$(lspci -nns "$dev" 2>/dev/null | cut -d' ' -f2-)
      say "    $dev  $desc"
    done
  done

  echo
  ok "Зелёным — группа с одним устройством, безопасна для PCI passthrough."
  warn "Жёлтым — устройство делит IOMMU-группу с другими, пробрасывать рискованно без ACS override."
}

# =====================================================
# Сетевой мост + NIC
# =====================================================
next_free_bridge() {
  local used max=-1 n
  used=$(
    { ip -o link show 2>/dev/null | awk -F': ' '{print $2}'
      [[ -f /etc/network/interfaces ]] && grep -oE '\bvmbr[0-9]+\b' /etc/network/interfaces
    } | grep -E '^vmbr[0-9]+$' | sort -u
  )
  while read -r n; do
    [[ -z "$n" ]] && continue
    n=${n#vmbr}
    (( n > max )) && max=$n
  done <<< "$used"
  echo "vmbr$((max + 1))"
}

next_free_net_slot() {
  local vmid="$1" i=0
  while (( i < 32 )); do
    qm config "$vmid" 2>/dev/null | grep -q "^net$i:" || { echo "net$i"; return 0; }
    ((i++))
  done
  return 1
}

attach_bridge_nic() {
  local vmid="$1" bridge ip_cidr default_bridge iface="/etc/network/interfaces"

  title "Дополнительный мост + VirtIO NIC (опционально)"
  ask_yes_no "Создать Linux Bridge и подключить его к VM?" Y || { info "Пропускаю."; return 0; }

  default_bridge=$(next_free_bridge)
  read -rp " Имя моста [$default_bridge]: " bridge
  bridge=${bridge:-$default_bridge}
  [[ "$bridge" =~ ^vmbr[0-9]+$ ]] || { fail "Имя моста должно быть вида vmbrN."; return 1; }

  read -rp " IP/CIDR моста [192.168.1.5/24]: " ip_cidr
  ip_cidr=${ip_cidr:-192.168.1.5/24}
  [[ "$ip_cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || { fail "Неверный формат IP/CIDR."; return 1; }

  if ip -o -4 addr show | awk '{print $4}' | grep -qx "$ip_cidr"; then
    warn "Такой адрес уже используется в системе."
    ask_yes_no "Всё равно продолжить?" N || { info "Отменено."; return 0; }
  fi

  [[ -f "$iface" ]] || { fail "Не найден $iface."; return 1; }

  if ! grep -Eq "^[[:space:]]*(auto|iface)[[:space:]]+$bridge([[:space:]]|\$)" "$iface"; then
    {
      echo
      echo "auto $bridge"
      echo "iface $bridge inet static"
      echo "    address $ip_cidr"
      echo "    bridge-ports none"
      echo "    bridge-stp off"
      echo "    bridge-fd 0"
    } >> "$iface"
    ok "Мост $bridge добавлен в $iface"
  else
    info "Мост $bridge уже описан в $iface"
  fi

  if command -v ifreload >/dev/null 2>&1; then
    ifreload -a >/dev/null 2>&1 && ok "Сеть применена (ifreload)" || warn "Не удалось применить сеть автоматически."
  else
    systemctl restart networking >/dev/null 2>&1 && ok "Сеть применена (networking.service)" || warn "Не удалось применить сеть автоматически."
  fi

  local slot
  slot=$(next_free_net_slot "$vmid") || { fail "Нет свободного сетевого слота у VM $vmid."; return 1; }
  qm set "$vmid" -"$slot" "virtio,bridge=$bridge" >/dev/null
  ok "NIC $slot подключён к $bridge"
}

# =====================================================
# Установка OpenWrt
# =====================================================
latest_openwrt_version() {
  local listing ver
  listing=$(curl -fsSL "${CURL_OPTS[@]}" https://downloads.openwrt.org/releases/ 2>/dev/null) || return 1
  ver=$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+/"' <<< "$listing" | tr -d '"/' | sort -V | tail -n1)
  [[ -n "$ver" ]] || return 1
  curl -fsSLI "${CURL_OPTS[@]}" \
    "https://downloads.openwrt.org/releases/$ver/targets/x86/64/openwrt-$ver-x86-64-generic-ext4-combined.img.gz" \
    >/dev/null 2>&1 || return 1
  echo "$ver"
}

deploy_openwrt_vm() {
  banner
  title "Установка OpenWrt VM"
  # Очищаем временную папку с образом при ЛЮБОМ выходе из функции —
  # не только при штатном завершении всего скрипта.
  trap 'cleanup_workdir; WORKDIR=""' RETURN

  local ver pick base img
  info "Ищу последнюю стабильную версию OpenWrt"
  if ver=$(latest_openwrt_version); then
    ok "Найдена версия $ver"
  else
    warn "Автоопределение версии не удалось."
    read -rp " Введите версию вручную (например 24.10.2): " ver
    [[ -n "$ver" ]] || { fail "Версия не указана."; return 1; }
  fi
  read -rp " Использовать версию [$ver]: " pick
  ver=${pick:-$ver}

  base="https://downloads.openwrt.org/releases/$ver/targets/x86/64"
  img="openwrt-$ver-x86-64-generic-ext4-combined.img.gz"

  WORKDIR=$(mktemp -d)
  cd "$WORKDIR"

  info "Скачиваю образ и контрольные суммы"
  curl -fL# "${CURL_OPTS[@]}" -o image.img.gz "$base/$img" || { fail "Не удалось скачать образ."; return 1; }
  curl -fsSL "${CURL_OPTS[@]}" -o SHA256SUMS "$base/sha256sums" || { fail "Не удалось скачать SHA256SUMS."; return 1; }

  local expected
  expected=$(awk -v f="$img" '$0 ~ f {print $1}' SHA256SUMS)
  [[ -n "$expected" ]] || { fail "Хэш для $img не найден в SHA256SUMS."; return 1; }
  echo "$expected  image.img.gz" | sha256sum -c - >/dev/null 2>&1 || { fail "SHA256 не совпадает, файл повреждён."; return 1; }
  ok "Контрольная сумма совпала"

  info "Распаковываю образ"
  gunzip -k image.img.gz

  local vmid storage ram disk cores
  vmid=$(prompt_vmid "$(pvesh get /cluster/nextid)")
  storage=$(prompt_storage "$(pvesm status -content images | awk 'NR>1 && $1!="local"{print $1; exit}')")
  cores=$(prompt_uint "Кол-во ядер CPU" 1)
  ram=$(prompt_uint "RAM, МБ" 512)
  disk=$(prompt_uint "Размер диска, МБ" 512)

  info "Создаю VM $vmid"
  qm create "$vmid" \
    -name openwrt \
    -cores "$cores" -memory "$ram" \
    -ostype l26 -cpu host \
    -scsihw virtio-scsi-pci \
    -onboot 1 -tablet 0 \
    -description "OpenWrt $ver (x86_64)"

  pvesm alloc "$storage" "$vmid" "vm-$vmid-disk-0" 4M >/dev/null 2>&1 || true
  qm set "$vmid" -efidisk0 "${storage}:vm-$vmid-disk-0,efitype=4m,size=4M" >/dev/null 2>&1 \
    || qm set "$vmid" -efidisk0 "${storage}:0,efitype=4m,size=4M" >/dev/null

  qm importdisk "$vmid" image.img "$storage" --format raw >/dev/null
  sleep 2

  local diskref
  diskref=$(pvesm list "$storage" | awk -v v="vm-$vmid-disk" '$1 ~ v && $1 !~ /disk-0/{print $1}' | tail -n1)
  [[ -n "$diskref" ]] || { fail "Не нашёл импортированный диск."; return 1; }

  qm set "$vmid" -scsi0 "$diskref" -boot order=scsi0 -bootdisk scsi0 >/dev/null
  qm disk resize "$vmid" scsi0 "${disk}M" >/dev/null
  ok "Диск подключён, размер изменён до ${disk}MB"

  if ! attach_bridge_nic "$vmid"; then
    warn "Мост/NIC не подключены, но VM уже создана — можно донастроить сеть вручную позже."
  fi

  banner
  ok "VM $vmid готова."
  warn "Осталось вручную пробросить PCI-устройство сетевой карты (вкладка Hardware -> Add -> PCI Device, режим Raw Device, включить All Functions и ROM-Bar)."
  say  "Затем запустите VM: ${C_OK}qm start $vmid${C_RESET}"

  finish_run
}

finish_run() {
  cleanup_workdir
  WORKDIR=""
  if ask_yes_no "Удалить файл скрипта ($SELF)?" N; then
    rm -f -- "$SELF"
    ok "Скрипт удалён."
  fi
  exit 0
}

# =====================================================
# MAIN
# =====================================================
require_root
require_pve
require_local_file

while true; do
  banner
  say " 1) Настроить IOMMU"
  say " 2) Установить OpenWrt VM"
  say " 3) Статус IOMMU / VFIO"
  say " 4) IOMMU-группы PCI-устройств (кандидаты на passthrough)"
  say " 0) Выход"
  echo
  read -rp " Выбор: " choice
  case "$choice" in
    1) configure_iommu || true ;;
    2) deploy_openwrt_vm || true ;;
    3) show_iommu_status || true ;;
    4) list_iommu_groups || true ;;
    0) exit 0 ;;
    *) warn "Некорректный выбор." ;;
  esac
  echo
  read -rp " Enter для возврата в меню..." _
done
