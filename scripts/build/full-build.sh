#!/bin/bash
# LFS Full Build Script
# Runs the complete LFS build from disk creation to bootable desktop
#
# This script orchestrates:
# 1. Disk image creation
# 2. Filesystem setup
# 3. Source download
# 4. Cross-toolchain build
# 5. Temporary tools
# 6. Chroot base system
# 7. Kernel and bootloader
# 8. Desktop environment
#
# Run as root. Requires ~20GB free space minimum for basic system,
# ~100GB for full desktop with gaming support.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# Source safety library first
source "${ROOT_DIR}/scripts/lib/safety.sh"

# Load configuration
source "${ROOT_DIR}/config/build.conf" 2>/dev/null || true

# Defaults - optimized for build server
export LFS="${LFS:-/mnt/lfs}"

# Run safety checks (require Linux, validate LFS)
safety_check
export DISK_FILE="${LFS_DISK_FILE:-/mnt/storage/lfs.img}"
export DISK_SIZE="${LFS_DISK_SIZE:-512G}"

# Build settings
export MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"
export NPROC="${NPROC:-$(nproc)}"

# Logging
LOG_DIR="/tmp/lfs-build-logs"
MAIN_LOG="${LOG_DIR}/full-build-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*" | tee -a "${MAIN_LOG}"; }
ok() { echo -e "${GREEN}[OK]${NC} $*" | tee -a "${MAIN_LOG}"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${MAIN_LOG}"; }
die() { echo -e "${RED}[FATAL]${NC} $*" | tee -a "${MAIN_LOG}"; exit 1; }

banner() {
    echo -e "\n${CYAN}======================================${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}======================================${NC}\n"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build a complete LFS system from scratch.

Options:
    -d, --disk FILE     Disk image path (default: ${DISK_FILE})
    -s, --size SIZE     Disk size (default: ${DISK_SIZE})
    -m, --mount PATH    LFS mount point (default: ${LFS})
    -c, --continue      Continue from where left off
    -f, --force         Force rebuild (start from scratch)
    --skip-disk         Skip disk creation (use existing)
    --skip-download     Skip source downloads
    --desktop-only      Only build desktop (assumes base system exists)
    -h, --help          Show this help

Environment Variables:
    LFS_DISK_FILE       Disk image path
    LFS_DISK_SIZE       Disk size
    LFS                 Mount point
    MAKEFLAGS           Make flags (default: -j$(nproc))

Examples:
    sudo ./full-build.sh                    # Full build with defaults
    sudo ./full-build.sh -c                 # Continue interrupted build
    sudo ./full-build.sh --skip-disk        # Use existing disk
    sudo ./full-build.sh -d /dev/sdb        # Build to real disk

Log file: ${MAIN_LOG}
EOF
    exit 0
}

# Parse arguments
CONTINUE=0
FORCE=0
SKIP_DISK=0
SKIP_DOWNLOAD=0
DESKTOP_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--disk) DISK_FILE="$2"; shift 2 ;;
        -s|--size) DISK_SIZE="$2"; shift 2 ;;
        -m|--mount) LFS="$2"; shift 2 ;;
        -c|--continue) CONTINUE=1; shift ;;
        -f|--force) FORCE=1; shift ;;
        --skip-disk) SKIP_DISK=1; shift ;;
        --skip-download) SKIP_DOWNLOAD=1; shift ;;
        --desktop-only) DESKTOP_ONLY=1; shift ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

# Ensure running as root
[[ $EUID -eq 0 ]] || die "This script must be run as root"

# Create log directory
mkdir -p "${LOG_DIR}"

# Record start time
BUILD_START=$(date +%s)
log "LFS Full Build Started"
log "Disk: ${DISK_FILE} (${DISK_SIZE})"
log "Mount: ${LFS}"
log "CPUs: ${NPROC}"
log "Log: ${MAIN_LOG}"

