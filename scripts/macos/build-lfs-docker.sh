#!/bin/bash
# Build REAL LFS in Docker on macOS (Apple Silicon via Rosetta)
# Creates a complete bootable USB with actual LFS built from source
#
# The Docker container is the BUILD HOST
# The output is REAL LFS built from source with runit, XFCE, Claude Code

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
IMAGE_SIZE="${IMAGE_SIZE:-32G}"
OUTPUT_DIR="${OUTPUT_DIR:-${HOME}/lfs-build}"
IMAGE_FILE="${OUTPUT_DIR}/lfs-complete.img"
CACHE_DIR="${OUTPUT_DIR}/cache"
CONTAINER_NAME="lfs-builder"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build REAL LFS system from source in Docker and write to USB.

The Docker container is the BUILD HOST (Arch Linux with build tools).
The output is REAL LFS built from source with:
  - runit init system (fast boot)
  - XFCE desktop environment
  - Firefox browser
  - Claude Code (native installer)
  - lfs-infra repository

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
    $(basename "$0") -l                 # List available USB drives
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

# List USB drives
list_usb_drives() {
    header "Available USB Drives"
    diskutil list external 2>/dev/null || diskutil list
}

if [[ ${LIST_ONLY} -eq 1 ]]; then
    list_usb_drives
    exit 0
fi

header "LFS Docker Builder - Real LFS from Source"
echo "This builds REAL LFS from source - this will take several hours!"
echo ""

# Prompt for user credentials
header "User Configuration"
read -p "Username for the LFS system [default: user]: " LFS_USERNAME
LFS_USERNAME="${LFS_USERNAME:-user}"

