#!/usr/bin/env bash
# OPNsense-on-Proxmox helper: provisions an OPNsense VM (x86_64) from the
# official "nano" image (serial console build, meant for headless use).
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
|              OPNsense Installer for Proxmox            |
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

require_tools() {
  local missing=() cmd
  for cmd in bunzip2 qemu-img; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "Не хватает утилит: ${missing[*]}"
    exit 1
  fi
}

require_local_file() {
  if [[ ! -f "$SELF" ]]; then
    banner
    fail "Похоже, скрипт запущен через 'curl | bash'."
    say  "Сначала сохраните файл, затем запустите его напрямую:"
    say  "  ${C_OK}wget -qO opnsense-pve-installer.sh <ссылка> && bash opnsense-pve-installer.sh${C_RESET}"
    exit 1
  fi
}

# =====================================================
# Сетевой мост + NIC (второй интерфейс для LAN)
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

  title "Дополнительный мост + VirtIO NIC для LAN (опционально)"
  ask_yes_no "Создать Linux Bridge и подключить его к VM как второй интерфейс?" Y || { info "Пропускаю."; return 0; }

  default_bridge=$(next_free_bridge)
  read -rp " Имя моста [$default_bridge]: " bridge
  bridge=${bridge:-$default_bridge}
  [[ "$bridge" =~ ^vmbr[0-9]+$ ]] || { fail "Имя моста должно быть вида vmbrN."; return 1; }

  read -rp " IP/CIDR моста [192.168.1.1/24]: " ip_cidr
  ip_cidr=${ip_cidr:-192.168.1.1/24}
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
  ok "NIC $slot (LAN) подключён к $bridge"
}

# =====================================================
# Установка OPNsense
# =====================================================
latest_opnsense_version() {
  local listing ver
  listing=$(curl -fsSL "${CURL_OPTS[@]}" https://pkg.opnsense.org/releases/mirror/ 2>/dev/null) || return 1
  ver=$(grep -oE 'OPNsense-[0-9]+\.[0-9]+-nano-amd64\.img\.bz2' <<< "$listing" \
        | grep -oE '[0-9]+\.[0-9]+' | sort -V | tail -n1)
  [[ -n "$ver" ]] || return 1
  echo "$ver"
}

deploy_opnsense_vm() {
  banner
  title "Установка OPNsense VM"
  trap 'cleanup_workdir; WORKDIR=""' RETURN

  local ver pick base img
  info "Ищу последнюю версию OPNsense (nano image)"
  if ver=$(latest_opnsense_version); then
    ok "Найдена версия $ver"
  else
    warn "Автоопределение версии не удалось."
    read -rp " Введите версию вручную (например 26.7): " ver
    [[ -n "$ver" ]] || { fail "Версия не указана."; return 1; }
  fi
  read -rp " Использовать версию [$ver]: " pick
  ver=${pick:-$ver}

  base="https://pkg.opnsense.org/releases/mirror"
  img="OPNsense-$ver-nano-amd64.img.bz2"

  WORKDIR=$(mktemp -d)
  cd "$WORKDIR"

  info "Скачиваю образ и контрольные суммы"
  curl -fL# "${CURL_OPTS[@]}" -o image.img.bz2 "$base/$img" || { fail "Не удалось скачать образ."; return 1; }
  curl -fsSL "${CURL_OPTS[@]}" -o checksums.sha256 "$base/OPNsense-$ver-checksums-amd64.sha256" \
    || { fail "Не удалось скачать checksums."; return 1; }

  local expected actual
  expected=$(grep -F "($img)" checksums.sha256 | sed -E 's/.*= *//')
  [[ -n "$expected" ]] || { fail "Хэш для $img не найден в checksums."; return 1; }
  actual=$(sha256sum image.img.bz2 | awk '{print $1}')
  [[ "$expected" == "$actual" ]] || { fail "SHA256 не совпадает, файл повреждён."; return 1; }
  ok "Контрольная сумма совпала"

  info "Распаковываю образ"
  bunzip2 -k image.img.bz2

  local vmid storage ram disk cores disk_gb
  vmid=$(prompt_vmid "$(pvesh get /cluster/nextid)")
  storage=$(prompt_storage "$(pvesm status -content images | awk 'NR>1 && $1!="local"{print $1; exit}')")
  cores=$(prompt_uint "Кол-во ядер CPU" 2)
  ram=$(prompt_uint "RAM, МБ" 2048)
  disk_gb=$(prompt_uint "Размер диска, ГБ (образ будет расширен)" 8)

  info "Расширяю образ диска до ${disk_gb}G"
  qemu-img resize -f raw image.img "${disk_gb}G" >/dev/null

  info "Создаю VM $vmid"
  qm create "$vmid" \
    -name opnsense \
    -cores "$cores" -memory "$ram" \
    -ostype other -cpu host \
    -scsihw virtio-scsi-pci \
    -net0 virtio,bridge=vmbr0 \
    -onboot 1 -tablet 0 \
    -description "OPNsense $ver (x86_64, nano/serial)"

  qm importdisk "$vmid" image.img "$storage" --format raw >/dev/null

  local diskref
  diskref=$(pvesm list "$storage" | awk -v v="vm-$vmid-disk" '$1 ~ v {print $1}' | tail -n1)
  [[ -n "$diskref" ]] || { fail "Не нашёл импортированный диск."; return 1; }

  qm set "$vmid" -virtio0 "$diskref" >/dev/null
  qm set "$vmid" -serial0 socket -vga serial0 >/dev/null
  qm set "$vmid" -boot c -bootdisk virtio0 >/dev/null
  ok "Диск подключён (virtio0), консоль переведена в serial-режим"

  attach_bridge_nic "$vmid" || warn "LAN-мост не подключён, но VM уже создана — можно донастроить сеть вручную позже."

  banner
  ok "VM $vmid готова."
  say  "Консоль VM — serial (не VGA): откройте её через ${C_OK}qm terminal $vmid${C_RESET} или вкладку Console в Proxmox."
  say  "Логин по умолчанию: ${C_OK}root / opnsense${C_RESET} — смените пароль сразу после первого входа."
  warn "При первом старте образ сам расширит файловую систему под новый размер диска — это может занять минуту."
  say  "Запустите VM: ${C_OK}qm start $vmid${C_RESET}"

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
require_tools
require_local_file

while true; do
  banner
  say " 1) Установить OPNsense VM"
  say " 0) Выход"
  echo
  read -rp " Выбор: " choice
  case "$choice" in
    1) deploy_opnsense_vm || true ;;
    0) exit 0 ;;
    *) warn "Некорректный выбор." ;;
  esac
  echo
  read -rp " Enter для возврата в меню..." _
done