# Step 1: Create disk image
step_create_disk() {
    banner "Step 1: Creating Disk Image"

    if [[ ${SKIP_DISK} -eq 1 ]] && [[ -f "${DISK_FILE}" || -b "${DISK_FILE}" ]]; then
        log "Skipping disk creation (--skip-disk)"
        return 0
    fi

    if [[ -f "${DISK_FILE}" ]] && [[ ${FORCE} -eq 0 ]]; then
        log "Disk already exists: ${DISK_FILE}"
        read -p "Delete and recreate? [y/N] " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] || return 0
    fi

    log "Creating disk image..."
    "${SCRIPT_DIR}/../vm/setup-disk.sh" -d "${DISK_FILE}" -s "${DISK_SIZE}" create

    ok "Disk created"
}

# Step 2: Mount disk
step_mount_disk() {
    banner "Step 2: Mounting Disk"

    if mountpoint -q "${LFS}" 2>/dev/null; then
        log "Already mounted at ${LFS}"
        return 0
    fi

    log "Mounting disk..."
    "${SCRIPT_DIR}/../vm/setup-disk.sh" -d "${DISK_FILE}" -m "${LFS}" mount

    ok "Disk mounted at ${LFS}"
}

# Step 3: Download sources
step_download() {
    banner "Step 3: Downloading Sources"

    if [[ ${SKIP_DOWNLOAD} -eq 1 ]]; then
        log "Skipping downloads (--skip-download)"
        return 0
    fi

    log "Downloading sources..."
    "${SCRIPT_DIR}/download-sources.sh" 2>&1 | tee -a "${MAIN_LOG}"

    ok "Sources downloaded"
}

# Step 4: Build cross-toolchain
step_toolchain() {
    banner "Step 4: Building Cross-Toolchain"

    if [[ -f "${LFS}/.build-state" ]] && grep -q "^toolchain$" "${LFS}/.build-state" && [[ ${FORCE} -eq 0 ]]; then
        log "Toolchain already built (use -f to force)"
        return 0
    fi

    log "Building cross-toolchain..."
    "${SCRIPT_DIR}/build-lfs.sh" toolchain 2>&1 | tee -a "${MAIN_LOG}"

    ok "Toolchain complete"
}

# Step 5: Build temporary tools
step_temptools() {
    banner "Step 5: Building Temporary Tools"

    if [[ -f "${LFS}/.build-state" ]] && grep -q "^temptools$" "${LFS}/.build-state" && [[ ${FORCE} -eq 0 ]]; then
        log "Temp tools already built (use -f to force)"
        return 0
    fi

    log "Building temporary tools..."
    "${SCRIPT_DIR}/build-lfs.sh" temptools 2>&1 | tee -a "${MAIN_LOG}"

    ok "Temporary tools complete"
}

# Step 6: Prepare chroot
step_chroot_prep() {
    banner "Step 6: Preparing Chroot Environment"

    if [[ -f "${LFS}/.build-state" ]] && grep -q "^chroot-prep$" "${LFS}/.build-state" && [[ ${FORCE} -eq 0 ]]; then
        log "Chroot already prepared (use -f to force)"
        return 0
    fi

    log "Preparing chroot..."
    "${SCRIPT_DIR}/build-lfs.sh" chroot-prep 2>&1 | tee -a "${MAIN_LOG}"

    ok "Chroot prepared"
}

# Step 7: Build base system
step_base() {
    banner "Step 7: Building Base System"

    if [[ -f "${LFS}/.build-state" ]] && grep -q "^base$" "${LFS}/.build-state" && [[ ${FORCE} -eq 0 ]]; then
        log "Base system already built (use -f to force)"
        return 0
    fi

    log "Building base system in chroot..."
    "${SCRIPT_DIR}/build-lfs.sh" base 2>&1 | tee -a "${MAIN_LOG}"

    ok "Base system complete"
}

