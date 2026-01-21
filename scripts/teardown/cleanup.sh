#!/bin/bash
# LFS Cleanup Script
# Cleans up build artifacts and optionally unmounts LFS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

source "${ROOT_DIR}/config/lfs.conf" 2>/dev/null || true

LFS="${LFS:-/mnt/lfs}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Clean up LFS build environment.

Options:
    -b, --build         Clean build directory only
    -s, --sources       Clean downloaded sources
    -p, --packages      Clean built packages
    -l, --logs          Clean log files
    -t, --tools         Remove cross-toolchain
    -a, --all           Clean everything (build, sources, packages, logs)
    -u, --umount        Unmount virtual filesystems
    -f, --full          Full teardown (umount + delete LFS directory)
    -h, --help          Show this help

Examples:
    $(basename "$0") -b              # Clean build directory
    $(basename "$0") -a              # Clean all artifacts
    $(basename "$0") -u              # Unmount virtual fs
    $(basename "$0") -f              # Full teardown
EOF
    exit 0
}

CLEAN_BUILD=0
CLEAN_SOURCES=0
CLEAN_PACKAGES=0
CLEAN_LOGS=0
CLEAN_TOOLS=0
DO_UMOUNT=0
FULL_TEARDOWN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--build) CLEAN_BUILD=1; shift ;;
        -s|--sources) CLEAN_SOURCES=1; shift ;;
        -p|--packages) CLEAN_PACKAGES=1; shift ;;
        -l|--logs) CLEAN_LOGS=1; shift ;;
        -t|--tools) CLEAN_TOOLS=1; shift ;;
        -a|--all)
            CLEAN_BUILD=1
            CLEAN_SOURCES=1
            CLEAN_PACKAGES=1
            CLEAN_LOGS=1
            shift
            ;;
        -u|--umount) DO_UMOUNT=1; shift ;;
        -f|--full)
            DO_UMOUNT=1
            FULL_TEARDOWN=1
            shift
            ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1" ;;
    esac
done

# Check if nothing selected
if [[ ${CLEAN_BUILD} -eq 0 ]] && [[ ${CLEAN_SOURCES} -eq 0 ]] && \
   [[ ${CLEAN_PACKAGES} -eq 0 ]] && [[ ${CLEAN_LOGS} -eq 0 ]] && \
   [[ ${CLEAN_TOOLS} -eq 0 ]] && [[ ${DO_UMOUNT} -eq 0 ]]; then
    usage
fi

# Unmount virtual filesystems
umount_virtual_fs() {
    log_info "Unmounting virtual filesystems..."

    local mounts=(
        "${LFS}/dev/shm"
        "${LFS}/dev/pts"
        "${LFS}/run"
        "${LFS}/sys"
        "${LFS}/proc"
        "${LFS}/dev"
    )

    for mount in "${mounts[@]}"; do
        if mountpoint -q "${mount}" 2>/dev/null; then
            umount -lv "${mount}" 2>/dev/null || log_warn "Failed to unmount ${mount}"
        fi
    done

    log_ok "Virtual filesystems unmounted"
}

# Clean build directory
clean_build() {
    log_info "Cleaning build directory..."

    if [[ -d "${LFS}/build" ]]; then
        rm -rf "${LFS}/build"/*
        log_ok "Build directory cleaned"
    else
        log_warn "Build directory not found"
    fi
}

# Clean sources
clean_sources() {
    log_info "Cleaning sources directory..."

    if [[ -d "${LFS}/sources" ]]; then
        rm -rf "${LFS}/sources"/*
        log_ok "Sources directory cleaned"
    else
        log_warn "Sources directory not found"
    fi
}

# Clean packages
clean_packages() {
    log_info "Cleaning packages directory..."

    if [[ -d "${LFS}/pkg" ]]; then
        rm -rf "${LFS}/pkg"/*
        log_ok "Packages directory cleaned"
    else
        log_warn "Packages directory not found"
    fi
}

# Clean logs
clean_logs() {
    log_info "Cleaning logs directory..."

    if [[ -d "${LFS}/logs" ]]; then
        rm -rf "${LFS}/logs"/*
        log_ok "Logs directory cleaned"
    else
        log_warn "Logs directory not found"
    fi
}

# Clean tools
clean_tools() {
    log_info "Removing cross-toolchain..."

    if [[ -d "${LFS}/tools" ]]; then
        rm -rf "${LFS}/tools"
        log_ok "Cross-toolchain removed"
    else
        log_warn "Tools directory not found"
    fi

    # Remove symlink
    rm -f /tools
}

# Full teardown
full_teardown() {
    log_warn "Full teardown will delete ${LFS}"
    read -p "Are you sure? [y/N] " -n 1 -r
    echo

    if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
        log_info "Aborted"
        exit 0
    fi

    # Remove lfs user
    if id lfs >/dev/null 2>&1; then
        log_info "Removing lfs user..."
        userdel -r lfs 2>/dev/null || true
        groupdel lfs 2>/dev/null || true
    fi

    # Unmount LFS partition if mounted
    if mountpoint -q "${LFS}" 2>/dev/null; then
        log_info "Unmounting ${LFS}..."
        umount -l "${LFS}"
    fi

    # Remove directory
    if [[ -d "${LFS}" ]]; then
        log_info "Removing ${LFS}..."
        rm -rf "${LFS}"
    fi

    # Remove /tools symlink
    rm -f /tools

    log_ok "Full teardown complete"
}

# Main
main() {
    echo -e "${BLUE}LFS Cleanup${NC}"
    echo "========================================"

    # Check root for certain operations
    if [[ ${DO_UMOUNT} -eq 1 ]] || [[ ${FULL_TEARDOWN} -eq 1 ]]; then
        if [[ ${EUID} -ne 0 ]]; then
            log_error "Root required for umount/teardown operations"
        fi
    fi

    [[ ${DO_UMOUNT} -eq 1 ]] && umount_virtual_fs
    [[ ${CLEAN_BUILD} -eq 1 ]] && clean_build
    [[ ${CLEAN_SOURCES} -eq 1 ]] && clean_sources
    [[ ${CLEAN_PACKAGES} -eq 1 ]] && clean_packages
    [[ ${CLEAN_LOGS} -eq 1 ]] && clean_logs
    [[ ${CLEAN_TOOLS} -eq 1 ]] && clean_tools
    [[ ${FULL_TEARDOWN} -eq 1 ]] && full_teardown

    echo ""
    echo "========================================"
    echo -e "${GREEN}Cleanup complete${NC}"
}

main
