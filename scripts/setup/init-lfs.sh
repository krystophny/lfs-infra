#!/bin/bash
# LFS Environment Initialization Script
# Sets up the LFS build environment from scratch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# Source configurations
source "${ROOT_DIR}/config/lfs.conf"
source "${ROOT_DIR}/config/build.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check if running as root
check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        log_error "This script must be run as root"
    fi
}

# Verify host system requirements
check_host_requirements() {
    log_info "Checking host system requirements..."

    local required_tools=(
        "bash:4.0"
        "binutils:2.25"
        "bison:2.7"
        "gcc:5.2"
        "g++:5.2"
        "glibc:2.17"
        "grep:2.5.1"
        "gzip:1.3.12"
        "m4:1.4.10"
        "make:4.0"
        "patch:2.5.4"
        "perl:5.8.8"
        "python3:3.4"
        "sed:4.1.5"
        "tar:1.22"
        "texinfo:5.0"
        "xz:5.0.0"
    )

    local missing=()

    for tool_spec in "${required_tools[@]}"; do
        local tool="${tool_spec%%:*}"
        local min_version="${tool_spec##*:}"

        if ! command -v "${tool}" >/dev/null 2>&1; then
            missing+=("${tool}")
            continue
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
    fi

    # Check /bin/sh -> bash
    if [[ ! "$(readlink -f /bin/sh)" =~ bash ]]; then
        log_warn "/bin/sh is not linked to bash, this may cause issues"
    fi

    # Check yacc -> bison
    if command -v yacc >/dev/null 2>&1; then
        if [[ ! "$(yacc --version 2>&1)" =~ bison ]]; then
            log_warn "yacc is not bison"
        fi
    fi

    # Check awk -> gawk
    if command -v awk >/dev/null 2>&1; then
        if [[ ! "$(awk --version 2>&1)" =~ GNU ]]; then
            log_warn "awk is not GNU awk"
        fi
    fi

    log_ok "Host requirements check passed"
}

# Create LFS partition and mount
setup_partition() {
    local device="${1:-}"

    if [[ -z "${device}" ]]; then
        log_info "No device specified, assuming ${LFS} is already mounted"

        if ! mountpoint -q "${LFS}" 2>/dev/null; then
            log_warn "${LFS} is not a mount point"
            log_info "Creating ${LFS} as a directory (for testing/development)"
            mkdir -p "${LFS}"
        fi
        return 0
    fi

    log_info "Setting up partition ${device}..."

    # Check if device exists
    if [[ ! -b "${device}" ]]; then
        log_error "Device ${device} does not exist"
    fi

    # Create filesystem
    log_info "Creating ext4 filesystem on ${device}..."
    mkfs.ext4 -F "${device}"

    # Create mount point and mount
    mkdir -p "${LFS}"
    mount "${device}" "${LFS}"

    # Add to fstab
    local uuid=$(blkid -s UUID -o value "${device}")
    if ! grep -q "${uuid}" /etc/fstab; then
        echo "UUID=${uuid} ${LFS} ext4 defaults 0 2" >> /etc/fstab
        log_ok "Added ${device} to /etc/fstab"
    fi

    log_ok "Partition ${device} mounted at ${LFS}"
}

# Create directory structure
create_directories() {
    log_info "Creating directory structure..."

    # Main directories
    mkdir -pv "${LFS}"/{sources,build,tools,pkg,logs}

    # Standard filesystem hierarchy
    mkdir -pv "${LFS}"/{boot,etc,home,mnt,opt,srv,run}
    mkdir -pv "${LFS}"/etc/{opt,sysconfig}
    mkdir -pv "${LFS}"/{lib,bin,sbin}

    # 64-bit specific
    if [[ "$(uname -m)" == "x86_64" ]]; then
        mkdir -pv "${LFS}/lib64"
    fi

    mkdir -pv "${LFS}"/usr/{,local/}{bin,include,lib,sbin,src}
    mkdir -pv "${LFS}"/usr/{,local/}share/{color,dict,doc,info,locale,man}
    mkdir -pv "${LFS}"/usr/{,local/}share/{misc,terminfo,zoneinfo}
    mkdir -pv "${LFS}"/usr/{,local/}share/man/man{1..8}

    mkdir -pv "${LFS}"/var/{cache,local,log,mail,opt,spool}
    mkdir -pv "${LFS}"/var/lib/{color,misc,locate,pkg}

    # Create pkg database directory
    mkdir -pv "${LFS}"/var/lib/pkg
    touch "${LFS}"/var/lib/pkg/db

    # /var/tmp and /tmp
    install -dv -m 1777 "${LFS}"/{var/,}tmp

    # Symlinks
    ln -sfv usr/bin "${LFS}/bin" 2>/dev/null || true
    ln -sfv usr/lib "${LFS}/lib" 2>/dev/null || true
    ln -sfv usr/sbin "${LFS}/sbin" 2>/dev/null || true

    if [[ "$(uname -m)" == "x86_64" ]]; then
        ln -sfv usr/lib "${LFS}/lib64" 2>/dev/null || true
    fi

    # Create tools symlink
    ln -sfv "${LFS}/tools" / 2>/dev/null || true

    log_ok "Directory structure created"
}

