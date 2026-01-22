#!/bin/bash
# LFS VM Disk Setup
# Creates and partitions a disk image for LFS build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# Source safety library first - validates Linux
source "${ROOT_DIR}/scripts/lib/safety.sh"

# Require Linux for disk operations
require_linux

# Defaults - use /mnt/storage for large disk images
DISK_FILE="${LFS_DISK_FILE:-/mnt/storage/lfs.img}"
DISK_SIZE="${LFS_DISK_SIZE:-512G}"
MOUNT_POINT="${LFS:-/mnt/lfs}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
die() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] COMMAND

Setup disk image for LFS build.

Commands:
    create      Create and partition disk image
    mount       Mount disk image for building
    umount      Unmount disk image
    chroot      Enter chroot environment
    snapshot    Create a btrfs snapshot (e.g., snapshot pre-desktop)
    rollback    Rollback to a snapshot (e.g., rollback pre-desktop)
    status      Show current status

Options:
    -d, --disk FILE     Disk image path (default: ${DISK_FILE})
    -s, --size SIZE     Disk size (default: ${DISK_SIZE})
    -m, --mount PATH    Mount point (default: ${MOUNT_POINT})
    -h, --help          Show this help

Partition layout (GPT):
    1: EFI System Partition (512MB, FAT32)
    2: Root filesystem (rest, btrfs with subvolumes)

Btrfs subvolumes:
    @           Root filesystem
    @snapshots  Snapshot storage (for rollback)
EOF
    exit 0
}

COMMAND=""
SNAPSHOT_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--disk) DISK_FILE="$2"; shift 2 ;;
        -s|--size) DISK_SIZE="$2"; shift 2 ;;
        -m|--mount) MOUNT_POINT="$2"; shift 2 ;;
        -h|--help) usage ;;
        create|mount|umount|chroot|status) COMMAND="$1"; shift ;;
        snapshot|rollback)
            COMMAND="$1"
            [[ $# -ge 2 ]] && SNAPSHOT_NAME="$2" && shift
            shift
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -z "${COMMAND}" ]] && usage

# Check root
check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

# Find free loop device
find_loop() {
    losetup -f
}

# Get loop device for disk
get_loop() {
    losetup -j "${DISK_FILE}" | cut -d: -f1 | head -1
}

# Create disk image with partitions
create_disk() {
    check_root

    # Validate disk file path is safe (not a block device, not in system dirs)
    validate_disk_file "${DISK_FILE}"

    log "Creating disk image: ${DISK_FILE} (${DISK_SIZE})"
    mkdir -p "$(dirname "${DISK_FILE}")"

    # Create sparse file
    truncate -s "${DISK_SIZE}" "${DISK_FILE}"

    # Create GPT partition table
    log "Creating GPT partition table..."
    parted -s "${DISK_FILE}" mklabel gpt

    # Create EFI partition (512MB)
    parted -s "${DISK_FILE}" mkpart ESP fat32 1MiB 513MiB
    parted -s "${DISK_FILE}" set 1 esp on

    # Create root partition (rest)
    parted -s "${DISK_FILE}" mkpart root btrfs 513MiB 100%

    # Setup loop device
    log "Setting up loop device..."
    local loop
    loop=$(find_loop)
    losetup -P "${loop}" "${DISK_FILE}"

    # Format partitions
    log "Formatting EFI partition (FAT32)..."
    mkfs.fat -F32 "${loop}p1"

    log "Formatting root partition (btrfs)..."
    mkfs.btrfs -L lfs-root "${loop}p2"

    # Create btrfs subvolumes
    log "Creating btrfs subvolumes..."
    local tmp_mount="/tmp/lfs-btrfs-setup"
    mkdir -p "${tmp_mount}"
    mount "${loop}p2" "${tmp_mount}"

    btrfs subvolume create "${tmp_mount}/@"
    btrfs subvolume create "${tmp_mount}/@snapshots"

    umount "${tmp_mount}"
    rmdir "${tmp_mount}"

    # Detach loop device
    losetup -d "${loop}"

    ok "Disk created successfully with btrfs subvolumes"
    echo ""
    echo "Partition layout:"
    parted -s "${DISK_FILE}" print
    echo ""
    echo "Btrfs subvolumes: @, @snapshots"
}

