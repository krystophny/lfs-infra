#!/bin/bash
# LFS Real Hardware Installation Setup
# Prepares a real partition for LFS installation with NVIDIA, WiFi, and Ethernet support

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# Source safety library
source "${ROOT_DIR}/scripts/lib/safety.sh"
require_linux

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

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] DEVICE

Setup a real partition for LFS installation.

Arguments:
    DEVICE          Block device to use (e.g., /dev/nvme1n1, /dev/sdb)

Options:
    -m, --mount PATH    Mount point (default: /mnt/lfs)
    -e, --efi-size SIZE EFI partition size (default: 512M)
    -s, --swap SIZE     Swap partition size (default: 16G, 0 to disable)
    -f, --filesystem FS Root filesystem: btrfs (default), ext4, xfs
    -y, --yes           Skip confirmation prompts
    -h, --help          Show this help

Examples:
    # Install on second NVMe drive
    $(basename "$0") /dev/nvme1n1

    # Install on USB drive with ext4
    $(basename "$0") -f ext4 /dev/sdb

    # Custom mount point and swap size
    $(basename "$0") -m /mnt/mylfs -s 32G /dev/nvme1n1

Notes:
    - This script will ERASE ALL DATA on the target device
    - Run from a live Linux environment (not from the target system)
    - Requires: parted, mkfs utilities, and root privileges
EOF
    exit 0
}

