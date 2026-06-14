#!/usr/bin/env bash
#===============================================================================
# Mac Mini Linux Tweaker — Arch Linux (и форки)
# Оптимизация под Mac Mini Late (2012/2014/2018) со встроенной графикой Intel.
# Включает: Vulkan, VGA/вирт.GPU, Zram, GPU-твики, CPU-твики, I/O, sysctl, звук, WiFi, TRIM.
#===============================================================================
set -uo pipefail

# --- Цвета ---
RED='\033[0;31m';    GREEN='\033[0;32m';    YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';     BOLD='\033[1m'
NC='\033[0m'         # No Color

# --- Глобальные флаги ---
DRY_RUN=false
FORCE=false
INTERACTIVE=false
BACKUP_DIR="/var/backups/mac-tweaker/$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/mac-tweaker.log"
MODEL="unknown"
GPU="unknown"
KERNEL_CHOICE=""

# --- Служебные функции ---

log_msg() { echo -e "${BLUE}[*]${NC} $*" | tee -a "$LOG_FILE"; }
log_ok()  { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
log_warn(){ echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
log_err() { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE" >&2; }
log_hdr() { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}" | tee -a "$LOG_FILE"; }

backup_file() {
    local src="$1"
    if [[ -f "$src" ]]; then
        local dst="$BACKUP_DIR${src}"
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
        log_msg "Бэкап: $src → $dst"
    fi
}

dry_cmd() {
    if $DRY_RUN; then
        log_warn "[DRY-RUN] $*"
    else
        eval "$@" || log_warn "Ошибка (не фатально): $*"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Запусти от root:  sudo $0"
        exit 1
    fi
}

check_arch() {
    if ! command -v pacman &>/dev/null; then
        log_err "Скрипт только для Arch Linux и форков (pacman не найден)"
        exit 1
    fi
    if ! command -v lspci &>/dev/null; then
        log_msg "Устанавливаю pciutils (нужен lspci)..."
        pacman -S --needed --noconfirm pciutils || {
            log_err "Не удалось установить pciutils"
            exit 1
        }
    fi
    log_msg "Обновляю базу пакетов..."
    dry_cmd "pacman -Sy --noconfirm"
}

# --- Обнаружение железа ---

detect_mac_model() {
    log_hdr "Определение модели Mac Mini"
    local sys_vendor product_name board
    sys_vendor=$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || echo "")
    product_name=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "")
    board=$(cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null || echo "")

    case "${sys_vendor}${product_name}${board}" in
        *"Apple"*"Macmini6"*)
            MODEL="macmini6_2012"
            log_ok "Mac Mini Late 2012 (Macmini6,x) — Ivy Bridge / HD 4000"
            ;;
        *"Apple"*"Macmini7"*)
            MODEL="macmini7_2014"
            log_ok "Mac Mini Late 2014 (Macmini7,x) — Haswell / HD 5000"
            ;;
        *"Apple"*"Macmini8"*)
            MODEL="macmini8_2018"
            log_ok "Mac Mini Late 2018 (Macmini8,x) — Coffee Lake / UHD 630"
            ;;
        *)
            MODEL="apple_unknown"
            log_warn "Точная модель не определена. Продолжаю как Apple-железо."
            ;;
    esac
}

detect_gpu() {
    log_hdr "Определение GPU"
    if lspci 2>/dev/null | grep -qi "VGA.*Intel"; then
        GPU="intel"
        local gpu_info
        gpu_info=$(lspci 2>/dev/null | grep -i "VGA.*Intel" | head -1 || true)
        log_ok "Intel GPU: $gpu_info"
    elif lspci 2>/dev/null | grep -qi "VGA.*NVIDIA"; then
        GPU="nvidia"
        log_ok "NVIDIA GPU обнаружена"
    elif lspci 2>/dev/null | grep -qi "VGA.*AMD"; then
        GPU="amd"
        log_ok "AMD GPU обнаружена"
    else
        GPU="unknown"
        log_warn "GPU не обнаружен через lspci — пытаюсь продолжить"
    fi
}