# Validate username
if [[ ! "${LFS_USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    die "Invalid username. Use lowercase letters, numbers, underscore, hyphen."
fi

while true; do
    read -sp "Password for ${LFS_USERNAME}: " LFS_PASSWORD
    echo ""
    read -sp "Confirm password: " LFS_PASSWORD_CONFIRM
    echo ""
    if [[ "${LFS_PASSWORD}" == "${LFS_PASSWORD_CONFIRM}" ]]; then
        break
    fi
    warn "Passwords don't match. Try again."
done

[[ -z "${LFS_PASSWORD}" ]] && die "Password cannot be empty"
ok "User '${LFS_USERNAME}' will be created with sudo access"
echo ""

# Check Docker
if ! docker info &>/dev/null; then
    die "Docker not running. Start OrbStack first."
fi

# Check Rosetta support
log "Checking x86_64 support via Rosetta..."
if docker run --rm --platform linux/amd64 alpine:latest uname -m 2>/dev/null | grep -q x86_64; then
    ok "Rosetta x86_64 emulation working"
else
    die "x86_64 emulation not working. Enable Rosetta in OrbStack settings."
fi

# Create output and cache directories
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${CACHE_DIR}/sources"
mkdir -p "${CACHE_DIR}/tools"

# Clear cache if requested
if [[ ${NO_CACHE} -eq 1 ]]; then
    warn "Clearing caches..."
    rm -rf "${CACHE_DIR:?}"/*
    mkdir -p "${CACHE_DIR}/sources"
    mkdir -p "${CACHE_DIR}/tools"
fi

header "Building LFS Docker Image (Build Host)"

# Create Dockerfile for the BUILD HOST with all LFS dependencies
cat > "${OUTPUT_DIR}/Dockerfile" <<'DOCKERFILE'
FROM archlinux:latest

# Update and install ALL LFS build dependencies
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
        patch diffutils \
        rsync \
        && pacman -Scc --noconfirm

# Create lfs user for building (LFS requires non-root for some steps)
RUN useradd -m lfs && echo "lfs ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

WORKDIR /lfs-build
DOCKERFILE

log "Building Docker image..."
docker build --platform linux/amd64 -t lfs-builder "${OUTPUT_DIR}"

header "Preparing LFS Build Environment"

# Copy lfs-infra repo to output directory for Docker access
log "Copying lfs-infra repository..."
rsync -a --exclude='.git' --exclude='*.img' "${ROOT_DIR}/" "${OUTPUT_DIR}/lfs-infra/"

# Create the main build script that runs inside Docker
cat > "${OUTPUT_DIR}/build-inside-docker.sh" <<'BUILD_SCRIPT'
#!/bin/bash
set -e

export LFS=/mnt/lfs
export LFS_TGT=x86_64-lfs-linux-gnu
export MAKEFLAGS="-j$(nproc)"
export NPROC=$(nproc)
export PATH="${LFS}/tools/bin:${PATH}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[BUILD]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
die() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

# CRITICAL SAFETY CHECK
validate_lfs() {
    if [[ -z "${LFS}" ]]; then
        die "SAFETY: LFS variable is not set!"
    fi
    local forbidden=("/" "/bin" "/boot" "/dev" "/etc" "/home" "/lib" "/lib64"
                     "/opt" "/proc" "/root" "/run" "/sbin" "/srv" "/sys" "/tmp" "/usr" "/var")
    local normalized="${LFS%/}"
    for f in "${forbidden[@]}"; do
        [[ "${normalized}" == "${f}" ]] && die "SAFETY: LFS=${LFS} is protected!"
    done
    [[ "${LFS}" != /* ]] && die "SAFETY: LFS must be absolute path"
    ok "LFS variable validated: ${LFS}"
}

validate_lfs

IMAGE_FILE="/output/lfs-complete.img"
IMAGE_SIZE="${IMAGE_SIZE:-32G}"
LFS_USERNAME="${LFS_USERNAME:-user}"
LFS_PASSWORD="${LFS_PASSWORD:-changeme}"

log "Creating loop device nodes..."
losetup -D 2>/dev/null || true
for i in $(seq 0 31); do
    [[ ! -e /dev/loop${i} ]] && mknod /dev/loop${i} b 7 ${i} 2>/dev/null || true
done
[[ ! -e /dev/loop-control ]] && mknod /dev/loop-control c 10 237 2>/dev/null || true

log "Creating ${IMAGE_SIZE} disk image..."
truncate -s "${IMAGE_SIZE}" "${IMAGE_FILE}"

log "Creating partitions..."
parted -s "${IMAGE_FILE}" mklabel gpt
parted -s "${IMAGE_FILE}" mkpart ESP fat32 1MiB 513MiB
parted -s "${IMAGE_FILE}" set 1 esp on
parted -s "${IMAGE_FILE}" mkpart root ext4 513MiB 100%

log "Setting up loop devices..."
EFI_OFFSET=$((1 * 1024 * 1024))
EFI_SIZE=$((512 * 1024 * 1024))
ROOT_OFFSET=$((513 * 1024 * 1024))

LOOP_EFI=$(losetup -f --show --offset ${EFI_OFFSET} --sizelimit ${EFI_SIZE} "${IMAGE_FILE}")
LOOP_ROOT=$(losetup -f --show --offset ${ROOT_OFFSET} "${IMAGE_FILE}")
log "EFI loop: ${LOOP_EFI}, Root loop: ${LOOP_ROOT}"

log "Formatting partitions..."
mkfs.fat -F32 "${LOOP_EFI}"
mkfs.ext4 -F "${LOOP_ROOT}"

log "Mounting filesystems..."
mkdir -p "${LFS}"
mount "${LOOP_ROOT}" "${LFS}"
mkdir -p "${LFS}/boot/efi"
mount "${LOOP_EFI}" "${LFS}/boot/efi"

# Use cached sources if available
if [[ -d /cache/sources ]] && ls /cache/sources/*.tar.* &>/dev/null; then
    log "Using cached sources..."
    mkdir -p "${LFS}/sources"
    cp -n /cache/sources/*.tar.* "${LFS}/sources/" 2>/dev/null || true
fi

# Use cached tools if available
if [[ -d /cache/tools ]] && [[ -d /cache/tools/bin ]]; then
    log "Using cached toolchain..."
    mkdir -p "${LFS}/tools"
    cp -a /cache/tools/* "${LFS}/tools/" 2>/dev/null || true
fi

log "=========================================="
log "Starting REAL LFS Build from Source"
log "=========================================="

cd /lfs-infra

# Export credentials for build-lfs.sh
export LFS_USERNAME
export LFS_PASSWORD

# Run the actual LFS build
log "Running LFS build script..."
./scripts/build/build-lfs.sh all

# Cache the sources and tools for next build
log "Caching sources and tools for future builds..."
cp -n "${LFS}/sources/"*.tar.* /cache/sources/ 2>/dev/null || true
if [[ -d "${LFS}/tools/bin" ]]; then
    cp -a "${LFS}/tools/"* /cache/tools/ 2>/dev/null || true
fi

# Generate fstab with UUIDs
log "Generating fstab..."
ROOT_UUID=$(blkid -s UUID -o value "${LOOP_ROOT}")
EFI_UUID=$(blkid -s UUID -o value "${LOOP_EFI}")

cat > "${LFS}/etc/fstab" <<EOF
# /etc/fstab - LFS
UUID=${ROOT_UUID}  /          ext4  defaults,noatime  0 1
UUID=${EFI_UUID}   /boot/efi  vfat  umask=0077        0 2
proc               /proc      proc  nosuid,noexec,nodev  0 0
sysfs              /sys       sysfs nosuid,noexec,nodev  0 0
devpts             /dev/pts   devpts gid=5,mode=620      0 0
tmpfs              /run       tmpfs  defaults            0 0
EOF

# Install GRUB bootloader
log "Installing GRUB bootloader..."
# Copy GRUB modules to LFS
mkdir -p "${LFS}/boot/grub/x86_64-efi"

# Install GRUB to EFI
grub-install --target=x86_64-efi \
    --efi-directory="${LFS}/boot/efi" \
    --boot-directory="${LFS}/boot" \
    --bootloader-id=LFS \
    --removable

# Create GRUB config for fast boot
cat > "${LFS}/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=0

menuentry "LFS" {
    linux /boot/vmlinuz root=UUID=${ROOT_UUID} ro quiet
    initrd /boot/initrd.img
}
EOF

# Unmount
log "Unmounting..."
umount -R "${LFS}"
losetup -d "${LOOP_EFI}"
losetup -d "${LOOP_ROOT}"

ok "=========================================="
ok "REAL LFS Build Complete!"
ok "=========================================="
echo ""
echo "Image: ${IMAGE_FILE}"
echo "User: ${LFS_USERNAME} (sudo access, root locked)"
echo ""
echo "This is REAL LFS built from source with:"
echo "  - runit init system"
echo "  - XFCE desktop"
echo "  - Firefox"
echo "  - Claude Code"
echo ""
BUILD_SCRIPT

chmod +x "${OUTPUT_DIR}/build-inside-docker.sh"

header "Starting Docker Build"

log "Building REAL LFS from source..."
log "Image will be created at: ${IMAGE_FILE}"
log "This will take several hours!"
echo ""

# Remove any existing container
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

# Run the build in Docker with caches
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

if [[ ! -f "${IMAGE_FILE}" ]]; then
    die "Build failed - image not created"
fi

ok "Image built successfully: ${IMAGE_FILE}"
ls -lh "${IMAGE_FILE}"

# Write to USB if device specified
if [[ ${BUILD_ONLY} -eq 1 ]]; then
    echo ""
    log "Build-only mode. To write to USB later:"
    log "  sudo dd if=${IMAGE_FILE} of=/dev/rdiskN bs=4m status=progress"
    exit 0
fi

if [[ -z "${DEVICE}" ]]; then
    echo ""
    list_usb_drives
    echo ""
    read -p "Enter disk to write to (e.g., disk4): " DEVICE
fi

[[ -z "${DEVICE}" ]] && die "No device specified"

# Normalize device name
DEVICE="${DEVICE#/dev/}"
DEVICE="${DEVICE#disk}"
DEVICE="disk${DEVICE}"

# Safety check
if ! diskutil info "/dev/${DEVICE}" 2>/dev/null | grep -q "Removable Media:.*Yes\|Protocol:.*USB\|Location:.*External"; then
    die "${DEVICE} doesn't appear to be a USB drive"
fi

header "Writing to /dev/${DEVICE}"

warn "This will ERASE ALL DATA on /dev/${DEVICE}!"
read -p "Type 'YES' to continue: " confirm
[[ "${confirm}" == "YES" ]] || die "Aborted"

log "Unmounting /dev/${DEVICE}..."
diskutil unmountDisk "/dev/${DEVICE}" || true

log "Writing image..."
sudo dd if="${IMAGE_FILE}" of="/dev/r${DEVICE}" bs=4m status=progress

log "Syncing..."
sync

log "Ejecting..."
diskutil eject "/dev/${DEVICE}" || true

header "Complete!"

ok "REAL LFS USB is ready!"
echo ""
echo "Boot from USB and login as: ${LFS_USERNAME}"
echo "(Root account is locked - use sudo for admin tasks)"
echo ""