# Create lfs user
create_lfs_user() {
    log_info "Creating lfs user..."

    if id lfs >/dev/null 2>&1; then
        log_info "User 'lfs' already exists"
    else
        groupadd lfs 2>/dev/null || true
        useradd -s /bin/bash -g lfs -m -k /dev/null lfs
        log_ok "User 'lfs' created"
    fi

    # Set ownership
    chown -v lfs "${LFS}"/{tools,sources,build,pkg,logs}
    chmod -v a+wt "${LFS}/sources"

    log_ok "LFS user configured"
}

# Setup lfs user environment
setup_lfs_environment() {
    log_info "Setting up lfs user environment..."

    local lfs_home=$(getent passwd lfs | cut -d: -f6)

    # Create .bash_profile
    cat > "${lfs_home}/.bash_profile" << 'BASHPROFILE'
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
BASHPROFILE

    # Create .bashrc with aggressive optimizations
    cat > "${lfs_home}/.bashrc" << BASHRC
set +h
umask 022
LFS=${LFS}
LC_ALL=POSIX
LFS_TGT=\$(uname -m)-lfs-linux-gnu
PATH=${LFS}/tools/bin:/bin:/usr/bin
CONFIG_SITE=${LFS}/usr/share/config.site

# Aggressive optimization flags
NPROC=\$(nproc)
MAKEFLAGS="-j\${NPROC}"

# Performance CFLAGS (be careful with these during bootstrap)
CFLAGS_PERF="-O3 -march=native -mtune=native -pipe"
CXXFLAGS_PERF="\${CFLAGS_PERF}"

export LFS LC_ALL LFS_TGT PATH CONFIG_SITE MAKEFLAGS
export CFLAGS_PERF CXXFLAGS_PERF NPROC
BASHRC

    chown lfs:lfs "${lfs_home}"/.bash{_profile,rc}

    log_ok "LFS environment configured"
}

# Download sources
download_sources() {
    log_info "Downloading package sources..."

    local download_script="${ROOT_DIR}/scripts/build/download-sources.sh"

    if [[ -x "${download_script}" ]]; then
        "${download_script}"
    else
        log_warn "Download script not found, skipping source download"
    fi
}

# Install pkgutils on host (for package management)
install_pkgutils() {
    log_info "Installing pkgutils..."

    local pkgutils_dir="${LFS_SOURCES}/pkgutils"

    if [[ -d "${pkgutils_dir}" ]]; then
        log_info "pkgutils source found, building..."
        cd "${pkgutils_dir}"
        make clean || true
        make -j"$(nproc)"
        make install PREFIX="${LFS}/tools"
        cd -
        log_ok "pkgutils installed to ${LFS}/tools"
    else
        log_warn "pkgutils source not found, will be built during bootstrap"
    fi
}

# Print summary
print_summary() {
    echo ""
    echo "========================================"
    echo -e "${GREEN}LFS Environment Setup Complete${NC}"
    echo "========================================"
    echo ""
    echo "LFS Root:     ${LFS}"
    echo "Sources:      ${LFS_SOURCES}"
    echo "Build Dir:    ${LFS_BUILD}"
    echo "Tools:        ${LFS_TOOLS}"
    echo "Packages:     ${LFS_PKG}"
    echo ""
    echo "CPU Cores:    $(nproc)"
    echo "Make Jobs:    $(nproc)"
    echo ""
    echo "Next steps:"
    echo "  1. Download sources:  ./scripts/build/download-sources.sh"
    echo "  2. Build toolchain:   su - lfs -c '${ROOT_DIR}/scripts/build/build-toolchain.sh'"
    echo "  3. Build system:      chroot into LFS and run build scripts"
    echo ""
}

# Main
main() {
    local device="${1:-}"

    echo -e "${BLUE}LFS Environment Initialization${NC}"
    echo "========================================"

    check_root
    check_host_requirements
    setup_partition "${device}"
    create_directories
    create_lfs_user
    setup_lfs_environment
    install_pkgutils

    print_summary
}

main "$@"