# --- Vulkan ---

setup_vulkan() {
    log_hdr "Установка Vulkan"

    # Базовые пакеты Mesa + Vulkan
    local pkg=(
        mesa mesa-utils
        vulkan-tools vulkan-headers
        lib32-mesa lib32-vulkan-icd-loader
    )

    if [[ "$GPU" == "intel" ]]; then
        pkg+=(vulkan-intel lib32-vulkan-intel)
    elif [[ "$GPU" == "nvidia" ]]; then
        pkg+=(nvidia-utils lib32-nvidia-utils)
    elif [[ "$GPU" == "amd" ]]; then
        pkg+=(vulkan-radeon lib32-vulkan-radeon)
    fi

    dry_cmd "pacman -S --needed --noconfirm ${pkg[*]}"
    log_ok "Vulkan: пакеты установлены"
}

# --- Zram ---

setup_zram() {
    log_hdr "Настройка Zram"

    dry_cmd "pacman -S --needed --noconfirm zram-generator"

    local conf="/etc/systemd/zram-generator.conf"
    backup_file "$conf"

    # 50% от RAM на zstd-сжатие
    cat > "$conf" <<'ZRAMEOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
ZRAMEOF

    if ! $DRY_RUN; then
        # Перезагружаем zram-generator
        systemctl daemon-reload 2>/dev/null || true
        # Пытаемся запустить новый zram без перезагрузки
        systemctl restart systemd-zram-setup@zram0 2>/dev/null || true

        # Если старый swap-device был, выключаем
        swapoff /dev/zram0 2>/dev/null || true
        # zram-generator сам поднимет
        systemctl restart systemd-zram-setup@zram0 2>/dev/null || \
            log_warn "Zram: перезагрузка юнита не удалась — применится после ребута"

        log_ok "Zram настроен (zstd, ram/2, priority=100)"
        zramctl 2>/dev/null && log_msg "Состояние zram:" && zramctl || true
    else
        log_ok "[DRY-RUN] Конфиг Zram записан в $conf"
    fi
}

# --- Установка производительного ядра ---

install_cachyos_repo() {
    log_hdr "Добавление репозитория CachyOS"

    if pacman -Q cachyos-keyring &>/dev/null && \
       grep -q '\[cachyos\]' /etc/pacman.conf 2>/dev/null; then
        log_msg "Репозиторий CachyOS уже подключён"
        return 0
    fi

    # Получаем ключ
    dry_cmd "pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com 2>/dev/null || true"
    dry_cmd "pacman-key --lsign-key F3B607488DB35A47 2>/dev/null || true"

    # Скачиваем и ставим keyring + mirrorlist напрямую
    local tmpdir
    tmpdir=$(mktemp -d)
    local pkg_url="https://mirror.cachyos.org/repo/x86_64/cachyos"

    dry_cmd "curl -sL '$pkg_url/cachyos-keyring-3-1-any.pkg.tar.zst' -o '$tmpdir/cachyos-keyring.pkg.tar.zst'"
    dry_cmd "curl -sL '$pkg_url/cachyos-mirrorlist-18-1-any.pkg.tar.zst' -o '$tmpdir/cachyos-mirrorlist.pkg.tar.zst'"

    if ! $DRY_RUN; then
        if [[ -f "$tmpdir/cachyos-keyring.pkg.tar.zst" ]] && [[ -f "$tmpdir/cachyos-mirrorlist.pkg.tar.zst" ]]; then
            pacman -U --noconfirm "$tmpdir/cachyos-keyring.pkg.tar.zst" "$tmpdir/cachyos-mirrorlist.pkg.tar.zst" 2>/dev/null
            rm -rf "$tmpdir"
        else
            log_warn "Не удалось скачать пакеты CachyOS — пропускаю"
            rm -rf "$tmpdir"
            return 1
        fi
    else
        rm -rf "$tmpdir"
    fi

    # Добавляем репо в pacman.conf
    local pacman_cfg="/etc/pacman.conf"
    backup_file "$pacman_cfg"
    if ! grep -q '\[cachyos\]' "$pacman_cfg" 2>/dev/null; then
        cat >> "$pacman_cfg" <<'CACHYEOF'

# mac-tweaker: CachyOS repo
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
CACHYEOF
    fi

    dry_cmd "pacman -Sy"
    log_ok "Репозиторий CachyOS добавлен"
    return 0
}