# Step 8: Configure system
step_config() {
    banner "Step 8: Configuring System"

    if [[ -f "${LFS}/.build-state" ]] && grep -q "^config$" "${LFS}/.build-state" && [[ ${FORCE} -eq 0 ]]; then
        log "System already configured (use -f to force)"
        return 0
    fi

    log "Configuring system..."
    "${SCRIPT_DIR}/build-lfs.sh" config 2>&1 | tee -a "${MAIN_LOG}"

    ok "System configured"
}

# Step 9: Build kernel
step_kernel() {
    banner "Step 9: Building Linux Kernel"

    if [[ -f "${LFS}/.build-state" ]] && grep -q "^kernel$" "${LFS}/.build-state" && [[ ${FORCE} -eq 0 ]]; then
        log "Kernel already built (use -f to force)"
        return 0
    fi

    log "Building kernel..."
    "${SCRIPT_DIR}/build-lfs.sh" kernel 2>&1 | tee -a "${MAIN_LOG}"

    ok "Kernel complete"
}

# Step 10: Install bootloader
step_bootloader() {
    banner "Step 10: Installing Bootloader"

    if [[ -f "${LFS}/.build-state" ]] && grep -q "^bootloader$" "${LFS}/.build-state" && [[ ${FORCE} -eq 0 ]]; then
        log "Bootloader already installed (use -f to force)"
        return 0
    fi

    log "Installing GRUB bootloader..."
    "${SCRIPT_DIR}/build-lfs.sh" bootloader 2>&1 | tee -a "${MAIN_LOG}"

    ok "Bootloader installed"
}

# Step 11: Build desktop environment
step_desktop() {
    banner "Step 11: Building Desktop Environment"

    if [[ -f "${LFS}/.build-state" ]] && grep -q "^desktop$" "${LFS}/.build-state" && [[ ${FORCE} -eq 0 ]]; then
        log "Desktop already built (use -f to force)"
        return 0
    fi

    log "Building XFCE desktop with Chicago95 theme..."
    "${SCRIPT_DIR}/build-lfs.sh" desktop 2>&1 | tee -a "${MAIN_LOG}"

    ok "Desktop complete"
}

# Final report
final_report() {
    banner "Build Complete!"

    local build_end=$(date +%s)
    local duration=$((build_end - BUILD_START))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))

    echo ""
    echo "=============================================="
    echo "LFS Build Complete!"
    echo "=============================================="
    echo ""
    echo "Build time: ${hours}h ${minutes}m ${seconds}s"
    echo "Disk image: ${DISK_FILE}"
    echo "Mount point: ${LFS}"
    echo ""
    echo "To test in QEMU:"
    echo "  ${ROOT_DIR}/scripts/vm/run-vm.sh"
    echo ""
    echo "To copy to physical disk:"
    echo "  sudo dd if=${DISK_FILE} of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "Log file: ${MAIN_LOG}"
    echo ""

    # Disk usage
    if mountpoint -q "${LFS}" 2>/dev/null; then
        echo "Disk usage:"
        df -h "${LFS}"
    fi
}

# Main execution
main() {
    log "Starting LFS full build..."

    if [[ ${DESKTOP_ONLY} -eq 1 ]]; then
        step_desktop
        final_report
        return 0
    fi

    # Run all steps
    step_create_disk
    step_mount_disk
    step_download
    step_toolchain
    step_temptools
    step_chroot_prep
    step_base
    step_config
    step_kernel
    step_bootloader
    step_desktop

    final_report
}

# Cleanup on exit
cleanup() {
    log "Cleaning up..."
    # Unmount virtual filesystems if mounted
    umount "${LFS}/run" 2>/dev/null || true
    umount "${LFS}/sys" 2>/dev/null || true
    umount "${LFS}/proc" 2>/dev/null || true
    umount "${LFS}/dev/pts" 2>/dev/null || true
    umount "${LFS}/dev" 2>/dev/null || true
}

trap cleanup EXIT

main "$@"
