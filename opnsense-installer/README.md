# OPNsense Installer for Proxmox VE

Разворачивает OPNsense в Proxmox VE из официального образа `nano`
(предсобранный образ диска для serial-консоли — то же самое, что делает
`openwrt-installer`, только для OPNsense).

## Что делает скрипт

- Находит последнюю версию на `pkg.opnsense.org` (официальный mirror-каталог
  OPNsense — там всегда лежит только актуальный релиз).
- Скачивает `nano`-образ, проверяет SHA256 по официальному checksums-файлу.
- Расширяет образ диска до нужного размера (`qemu-img resize`) — сам
  OPNsense увеличит файловую систему под него при первом запуске.
- Создаёт VM: VMID/storage проверяются на валидность, ядра/RAM/диск —
  на то, что введено число.
- Настраивает VM на **serial-консоль** (`--serial0 socket --vga serial0`) —
  так и задуман `nano`-образ, консоль открывается через `qm terminal <VMID>`
  или вкладку Console в Proxmox, а не через VNC/VGA.
- Опционально добавляет второй интерфейс (Linux Bridge + VirtIO NIC) под LAN.

## Запуск

```bash
wget -qO opnsense-pve-installer.sh https://raw.githubusercontent.com/Mishazx/proxmox-scripts/main/opnsense-installer/opnsense-pve-installer.sh && bash opnsense-pve-installer.sh
```

Запуск через `curl | bash` не поддерживается — скрипту нужен физический
файл на диске.

## После установки

1. Откройте консоль VM: `qm terminal <VMID>` (это serial, не VGA).
2. Логин по умолчанию — `root` / `opnsense`, смените пароль сразу.
3. Настройте интерфейсы (WAN/LAN) через консольное меню OPNsense.
4. Дальше — обычный веб-интерфейс OPNsense по адресу LAN-интерфейса.

## Требования

- Proxmox VE 7.x/8.x, установлены `bunzip2` и `qemu-img` (штатно есть на
  любой ноде Proxmox).
- Минимум ~500 МБ на storage под сжатый образ + место под сам диск VM.
