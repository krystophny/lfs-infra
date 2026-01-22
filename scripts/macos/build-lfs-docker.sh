#!/bin/bash
# Build minimal LFS USB on macOS (Apple Silicon via Rosetta)
# Creates bootable USB with minimal LFS - boots to bash shell with networking
# Use lfs-install to install full LFS with desktop onto hard drive
#
# Features:
# - SSH server enabled
# - WiFi pre-configured (SSID/password set during build)
# - LAN networking (DHCP or static)
# - Claude Code CLI installed
# - lfs-install script for full desktop installation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

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

[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS"

# Configuration
IMAGE_SIZE="${IMAGE_SIZE:-16G}"
OUTPUT_DIR="${OUTPUT_DIR:-${HOME}/lfs-build}"
IMAGE_FILE="${OUTPUT_DIR}/lfs-minimal.img"
CACHE_DIR="${OUTPUT_DIR}/cache"
CONTAINER_NAME="lfs-builder"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build minimal LFS USB for installing full LFS on target hardware.

The USB boots to bash shell with SSH, WiFi, and networking ready.
Run: lfs-install /dev/nvme0n1

Options:
    -d, --device DISK   Target USB disk (e.g., disk4)
    -s, --size SIZE     Image size (default: ${IMAGE_SIZE})
    -o, --output DIR    Output directory (default: ${OUTPUT_DIR})
    -l, --list          List USB drives and exit
    -b, --build-only    Build image but don't write to USB
    -n, --no-cache      Clear all caches before build
    -h, --help          Show this help
EOF
    exit 0
}

DEVICE=""
BUILD_ONLY=0
LIST_ONLY=0
NO_CACHE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device) DEVICE="$2"; shift 2 ;;
        -s|--size) IMAGE_SIZE="$2"; shift 2 ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -l|--list) LIST_ONLY=1; shift ;;
        -b|--build-only) BUILD_ONLY=1; shift ;;
        -n|--no-cache) NO_CACHE=1; shift ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

list_usb_drives() {
    header "Available USB Drives"
    diskutil list external 2>/dev/null || diskutil list
}

[[ ${LIST_ONLY} -eq 1 ]] && { list_usb_drives; exit 0; }

header "LFS Minimal USB Builder"
echo "Creates bootable USB with minimal LFS + SSH + networking"
echo ""

# ============================================================================
# User Configuration
# ============================================================================
header "User Configuration"