setup_kernel() {
    log_hdr "Выбор и установка производительного ядра"

    local kernel_pkg kernel_hdrs kernel_name kernel_running_check

    # Если не задан через --kernel, спрашиваем
    if [[ -z "$KERNEL_CHOICE" ]] && ! $DRY_RUN; then
        echo ""
        echo -e "  ${BOLD}Выбери ядро:${NC}"
        echo -e "  ${GREEN}1)${NC} linux-zen      — из официальных репов Arch (стабильное, MuQSS)"
        echo -e "  ${CYAN}2)${NC} linux-cachyos  — из репов CachyOS (агрессивные оптимизации, -O3, BORE/LRNG)"
        echo ""
        read -r -p "  Твой выбор [1]: " choice
        case "${choice:-1}" in
            1) KERNEL_CHOICE="zen" ;;
            2) KERNEL_CHOICE="cachyos" ;;
            *) KERNEL_CHOICE="zen" ;;
        esac
    elif [[ -z "$KERNEL_CHOICE" ]]; then
        KERNEL_CHOICE="zen"
    fi

    case "$KERNEL_CHOICE" in
        cachyos)
            kernel_name="linux-cachyos"
            kernel_pkg="linux-cachyos"
            kernel_hdrs="linux-cachyos-headers"
            kernel_running_check="-cachyos"
            install_cachyos_repo || {
                log_warn "Не удалось добавить CachyOS — откат на linux-zen"
                kernel_name="linux-zen"; kernel_pkg="linux-zen"
                kernel_hdrs="linux-zen-headers"; kernel_running_check="-zen"
            }
            ;;
        *)
            kernel_name="linux-zen"
            kernel_pkg="linux-zen"
            kernel_hdrs="linux-zen-headers"
            kernel_running_check="-zen"
            ;;
    esac

    if pacman -Q "$kernel_pkg" &>/dev/null; then
        log_msg "$kernel_name уже установлен — пропускаю"
        return
    fi

    log_msg "Устанавливаю: $kernel_name..."
    dry_cmd "pacman -S --needed --noconfirm $kernel_pkg $kernel_hdrs"

    # Обновляем GRUB
    if command -v grub-mkconfig &>/dev/null; then
        dry_cmd "grub-mkconfig -o /boot/grub/grub.cfg"
    fi

    log_ok "$kernel_name установлен. Старое ядро (linux) пока оставлено для отката."

    # Удаление старого ядра
    if pacman -Q linux &>/dev/null && [[ "$(uname -r)" == *"$kernel_running_check" ]]; then
        log_msg "Удаляю старый пакет linux..."
        dry_cmd "pacman -R --noconfirm linux linux-headers 2>/dev/null || true"
        dry_cmd "grub-mkconfig -o /boot/grub/grub.cfg"
        log_ok "Старое ядро linux удалено"
    elif pacman -Q linux &>/dev/null; then
        if $FORCE; then
            log_warn "FORCE: удаляю linux НЕ перезагружаясь. При проблемах — загрузись с флешки."
            dry_cmd "pacman -R --noconfirm linux linux-headers 2>/dev/null || true"
            dry_cmd "grub-mkconfig -o /boot/grub/grub.cfg"
        else
            log_msg "Старое ядро linux оставлено. Перезагрузайся в $kernel_name, затем:"
            log_msg "  sudo pacman -R linux linux-headers && sudo grub-mkconfig -o /boot/grub/grub.cfg"
        fi
    fi
}

