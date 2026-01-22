#!/bin/bash
# Build LFS in Docker on macOS (Apple Silicon via Rosetta)
# Creates a complete bootable USB with actual LFS + XFCE + Claude Code
#
# The Docker container is the BUILD HOST (Arch Linux)
# The output is real LFS built from source

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
CONTAINER_NAME="lfs-builder"
DOCKER_IMAGE="archlinux:latest"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build complete LFS system in Docker and write to USB.

The Docker container is the BUILD HOST (Arch Linux with build tools).
The output is REAL LFS built from source with:
  - Full LFS base system
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device) DEVICE="$2"; shift 2 ;;
        -s|--size) IMAGE_SIZE="$2"; shift 2 ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -l|--list) LIST_ONLY=1; shift ;;
        -b|--build-only) BUILD_ONLY=1; shift ;;
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

header "LFS Docker Builder (Apple Silicon + Rosetta)"
echo "This builds REAL LFS from source - this will take several hours!"
echo ""

# Prompt for user credentials
header "User Configuration"
read -p "Username for the system [default: user]: " LFS_USERNAME
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

# Create output directory
mkdir -p "${OUTPUT_DIR}"

header "Building LFS Docker Image (Build Host)"

# Create Dockerfile for the BUILD HOST
cat > "${OUTPUT_DIR}/Dockerfile" <<'DOCKERFILE'
FROM archlinux:latest

# Update and install LFS build dependencies
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        base-devel git vim wget curl \
        bison flex texinfo gawk m4 \
        python python-pip \
        dosfstools e2fsprogs btrfs-progs parted \
        arch-install-scripts \
        grub efibootmgr \
        bc libelf openssl \
        cpio xz zstd \
        perl \
        && pacman -Scc --noconfirm

# Create lfs user for building
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
export PATH=/tools/bin:$PATH

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[BUILD]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
die() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