# Mount disk image
mount_disk() {
    check_root

    # Validate mount point is safe (will be used as LFS)
    export LFS="${MOUNT_POINT}"
    validate_lfs_variable

    [[ -f "${DISK_FILE}" ]] || die "Disk image not found: ${DISK_FILE}"

    local loop
    loop=$(get_loop)

    if [[ -z "${loop}" ]]; then
        log "Setting up loop device..."
        loop=$(find_loop)
        losetup -P "${loop}" "${DISK_FILE}"
    fi

    log "Mounting partitions..."

    # Create mount point
    mkdir -p "${MOUNT_POINT}"

    # Mount root subvolume with compression
    mount -o subvol=@,compress=zstd:3 "${loop}p2" "${MOUNT_POINT}"

    # Create and mount EFI partition
    mkdir -p "${MOUNT_POINT}/boot/efi"
    mount "${loop}p1" "${MOUNT_POINT}/boot/efi"

    # Mount snapshots subvolume
    mkdir -p "${MOUNT_POINT}/.snapshots"
    mount -o subvol=@snapshots,compress=zstd:3 "${loop}p2" "${MOUNT_POINT}/.snapshots"

    # Create essential directories
    mkdir -p "${MOUNT_POINT}"/{sources,tools,boot,etc,var,usr,lib,bin,sbin}
    mkdir -p "${MOUNT_POINT}/usr"/{bin,lib,sbin}

    # Create lib64 symlink for x86_64
    case $(uname -m) in
        x86_64)
            mkdir -p "${MOUNT_POINT}/lib64"
            [[ -L "${MOUNT_POINT}/usr/lib64" ]] || ln -sf lib "${MOUNT_POINT}/usr/lib64"
            ;;
    esac

    # Create /tools symlink
    [[ -L "${MOUNT_POINT}/tools" ]] || ln -sf usr "${MOUNT_POINT}/tools"

    ok "Mounted at ${MOUNT_POINT}"
    echo ""
    echo "Loop device: ${loop}"
    echo "Root: ${loop}p2 -> ${MOUNT_POINT}"
    echo "EFI:  ${loop}p1 -> ${MOUNT_POINT}/boot/efi"
    echo ""
    echo "Export LFS variable:"
    echo "  export LFS=${MOUNT_POINT}"
}

# Unmount disk image
umount_disk() {
    check_root

    local loop
    loop=$(get_loop)

    if mountpoint -q "${MOUNT_POINT}/.snapshots" 2>/dev/null; then
        log "Unmounting snapshots subvolume..."
        umount "${MOUNT_POINT}/.snapshots"
    fi

    if mountpoint -q "${MOUNT_POINT}/boot/efi" 2>/dev/null; then
        log "Unmounting EFI partition..."
        umount "${MOUNT_POINT}/boot/efi"
    fi

    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        log "Unmounting root subvolume..."
        umount "${MOUNT_POINT}"
    fi

    if [[ -n "${loop}" ]]; then
        log "Detaching loop device..."
        losetup -d "${loop}"
    fi

    ok "Unmounted"
}

# Enter chroot
enter_chroot() {
    check_root

    mountpoint -q "${MOUNT_POINT}" || die "Disk not mounted. Run: $0 mount"

    log "Setting up chroot environment..."

    # Mount virtual filesystems
    mount --bind /dev "${MOUNT_POINT}/dev"
    mount --bind /dev/pts "${MOUNT_POINT}/dev/pts"
    mount -t proc proc "${MOUNT_POINT}/proc"
    mount -t sysfs sysfs "${MOUNT_POINT}/sys"
    mount -t tmpfs tmpfs "${MOUNT_POINT}/run"

    # Enter chroot
    log "Entering chroot..."
    chroot "${MOUNT_POINT}" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM}" \
        PS1='(lfs chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        /bin/bash --login

    # Cleanup virtual filesystems on exit
    log "Cleaning up virtual filesystems..."
    umount "${MOUNT_POINT}/run" 2>/dev/null || true
    umount "${MOUNT_POINT}/sys" 2>/dev/null || true
    umount "${MOUNT_POINT}/proc" 2>/dev/null || true
    umount "${MOUNT_POINT}/dev/pts" 2>/dev/null || true
    umount "${MOUNT_POINT}/dev" 2>/dev/null || true

    ok "Exited chroot"
}