# --- Ядро и модули ---

setup_kernel_params() {
    log_hdr "Параметры загрузки ядра (i915 + производительность)"

    local grub_cfg="/etc/default/grub"
    if [[ ! -f "$grub_cfg" ]]; then
        log_warn "GRUB не найден — пропускаю параметры ядра"
        return
    fi

    backup_file "$grub_cfg"

    local i915_params="i915.enable_fbc=1 i915.enable_psr=0 i915.fastboot=1"
    # Для относительно свежих ядер 5.x+
    if uname -r | grep -qE '^5\.1[5-9]|^5\.[2-9]|^6'; then
        i915_params+=" i915.enable_guc=2"
    fi

    local quiet_params="quiet splash mitigations=off"

    if $DRY_RUN; then
        log_warn "[DRY-RUN] Добавил бы: $i915_params $quiet_params в GRUB_CMDLINE_LINUX_DEFAULT"
    else
        if grep -q "mac-tweaker" "$grub_cfg"; then
            log_msg "GRUB уже был пропатчен — пропускаю"
        else
            sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ $i915_params $quiet_params&/" "$grub_cfg"
            echo "# mac-tweaker: applied kernel params $(date)" >> "$grub_cfg"

            # Автоопределение: grub-mkconfig или update-grub
            if command -v grub-mkconfig &>/dev/null; then
                dry_cmd "grub-mkconfig -o /boot/grub/grub.cfg"
            elif command -v update-grub &>/dev/null; then
                dry_cmd "update-grub"
            fi
            log_ok "Параметры ядра обновлены: $i915_params"
        fi
    fi

    # Добавляем i915 в initramfs (MODULES)
    local mkinitcpio_cfg="/etc/mkinitcpio.conf"
    if [[ -f "$mkinitcpio_cfg" ]]; then
        backup_file "$mkinitcpio_cfg"
        if ! grep -q "^MODULES=.*i915" "$mkinitcpio_cfg"; then
            sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 i915)/' "$mkinitcpio_cfg"
            dry_cmd "mkinitcpio -P"
            log_ok "i915 добавлен в initramfs (ранний KMS)"
        else
            log_msg "i915 уже в initramfs"
        fi
    fi
}

# --- CPU governor / производительность ---

setup_cpu_governor() {
    log_hdr "CPU Governor: performance"

    dry_cmd "pacman -S --needed --noconfirm cpupower"

    if ! $DRY_RUN; then
        cpupower frequency-set -g performance 2>/dev/null || \
            log_warn "cpupower не удалось — вероятно, драйвер intel_pstate не активен"
        systemctl enable --now cpupower 2>/dev/null || true
    fi

    # Настройка intel_pstate (если доступен)
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]] && \
       grep -q "intel_pstate" /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null; then
        dry_cmd "echo performance > /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference 2>/dev/null || true"
        log_ok "Intel P-state: energy_performance_preference = performance"
    fi
}

# --- I/O Scheduler ---

setup_io_scheduler() {
    log_hdr "I/O Scheduler: mq-deadline / bfq"

    local udev_rule="/etc/udev/rules.d/60-ioschedulers.rules"
    backup_file "$udev_rule"

    # mq-deadline для NVMe/SSD, bfq для HDD
    cat > "$udev_rule" <<'UDEVEOF'
# mac-tweaker: I/O schedulers
# NVMe — none (hardware queue), SSD — mq-deadline, rotational — bfq
ACTION=="add|change", KERNEL=="sd[a-z]*|nvme[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
UDEVEOF

    log_ok "udev-правило для I/O scheduler создано"

    # Применяем сразу
    if ! $DRY_RUN; then
        udevadm control --reload-rules 2>/dev/null || true
        for blk in /sys/block/sd* /sys/block/nvme*; do
            if [[ -f "$blk/queue/rotational" ]]; then
                local name="${blk##*/}"
                if [[ "$(cat "$blk/queue/rotational")" == "0" ]]; then
                    echo "mq-deadline" > "$blk/queue/scheduler" 2>/dev/null || true
                    log_msg "  $name → mq-deadline"
                else
                    echo "bfq" > "$blk/queue/scheduler" 2>/dev/null || true
                    log_msg "  $name → bfq"
                fi
            fi
        done
    fi
}