# Defaults
MOUNT_POINT="/mnt/lfs"
EFI_SIZE="512M"
SWAP_SIZE="16G"
ROOT_FS="btrfs"
SKIP_CONFIRM=0
DEVICE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mount) MOUNT_POINT="$2"; shift 2 ;;
        -e|--efi-size) EFI_SIZE="$2"; shift 2 ;;
        -s|--swap) SWAP_SIZE="$2"; shift 2 ;;
        -f|--filesystem) ROOT_FS="$2"; shift 2 ;;
        -y|--yes) SKIP_CONFIRM=1; export LFS_I_KNOW_WHAT_I_AM_DOING=1; shift ;;
        -h|--help) usage ;;
        /dev/*) DEVICE="$1"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -z "${DEVICE}" ]] && usage

# Must be root
[[ $EUID -eq 0 ]] || die "This script must be run as root"

# Validate device
validate_device "${DEVICE}"

# Export LFS for other scripts
export LFS="${MOUNT_POINT}"
validate_lfs_variable

header "LFS Real Hardware Installation Setup"

echo "Configuration:"
echo "  Device:      ${DEVICE}"
echo "  Mount point: ${MOUNT_POINT}"
echo "  EFI size:    ${EFI_SIZE}"
echo "  Swap size:   ${SWAP_SIZE}"
echo "  Root FS:     ${ROOT_FS}"
echo ""

# Show current partition table
log "Current partition table on ${DEVICE}:"
parted -s "${DEVICE}" print 2>/dev/null || true
echo ""

if [[ ${SKIP_CONFIRM} -eq 0 ]]; then
    warn "This will ERASE ALL DATA on ${DEVICE}!"
    read -p "Type 'ERASE' to continue: " confirm
    if [[ "${confirm}" != "ERASE" ]]; then
        die "Aborted by user"
    fi
fi

header "Detecting Hardware"

# Detect hardware
log "Detecting network hardware..."
echo ""
echo "Ethernet controllers:"
lspci | grep -i ethernet || echo "  (none found via PCI)"
echo ""
echo "WiFi controllers:"
lspci | grep -i wireless || lspci | grep -i wifi || lspci | grep -i network | grep -i wireless || echo "  (none found via PCI)"
echo ""
echo "GPU:"
lspci | grep -i vga || lspci | grep -i nvidia || echo "  (none found)"
echo ""

header "Creating Partitions"

# Unmount any existing mounts on device
for part in "${DEVICE}"*; do
    if mountpoint -q "${part}" 2>/dev/null; then
        log "Unmounting ${part}..."
        umount "${part}" || true
    fi
done

# Create GPT partition table
log "Creating GPT partition table..."
parted -s "${DEVICE}" mklabel gpt

# Calculate partition layout
# p1: EFI (512M default)
# p2: Swap (16G default, optional)
# p3: Root (rest)

EFI_END="${EFI_SIZE}"
# Convert to MiB for parted
case "${EFI_SIZE}" in
    *M) EFI_END_MIB="${EFI_SIZE%M}" ;;
    *G) EFI_END_MIB="$((${EFI_SIZE%G} * 1024))" ;;
    *) EFI_END_MIB="${EFI_SIZE}" ;;
esac
EFI_END_MIB=$((EFI_END_MIB + 1))  # Start at 1MiB

# Create EFI partition
log "Creating EFI System Partition (${EFI_SIZE})..."
parted -s "${DEVICE}" mkpart ESP fat32 1MiB "${EFI_END_MIB}MiB"
parted -s "${DEVICE}" set 1 esp on

NEXT_START="${EFI_END_MIB}"

# Create swap partition if requested
if [[ "${SWAP_SIZE}" != "0" ]]; then
    case "${SWAP_SIZE}" in
        *M) SWAP_SIZE_MIB="${SWAP_SIZE%M}" ;;
        *G) SWAP_SIZE_MIB="$((${SWAP_SIZE%G} * 1024))" ;;
        *) SWAP_SIZE_MIB="${SWAP_SIZE}" ;;
    esac
    SWAP_END=$((NEXT_START + SWAP_SIZE_MIB))

    log "Creating swap partition (${SWAP_SIZE})..."
    parted -s "${DEVICE}" mkpart swap linux-swap "${NEXT_START}MiB" "${SWAP_END}MiB"
    NEXT_START="${SWAP_END}"
    SWAP_PART=2
    ROOT_PART=3
else
    SWAP_PART=""
    ROOT_PART=2
fi

# Create root partition
log "Creating root partition (${ROOT_FS})..."
parted -s "${DEVICE}" mkpart root "${ROOT_FS}" "${NEXT_START}MiB" 100%

# Wait for partitions to appear
sleep 2

# Determine partition naming scheme
if [[ "${DEVICE}" == *nvme* ]] || [[ "${DEVICE}" == *loop* ]]; then
    PART_PREFIX="${DEVICE}p"
else
    PART_PREFIX="${DEVICE}"
fi

EFI_PARTITION="${PART_PREFIX}1"
[[ -n "${SWAP_PART:-}" ]] && SWAP_PARTITION="${PART_PREFIX}${SWAP_PART}"
ROOT_PARTITION="${PART_PREFIX}${ROOT_PART}"

header "Formatting Partitions"

# Format EFI partition
log "Formatting EFI partition as FAT32..."
mkfs.fat -F32 -n EFI "${EFI_PARTITION}"

# Format swap partition
if [[ -n "${SWAP_PART:-}" ]]; then
    log "Setting up swap partition..."
    mkswap -L swap "${SWAP_PARTITION}"
fi

# Format root partition
log "Formatting root partition as ${ROOT_FS}..."
case "${ROOT_FS}" in
    btrfs)
        mkfs.btrfs -f -L lfs-root "${ROOT_PARTITION}"
        ;;
    ext4)
        mkfs.ext4 -L lfs-root "${ROOT_PARTITION}"
        ;;
    xfs)
        mkfs.xfs -f -L lfs-root "${ROOT_PARTITION}"
        ;;
    *)
        die "Unknown filesystem: ${ROOT_FS}"
        ;;
esac

header "Mounting Filesystems"

# Create mount point
mkdir -p "${MOUNT_POINT}"

# Mount root
if [[ "${ROOT_FS}" == "btrfs" ]]; then
    # Create subvolumes for btrfs
    log "Creating btrfs subvolumes..."
    mount "${ROOT_PARTITION}" "${MOUNT_POINT}"
    btrfs subvolume create "${MOUNT_POINT}/@"
    btrfs subvolume create "${MOUNT_POINT}/@home"
    btrfs subvolume create "${MOUNT_POINT}/@snapshots"
    umount "${MOUNT_POINT}"

    # Mount with compression
    log "Mounting root with zstd compression..."
    mount -o subvol=@,compress=zstd:3 "${ROOT_PARTITION}" "${MOUNT_POINT}"
    mkdir -p "${MOUNT_POINT}/home" "${MOUNT_POINT}/.snapshots"
    mount -o subvol=@home,compress=zstd:3 "${ROOT_PARTITION}" "${MOUNT_POINT}/home"
    mount -o subvol=@snapshots,compress=zstd:3 "${ROOT_PARTITION}" "${MOUNT_POINT}/.snapshots"
else
    mount "${ROOT_PARTITION}" "${MOUNT_POINT}"
fi

# Mount EFI
mkdir -p "${MOUNT_POINT}/boot/efi"
mount "${EFI_PARTITION}" "${MOUNT_POINT}/boot/efi"

# Enable swap
if [[ -n "${SWAP_PART:-}" ]]; then
    log "Enabling swap..."
    swapon "${SWAP_PARTITION}"
fi

header "Creating Directory Structure"

# Create LFS directory structure
mkdir -p "${MOUNT_POINT}"/{sources,tools,build,pkg,logs}
mkdir -p "${MOUNT_POINT}"/{boot,etc,home,mnt,opt,srv,run}
mkdir -p "${MOUNT_POINT}"/etc/{opt,sysconfig}
mkdir -p "${MOUNT_POINT}"/{lib,bin,sbin}

if [[ "$(uname -m)" == "x86_64" ]]; then
    mkdir -p "${MOUNT_POINT}/lib64"
fi

mkdir -p "${MOUNT_POINT}"/usr/{,local/}{bin,include,lib,sbin,src}
mkdir -p "${MOUNT_POINT}"/usr/{,local/}share/{color,dict,doc,info,locale,man}
mkdir -p "${MOUNT_POINT}"/usr/{,local/}share/{misc,terminfo,zoneinfo}
mkdir -p "${MOUNT_POINT}"/usr/{,local/}share/man/man{1..8}

mkdir -p "${MOUNT_POINT}"/var/{cache,local,log,mail,opt,spool}
mkdir -p "${MOUNT_POINT}"/var/lib/{color,misc,locate,pkg}

install -dv -m 1777 "${MOUNT_POINT}"/{var/,}tmp

# Create firmware directory for drivers
mkdir -p "${MOUNT_POINT}/lib/firmware"

header "Generating fstab"

# Generate fstab
log "Generating /etc/fstab..."
EFI_UUID=$(blkid -s UUID -o value "${EFI_PARTITION}")
ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PARTITION}")

mkdir -p "${MOUNT_POINT}/etc"

cat > "${MOUNT_POINT}/etc/fstab" << EOF
# /etc/fstab - LFS filesystem table
# Generated by setup-real-hardware.sh

# Root filesystem
EOF

if [[ "${ROOT_FS}" == "btrfs" ]]; then
    cat >> "${MOUNT_POINT}/etc/fstab" << EOF
UUID=${ROOT_UUID}  /             btrfs  subvol=@,compress=zstd:3,noatime  0 1
UUID=${ROOT_UUID}  /home         btrfs  subvol=@home,compress=zstd:3,noatime  0 2
UUID=${ROOT_UUID}  /.snapshots   btrfs  subvol=@snapshots,compress=zstd:3,noatime  0 2
EOF
else
    cat >> "${MOUNT_POINT}/etc/fstab" << EOF
UUID=${ROOT_UUID}  /             ${ROOT_FS}  defaults,noatime  0 1
EOF
fi

cat >> "${MOUNT_POINT}/etc/fstab" << EOF

# EFI System Partition
UUID=${EFI_UUID}   /boot/efi     vfat   umask=0077  0 2
EOF

if [[ -n "${SWAP_PART:-}" ]]; then
    SWAP_UUID=$(blkid -s UUID -o value "${SWAP_PARTITION}")
    cat >> "${MOUNT_POINT}/etc/fstab" << EOF

# Swap
UUID=${SWAP_UUID}  none          swap   sw  0 0
EOF
fi

cat >> "${MOUNT_POINT}/etc/fstab" << EOF

# Virtual filesystems
proc           /proc         proc   nosuid,noexec,nodev  0 0
sysfs          /sys          sysfs  nosuid,noexec,nodev  0 0
devpts         /dev/pts      devpts gid=5,mode=620       0 0
tmpfs          /run          tmpfs  defaults             0 0
devtmpfs       /dev          devtmpfs mode=0755,nosuid   0 0
EOF

header "Installation Summary"

echo "Partition layout:"
parted -s "${DEVICE}" print
echo ""

echo "Mount points:"
df -h "${MOUNT_POINT}" "${MOUNT_POINT}/boot/efi"
echo ""

echo "Generated fstab:"
cat "${MOUNT_POINT}/etc/fstab"
echo ""

ok "Real hardware setup complete!"
echo ""
echo "Next steps:"
echo "  1. Export LFS variable:"
echo "     export LFS=${MOUNT_POINT}"
echo ""
echo "  2. Download sources:"
echo "     ./scripts/build/download-sources.sh"
echo ""
echo "  3. Build LFS with hardware config:"
echo "     export KERNEL_CONFIG=${ROOT_DIR}/config/kernel/nvidia-hardware.config"
echo "     ./scripts/build/build-lfs.sh all"
echo ""
echo "  4. Install firmware (after chroot):"
echo "     Install linux-firmware package for WiFi/Ethernet/GPU support"
echo ""
echo "  5. Install NVIDIA driver (if applicable):"
echo "     ./NVIDIA-Linux-x86_64-*.run --no-questions --ui=none"
echo ""
echo "Hardware detected:"
echo "  - Use iwlwifi for Intel WiFi"
echo "  - Use r8169/r8125 for Realtek Ethernet"
echo "  - Use e1000e/igb for Intel Ethernet"
echo "  - Use NVIDIA proprietary driver for NVIDIA GPU"
