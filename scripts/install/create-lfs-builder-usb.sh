#!/bin/bash
# Create Arch Linux USB for LFS Building
# Run this FROM a booted Arch Linux live USB/ISO
#
# Installs persistent Arch with: LFS build deps, Claude Code, SSH, your credentials
#
# Usage: curl -sL <raw-url> | bash -s /dev/sdX
#    or: ./create-lfs-builder-usb.sh /dev/sdX

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

usage() {
    cat <<EOF
Create Arch Linux USB for LFS Building
=======================================
Run this FROM a booted Arch Linux live USB/ISO.

Usage: $(basename "$0") DEVICE [OPTIONS]

Arguments:
    DEVICE              Target USB device (e.g., /dev/sdb)

Options:
    --ssh-keys DIR      Copy SSH keys from DIR (default: tries /root/.ssh)
    --claude-creds DIR  Copy Claude credentials from DIR
    --help              Show this help

What gets installed:
    - Persistent Arch Linux (survives reboot)
    - All LFS build dependencies (gcc, make, bison, flex, etc.)
    - Claude Code (npm install)
    - SSH client + server
    - Git, btrfs-progs, curl, vim

After booting from the created USB:
    1. Connect to network: nmcli device wifi connect "SSID" password "PASS"
    2. Setup LFS target:   setup-lfs-target /dev/nvme0n1
    3. Clone and build:    git clone <repo> && cd lfs-infra && ./scripts/build/build-lfs.sh all

Quick start (from Arch live):
    curl -sL https://raw.githubusercontent.com/USER/lfs-infra/main/scripts/install/create-lfs-builder-usb.sh | bash -s /dev/sdb
EOF
    exit 0
}