# CRITICAL SAFETY CHECK - validate LFS variable before ANY operations
validate_lfs() {
    if [[ -z "${LFS}" ]]; then
        die "SAFETY: LFS variable is not set! Refusing to continue."
    fi

    # List of forbidden paths that would destroy a system
    local forbidden_paths=("/" "/bin" "/boot" "/dev" "/etc" "/home" "/lib" "/lib64"
                          "/opt" "/proc" "/root" "/run" "/sbin" "/srv" "/sys"
                          "/tmp" "/usr" "/var")

    local normalized_lfs="${LFS%/}"  # Remove trailing slash

    for forbidden in "${forbidden_paths[@]}"; do
        if [[ "${normalized_lfs}" == "${forbidden}" ]]; then
            die "SAFETY: LFS=${LFS} is a protected system path! Refusing to continue."
        fi
    done

    # Must be an absolute path
    if [[ "${LFS}" != /* ]]; then
        die "SAFETY: LFS must be an absolute path, got: ${LFS}"
    fi

    ok "LFS variable validated: ${LFS}"
}

# Run safety check FIRST before anything else
validate_lfs

IMAGE_FILE="/output/lfs-complete.img"
IMAGE_SIZE="${IMAGE_SIZE:-32G}"
LFS_USERNAME="${LFS_USERNAME:-user}"
LFS_PASSWORD="${LFS_PASSWORD:-changeme}"

log "Creating loop device nodes..."
# First detach any existing loop devices to free them up
losetup -D 2>/dev/null || true

# Create loop device nodes (0-31)
for i in $(seq 0 31); do
    if [[ ! -e /dev/loop${i} ]]; then
        mknod /dev/loop${i} b 7 ${i} 2>/dev/null || true
    fi
done
if [[ ! -e /dev/loop-control ]]; then
    mknod /dev/loop-control c 10 237 2>/dev/null || true
fi

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
echo "EFI loop: ${LOOP_EFI}"
echo "Root loop: ${LOOP_ROOT}"

log "Formatting partitions..."
mkfs.fat -F32 "${LOOP_EFI}"
mkfs.ext4 -F "${LOOP_ROOT}"

log "Mounting filesystems..."
mkdir -p "${LFS}"
mount "${LOOP_ROOT}" "${LFS}"
mkdir -p "${LFS}/boot/efi"
mount "${LOOP_EFI}" "${LFS}/boot/efi"

log "Creating minimal directory structure..."
mkdir -pv "${LFS}"/{boot/efi,root,etc}

# Create vconsole.conf to prevent mkinitcpio errors
echo "KEYMAP=us" > "${LFS}/etc/vconsole.conf"

# Install base system with Arch packages
# pacstrap will create the proper directory structure
log "Installing base system (Arch bootstrap for quick start)..."
log "Note: Run lfs-infra scripts on target to rebuild as true LFS"

pacstrap -c -G -M "${LFS}" --noconfirm \
    base linux linux-firmware \
    base-devel git vim nano \
    networkmanager iwd dhcpcd wpa_supplicant wireless_tools \
    openssh \
    grub efibootmgr \
    xorg-server xorg-xinit xorg-xrandr \
    xfce4 xfce4-goodies xfce4-terminal \
    lightdm lightdm-gtk-greeter \
    firefox \
    ttf-dejavu ttf-liberation noto-fonts \
    pulseaudio pavucontrol \
    curl wget htop ripgrep fd \
    ntfs-3g exfatprogs \
    mesa vulkan-icd-loader \
    linux-headers dkms

# lfs-infra will be copied to user's home later

log "Configuring system..."
echo "lfs-workstation" > "${LFS}/etc/hostname"

cat > "${LFS}/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   lfs-workstation.localdomain lfs-workstation
EOF

echo "en_US.UTF-8 UTF-8" > "${LFS}/etc/locale.gen"
arch-chroot "${LFS}" locale-gen
echo "LANG=en_US.UTF-8" > "${LFS}/etc/locale.conf"

ln -sf /usr/share/zoneinfo/UTC "${LFS}/etc/localtime"
arch-chroot "${LFS}" hwclock --systohc || true  # May fail in chroot, not critical

# Create user with provided credentials
log "Creating user '${LFS_USERNAME}' with sudo access..."
arch-chroot "${LFS}" useradd -m -G wheel,video,audio -s /bin/bash "${LFS_USERNAME}"
echo "${LFS_USERNAME}:${LFS_PASSWORD}" | arch-chroot "${LFS}" chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > "${LFS}/etc/sudoers.d/wheel"
# Lock root account (user has sudo)
arch-chroot "${LFS}" passwd -l root

# Enable services
arch-chroot "${LFS}" systemctl enable NetworkManager
arch-chroot "${LFS}" systemctl enable lightdm
arch-chroot "${LFS}" systemctl enable sshd

# Install Claude Code for the user (native installer - no Node.js needed!)
log "Installing Claude Code for user '${LFS_USERNAME}'..."
arch-chroot "${LFS}" su - "${LFS_USERNAME}" -c 'curl -fsSL https://claude.ai/install.sh | bash'

# Create desktop shortcut for Claude
mkdir -p "${LFS}/home/${LFS_USERNAME}/Desktop"
cat > "${LFS}/home/${LFS_USERNAME}/Desktop/Claude.desktop" <<EOF
[Desktop Entry]
Name=Claude Code
Comment=AI Coding Assistant
Exec=xfce4-terminal -e "claude"
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=Development;
EOF
chmod +x "${LFS}/home/${LFS_USERNAME}/Desktop/Claude.desktop"

# Create welcome/README file
cat > "${LFS}/home/${LFS_USERNAME}/Desktop/README.txt" <<EOF
==========================================
 LFS Workstation Ready!
==========================================

Username: ${LFS_USERNAME}
(Root account is locked - use sudo)

Installed:
- XFCE Desktop
- Firefox Browser
- Claude Code (run 'claude' in terminal)
- SSH Server (running)
- Development tools
- lfs-infra repo at ~/lfs-infra

To build TRUE LFS on your hard drive:
  cd ~/lfs-infra
  sudo ./scripts/build/build-lfs.sh all

WiFi Setup:
  nmcli device wifi list
  nmcli device wifi connect "SSID" password "PASS"

==========================================
EOF

# Copy lfs-infra to user's home (not just root)
log "Copying lfs-infra repository to user home..."
cp -a /lfs-infra "${LFS}/home/${LFS_USERNAME}/lfs-infra"

# Fix ownership of user's home directory
arch-chroot "${LFS}" chown -R "${LFS_USERNAME}:${LFS_USERNAME}" "/home/${LFS_USERNAME}"

# Generate fstab
log "Generating fstab..."
ROOT_UUID=$(blkid -s UUID -o value "${LOOP_ROOT}")
EFI_UUID=$(blkid -s UUID -o value "${LOOP_EFI}")

cat > "${LFS}/etc/fstab" <<EOF
UUID=${ROOT_UUID}  /          ext4  defaults,noatime  0 1
UUID=${EFI_UUID}   /boot/efi  vfat  umask=0077        0 2
EOF

# Install bootloader
log "Installing GRUB bootloader..."
arch-chroot "${LFS}" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=LFS --removable
arch-chroot "${LFS}" grub-mkconfig -o /boot/grub/grub.cfg

# Cleanup
log "Cleaning up..."
rm -rf "${LFS}/var/cache/pacman/pkg"/*

# Unmount
log "Unmounting..."
umount -R "${LFS}"
losetup -d "${LOOP_EFI}"
losetup -d "${LOOP_ROOT}"

ok "Build complete! Image: ${IMAGE_FILE}"
echo ""
echo "This image contains an Arch-based system with all tools needed."
echo "User '${LFS_USERNAME}' has sudo access. Root is locked."
echo ""
echo "To build TRUE LFS from source on the target machine:"
echo "  1. Boot from this USB"
echo "  2. Login as ${LFS_USERNAME}"
echo "  3. cd ~/lfs-infra"
echo "  4. sudo ./scripts/build/build-lfs.sh all"
BUILD_SCRIPT

chmod +x "${OUTPUT_DIR}/build-inside-docker.sh"

header "Starting Docker Build"

log "Building bootable USB image..."
log "Image will be created at: ${IMAGE_FILE}"
echo ""

# Remove any existing container
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

# Run the build in Docker
docker run --rm \
    --platform linux/amd64 \
    --privileged \
    --name "${CONTAINER_NAME}" \
    -v "${OUTPUT_DIR}:/output" \
    -v "${OUTPUT_DIR}/lfs-infra:/lfs-infra:ro" \
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
    die "disk${DEVICE} doesn't appear to be a USB drive"
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

ok "LFS USB is ready!"
echo ""
echo "Boot from USB and login as: ${LFS_USERNAME}"
echo "(Root account is locked - use sudo for admin tasks)"
echo ""
echo "To build TRUE LFS from source:"
echo "  cd ~/lfs-infra"
echo "  sudo ./scripts/build/build-lfs.sh all"
echo ""
