#!/bin/bash
# Build minimal LFS USB on macOS (Apple Silicon via Rosetta)
# Creates a bootable USB with minimal LFS - boots to bash shell
# Use the USB to install full LFS with desktop onto hard drive
#
# Docker = build host, Output = minimal LFS (like Arch live ISO)

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

The USB boots to a bash shell (no GUI). From there, run:
  lfs-install /dev/nvme0n1

This formats the drive with btrfs and builds full LFS with:
  - runit init, XFCE desktop, Firefox, Claude Code

Options:
    -d, --device DISK   Target USB disk (e.g., disk4)
    -s, --size SIZE     Image size (default: ${IMAGE_SIZE})
    -o, --output DIR    Output directory (default: ${OUTPUT_DIR})
    -l, --list          List USB drives and exit
    -b, --build-only    Build image but don't write to USB
    -n, --no-cache      Clear all caches before build
    -h, --help          Show this help

Examples:
    $(basename "$0") -d disk4           # Build and write to disk4
    $(basename "$0") -b                 # Build only, no USB write
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

if [[ ${LIST_ONLY} -eq 1 ]]; then
    list_usb_drives
    exit 0
fi

header "LFS Minimal USB Builder"
echo "Creates bootable USB with minimal LFS (boots to bash shell)"
echo "Use it to install full LFS with desktop onto your hard drive"
echo ""

# Prompt for user credentials
header "User Configuration"
read -p "Username [default: lfs]: " LFS_USERNAME
LFS_USERNAME="${LFS_USERNAME:-lfs}"