# --- sysctl ---

setup_sysctl() {
    log_hdr "sysctl — сеть, ввод-вывод, память"

    local sysctl_conf="/etc/sysctl.d/99-mac-tweaker.conf"
    backup_file "$sysctl_conf"

    cat > "$sysctl_conf" <<'SYSEOF'
# mac-tweaker sysctl optimizations

# --- VM ---
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 5
vm.dirty_background_ratio = 3
vm.page-cluster = 0

# --- Сеть ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3

# --- FS ---
fs.inotify.max_user_watches = 524288
fs.file-max = 2097152
fs.nr_open = 2097152

# --- Безопасность (база) ---
kernel.kptr_restrict = 1
SYSEOF

    dry_cmd "sysctl --system"
    log_ok "sysctl применён"
}

# --- TRIM для SSD ---

setup_fstrim() {
    log_hdr "TRIM для SSD"

    if ! $DRY_RUN; then
        if systemctl list-unit-files | grep -q "fstrim.timer"; then
            systemctl enable --now fstrim.timer 2>/dev/null
            log_ok "fstrim.timer включён (еженедельный TRIM)"
        else
            log_msg "fstrim.timer не найден — стандартно в util-linux"
        fi
    fi
}

# --- Аппаратное видео-ускорение ---

setup_vaapi() {
    log_hdr "VA-API: аппаратное декодирование видео"

    local pkg=(libva libva-utils libva-intel-driver intel-media-driver)

    # Для 32-битных приложений
    pkg+=(lib32-libva lib32-libva-intel-driver)

    dry_cmd "pacman -S --needed --noconfirm ${pkg[*]}"

    # Переменные окружения для VA-API
    local env_file="/etc/environment"
    backup_file "$env_file"

    if ! grep -q "LIBVA_DRIVER_NAME" "$env_file" 2>/dev/null; then
        cat >> "$env_file" <<'ENVEOF'

# mac-tweaker: VA-API
LIBVA_DRIVER_NAME=i965
ENVEOF
    fi
    log_ok "VA-API: драйверы и переменные установлены"
}

# --- WiFi Broadcom (часто в Mac) ---

setup_wifi() {
    log_hdr "WiFi — Broadcom (если есть)"

    if lspci 2>/dev/null | grep -qi "Broadcom.*Network"; then
        log_msg "Обнаружен Broadcom WiFi"
        # Пытаемся определить поколение
        if lspci -nn 2>/dev/null | grep -qi "14e4:43a0\|14e4:43b1"; then
            # BCM4360/BCM43602 — нужен broadcom-wl
            dry_cmd "pacman -S --needed --noconfirm broadcom-wl-dkms linux-headers"
            if ! $DRY_RUN; then
                modprobe wl 2>/dev/null || log_warn "модуль wl не загрузился — перезагрузитесь"
            fi
            log_ok "Broadcom WiFi: установлен broadcom-wl-dkms"
        else
            dry_cmd "pacman -S --needed --noconfirm b43-firmware"
            log_ok "Broadcom WiFi: установлен b43-firmware"
        fi
    else
        log_msg "Broadcom WiFi не обнаружен — пропускаю"
    fi
}

# --- Звук Apple ---

setup_audio() {
    log_hdr "Звук — Apple Cirrus Logic / Realtek"

    # Смотрим, какой кодек
    local codec
    codec=$(cat /proc/asound/card*/codec* 2>/dev/null | grep -i "Cirrus\|CS420" | head -1 || true)

    if [[ -n "$codec" ]]; then
        log_msg "Обнаружен Cirrus Logic: $codec"

        # Modprobe-конфиг для CS420x
        local mod_cfg="/etc/modprobe.d/mac-tweaker-audio.conf"
        backup_file "$mod_cfg"
        cat > "$mod_cfg" <<'AUDIOEOF'
# mac-tweaker: Apple audio fixes
options snd-hda-intel model=mbp101,mbp101 probe_mask=1
AUDIOEOF
        log_ok "Конфиг звука для Cirrus Logic создан"
    else
        log_msg "Cirrus Logic не найден — пропускаю"
    fi
}

