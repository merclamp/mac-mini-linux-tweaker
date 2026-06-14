# Mac Mini Arch Tweaker

[![ru](https://img.shields.io/badge/lang-ru-blue.svg)](README.ru.md)

Tweaker script to optimize Arch Linux (and forks) for Mac Mini Late with integrated Intel graphics.

Supported models are detected automatically via DMI:
- **Mac Mini Late 2012** — Macmini6,x — Ivy Bridge / Intel HD 4000
- **Mac Mini Late 2014** — Macmini7,x — Haswell / Intel HD 5000
- **Mac Mini Late 2018** — Macmini8,x — Coffee Lake / Intel UHD 630

## Quick Start

```bash
git clone https://github.com/anomalyco/mac-mini-linux-tweaker.git
cd mac-mini-linux-tweaker
chmod +x tweak.sh

# Preview without changes
sudo ./tweak.sh --dry-run

# Apply everything (kernel chosen interactively)
sudo ./tweak.sh

# Apply with a specific kernel
sudo ./tweak.sh --kernel zen
sudo ./tweak.sh --kernel cachyos
```

## Kernel Choice

Without the `--kernel` flag, the script will ask in the console. You can also specify upfront:

| Flag | Kernel | Source | Notes |
|------|--------|--------|-------|
| `--kernel zen` | `linux-zen` | Official Arch repos | MuQSS scheduler, preempt, BFQ, stability |
| `--kernel cachyos` | `linux-cachyos` | CachyOS repos (added automatically) | `-O3`, BORE/LRNG, aggressive performance patches |

When choosing CachyOS, the script will download `cachyos-keyring`, `cachyos-mirrorlist` and add the repo to `/etc/pacman.conf` automatically.

## What It Does

| # | Module | Details |
|---|--------|---------|
| 1 | **Detection** | Mac Mini model via DMI, GPU via lspci (Intel/NVIDIA/AMD) |
| 2 | **Vulkan** | `mesa`, `vulkan-intel`/`radeon`/`nvidia`, `lib32-*`, `vulkan-tools` |
| 3 | **Kernel** | `linux-zen` or `linux-cachyos` (performance), old `linux` removed |
| 4 | **Zram** | `systemd-zram-generator`, 50% RAM, `zstd` compression, priority 100 |
| 5 | **Kernel params** | `i915.enable_fbc=1 enable_guc=2 fastboot=1 mitigations=off` |
| 6 | **CPU** | `cpupower` → governor `performance`, Intel P-state |
| 7 | **I/O** | `mq-deadline` for SSD, `bfq` for HDD (udev rule) |
| 8 | **sysctl** | swappiness=10, TCP BBR, net buffers, inotify, file-max |
| 9 | **TRIM** | `fstrim.timer` for SSD |
| 10 | **VA-API** | `intel-media-driver`, `libva-intel-driver`, hardware video decoding |
| 11 | **WiFi** | Broadcom → `broadcom-wl-dkms` or `b43-firmware` auto |
| 12 | **Audio** | Cirrus Logic CS420x → modprobe fix |
| 13 | **VGA** | `xf86-video-intel`, `fbcon` in initramfs, Terminus font in tty |
| 14 | **Microcode** | `intel-ucode` + initramfs rebuild |

## Options

```
--dry-run           Show what will be done (no real changes)
--force             Skip confirmation prompt
--kernel zen|..     Kernel choice: zen (default) or cachyos
--help              Show this help
```

## Backups & Rollback

All modified configs are saved to `/var/backups/mac-tweaker/<datetime>/`. The log is written to `/var/log/mac-tweaker.log`.

To roll back kernel parameters — remove the `# mac-tweaker` line from `/etc/default/grub` and rebuild GRUB:

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

## Requirements

- Arch Linux or fork (EndeavourOS, Manjaro, CachyOS, …)
- `pacman`
- Root access

## After Installation

A reboot is recommended to activate all changes (Zram, kernel parameters, initramfs).