if [[ ! "${LFS_USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    die "Invalid username. Use lowercase letters, numbers, underscore, hyphen."
fi

while true; do
    read -sp "Password for ${LFS_USERNAME}: " LFS_PASSWORD
    echo ""
    read -sp "Confirm password: " LFS_PASSWORD_CONFIRM
    echo ""
    [[ "${LFS_PASSWORD}" == "${LFS_PASSWORD_CONFIRM}" ]] && break
    warn "Passwords don't match. Try again."
done

[[ -z "${LFS_PASSWORD}" ]] && die "Password cannot be empty"
ok "User '${LFS_USERNAME}' will have sudo access"
echo ""

# Check Docker
docker info &>/dev/null || die "Docker not running. Start OrbStack first."

log "Checking x86_64 support via Rosetta..."
docker run --rm --platform linux/amd64 alpine:latest uname -m 2>/dev/null | grep -q x86_64 \
    || die "x86_64 emulation not working. Enable Rosetta in OrbStack."
ok "Rosetta working"

# Setup directories
mkdir -p "${OUTPUT_DIR}" "${CACHE_DIR}/sources" "${CACHE_DIR}/tools"

if [[ ${NO_CACHE} -eq 1 ]]; then
    warn "Clearing caches..."
    rm -rf "${CACHE_DIR:?}"/*
    mkdir -p "${CACHE_DIR}/sources" "${CACHE_DIR}/tools"
fi

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
        && pacman -Scc --noconfirm

RUN useradd -m lfs && echo "lfs ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
WORKDIR /lfs-build
DOCKERFILE

docker build --platform linux/amd64 -t lfs-builder "${OUTPUT_DIR}"

header "Preparing Build"

rsync -a --exclude='.git' --exclude='*.img' "${ROOT_DIR}/" "${OUTPUT_DIR}/lfs-infra/"

# Create build script for inside Docker
cat > "${OUTPUT_DIR}/build-inside-docker.sh" <<'BUILD_SCRIPT'
#!/bin/bash
set -e

export LFS=/mnt/lfs
export LFS_TGT=x86_64-lfs-linux-gnu
export MAKEFLAGS="-j$(nproc)"
export NPROC=$(nproc)
export PATH="${LFS}/tools/bin:${PATH}"

log() { echo -e "\033[0;34m[BUILD]\033[0m $*"; }
ok() { echo -e "\033[0;32m[OK]\033[0m $*"; }
die() { echo -e "\033[0;31m[FATAL]\033[0m $*"; exit 1; }

# Safety check
[[ -z "${LFS}" ]] && die "LFS not set"
[[ "${LFS}" == "/" ]] && die "LFS cannot be /"

IMAGE_FILE="/output/lfs-minimal.img"
IMAGE_SIZE="${IMAGE_SIZE:-16G}"
LFS_USERNAME="${LFS_USERNAME:-lfs}"
LFS_PASSWORD="${LFS_PASSWORD:-lfs}"

log "Setting up loop devices..."
losetup -D 2>/dev/null || true
for i in $(seq 0 15); do
    [[ ! -e /dev/loop${i} ]] && mknod /dev/loop${i} b 7 ${i} 2>/dev/null || true
done
[[ ! -e /dev/loop-control ]] && mknod /dev/loop-control c 10 237 2>/dev/null || true

log "Creating ${IMAGE_SIZE} disk image..."
truncate -s "${IMAGE_SIZE}" "${IMAGE_FILE}"

log "Partitioning..."
parted -s "${IMAGE_FILE}" mklabel gpt
parted -s "${IMAGE_FILE}" mkpart ESP fat32 1MiB 513MiB
parted -s "${IMAGE_FILE}" set 1 esp on
parted -s "${IMAGE_FILE}" mkpart root ext4 513MiB 100%

EFI_OFFSET=$((1 * 1024 * 1024))
EFI_SIZE=$((512 * 1024 * 1024))
ROOT_OFFSET=$((513 * 1024 * 1024))

LOOP_EFI=$(losetup -f --show --offset ${EFI_OFFSET} --sizelimit ${EFI_SIZE} "${IMAGE_FILE}")
LOOP_ROOT=$(losetup -f --show --offset ${ROOT_OFFSET} "${IMAGE_FILE}")

log "Formatting..."
mkfs.fat -F32 "${LOOP_EFI}"
mkfs.ext4 -F "${LOOP_ROOT}"

log "Mounting..."
mkdir -p "${LFS}"
mount "${LOOP_ROOT}" "${LFS}"
mkdir -p "${LFS}/boot/efi"
mount "${LOOP_EFI}" "${LFS}/boot/efi"

# Use cached sources/tools
if ls /cache/sources/*.tar.* &>/dev/null 2>&1; then
    log "Using cached sources..."
    mkdir -p "${LFS}/sources"
    cp -n /cache/sources/*.tar.* "${LFS}/sources/" 2>/dev/null || true
fi

if [[ -d /cache/tools/bin ]]; then
    log "Using cached toolchain..."
    mkdir -p "${LFS}/tools"
    cp -a /cache/tools/* "${LFS}/tools/" 2>/dev/null || true
fi

log "=========================================="
log "Building Minimal LFS (base system only)"
log "=========================================="

cd /lfs-infra
export LFS_USERNAME LFS_PASSWORD

# Build only base system (no desktop) for minimal USB
# We'll build desktop stages when installing to hard drive
./scripts/build/build-lfs.sh download
./scripts/build/build-lfs.sh toolchain
./scripts/build/build-lfs.sh temptools
./scripts/build/build-lfs.sh chroot-prep
./scripts/build/build-lfs.sh base
./scripts/build/build-lfs.sh config
./scripts/build/build-lfs.sh kernel

# Cache for next build
log "Caching sources and tools..."
cp -n "${LFS}/sources/"*.tar.* /cache/sources/ 2>/dev/null || true
[[ -d "${LFS}/tools/bin" ]] && cp -a "${LFS}/tools/"* /cache/tools/ 2>/dev/null || true

# Copy lfs-infra to the USB
log "Installing lfs-infra..."
cp -a /lfs-infra "${LFS}/root/lfs-infra"

# Create the installer script
log "Creating lfs-install script..."
cat > "${LFS}/usr/local/bin/lfs-install" <<'INSTALLER'
#!/bin/bash
# LFS Full Installation Script
# Formats target drive with btrfs and builds complete LFS with desktop

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

[[ $EUID -eq 0 ]] || die "Run as root: sudo lfs-install [device]"

header "LFS Full Installation"
echo "This will install complete LFS with XFCE desktop onto a drive."
echo ""

# List available drives
list_drives() {
    echo "Available drives:"
    echo ""
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "loop\|sr\|NAME"
    echo ""
}

DEVICE="${1:-}"

if [[ -z "${DEVICE}" ]]; then
    list_drives
    read -p "Enter device to install to (e.g., /dev/nvme0n1 or /dev/sda): " DEVICE
fi

[[ -z "${DEVICE}" ]] && die "No device specified"
[[ "${DEVICE}" != /dev/* ]] && DEVICE="/dev/${DEVICE}"
[[ -b "${DEVICE}" ]] || die "Device ${DEVICE} not found"

# Safety: don't install to the boot device
BOOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
if [[ "${DEVICE}" == "${BOOT_DEV}" ]]; then
    die "Cannot install to boot device ${DEVICE}"
fi

echo ""
echo "Target device: ${DEVICE}"
lsblk "${DEVICE}"
echo ""
warn "ALL DATA ON ${DEVICE} WILL BE ERASED!"
echo ""
read -p "Type 'ERASE' to confirm: " confirm
[[ "${confirm}" == "ERASE" ]] || die "Aborted"

header "Network Setup"

if ! ping -c1 -W2 archlinux.org &>/dev/null; then
    warn "No network connection"
    echo ""
    # Try to find WiFi interface
    WIFI=$(ip link | grep -E "wlan|wlp" | awk -F: '{print $2}' | tr -d ' ' | head -1)
    if [[ -n "${WIFI}" ]]; then
        echo "WiFi interface found: ${WIFI}"
        ip link set "${WIFI}" up 2>/dev/null || true

        echo "Scanning for networks..."
        iw dev "${WIFI}" scan 2>/dev/null | grep SSID | head -10 || true
        echo ""

        read -p "WiFi SSID: " SSID
        read -sp "WiFi Password: " PASS
        echo ""

        wpa_passphrase "${SSID}" "${PASS}" > /tmp/wifi.conf
        wpa_supplicant -B -i "${WIFI}" -c /tmp/wifi.conf
        sleep 2
        dhcpcd "${WIFI}" || udhcpc -i "${WIFI}" || true
        sleep 3
    fi

    ping -c1 -W2 archlinux.org &>/dev/null || die "No network. Connect manually and retry."
fi
ok "Network connected"

header "Partitioning ${DEVICE}"

# Unmount any existing
for part in "${DEVICE}"*; do
    umount "${part}" 2>/dev/null || true
done
swapoff -a 2>/dev/null || true

# Partition: EFI (512M) + Root (rest, btrfs)
parted -s "${DEVICE}" mklabel gpt
parted -s "${DEVICE}" mkpart ESP fat32 1MiB 513MiB
parted -s "${DEVICE}" set 1 esp on
parted -s "${DEVICE}" mkpart root btrfs 513MiB 100%

sleep 2

# Determine partition names
if [[ "${DEVICE}" == *nvme* ]] || [[ "${DEVICE}" == *loop* ]]; then
    EFI_PART="${DEVICE}p1"
    ROOT_PART="${DEVICE}p2"
else
    EFI_PART="${DEVICE}1"
    ROOT_PART="${DEVICE}2"
fi

header "Formatting"

mkfs.fat -F32 "${EFI_PART}"
mkfs.btrfs -f "${ROOT_PART}"

header "Setting up btrfs subvolumes"

export LFS=/mnt/lfs
mkdir -p "${LFS}"
mount "${ROOT_PART}" "${LFS}"

btrfs subvolume create "${LFS}/@"
btrfs subvolume create "${LFS}/@home"
btrfs subvolume create "${LFS}/@snapshots"

umount "${LFS}"

mount -o subvol=@,compress=zstd:3,noatime "${ROOT_PART}" "${LFS}"
mkdir -p "${LFS}/home" "${LFS}/.snapshots" "${LFS}/boot/efi"
mount -o subvol=@home,compress=zstd:3,noatime "${ROOT_PART}" "${LFS}/home"
mount -o subvol=@snapshots,compress=zstd:3,noatime "${ROOT_PART}" "${LFS}/.snapshots"
mount "${EFI_PART}" "${LFS}/boot/efi"

header "Building Full LFS with Desktop"
echo "This will take several hours..."
echo ""

cd /root/lfs-infra

# Prompt for user credentials for the new system
echo "Configure user for the new LFS system:"
read -p "Username [default: user]: " NEW_USERNAME
NEW_USERNAME="${NEW_USERNAME:-user}"

while true; do
    read -sp "Password for ${NEW_USERNAME}: " NEW_PASSWORD
    echo ""
    read -sp "Confirm password: " NEW_PASSWORD_CONFIRM
    echo ""
    [[ "${NEW_PASSWORD}" == "${NEW_PASSWORD_CONFIRM}" ]] && break
    warn "Passwords don't match."
done

export LFS_USERNAME="${NEW_USERNAME}"
export LFS_PASSWORD="${NEW_PASSWORD}"

# Build everything including desktop
./scripts/build/build-lfs.sh all

header "Installing Bootloader"

# Generate fstab
ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}")
EFI_UUID=$(blkid -s UUID -o value "${EFI_PART}")

cat > "${LFS}/etc/fstab" <<EOF
# /etc/fstab - LFS
UUID=${ROOT_UUID}  /            btrfs  subvol=@,compress=zstd:3,noatime  0 1
UUID=${ROOT_UUID}  /home        btrfs  subvol=@home,compress=zstd:3,noatime  0 2
UUID=${ROOT_UUID}  /.snapshots  btrfs  subvol=@snapshots,compress=zstd:3,noatime  0 2
UUID=${EFI_UUID}   /boot/efi    vfat   umask=0077  0 2
proc               /proc        proc   nosuid,noexec,nodev  0 0
sysfs              /sys         sysfs  nosuid,noexec,nodev  0 0
devpts             /dev/pts     devpts gid=5,mode=620  0 0
tmpfs              /run         tmpfs  defaults  0 0
EOF

# Install GRUB
grub-install --target=x86_64-efi \
    --efi-directory="${LFS}/boot/efi" \
    --boot-directory="${LFS}/boot" \
    --bootloader-id=LFS \
    --removable

cat > "${LFS}/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=0

menuentry "LFS" {
    linux /boot/vmlinuz root=UUID=${ROOT_UUID} rootflags=subvol=@ ro quiet
    initrd /boot/initrd.img
}
EOF

header "Cleanup"

umount -R "${LFS}"

header "Installation Complete!"

ok "LFS has been installed to ${DEVICE}"
echo ""
echo "Remove the USB drive and reboot to start your new LFS system."
echo ""
echo "Login: ${NEW_USERNAME}"
echo "(Root is locked - use sudo)"
echo ""
INSTALLER

chmod +x "${LFS}/usr/local/bin/lfs-install"

# Create welcome message
cat > "${LFS}/etc/motd" <<EOF

  _     _____ ____
 | |   |  ___/ ___|
 | |   | |_  \___ \
 | |___|  _|  ___) |
 |_____|_|   |____/

 Linux From Scratch - Minimal Installation USB

 To install full LFS with XFCE desktop onto your hard drive:

   sudo lfs-install /dev/nvme0n1

 Or just: sudo lfs-install (will list drives and prompt)

 WiFi: Use wpa_supplicant or edit /etc/wpa_supplicant.conf

EOF

# Generate fstab for USB
ROOT_UUID=$(blkid -s UUID -o value "${LOOP_ROOT}")
EFI_UUID=$(blkid -s UUID -o value "${LOOP_EFI}")

cat > "${LFS}/etc/fstab" <<EOF
UUID=${ROOT_UUID}  /          ext4  defaults,noatime  0 1
UUID=${EFI_UUID}   /boot/efi  vfat  umask=0077        0 2
proc               /proc      proc  nosuid,noexec,nodev  0 0
sysfs              /sys       sysfs nosuid,noexec,nodev  0 0
devpts             /dev/pts   devpts gid=5,mode=620  0 0
tmpfs              /run       tmpfs  defaults  0 0
EOF

# Install GRUB
log "Installing bootloader..."
grub-install --target=x86_64-efi \
    --efi-directory="${LFS}/boot/efi" \
    --boot-directory="${LFS}/boot" \
    --bootloader-id=LFS \
    --removable

cat > "${LFS}/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=0

menuentry "LFS Installer" {
    linux /boot/vmlinuz root=UUID=${ROOT_UUID} ro quiet
    initrd /boot/initrd.img
}
EOF

log "Unmounting..."
umount -R "${LFS}"
losetup -d "${LOOP_EFI}"
losetup -d "${LOOP_ROOT}"

ok "=========================================="
ok "Minimal LFS USB Build Complete!"
ok "=========================================="
echo ""
echo "Image: ${IMAGE_FILE}"
echo "Boot to bash shell, then run: sudo lfs-install"
echo ""
BUILD_SCRIPT

chmod +x "${OUTPUT_DIR}/build-inside-docker.sh"

header "Starting Build"

log "Building minimal LFS..."
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
    -e IMAGE_SIZE="${IMAGE_SIZE}" \
    -e LFS_USERNAME="${LFS_USERNAME}" \
    -e LFS_PASSWORD="${LFS_PASSWORD}" \
    lfs-builder \
    bash /output/build-inside-docker.sh

[[ -f "${IMAGE_FILE}" ]] || die "Build failed"

ok "Build complete: ${IMAGE_FILE}"
ls -lh "${IMAGE_FILE}"

if [[ ${BUILD_ONLY} -eq 1 ]]; then
    echo ""
    log "To write to USB: sudo dd if=${IMAGE_FILE} of=/dev/rdiskN bs=4m status=progress"
    exit 0
fi

if [[ -z "${DEVICE}" ]]; then
    echo ""
    list_usb_drives
    read -p "Enter disk to write to (e.g., disk4): " DEVICE
fi

[[ -z "${DEVICE}" ]] && die "No device"

DEVICE="${DEVICE#/dev/}"
DEVICE="${DEVICE#disk}"
DEVICE="disk${DEVICE}"

diskutil info "/dev/${DEVICE}" 2>/dev/null | grep -q "Removable Media:.*Yes\|Protocol:.*USB\|Location:.*External" \
    || die "${DEVICE} not a USB drive"

header "Writing to /dev/${DEVICE}"
warn "ALL DATA ON /dev/${DEVICE} WILL BE ERASED!"
read -p "Type 'YES': " confirm
[[ "${confirm}" == "YES" ]] || die "Aborted"

diskutil unmountDisk "/dev/${DEVICE}" || true
sudo dd if="${IMAGE_FILE}" of="/dev/r${DEVICE}" bs=4m status=progress
sync
diskutil eject "/dev/${DEVICE}" || true

header "Done!"
ok "USB ready. Boot it and run: sudo lfs-install"