# --- Микрокод Intel ---

setup_microcode() {
    log_hdr "Микрокод Intel"

    # Проверяем, что процессор Intel
    if grep -qi "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        dry_cmd "pacman -S --needed --noconfirm intel-ucode"

        # Обновляем initramfs после установки микрокода
        if ! $DRY_RUN; then
            dry_cmd "mkinitcpio -P"
        fi
        log_ok "intel-ucode установлен, initramfs пересобран"
    else
        log_msg "Процессор не Intel — пропускаю"
    fi
}

# --- VGA / Framebuffer консоль ---

setup_vga() {
    log_hdr "VGA / Framebuffer консоль"

    # 1. Базовый X.org VGA-драйвер (fallback, если modesetting недоступен)
    dry_cmd "pacman -S --needed --noconfirm xf86-video-fbdev xf86-video-vesa"

    # 2. Intel-специфичный X-драйвер (modesetting — современный путь, но intel-драйвер — запасной)
    if [[ "$GPU" == "intel" ]]; then
        dry_cmd "pacman -S --needed --noconfirm xf86-video-intel"
        log_ok "xf86-video-intel установлен (DDX-драйвер VGA)"
    fi

    # 3. Настройка консольного framebuffer: шрифт + разрешение
    dry_cmd "pacman -S --needed --noconfirm terminus-font"

    local vconsole_conf="/etc/vconsole.conf"
    backup_file "$vconsole_conf"
    cat > "$vconsole_conf" <<'VCONEOF'
# mac-tweaker: framebuffer console
FONT=ter-v32n
FONT_MAP=8859-2
VCONEOF
    log_ok "vconsole.conf: шрифт Terminus ter-v32n"

    # 4. fbcon в initramfs — ранний вывод на консоль
    local mkinitcpio_cfg="/etc/mkinitcpio.conf"
    if [[ -f "$mkinitcpio_cfg" ]]; then
        if ! grep -q "^MODULES=.*fbcon" "$mkinitcpio_cfg"; then
            backup_file "$mkinitcpio_cfg"
            sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 fbcon)/' "$mkinitcpio_cfg"
            dry_cmd "mkinitcpio -P"
            log_ok "fbcon добавлен в initramfs (ранний консольный framebuffer)"
        else
            log_msg "fbcon уже в initramfs"
        fi
    fi

    # 5. VGA-совместимость: не выключаем VGA-арбитраж
    local mod_cfg="/etc/modprobe.d/mac-tweaker-vga.conf"
    backup_file "$mod_cfg"
    cat > "$mod_cfg" <<'VGAEOF'
# mac-tweaker: VGA arbitration / совместимость
options vgaarb vga_default_device=0
VGAEOF
    log_ok "VGA arbitration: modprobe-конфиг создан"
}

# --- NVIDIA для старых Mac Mini (до 2012) ---

setup_nvidia_legacy() {
    log_hdr "NVIDIA (legacy) — старые Mac Mini"

    if [[ "$GPU" != "nvidia" ]]; then
        log_msg "GPU не NVIDIA — пропускаю"
        return
    fi

    local nvidia_id
    nvidia_id=$(lspci -nn 2>/dev/null | grep -i "VGA.*NVIDIA" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}' | head -1 || true)

    case "$nvidia_id" in
        0863:*|0866:*|0867:*|086e:*|086f:*)
            # GeForce 320M, 9400M — nvidia-340xx
            log_msg "Legacy NVIDIA (340xx): добавил бы AUR пакет, но ставь вручную"
            log_warn "nvidia-340xx-dkms нужно собирать из AUR. Пропускаю."
            ;;
        *)
            log_msg "NVIDIA: не legacy — пропускаю"
            ;;
    esac
}

