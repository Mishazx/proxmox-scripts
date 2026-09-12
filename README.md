# proxmox-scripts

Набор самостоятельных bash-скриптов для Proxmox VE. Каждый скрипт лежит в
своей папке со своим README — независимая настройка, без общих зависимостей
между скриптами.

## Скрипты

| Папка | Что делает |
|---|---|
| [`openwrt-installer/`](openwrt-installer/README.md) | Настройка IOMMU/VFIO passthrough и установка OpenWrt VM (x86_64) из официального образа |
| [`opnsense-installer/`](opnsense-installer/README.md) | Установка OPNsense VM (x86_64) из официального `nano`-образа (serial-консоль) |
| [`mikrotik-chr-installer/`](mikrotik-chr-installer/README.md) | Установка MikroTik RouterOS CHR (x86_64) из официального raw-образа |

VyOS-инсталлер пока не сделан: бесплатного готового образа для прямого
импорта у VyOS нет (только платная подписка или ISO с интерактивной
установкой) — вернёмся к нему отдельно.

## Требования

Скрипты рассчитаны на Proxmox VE 7.x/8.x и запускаются от `root` на самой
ноде. Подробности — в README конкретного скрипта.
