#!/bin/bash
# Setup Arch Linux Workstation with XFCE, Firefox, Claude Code, SSH
# Run this AFTER booting from Arch live USB
#
# This script installs a persistent Arch Linux to a target drive with:
# - XFCE desktop environment
# - Firefox browser
# - Claude Code (Node.js + npm)
# - SSH server and client
# - Development tools (git, vim, etc.)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }
header() { echo -e "\n${CYAN}=== $* ===${NC}\n"; }

# Must be Linux
[[ "$(uname -s)" == "Linux" ]] || die "This script must be run from Linux (Arch live USB)"

# Must be root
[[ $EUID -eq 0 ]] || die "This script must be run as root"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] DEVICE

Install Arch Linux workstation with XFCE, Firefox, Claude Code, and SSH.

Arguments:
    DEVICE          Target device (e.g., /dev/sda, /dev/nvme0n1)
                    Can be the same USB you booted from (will be overwritten)
                    or a different drive

Options:
    -u, --username NAME   Username to create (default: user)
    -h, --hostname NAME   Hostname (default: arch-workstation)
    -t, --timezone TZ     Timezone (default: UTC)
    -l, --locale LOCALE   Locale (default: en_US.UTF-8)
    -s, --swap SIZE       Swap size (default: 4G, 0 to disable)
    -y, --yes             Skip confirmation
    --help                Show this help

Examples:
    # Install to USB drive (same one you booted from or different)
    $(basename "$0") /dev/sda

    # Install with custom settings
    $(basename "$0") -u myuser -h mypc -t America/New_York /dev/sda

    # Install to NVMe drive
    $(basename "$0") /dev/nvme0n1

What gets installed:
    - Base Arch Linux system
    - XFCE desktop environment (minimal)
    - Firefox browser
    - Claude Code (via npm)
    - SSH server (openssh)
    - Development tools (git, vim, base-devel)
    - Network tools (networkmanager, iwd for WiFi)
EOF
    exit 0
}

