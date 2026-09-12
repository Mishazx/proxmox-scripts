# MikroTik CHR Installer for Proxmox VE

Разворачивает MikroTik RouterOS **CHR** (Cloud Hosted Router) в Proxmox VE
из официального raw-образа — по той же схеме, что и `openwrt-installer` /
`opnsense-installer`.

## Что делает скрипт

- Находит последнюю версию и её SHA256 прямо на `mikrotik.com/download/chr`
  (MikroTik не публикует отдельный файл с суммой — хэш встроен в саму
  страницу загрузки).
- Скачивает `chr-<версия>.img.zip`, проверяет SHA256, распаковывает.
- Расширяет образ диска до нужного размера (`qemu-img resize`).
- Создаёт VM: VMID/storage проверяются на валидность/занятость,
  ядра/RAM/диск — на то, что введено число.
- Опционально добавляет второй интерфейс (Linux Bridge + VirtIO NIC) под LAN.

## Запуск

```bash
wget -qO mikrotik-chr-pve-installer.sh https://raw.githubusercontent.com/Mishazx/proxmox-scripts/main/mikrotik-chr-installer/mikrotik-chr-pve-installer.sh && bash mikrotik-chr-pve-installer.sh
```

Запуск через `curl | bash` не поддерживается — скрипту нужен физический
файл на диске.

## После установки

1. Логин по умолчанию — `admin` с пустым паролем; RouterOS попросит задать
   новый пароль при первом входе (через консоль VM, WinBox или Web-интерфейс
   по IP LAN-интерфейса).
2. **Лицензия.** Без лицензии CHR работает бессрочно, но с ограничением
   **1 Мбит/с** на исходящий трафик каждого интерфейса — этого достаточно
   для проверки конфигурации, но не для реальной работы роутером. Платная
   лицензия оформляется в личном кабинете на mikrotik.com и активируется
   изнутри RouterOS (`/system license`).

## Требования

- Proxmox VE 7.x/8.x, установлены `unzip` и `qemu-img` (штатно есть на
  любой ноде Proxmox; `unzip` иногда приходится доставить: `apt install unzip`).
- Минимум ~50 МБ на storage под сжатый образ + место под сам диск VM.