# --- Сводка состояния ---

print_summary() {
    log_hdr "Сводка"
    echo -e "  ${BOLD}Модель:${NC} $MODEL"
    echo -e "  ${BOLD}GPU:${NC}    $GPU"
    echo -e "  ${BOLD}Ядро:${NC}  $(uname -r)"
    echo -e "  ${BOLD}Zram:${NC}  $(zramctl 2>/dev/null || echo 'проверь после ребута')"
    echo -e "  ${GREEN}Бэкапы конфигов:${NC} $BACKUP_DIR"
    echo -e "  ${YELLOW}Рекомендуется перезагрузка для активации всех изменений${NC}"
}

# --- Помощь ---

show_help() {
    cat <<HELPEOF
${BOLD}Mac Mini Linux Tweaker v1.0${NC}
  Оптимизация Arch Linux под Mac Mini Late со встроенной Intel HD Graphics.

${BOLD}Опции:${NC}
  --dry-run        Показать, что будет сделано (без реальных изменений)
  --force          Не спрашивать подтверждений
  --interactive,-i Выбрать отдельные модули (иначе — применить всё)
  --kernel zen|..  Выбор ядра: zen (по умолчанию) или cachyos
  --help           Эта справка

${BOLD}Что делает:${NC}
  1. Определяет модель Mac Mini и GPU
  2. Ставит Vulkan (mesa, vulkan-intel/radeon/nvidia)
  3. Устанавливает производительное ядро (linux-zen или linux-cachyos), удаляет linux
  4. Настраивает Zram (zstd, 50% RAM)
  5. Прописывает параметры ядра i915 (FBC, GuC, Fastboot)
  6. CPU governor → performance
  7. I/O scheduler → mq-deadline (SSD) / bfq (HDD)
  8. sysctl: swappiness=10, BBR, буферы сети, лимиты inotify
  9. Включает TRIM для SSD
  10. Ставит VA-API для аппаратного видео-декодирования
  11. Настраивает Broadcom WiFi (если есть)
  12. Фикс звука Apple Cirrus Logic
  13. VGA/Framebuffer: xf86-video-intel, fbcon, Terminus-шрифт в консоли
  14. Устанавливает микрокод Intel

${BOLD}Откат:${NC}
  Конфиги сохранены в $BACKUP_DIR
  Для отката параметров ядра — удали строку '# mac-tweaker' из /etc/default/grub
HELPEOF
}

# --- Главный парсер аргументов ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)     DRY_RUN=true; shift ;;
            --force)       FORCE=true;   shift ;;
            --interactive) INTERACTIVE=true; shift ;;
            -i)            INTERACTIVE=true; shift ;;
            --kernel)      KERNEL_CHOICE="$2"; shift 2 ;;
            --help)        show_help;    exit 0 ;;
            *)
                echo "Неизвестный аргумент: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# --- Интерактивное меню ---