# Defaults
USERNAME="user"
HOSTNAME="arch-workstation"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
SWAP_SIZE="4G"
SKIP_CONFIRM=0
DEVICE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--username) USERNAME="$2"; shift 2 ;;
        -h|--hostname) HOSTNAME="$2"; shift 2 ;;
        -t|--timezone) TIMEZONE="$2"; shift 2 ;;
        -l|--locale) LOCALE="$2"; shift 2 ;;
        -s|--swap) SWAP_SIZE="$2"; shift 2 ;;
        -y|--yes) SKIP_CONFIRM=1; shift ;;
        --help) usage ;;
        /dev/*) DEVICE="$1"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -z "${DEVICE}" ]] && usage

# Validate device exists
[[ -b "${DEVICE}" ]] || die "Device ${DEVICE} does not exist"

# Safety check - don't write to mounted root
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p$//')
DEV_BASE=$(echo "${DEVICE}" | sed 's/[0-9]*$//' | sed 's/p$//')
if [[ "${DEV_BASE}" == "${ROOT_DEV}" ]] && findmnt -n / | grep -qv "archiso\|airootfs"; then
    die "Cannot install to the currently running system's disk"
fi

header "Arch Linux Workstation Setup"

echo "Configuration:"
echo "  Device:    ${DEVICE}"
echo "  Username:  ${USERNAME}"
echo "  Hostname:  ${HOSTNAME}"
echo "  Timezone:  ${TIMEZONE}"
echo "  Locale:    ${LOCALE}"
echo "  Swap:      ${SWAP_SIZE}"
echo ""

# Show device info
log "Target device:"
lsblk "${DEVICE}"
echo ""

if [[ ${SKIP_CONFIRM} -eq 0 ]]; then
    warn "ALL DATA ON ${DEVICE} WILL BE ERASED!"
    read -p "Type 'INSTALL' to continue: " confirm
    [[ "${confirm}" == "INSTALL" ]] || die "Aborted"
fi

header "Checking Network"

# Check network connectivity
if ! ping -c 1 archlinux.org &>/dev/null; then
    warn "No network connection detected"
    echo ""
    echo "Connect to network first:"
    echo "  Ethernet: Should be automatic"
    echo "  WiFi:     iwctl station wlan0 connect SSID"
    echo ""
    read -p "Press Enter after connecting to network..."

    if ! ping -c 1 archlinux.org &>/dev/null; then
        die "Still no network. Cannot continue without internet."
    fi
fi
ok "Network connected"

header "Partitioning ${DEVICE}"

# Unmount any existing partitions
for part in "${DEVICE}"*; do
    umount "${part}" 2>/dev/null || true
done
swapoff -a 2>/dev/null || true

# Determine partition naming
if [[ "${DEVICE}" == *nvme* ]] || [[ "${DEVICE}" == *loop* ]]; then
    PART="${DEVICE}p"
else
    PART="${DEVICE}"
fi

# Create partitions
log "Creating GPT partition table..."
parted -s "${DEVICE}" mklabel gpt

# EFI partition (512MB)
parted -s "${DEVICE}" mkpart ESP fat32 1MiB 513MiB
parted -s "${DEVICE}" set 1 esp on

# Swap partition (if enabled)
if [[ "${SWAP_SIZE}" != "0" ]]; then
    case "${SWAP_SIZE}" in
        *G) SWAP_MB=$((${SWAP_SIZE%G} * 1024)) ;;
        *M) SWAP_MB="${SWAP_SIZE%M}" ;;
        *) SWAP_MB="${SWAP_SIZE}" ;;
    esac
    SWAP_END=$((513 + SWAP_MB))
    parted -s "${DEVICE}" mkpart swap linux-swap 513MiB "${SWAP_END}MiB"
    parted -s "${DEVICE}" mkpart root ext4 "${SWAP_END}MiB" 100%
    EFI_PART="${PART}1"
    SWAP_PART="${PART}2"
    ROOT_PART="${PART}3"
else
    parted -s "${DEVICE}" mkpart root ext4 513MiB 100%
    EFI_PART="${PART}1"
    SWAP_PART=""
    ROOT_PART="${PART}2"
fi

sleep 2  # Wait for partitions

header "Formatting Partitions"

log "Formatting EFI partition..."
mkfs.fat -F32 "${EFI_PART}"

if [[ -n "${SWAP_PART}" ]]; then
    log "Setting up swap..."
    mkswap "${SWAP_PART}"
    swapon "${SWAP_PART}"
fi

log "Formatting root partition..."
mkfs.ext4 -F "${ROOT_PART}"

header "Mounting Filesystems"

MOUNT=/mnt

mount "${ROOT_PART}" "${MOUNT}"
mkdir -p "${MOUNT}/boot/efi"
mount "${EFI_PART}" "${MOUNT}/boot/efi"

header "Installing Base System"

log "Installing base packages (this takes a while)..."

# Base system + essential packages
pacstrap -K "${MOUNT}" \
    base linux linux-firmware \
    base-devel git vim nano \
    networkmanager iwd dhcpcd \
    openssh \
    sudo grub efibootmgr \
    man-db man-pages

header "Configuring System"

# Generate fstab
log "Generating fstab..."
genfstab -U "${MOUNT}" >> "${MOUNT}/etc/fstab"

# Chroot and configure
log "Configuring system in chroot..."

arch-chroot "${MOUNT}" /bin/bash <<CHROOT_SCRIPT
set -e

# Timezone
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Locale
echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Hostname
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# Enable services
systemctl enable NetworkManager
systemctl enable sshd

# Create user
useradd -m -G wheel -s /bin/bash ${USERNAME}
echo "${USERNAME}:${USERNAME}" | chpasswd
echo "root:root" | chpasswd

# Allow wheel group sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Install bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

CHROOT_SCRIPT

header "Installing Desktop Environment"

log "Installing XFCE, Firefox, and tools..."

arch-chroot "${MOUNT}" /bin/bash <<CHROOT_DESKTOP
set -e

# Xorg and XFCE
pacman -S --noconfirm --needed \
    xorg-server xorg-xinit xorg-xrandr \
    xfce4 xfce4-goodies \
    lightdm lightdm-gtk-greeter \
    firefox \
    ttf-dejavu ttf-liberation noto-fonts \
    pulseaudio pavucontrol \
    gvfs thunar-volman \
    network-manager-applet

# Enable display manager
systemctl enable lightdm

# Create .xinitrc for user
cat > /home/${USERNAME}/.xinitrc <<EOF
exec startxfce4
EOF
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.xinitrc

CHROOT_DESKTOP

header "Installing Claude Code Dependencies"

log "Installing Node.js and Claude Code..."

arch-chroot "${MOUNT}" /bin/bash <<CHROOT_CLAUDE
set -e

# Node.js and npm
pacman -S --noconfirm --needed nodejs npm

# Install Claude Code globally
npm install -g @anthropic-ai/claude-code

# Also install useful dev tools
pacman -S --noconfirm --needed \
    curl wget \
    htop btop \
    ripgrep fd \
    unzip p7zip \
    python python-pip

CHROOT_CLAUDE

header "Final Configuration"

# Set password reminder
arch-chroot "${MOUNT}" /bin/bash <<CHROOT_FINAL
set -e

# Create a welcome script
cat > /home/${USERNAME}/WELCOME.txt <<EOF
===========================================
 Arch Linux Workstation - Setup Complete!
===========================================

Credentials:
  Username: ${USERNAME}
  Password: ${USERNAME} (CHANGE THIS!)
  Root password: root (CHANGE THIS!)

To change passwords:
  passwd              # Change your password
  sudo passwd root    # Change root password

Installed software:
  - XFCE desktop environment
  - Firefox browser
  - Claude Code (run: claude)
  - SSH server (already running)
  - Git, Vim, development tools

WiFi setup:
  nmcli device wifi list
  nmcli device wifi connect "SSID" password "PASSWORD"

Start Claude Code:
  claude

To install LFS:
  git clone <your-repo> lfs-infra
  cd lfs-infra
  sudo ./scripts/install/setup-real-hardware.sh /dev/nvme0n1

===========================================
EOF
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/WELCOME.txt

CHROOT_FINAL

header "Installation Complete!"

# Unmount
log "Unmounting..."
umount -R "${MOUNT}"
[[ -n "${SWAP_PART}" ]] && swapoff "${SWAP_PART}" 2>/dev/null || true

ok "Arch Linux workstation installed successfully!"
echo ""
echo "==========================================="
echo " Installation Summary"
echo "==========================================="
echo ""
echo "Device:    ${DEVICE}"
echo "Username:  ${USERNAME}"
echo "Password:  ${USERNAME} (change after login!)"
echo "Root pass: root (change after login!)"
echo ""
echo "Installed:"
echo "  - XFCE desktop"
echo "  - Firefox browser"
echo "  - Claude Code (command: claude)"
echo "  - SSH server"
echo "  - Development tools"
echo ""
echo "Next steps:"
echo "  1. Reboot: reboot"
echo "  2. Remove the installation media (if different from target)"
echo "  3. Boot into your new Arch system"
echo "  4. Login and change your password!"
echo "  5. Run 'claude' to start Claude Code"
echo ""
echo "==========================================="