# Parse arguments
DEVICE=""
SSH_KEYS_DIR=""
CLAUDE_CREDS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-keys) SSH_KEYS_DIR="$2"; shift 2 ;;
        --claude-creds) CLAUDE_CREDS_DIR="$2"; shift 2 ;;
        --help|-h) usage ;;
        /dev/*) DEVICE="$1"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -z "${DEVICE}" ]] && usage

# Validations
[[ "$(uname -s)" == "Linux" ]] || die "Must run from Linux (boot Arch ISO first)"
[[ $EUID -eq 0 ]] || die "Must run as root"
[[ -b "${DEVICE}" ]] || die "Device ${DEVICE} not found"

# Don't install to the live USB we're running from
LIVE_DEV=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null | sed 's/[0-9]*$//' || true)
if [[ -n "${LIVE_DEV}" && "${DEVICE}" == "${LIVE_DEV}"* ]]; then
    die "Cannot install to the live USB you're running from. Use a different USB."
fi

# Check network
if ! ping -c 1 -W 3 archlinux.org &>/dev/null; then
    warn "No network connection detected."
    echo ""
    echo "Connect to WiFi:"
    echo "  iwctl station wlan0 connect YOUR_SSID"
    echo ""
    echo "Or check ethernet cable."
    echo ""
    die "Network required. Connect and re-run."
fi

echo "============================================"
echo " LFS Builder USB Creator"
echo "============================================"
echo ""
echo "Target device: ${DEVICE}"
lsblk "${DEVICE}" 2>/dev/null || true
echo ""
warn "ALL DATA ON ${DEVICE} WILL BE DESTROYED!"
echo ""
read -p "Type 'YES' to continue: " confirm
[[ "${confirm}" == "YES" ]] || die "Aborted by user"

# Unmount any existing partitions
log "Unmounting existing partitions..."
for part in "${DEVICE}"*; do
    umount "${part}" 2>/dev/null || true
done

# Determine partition naming
if [[ "${DEVICE}" == *nvme* ]] || [[ "${DEVICE}" == *loop* ]]; then
    PART="${DEVICE}p"
else
    PART="${DEVICE}"
fi

log "Creating partition table..."
parted -s "${DEVICE}" mklabel gpt
parted -s "${DEVICE}" mkpart ESP fat32 1MiB 513MiB
parted -s "${DEVICE}" set 1 esp on
parted -s "${DEVICE}" mkpart root ext4 513MiB 100%

sleep 2

EFI_PART="${PART}1"
ROOT_PART="${PART}2"

log "Formatting partitions..."
mkfs.fat -F32 -n LFSEFI "${EFI_PART}"
mkfs.ext4 -F -L lfsroot "${ROOT_PART}"

MOUNT=/mnt
mount "${ROOT_PART}" "${MOUNT}"
mkdir -p "${MOUNT}/boot/efi"
mount "${EFI_PART}" "${MOUNT}/boot/efi"

log "Installing base system (this takes a few minutes)..."
pacstrap -K "${MOUNT}" \
    base linux linux-firmware \
    base-devel \
    git curl wget rsync \
    btrfs-progs xfsprogs dosfstools parted \
    networkmanager openssh \
    vim nano less htop \
    man-db man-pages \
    grub efibootmgr \
    bison flex gawk m4 texinfo \
    python perl \
    libarchive zstd \
    nodejs npm

log "Generating fstab..."
genfstab -U "${MOUNT}" >> "${MOUNT}/etc/fstab"

log "Configuring system..."
arch-chroot "${MOUNT}" /bin/bash <<'CHROOT'
set -e

# Timezone and locale
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "lfs-builder" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   lfs-builder
EOF

# Enable services
systemctl enable NetworkManager
systemctl enable sshd

# Root password (change this!)
echo "root:lfs" | chpasswd

# Install Claude Code
npm install -g @anthropic-ai/claude-code || echo "Claude Code install failed, try manually later"

# Install bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH --removable
grub-mkconfig -o /boot/grub/grub.cfg

# Create helper script: setup-lfs-target
cat > /usr/local/bin/setup-lfs-target <<'SCRIPT'
#!/bin/bash
# Initialize LFS target volume - ALL building happens here, not on boot USB
set -euo pipefail
DEVICE="${1:-}"
[[ -z "${DEVICE}" ]] && { echo "Usage: setup-lfs-target /dev/sdX"; exit 1; }
[[ -b "${DEVICE}" ]] || { echo "Not a block device: ${DEVICE}"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Must be root"; exit 1; }

echo "This will ERASE ${DEVICE} and create LFS target with btrfs"
echo "All LFS building will happen on this drive (not the boot USB)"
read -p "Type 'ERASE' to continue: " c
[[ "$c" == "ERASE" ]] || { echo "Aborted"; exit 1; }

for p in "${DEVICE}"*; do umount "$p" 2>/dev/null || true; done

parted -s "${DEVICE}" mklabel gpt
parted -s "${DEVICE}" mkpart ESP fat32 1MiB 513MiB
parted -s "${DEVICE}" set 1 esp on
parted -s "${DEVICE}" mkpart root btrfs 513MiB 100%
sleep 2

if [[ "${DEVICE}" == *nvme* ]]; then P="${DEVICE}p"; else P="${DEVICE}"; fi

mkfs.fat -F32 -n LFSEFI "${P}1"
mkfs.btrfs -f -L lfs "${P}2"

mkdir -p /mnt/lfs
mount "${P}2" /mnt/lfs
btrfs subvolume create /mnt/lfs/@
btrfs subvolume create /mnt/lfs/@snapshots
btrfs subvolume create /mnt/lfs/@pkg
btrfs subvolume create /mnt/lfs/@src
umount /mnt/lfs

mount -o subvol=@,compress=zstd:3 "${P}2" /mnt/lfs
mkdir -p /mnt/lfs/{boot/efi,.snapshots,pkg,usr/src,sources,build,tools}
mount "${P}1" /mnt/lfs/boot/efi
mount -o subvol=@snapshots,compress=zstd:3 "${P}2" /mnt/lfs/.snapshots
mount -o subvol=@pkg,compress=zstd:3 "${P}2" /mnt/lfs/pkg
mount -o subvol=@src,compress=zstd:3 "${P}2" /mnt/lfs/usr/src

# Clone repo to target drive
cd /mnt/lfs/usr/src
if [[ ! -d lfs-infra ]]; then
    git clone https://github.com/ert/lfs-infra.git || echo "Clone manually: git clone <your-repo> /mnt/lfs/usr/src/lfs-infra"
fi

export LFS=/mnt/lfs
echo "export LFS=/mnt/lfs" >> /root/.bashrc

echo ""
echo "============================================"
echo " LFS target ready at /mnt/lfs"
echo "============================================"
echo ""
echo "All building will happen on this drive:"
echo "  Sources:  /mnt/lfs/sources"
echo "  Build:    /mnt/lfs/build"
echo "  Packages: /mnt/lfs/pkg"
echo "  Repo:     /mnt/lfs/usr/src/lfs-infra"
echo ""
echo "Next steps:"
echo "  cd /mnt/lfs/usr/src/lfs-infra"
echo "  ./scripts/build/build-lfs.sh all"
SCRIPT
chmod +x /usr/local/bin/setup-lfs-target

# Create motd
cat > /etc/motd <<'MOTD'
============================================
 LFS Builder - Arch Linux
============================================
Quick start:
  1. WiFi: nmcli device wifi connect "SSID" password "PASS"
  2. Target: setup-lfs-target /dev/nvme0n1
  3. Build: cd /mnt/lfs/usr/src/lfs-infra && ./scripts/build/build-lfs.sh all

All building happens on target drive, not this USB.
Root password: lfs | SSH on port 22
============================================
MOTD
CHROOT

# Copy SSH keys if available
if [[ -n "${SSH_KEYS_DIR:-}" && -d "${SSH_KEYS_DIR}" ]]; then
    log "Copying SSH keys from ${SSH_KEYS_DIR}..."
    mkdir -p "${MOUNT}/root/.ssh"
    cp -a "${SSH_KEYS_DIR}"/* "${MOUNT}/root/.ssh/" 2>/dev/null || true
    chmod 700 "${MOUNT}/root/.ssh"
    chmod 600 "${MOUNT}/root/.ssh"/* 2>/dev/null || true
elif [[ -d "/root/.ssh" ]]; then
    log "Copying SSH keys from /root/.ssh..."
    mkdir -p "${MOUNT}/root/.ssh"
    cp -a /root/.ssh/* "${MOUNT}/root/.ssh/" 2>/dev/null || true
    chmod 700 "${MOUNT}/root/.ssh"
    chmod 600 "${MOUNT}/root/.ssh"/* 2>/dev/null || true
fi

# Copy Claude credentials if available
if [[ -n "${CLAUDE_CREDS_DIR:-}" && -d "${CLAUDE_CREDS_DIR}" ]]; then
    log "Copying Claude credentials from ${CLAUDE_CREDS_DIR}..."
    mkdir -p "${MOUNT}/root/.claude"
    cp -a "${CLAUDE_CREDS_DIR}"/* "${MOUNT}/root/.claude/" 2>/dev/null || true
elif [[ -d "/root/.claude" ]]; then
    log "Copying Claude credentials from /root/.claude..."
    mkdir -p "${MOUNT}/root/.claude"
    cp -a /root/.claude/* "${MOUNT}/root/.claude/" 2>/dev/null || true
fi

log "Unmounting..."
umount -R "${MOUNT}"
sync

ok "============================================"
ok " LFS Builder USB Ready!"
ok "============================================"
echo ""
echo "Remove the live USB, insert this new USB, and boot from it."
echo ""
echo "Root password: lfs"
echo "WiFi: nmcli device wifi connect SSID password PASS"
echo "Then: setup-lfs-target /dev/nvme0n1"
echo ""