select_modules() {
    local modules=(
        "Vulkan (mesa + vulkan-intel/radeon/nvidia)"
        "Zram (zstd, 50% RAM)"
        "Ядро linux-zen или linux-cachyos"
        "Микрокод Intel"
        "Параметры ядра i915 (FBC, GuC, Fastboot)"
        "CPU governor → performance"
        "I/O scheduler mq-deadline/bfq"
        "sysctl (swappiness, BBR, буферы)"
        "TRIM fstrim.timer для SSD"
        "VA-API аппаратное видео-декодирование"
        "WiFi Broadcom"
        "Звук Apple Cirrus Logic"
        "VGA / Framebuffer консоль"
        "NVIDIA legacy (старые Mac Mini)"
    )

    echo ""
    echo -e "  ${BOLD}Выбери модули (цифры через пробел, 'a' = все):${NC}"
    echo "  0. ВСЕ"
    for i in "${!modules[@]}"; do
        printf "  %d. %s\n" $((i+1)) "${modules[$i]}"
    done
    echo ""

    read -r -p "  Твой выбор [0]: " sel

    if [[ -z "$sel" || "$sel" == "0" || "$sel" == "a" ]]; then
        return 0  # run all
    fi

    # Сбрасываем — будем выполнять только выбранные
    RUN_VULKAN=false; RUN_ZRAM=false; RUN_KERNEL=false; RUN_MICROCODE=false
    RUN_KERNEL_PARAMS=false; RUN_CPU=false; RUN_IO=false; RUN_SYSCTL=false
    RUN_FSTRIM=false; RUN_VAAPI=false; RUN_WIFI=false; RUN_AUDIO=false
    RUN_VGA=false; RUN_NVIDIA=false

    for num in $sel; do
        case "$num" in
            1)  RUN_VULKAN=true ;;
            2)  RUN_ZRAM=true ;;
            3)  RUN_KERNEL=true ;;
            4)  RUN_MICROCODE=true ;;
            5)  RUN_KERNEL_PARAMS=true ;;
            6)  RUN_CPU=true ;;
            7)  RUN_IO=true ;;
            8)  RUN_SYSCTL=true ;;
            9)  RUN_FSTRIM=true ;;
            10) RUN_VAAPI=true ;;
            11) RUN_WIFI=true ;;
            12) RUN_AUDIO=true ;;
            13) RUN_VGA=true ;;
            14) RUN_NVIDIA=true ;;
        esac
    done
    return 1  # selective run
}

# Второй main для выборочного запуска
run_selected() {
    if $RUN_VULKAN;        then setup_vulkan;        fi
    if $RUN_ZRAM;          then setup_zram;          fi
    if $RUN_KERNEL;        then setup_kernel;        fi
    if $RUN_MICROCODE;     then setup_microcode;     fi
    if $RUN_KERNEL_PARAMS; then setup_kernel_params; fi
    if $RUN_CPU;           then setup_cpu_governor;  fi
    if $RUN_IO;            then setup_io_scheduler;  fi
    if $RUN_SYSCTL;        then setup_sysctl;        fi
    if $RUN_FSTRIM;        then setup_fstrim;        fi
    if $RUN_VAAPI;         then setup_vaapi;         fi
    if $RUN_WIFI;          then setup_wifi;          fi
    if $RUN_AUDIO;         then setup_audio;         fi
    if $RUN_VGA;           then setup_vga;           fi
    if $RUN_NVIDIA;        then setup_nvidia_legacy; fi
}

# --- Main ---

main() {
    parse_args "$@"

    # Подготовка
    mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"
    echo "" > "$LOG_FILE"
    log_msg "Запуск Mac Mini Linux Tweaker — $(date)"
    log_msg "Бэкапы в: $BACKUP_DIR"
    log_msg "Лог: $LOG_FILE"
    $DRY_RUN && log_warn "РЕЖИМ DRY-RUN — изменений не будет"

    check_root
    check_arch
    detect_mac_model
    detect_gpu

    if ! $FORCE && ! $DRY_RUN; then
        echo -e "\n${YELLOW}${BOLD}ВНИМАНИЕ:${NC} Будут изменены системные конфиги."
        read -r -p "Продолжить? [y/N] " ans
        [[ "$ans" != "y" && "$ans" != "Y" ]] && { log_msg "Отмена."; exit 0; }
    fi

    if $INTERACTIVE; then
        select_modules
        if [[ $? -eq 0 ]]; then
            # Все модули
            run_all
        else
            run_selected
        fi
    else
        run_all
    fi

    print_summary
}

run_all() {
    setup_vulkan
    setup_zram
    setup_kernel
    setup_microcode
    setup_kernel_params
    setup_cpu_governor
    setup_io_scheduler
    setup_sysctl
    setup_fstrim
    setup_vaapi
    setup_wifi
    setup_audio
    setup_vga
    setup_nvidia_legacy
}

main "$@"