read -p "Username [default: lfs]: " LFS_USERNAME
LFS_USERNAME="${LFS_USERNAME:-lfs}"
[[ "${LFS_USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username"

while true; do
    read -sp "Password for ${LFS_USERNAME}: " LFS_PASSWORD
    echo ""
    read -sp "Confirm password: " LFS_PASSWORD_CONFIRM
    echo ""
    [[ "${LFS_PASSWORD}" == "${LFS_PASSWORD_CONFIRM}" ]] && break
    warn "Passwords don't match."
done
[[ -z "${LFS_PASSWORD}" ]] && die "Password cannot be empty"

# ============================================================================
# Network Configuration
# ============================================================================
header "Network Configuration"

# WiFi
echo "WiFi Configuration (leave empty to skip):"
read -p "WiFi SSID: " WIFI_SSID
WIFI_PASSWORD=""
if [[ -n "${WIFI_SSID}" ]]; then
    read -sp "WiFi Password: " WIFI_PASSWORD
    echo ""
fi

# LAN
echo ""
echo "LAN Configuration:"
echo "  1) DHCP (automatic)"
echo "  2) Static IP"
read -p "Select [1]: " LAN_MODE
LAN_MODE="${LAN_MODE:-1}"

LAN_IP=""
LAN_GATEWAY=""
LAN_DNS=""
if [[ "${LAN_MODE}" == "2" ]]; then
    read -p "Static IP (e.g., 192.168.1.100/24): " LAN_IP
    read -p "Gateway (e.g., 192.168.1.1): " LAN_GATEWAY
    read -p "DNS (e.g., 8.8.8.8): " LAN_DNS
fi

ok "Network configuration saved"

# ============================================================================
# Docker Check
# ============================================================================
docker info &>/dev/null || die "Docker not running. Start OrbStack first."

log "Checking x86_64 Rosetta support..."
docker run --rm --platform linux/amd64 alpine:latest uname -m 2>/dev/null | grep -q x86_64 \
    || die "Rosetta not working. Enable in OrbStack."
ok "Rosetta working"

# ============================================================================
# Update Package Versions
# ============================================================================
header "Updating Package Versions"

log "Checking for latest package versions..."
if [[ -x "${ROOT_DIR}/version-checker/check-versions.sh" ]]; then
    cd "${ROOT_DIR}"
    ./version-checker/check-versions.sh -u all 2>/dev/null || warn "Some version checks failed"
    ok "Package versions updated"
else
    warn "Version checker not found, using existing versions"
fi

# ============================================================================
# Setup Directories
# ============================================================================
mkdir -p "${OUTPUT_DIR}" "${CACHE_DIR}/sources" "${CACHE_DIR}/tools"

if [[ ${NO_CACHE} -eq 1 ]]; then
    warn "Clearing caches..."
    rm -rf "${CACHE_DIR:?}"/*
    mkdir -p "${CACHE_DIR}/sources" "${CACHE_DIR}/tools"
fi

# ============================================================================
# Build Docker Image
# ============================================================================
header "Building Docker Image (Build Host)"

cat > "${OUTPUT_DIR}/Dockerfile" <<'DOCKERFILE'
FROM archlinux:latest

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        base-devel git vim wget curl \
        bison flex texinfo gawk m4 \
        python python-pip \
        dosfstools e2fsprogs btrfs-progs parted \
        grub efibootmgr \
        bc libelf openssl \
        cpio xz zstd lz4 \
        perl perl-xml-parser \
        meson ninja cmake \
        autoconf automake libtool pkgconf \
        patch diffutils rsync \
        iproute2 wpa_supplicant dhcpcd openssh \
        && pacman -Scc --noconfirm

RUN useradd -m lfs && echo "lfs ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
WORKDIR /lfs-build
DOCKERFILE

docker build --platform linux/amd64 -t lfs-builder "${OUTPUT_DIR}"

# ============================================================================
# Prepare Build
# ============================================================================
header "Preparing Build"

rsync -a --exclude='.git' --exclude='*.img' "${ROOT_DIR}/" "${OUTPUT_DIR}/lfs-infra/"

# ============================================================================
# Create Build Script (runs inside Docker)
# ============================================================================
cat > "${OUTPUT_DIR}/build-inside-docker.sh" <<BUILDSCRIPT
#!/bin/bash
set -e

export LFS=/mnt/lfs
export LFS_TGT=x86_64-lfs-linux-gnu
export MAKEFLAGS="-j\$(nproc)"
export NPROC=\$(nproc)
export PATH="\${LFS}/tools/bin:\${PATH}"

log() { echo -e "\033[0;34m[BUILD]\033[0m \$*"; }
ok() { echo -e "\033[0;32m[OK]\033[0m \$*"; }
die() { echo -e "\033[0;31m[FATAL]\033[0m \$*"; exit 1; }

[[ -z "\${LFS}" || "\${LFS}" == "/" ]] && die "Invalid LFS"

IMAGE_FILE="/output/lfs-minimal.img"
IMAGE_SIZE="${IMAGE_SIZE}"
LFS_USERNAME="${LFS_USERNAME}"
LFS_PASSWORD="${LFS_PASSWORD}"
WIFI_SSID="${WIFI_SSID}"
WIFI_PASSWORD="${WIFI_PASSWORD}"
LAN_MODE="${LAN_MODE}"
LAN_IP="${LAN_IP}"
LAN_GATEWAY="${LAN_GATEWAY}"
LAN_DNS="${LAN_DNS}"

log "Setting up loop devices..."
losetup -D 2>/dev/null || true
for i in \$(seq 0 15); do
    [[ ! -e /dev/loop\${i} ]] && mknod /dev/loop\${i} b 7 \${i} 2>/dev/null || true
done
[[ ! -e /dev/loop-control ]] && mknod /dev/loop-control c 10 237 2>/dev/null || true

log "Creating \${IMAGE_SIZE} disk image..."
truncate -s "\${IMAGE_SIZE}" "\${IMAGE_FILE}"

log "Partitioning..."
parted -s "\${IMAGE_FILE}" mklabel gpt
parted -s "\${IMAGE_FILE}" mkpart ESP fat32 1MiB 513MiB
parted -s "\${IMAGE_FILE}" set 1 esp on
parted -s "\${IMAGE_FILE}" mkpart root ext4 513MiB 100%

EFI_OFFSET=\$((1 * 1024 * 1024))
EFI_SIZE=\$((512 * 1024 * 1024))
ROOT_OFFSET=\$((513 * 1024 * 1024))

LOOP_EFI=\$(losetup -f --show --offset \${EFI_OFFSET} --sizelimit \${EFI_SIZE} "\${IMAGE_FILE}")
LOOP_ROOT=\$(losetup -f --show --offset \${ROOT_OFFSET} "\${IMAGE_FILE}")

log "Formatting..."
mkfs.fat -F32 "\${LOOP_EFI}"
mkfs.ext4 -F "\${LOOP_ROOT}"

log "Mounting..."
mkdir -p "\${LFS}"
mount "\${LOOP_ROOT}" "\${LFS}"
mkdir -p "\${LFS}/boot/efi"
mount "\${LOOP_EFI}" "\${LFS}/boot/efi"

# Use cached sources/tools
if ls /cache/sources/*.tar.* &>/dev/null 2>&1; then
    log "Using cached sources..."
    mkdir -p "\${LFS}/sources"
    cp -n /cache/sources/*.tar.* "\${LFS}/sources/" 2>/dev/null || true
fi

if [[ -d /cache/tools/bin ]]; then
    log "Using cached toolchain..."
    mkdir -p "\${LFS}/tools"
    cp -a /cache/tools/* "\${LFS}/tools/" 2>/dev/null || true
fi

log "=========================================="
log "Building Minimal LFS"
log "=========================================="

cd /lfs-infra
export LFS_USERNAME LFS_PASSWORD

# Build base system (no desktop)
./scripts/build/build-lfs.sh download
./scripts/build/build-lfs.sh toolchain
./scripts/build/build-lfs.sh temptools
./scripts/build/build-lfs.sh chroot-prep
./scripts/build/build-lfs.sh base
./scripts/build/build-lfs.sh config
./scripts/build/build-lfs.sh kernel

# Cache for next build
log "Caching sources and tools..."
cp -n "\${LFS}/sources/"*.tar.* /cache/sources/ 2>/dev/null || true
[[ -d "\${LFS}/tools/bin" ]] && cp -a "\${LFS}/tools/"* /cache/tools/ 2>/dev/null || true

# ============================================================================
# Install Claude Code CLI
# ============================================================================
log "Installing Claude Code CLI..."
mkdir -p "\${LFS}/home/\${LFS_USERNAME}/.local/bin"
chroot "\${LFS}" /bin/bash -c "curl -fsSL https://claude.ai/install.sh | bash" || \
    warn "Claude Code install failed - can install later"

# ============================================================================
# Configure Networking
# ============================================================================
log "Configuring networking..."

# WiFi configuration
if [[ -n "\${WIFI_SSID}" ]]; then
    mkdir -p "\${LFS}/etc/wpa_supplicant"
    cat > "\${LFS}/etc/wpa_supplicant/wpa_supplicant.conf" <<WPAEOF
ctrl_interface=/run/wpa_supplicant
update_config=1
country=US

network={
    ssid="\${WIFI_SSID}"
    psk="\${WIFI_PASSWORD}"
    key_mgmt=WPA-PSK
}
WPAEOF
    chmod 600 "\${LFS}/etc/wpa_supplicant/wpa_supplicant.conf"
    ok "WiFi configured: \${WIFI_SSID}"
fi

# LAN configuration
mkdir -p "\${LFS}/etc/network"
if [[ "\${LAN_MODE}" == "2" && -n "\${LAN_IP}" ]]; then
    cat > "\${LFS}/etc/network/interfaces" <<LANEOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address \${LAN_IP}
    gateway \${LAN_GATEWAY}
LANEOF
    echo "nameserver \${LAN_DNS}" > "\${LFS}/etc/resolv.conf"
    ok "LAN configured: static IP \${LAN_IP}"
else
    cat > "\${LFS}/etc/network/interfaces" <<LANEOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
LANEOF
    ok "LAN configured: DHCP"
fi

# ============================================================================
# Enable SSH
# ============================================================================
log "Enabling SSH server..."
mkdir -p "\${LFS}/etc/ssh"
# Generate host keys during first boot
cat > "\${LFS}/etc/runit/sv/sshd/run" <<'SSHEOF'
#!/bin/sh
[ ! -f /etc/ssh/ssh_host_rsa_key ] && ssh-keygen -A
exec /usr/sbin/sshd -D
SSHEOF
chmod +x "\${LFS}/etc/runit/sv/sshd/run" 2>/dev/null || true

# ============================================================================
# Copy lfs-infra and create scripts
# ============================================================================
log "Installing lfs-infra and scripts..."
cp -a /lfs-infra "\${LFS}/root/lfs-infra"

# Create lfs-install script
cat > "\${LFS}/usr/local/bin/lfs-install" <<'INSTALLSCRIPT'
#!/bin/bash
# Install full LFS with desktop onto target drive
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "\${BLUE}[INFO]\${NC} \$*"; }
ok() { echo -e "\${GREEN}[OK]\${NC} \$*"; }
warn() { echo -e "\${YELLOW}[WARN]\${NC} \$*"; }
die() { echo -e "\${RED}[FATAL]\${NC} \$*"; exit 1; }
header() { echo -e "\n\${CYAN}=== \$* ===\${NC}\n"; }

[[ \$EUID -eq 0 ]] || die "Run as root: sudo lfs-install [device]"

header "LFS Full Installation"

list_drives() {
    echo "Available drives:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "loop\|sr\|NAME"
    echo ""
}

DEVICE="\${1:-}"
if [[ -z "\${DEVICE}" ]]; then
    list_drives
    read -p "Device to install to (e.g., /dev/nvme0n1): " DEVICE
fi

[[ -z "\${DEVICE}" ]] && die "No device"
[[ "\${DEVICE}" != /dev/* ]] && DEVICE="/dev/\${DEVICE}"
[[ -b "\${DEVICE}" ]] || die "Device \${DEVICE} not found"

# Safety check
BOOT_DEV=\$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*\$//' | sed 's/p[0-9]*\$//')
[[ "\${DEVICE}" == "\${BOOT_DEV}" ]] && die "Cannot install to boot device"

echo ""
echo "Target: \${DEVICE}"
lsblk "\${DEVICE}"
echo ""
warn "ALL DATA WILL BE ERASED!"
read -p "Type 'ERASE' to confirm: " confirm
[[ "\${confirm}" == "ERASE" ]] || die "Aborted"

header "Partitioning \${DEVICE}"

for part in "\${DEVICE}"*; do umount "\${part}" 2>/dev/null || true; done
swapoff -a 2>/dev/null || true

parted -s "\${DEVICE}" mklabel gpt
parted -s "\${DEVICE}" mkpart ESP fat32 1MiB 513MiB
parted -s "\${DEVICE}" set 1 esp on
parted -s "\${DEVICE}" mkpart root btrfs 513MiB 100%
sleep 2

if [[ "\${DEVICE}" == *nvme* ]] || [[ "\${DEVICE}" == *loop* ]]; then
    EFI_PART="\${DEVICE}p1"; ROOT_PART="\${DEVICE}p2"
else
    EFI_PART="\${DEVICE}1"; ROOT_PART="\${DEVICE}2"
fi

header "Formatting with btrfs"

mkfs.fat -F32 "\${EFI_PART}"
mkfs.btrfs -f "\${ROOT_PART}"

export LFS=/mnt/lfs
mkdir -p "\${LFS}"
mount "\${ROOT_PART}" "\${LFS}"

btrfs subvolume create "\${LFS}/@"
btrfs subvolume create "\${LFS}/@home"
btrfs subvolume create "\${LFS}/@snapshots"
umount "\${LFS}"

mount -o subvol=@,compress=zstd:3,noatime "\${ROOT_PART}" "\${LFS}"
mkdir -p "\${LFS}/home" "\${LFS}/.snapshots" "\${LFS}/boot/efi"
mount -o subvol=@home,compress=zstd:3,noatime "\${ROOT_PART}" "\${LFS}/home"
mount -o subvol=@snapshots,compress=zstd:3,noatime "\${ROOT_PART}" "\${LFS}/.snapshots"
mount "\${EFI_PART}" "\${LFS}/boot/efi"

header "User Configuration"

read -p "Username [default: user]: " NEW_USER
NEW_USER="\${NEW_USER:-user}"

while true; do
    read -sp "Password for \${NEW_USER}: " NEW_PASS
    echo ""
    read -sp "Confirm: " NEW_PASS2
    echo ""
    [[ "\${NEW_PASS}" == "\${NEW_PASS2}" ]] && break
    warn "Passwords don't match."
done

export LFS_USERNAME="\${NEW_USER}"
export LFS_PASSWORD="\${NEW_PASS}"

header "Building Full LFS with Desktop"
echo "This will take several hours..."

cd /root/lfs-infra
./scripts/build/build-lfs.sh all

header "Installing Bootloader"

ROOT_UUID=\$(blkid -s UUID -o value "\${ROOT_PART}")
EFI_UUID=\$(blkid -s UUID -o value "\${EFI_PART}")

cat > "\${LFS}/etc/fstab" <<FSTABEOF
UUID=\${ROOT_UUID}  /            btrfs  subvol=@,compress=zstd:3,noatime  0 1
UUID=\${ROOT_UUID}  /home        btrfs  subvol=@home,compress=zstd:3,noatime  0 2
UUID=\${ROOT_UUID}  /.snapshots  btrfs  subvol=@snapshots,compress=zstd:3,noatime  0 2
UUID=\${EFI_UUID}   /boot/efi    vfat   umask=0077  0 2
proc               /proc        proc   nosuid,noexec,nodev  0 0
sysfs              /sys         sysfs  nosuid,noexec,nodev  0 0
tmpfs              /run         tmpfs  defaults  0 0
FSTABEOF

grub-install --target=x86_64-efi --efi-directory="\${LFS}/boot/efi" \
    --boot-directory="\${LFS}/boot" --bootloader-id=LFS --removable

cat > "\${LFS}/boot/grub/grub.cfg" <<GRUBEOF
set default=0
set timeout=0
menuentry "LFS" {
    linux /boot/vmlinuz root=UUID=\${ROOT_UUID} rootflags=subvol=@ ro quiet
    initrd /boot/initrd.img
}
GRUBEOF

umount -R "\${LFS}"

header "Complete!"
ok "LFS installed to \${DEVICE}"
echo ""
echo "Remove USB and reboot. Login: \${NEW_USER}"
INSTALLSCRIPT
chmod +x "\${LFS}/usr/local/bin/lfs-install"

# Create lfs-build-desktop script (for building desktop from within LFS)
cat > "\${LFS}/usr/local/bin/lfs-build-desktop" <<'DESKTOPSCRIPT'
#!/bin/bash
# Build desktop environment on existing LFS installation
set -euo pipefail

[[ \$EUID -eq 0 ]] || { echo "Run as root: sudo lfs-build-desktop"; exit 1; }

echo "Building XFCE desktop environment..."
cd /root/lfs-infra
./scripts/build/build-lfs.sh desktop

echo ""
echo "Desktop installed! Reboot to start graphical login."
DESKTOPSCRIPT
chmod +x "\${LFS}/usr/local/bin/lfs-build-desktop"

# Create motd
cat > "\${LFS}/etc/motd" <<'MOTDEOF'

  _     _____ ____
 | |   |  ___/ ___|
 | |   | |_  \___ \
 | |___|  _|  ___) |
 |_____|_|   |____/

 LFS Minimal - Installation USB

 Commands:
   sudo lfs-install          Install full LFS with desktop to hard drive
   sudo lfs-build-desktop    Build desktop on current system
   claude                    Claude Code CLI

 SSH is enabled. WiFi configured during build.

MOTDEOF

# Generate fstab for USB
ROOT_UUID=\$(blkid -s UUID -o value "\${LOOP_ROOT}")
EFI_UUID=\$(blkid -s UUID -o value "\${LOOP_EFI}")

cat > "\${LFS}/etc/fstab" <<USBFSTAB
UUID=\${ROOT_UUID}  /          ext4  defaults,noatime  0 1
UUID=\${EFI_UUID}   /boot/efi  vfat  umask=0077        0 2
proc               /proc      proc  nosuid,noexec,nodev  0 0
sysfs              /sys       sysfs nosuid,noexec,nodev  0 0
tmpfs              /run       tmpfs defaults  0 0
USBFSTAB

# Install bootloader
log "Installing bootloader..."
grub-install --target=x86_64-efi \
    --efi-directory="\${LFS}/boot/efi" \
    --boot-directory="\${LFS}/boot" \
    --bootloader-id=LFS \
    --removable

cat > "\${LFS}/boot/grub/grub.cfg" <<GRUBCFG
set default=0
set timeout=0
menuentry "LFS Installer" {
    linux /boot/vmlinuz root=UUID=\${ROOT_UUID} ro quiet
    initrd /boot/initrd.img
}
GRUBCFG

log "Unmounting..."
umount -R "\${LFS}"
losetup -d "\${LOOP_EFI}"
losetup -d "\${LOOP_ROOT}"

ok "=========================================="
ok "Minimal LFS USB Build Complete!"
ok "=========================================="
echo ""
echo "Image: \${IMAGE_FILE}"
echo "User: \${LFS_USERNAME} (has sudo)"
echo "SSH: enabled"
echo "WiFi: \${WIFI_SSID:-not configured}"
echo ""
echo "Boot and run: sudo lfs-install"
BUILDSCRIPT

chmod +x "${OUTPUT_DIR}/build-inside-docker.sh"

# ============================================================================
# Run Build
# ============================================================================
header "Starting Build"

log "Building minimal LFS with networking..."
log "Image: ${IMAGE_FILE}"
echo ""

docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

docker run --rm \
    --platform linux/amd64 \
    --privileged \
    --name "${CONTAINER_NAME}" \
    -v "${OUTPUT_DIR}:/output" \
    -v "${OUTPUT_DIR}/lfs-infra:/lfs-infra:ro" \
    -v "${CACHE_DIR}:/cache" \
    lfs-builder \
    bash /output/build-inside-docker.sh

[[ -f "${IMAGE_FILE}" ]] || die "Build failed"

ok "Build complete: ${IMAGE_FILE}"
ls -lh "${IMAGE_FILE}"

# ============================================================================
# Write to USB
# ============================================================================
if [[ ${BUILD_ONLY} -eq 1 ]]; then
    echo ""
    log "To write: sudo dd if=${IMAGE_FILE} of=/dev/rdiskN bs=4m status=progress"
    exit 0
fi

if [[ -z "${DEVICE}" ]]; then
    echo ""
    list_usb_drives
    read -p "Disk to write to (e.g., disk4): " DEVICE
fi

[[ -z "${DEVICE}" ]] && die "No device"

DEVICE="${DEVICE#/dev/}"
DEVICE="${DEVICE#disk}"
DEVICE="disk${DEVICE}"

diskutil info "/dev/${DEVICE}" 2>/dev/null | grep -q "Removable Media:.*Yes\|Protocol:.*USB\|Location:.*External" \
    || die "${DEVICE} not a USB drive"

header "Writing to /dev/${DEVICE}"
warn "ALL DATA WILL BE ERASED!"
read -p "Type 'YES': " confirm
[[ "${confirm}" == "YES" ]] || die "Aborted"

diskutil unmountDisk "/dev/${DEVICE}" || true
sudo dd if="${IMAGE_FILE}" of="/dev/r${DEVICE}" bs=4m status=progress
sync
diskutil eject "/dev/${DEVICE}" || true

header "Done!"
ok "USB ready!"
echo ""
echo "Boot it, login as ${LFS_USERNAME}, then run:"
echo "  sudo lfs-install"
