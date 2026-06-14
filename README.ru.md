# Mac Mini Arch Tweaker

Скрипт-твикер для оптимизации Arch Linux (и форков) под Mac Mini Late со встроенной графикой Intel.

Поддерживаемые модели определяются автоматически по DMI:
- **Mac Mini Late 2012** — Macmini6,x — Ivy Bridge / Intel HD 4000
- **Mac Mini Late 2014** — Macmini7,x — Haswell / Intel HD 5000
- **Mac Mini Late 2018** — Macmini8,x — Coffee Lake / Intel UHD 630

## Быстрый старт

```bash
git clone https://github.com/anomalyco/mac-mini-linux-tweaker.git
cd mac-mini-linux-tweaker
chmod +x tweak.sh

# Предпросмотр без изменений
sudo ./tweak.sh --dry-run

# Применить всё (ядро выбирается интерактивно)
sudo ./tweak.sh

# Применить с конкретным ядром
sudo ./tweak.sh --kernel zen
sudo ./tweak.sh --kernel cachyos
```

## Выбор ядра

Без флага `--kernel` скрипт задаст вопрос в консоли. Можно указать сразу:

| Флаг | Ядро | Источник | Особенности |
|------|------|----------|-------------|
| `--kernel zen` | `linux-zen` | Официальные репы Arch | MuQSS-планировщик, preempt, BFQ, стабильность |
| `--kernel cachyos` | `linux-cachyos` | Репы CachyOS (добавляются авто) | `-O3`, BORE/LRNG, агрессивные патчи производительности |

При выборе CachyOS скрипт сам скачает `cachyos-keyring`, `cachyos-mirrorlist` и пропишет репозиторий в `/etc/pacman.conf`.

## Что делает

| # | Модуль | Детали |
|---|--------|--------|
| 1 | **Обнаружение** | Модель Mac Mini по DMI, GPU через lspci (Intel/NVIDIA/AMD) |
| 2 | **Vulkan** | `mesa`, `vulkan-intel`/`radeon`/`nvidia`, `lib32-*`, `vulkan-tools` |
| 3 | **Ядро** | `linux-zen` или `linux-cachyos` (производительное), старое `linux` удаляется |
| 4 | **Zram** | `systemd-zram-generator`, 50% RAM, сжатие `zstd`, priority 100 |
| 5 | **Параметры ядра** | `i915.enable_fbc=1 enable_guc=2 fastboot=1 mitigations=off` |
| 6 | **CPU** | `cpupower` → governor `performance`, Intel P-state |
| 7 | **I/O** | `mq-deadline` для SSD, `bfq` для HDD (udev-правило) |
| 8 | **sysctl** | swappiness=10, TCP BBR, буферы сети, inotify, file-max |
| 9 | **TRIM** | `fstrim.timer` для SSD |
| 10 | **VA-API** | `intel-media-driver`, `libva-intel-driver`, аппаратное декодирование |
| 11 | **WiFi** | Broadcom → `broadcom-wl-dkms` или `b43-firmware` авто |
| 12 | **Звук** | Cirrus Logic CS420x → modprobe-фикс |
| 13 | **VGA** | `xf86-video-intel`, `fbcon` в initramfs, Terminus-шрифт в tty |
| 14 | **Микрокод** | `intel-ucode` + пересборка initramfs |

## Опции

```
--dry-run           Показать, что будет сделано (без реальных изменений)
--force             Не запрашивать подтверждение
--kernel zen|..     Выбор ядра: zen (по умолчанию) или cachyos
--help              Справка
```

## Бэкапы и откат

Все изменяемые конфиги сохраняются в `/var/backups/mac-tweaker/<дата-время>/`. Лог пишется в `/var/log/mac-tweaker.log`.

Для отката параметров ядра — удали строку `# mac-tweaker` из `/etc/default/grub` и пересобери GRUB:

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

## Требования

- Arch Linux или форк (EndeavourOS, Manjaro, CachyOS, …)
- `pacman`
- root-доступ

## После установки

Рекомендуется перезагрузка для активации всех изменений (Zram, параметры ядра, initramfs).