# Create snapshot
create_snapshot() {
    check_root

    [[ -z "${SNAPSHOT_NAME}" ]] && die "Snapshot name required. Usage: $0 snapshot NAME"

    mountpoint -q "${MOUNT_POINT}" || die "Disk not mounted. Run: $0 mount"
    mountpoint -q "${MOUNT_POINT}/.snapshots" || die "Snapshots not mounted"

    local snapshot_path="${MOUNT_POINT}/.snapshots/${SNAPSHOT_NAME}"

    if [[ -d "${snapshot_path}" ]]; then
        die "Snapshot '${SNAPSHOT_NAME}' already exists"
    fi

    log "Creating snapshot: ${SNAPSHOT_NAME}..."
    btrfs subvolume snapshot -r "${MOUNT_POINT}" "${snapshot_path}"

    ok "Snapshot created: ${snapshot_path}"
    echo ""
    echo "Available snapshots:"
    ls -la "${MOUNT_POINT}/.snapshots/"
}

# Rollback to snapshot
rollback_snapshot() {
    check_root

    [[ -z "${SNAPSHOT_NAME}" ]] && die "Snapshot name required. Usage: $0 rollback NAME"

    mountpoint -q "${MOUNT_POINT}" || die "Disk not mounted. Run: $0 mount"

    local snapshot_path="${MOUNT_POINT}/.snapshots/${SNAPSHOT_NAME}"

    if [[ ! -d "${snapshot_path}" ]]; then
        die "Snapshot '${SNAPSHOT_NAME}' not found"
    fi

    log "Rolling back to snapshot: ${SNAPSHOT_NAME}..."

    # Get loop device
    local loop
    loop=$(get_loop)

    # Unmount current root (keep snapshots mounted)
    umount "${MOUNT_POINT}/boot/efi" 2>/dev/null || true
    umount "${MOUNT_POINT}" 2>/dev/null || true

    # Mount the raw partition temporarily
    local tmp_mount="/tmp/lfs-btrfs-rollback"
    mkdir -p "${tmp_mount}"
    mount "${loop}p2" "${tmp_mount}"

    # Delete current @ and recreate from snapshot
    log "Deleting current root subvolume..."
    btrfs subvolume delete "${tmp_mount}/@"

    log "Creating new root from snapshot..."
    btrfs subvolume snapshot "${tmp_mount}/@snapshots/${SNAPSHOT_NAME}" "${tmp_mount}/@"

    umount "${tmp_mount}"
    rmdir "${tmp_mount}"

    # Remount
    mount -o subvol=@,compress=zstd:3 "${loop}p2" "${MOUNT_POINT}"
    mount "${loop}p1" "${MOUNT_POINT}/boot/efi"
    mount -o subvol=@snapshots,compress=zstd:3 "${loop}p2" "${MOUNT_POINT}/.snapshots"

    ok "Rolled back to snapshot: ${SNAPSHOT_NAME}"
}

# Show status
show_status() {
    echo "Disk image: ${DISK_FILE}"
    if [[ -f "${DISK_FILE}" ]]; then
        echo "  Size: $(du -h "${DISK_FILE}" | cut -f1)"
        echo "  Format: $(file "${DISK_FILE}" | cut -d: -f2)"
    else
        echo "  Status: Not created"
    fi

    echo ""
    echo "Loop device:"
    local loop
    loop=$(get_loop 2>/dev/null)
    if [[ -n "${loop}" ]]; then
        echo "  Device: ${loop}"
        lsblk "${loop}" 2>/dev/null || true
    else
        echo "  Status: Not attached"
    fi

    echo ""
    echo "Mount point: ${MOUNT_POINT}"
    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        echo "  Status: Mounted"
        df -h "${MOUNT_POINT}"

        echo ""
        echo "Snapshots:"
        if [[ -d "${MOUNT_POINT}/.snapshots" ]]; then
            ls -1 "${MOUNT_POINT}/.snapshots/" 2>/dev/null || echo "  (none)"
        fi
    else
        echo "  Status: Not mounted"
    fi
}

# Main
case "${COMMAND}" in
    create) create_disk ;;
    mount) mount_disk ;;
    umount) umount_disk ;;
    chroot) enter_chroot ;;
    snapshot) create_snapshot ;;
    rollback) rollback_snapshot ;;
    status) show_status ;;
esac
