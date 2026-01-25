#!/bin/bash
# LFS Master Build Script
# Builds packages directly from packages.toml using pk package manager
#
# Build Stages:
#   Stage 1: Cross-toolchain (built on host, installs to $BOOTSTRAP)
#   Stage 2: Temporary tools (cross-compiled on host, installs to $LFS/usr)
#   Stage 3+: System packages (built in chroot using Stage 2 tools)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# Source safety library
source "${ROOT_DIR}/scripts/lib/safety.sh"

# Configuration
export LFS="${LFS:-/mnt/lfs}"
safety_check

export NPROC="$(nproc)"
export MAKEFLAGS="-j${NPROC}"
export FORCE_UNSAFE_CONFIGURE=1

# Optimization flags for Zen 3 (used by packages that respect environment)
# LTO enabled for Stage 3+ only
export CFLAGS_LTO="-O3 -march=znver3 -mtune=znver3 -pipe -flto=${NPROC} -fuse-linker-plugin"
export CXXFLAGS_LTO="${CFLAGS_LTO}"
export LDFLAGS_LTO="-Wl,-O2 -Wl,--as-needed -flto=${NPROC} -fuse-linker-plugin"

# Safe flags (no LTO, for cross-compilation in stages 1-2)
export CFLAGS_SAFE="-O3 -march=znver3 -mtune=znver3 -pipe"
export CXXFLAGS_SAFE="${CFLAGS_SAFE}"
export LDFLAGS_SAFE="-Wl,-O2 -Wl,--as-needed"

# Default to safe flags (will be overridden per-stage)
export CFLAGS="${CFLAGS_SAFE}"
export CXXFLAGS="${CXXFLAGS_SAFE}"
export FFLAGS="${CFLAGS_SAFE}"
export FCFLAGS="${CFLAGS_SAFE}"
export LDFLAGS="${LDFLAGS_SAFE}"

# Cross-compilation variables (standard names for packages.toml)
# TARGET: target triplet for cross-compilation
# SYSROOT: where target system files go (headers, libraries)
# BOOTSTRAP: where cross-toolchain binaries install (temporary, deleted after build)
# SOURCES: source tarballs location
export TARGET="$(uname -m)-lfs-linux-gnu"
export SYSROOT="${LFS}"
export BOOTSTRAP="${LFS}/var/tmp/lfs-bootstrap"
export SOURCES="${LFS}/usr/src"

# Legacy alias for internal use
export LFS_TGT="${TARGET}"

# Add bootstrap tools to PATH so builds can find cross-assembler, etc.
export PATH="${BOOTSTRAP}/bin:${PATH}"

# Paths
SOURCES_DIR="${SOURCES}"
PKG_CACHE="${LFS}/var/cache/pk"
BUILD_DIR="${LFS}/usr/src"
# Find packages directory dynamically
if [ -n "${PK_PACKAGES_DIR:-}" ]; then
    PACKAGES_DIR="$PK_PACKAGES_DIR"
else
    PACKAGES_DIR=""
    for d in "${ROOT_DIR}/../pk/packages" "/etc/pk/packages" "/usr/share/pk/packages"; do
        [ -d "$d" ] && PACKAGES_DIR="$(cd "$d" && pwd)" && break
    done
fi
[ -n "$PACKAGES_DIR" ] || { echo "Cannot find packages directory"; exit 1; }

# Find pk script dynamically
PK_SCRIPT="${PK_SCRIPT:-$(command -v pk 2>/dev/null || echo "${ROOT_DIR}/../pk/pk")}"

# Helper to cat all package definition files
cat_packages() {
    cat "${PACKAGES_DIR}"/*.toml
}

# Chroot state
CHROOT_PREPARED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }
stage_start() { echo -e "\n${CYAN}========== $* ==========${NC}\n"; }

# ============================================================
# Package info helpers (read from packages.toml)
# ============================================================

get_pkg_field() {
    local pkg="$1" field="$2"
    cat_packages | awk -v pkg="${pkg}" -v field="${field}" '
        BEGIN { pattern = "^\\[packages\\." pkg "\\]$" }
        $0 ~ pattern { found=1; next }
        /^\[/ && found { exit }
        found && $0 ~ "^"field" *= *\"" { gsub(/.*= *"|".*/, ""); print; exit }
    '
}

get_pkg_num_field() {
    local pkg="$1" field="$2"
    cat_packages | awk -v pkg="${pkg}" -v field="${field}" '
        BEGIN { pattern = "^\\[packages\\." pkg "\\]$" }
        $0 ~ pattern { found=1; next }
        /^\[/ && found { exit }
        found && $0 ~ "^"field" *= *[0-9]" { gsub(/.*= */, ""); print; exit }
    '
}

get_pkg_version() { get_pkg_field "$1" "version"; }
get_pkg_description() { get_pkg_field "$1" "description"; }
get_pkg_stage() { get_pkg_num_field "$1" "stage"; }
get_pkg_source_pkg() { get_pkg_field "$1" "source_pkg"; }
get_pkg_build_order() { get_pkg_num_field "$1" "build_order"; }

# Get package dependencies (comma-separated list)
get_pkg_depends() {
    local pkg="$1"
    cat_packages | awk -v pkg="${pkg}" '
        BEGIN { pattern = "^\\[packages\\." pkg "\\]$" }
        $0 ~ pattern { found=1; next }
        /^\[/ && found { exit }
        found && /^depends *= *\[/ {
            gsub(/^depends *= *\[|\]$/, "")
            gsub(/[" ]/, "")
            print
            exit
        }
    '
}

get_pkg_url() {
    local pkg="$1"
    local version version_mm url
    version=$(get_pkg_version "${pkg}")
    version_mm=$(echo "${version}" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
    url=$(get_pkg_field "${pkg}" "url")
    url="${url//\$\{version\}/${version}}"
    url="${url//\$\{version_mm\}/${version_mm}}"
    echo "${url}"
}

get_pkg_build_commands() {
    local pkg="$1"
    cat_packages | awk -v pkg="${pkg}" '
        BEGIN { pattern = "^\\[packages\\." pkg "\\]$" }
        $0 ~ pattern { found=1; next }
        /^\[packages\./ && found { exit }
        found && /^build_commands/ { in_array=1; next }
        in_array && /^\]/ { exit }
        in_array { gsub(/^[[:space:]]*"|"[[:space:]]*,?$/, ""); if (length($0) > 0) print }
    '
}

# List packages by stage, sorted by build_order (packages without build_order come last)
list_packages_by_stage() {
    local stage="$1"
    cat_packages | awk -v target_stage="${stage}" '
/^\[packages\./ {
    if (stage_match) print order, pkg
    pkg = $0
    sub(/^\[packages\./, "", pkg)
    sub(/]$/, "", pkg)
    order = 9999
    stage_match = 0
}
/^stage = / {
    if ($3 + 0 == target_stage) stage_match = 1
}
/^build_order = / {
    order = $3 + 0
}
END {
    if (pkg && stage_match) print order, pkg
}
' | sort -n | cut -d' ' -f2
}

# Check if all dependencies are installed
check_dependencies() {
    local pkg="$1"
    local deps=$(get_pkg_depends "${pkg}")

    [[ -z "${deps}" ]] && return 0

    local IFS=','
    for dep in ${deps}; do
        if ! pkg_installed "${dep}"; then
            die "Dependency not met: ${pkg} requires ${dep}"
        fi
    done
    return 0
}

# ============================================================
# pk integration
# ============================================================

# Check if package is installed (via pk database)
pkg_installed() {
    local pkg="$1"
    [[ -d "${LFS}/var/lib/pk/${pkg}" ]]
}

# Check if package file exists in cache
pkg_cached() {
    local pkg="$1" version="$2"
    [[ -f "${PKG_CACHE}/${pkg}-${version}.pkg.tar.xz" ]]
}

# Install package with pk
pkg_install() {
    local pkg="$1" version="$2"
    local pkg_file="${PKG_CACHE}/${pkg}-${version}.pkg.tar.xz"

    [[ -f "${pkg_file}" ]] || die "Package file not found: ${pkg_file}"

    log "Installing ${pkg} with pk..."
    PK_ROOT="${LFS}" "${PK_SCRIPT}" i "${pkg_file}" || die "pk install failed for ${pkg}"
    ok "Installed ${pkg}"
}

# Build package and create .pkg.tar.xz
build_package() {
    local pkg="$1"
    local version=$(get_pkg_version "${pkg}")
    local url=$(get_pkg_url "${pkg}")
    local source_pkg=$(get_pkg_source_pkg "${pkg}")
    local build_commands=$(get_pkg_build_commands "${pkg}")

    # Use source package URL if specified
    if [[ -n "${source_pkg}" ]]; then
        url=$(get_pkg_url "${source_pkg}")
    fi

    local filename=$(basename "${url}")
    local tarball="${SOURCES_DIR}/${filename}"
    local work_dir="${BUILD_DIR}/${pkg}"
    local pkg_dir="${work_dir}/pkg"
    local pkg_file="${PKG_CACHE}/${pkg}-${version}.pkg.tar.xz"

    [[ -f "${tarball}" ]] || die "Source not found: ${tarball}"

    log "Building ${pkg}-${version}..."

    rm -rf "${work_dir}"
    mkdir -p "${work_dir}/src" "${pkg_dir}"

    tar -xf "${tarball}" -C "${work_dir}/src" || die "Extract failed"

    cd "${work_dir}/src"
    cd "$(ls -d */ | head -1)" 2>/dev/null || true

    export PKG="${pkg_dir}"
    export DESTDIR="${pkg_dir}"

    if [[ -n "${build_commands}" ]]; then
        while IFS= read -r cmd; do
            [[ -z "${cmd}" ]] && continue
            cmd=$(echo "${cmd}" | sed \
                -e "s|\\\${TARGET}|${TARGET}|g" \
                -e "s|\\\${SYSROOT}|${SYSROOT}|g" \
                -e "s|\\\${BOOTSTRAP}|${BOOTSTRAP}|g" \
                -e "s|\\\${SOURCES}|${SOURCES}|g" \
                -e "s|\\\${NPROC}|${NPROC}|g" \
                -e "s|\\\${version}|${version}|g" \
                -e "s|\\\${PKG}|${PKG}|g")
            log "  $ ${cmd}"
            eval "${cmd}" || die "Command failed: ${cmd}"
        done <<< "${build_commands}"
    else
        ./configure --prefix=/usr || die "configure failed"
        make -j${NPROC} || die "make failed"
        make DESTDIR="${PKG}" install || die "make install failed"
    fi

    cd "${pkg_dir}"
    tar --xz -cf "${pkg_file}" . || die "Package creation failed"

    rm -rf "${work_dir}"
    ok "Built ${pkg}-${version}.pkg.tar.xz"
}

# Build and install a package (all stages use pk)
build_and_install() {
    local pkg="$1"
    local version=$(get_pkg_version "${pkg}")
    local desc=$(get_pkg_description "${pkg}")
    local stage=$(get_pkg_stage "${pkg}")

    echo ""
    log ">>> Package: ${pkg}-${version}"
    log "    ${desc}"

    if pkg_installed "${pkg}"; then
        ok "Already installed: ${pkg}"
        return 0
    fi

    # Check dependencies before building
    check_dependencies "${pkg}"

    # Stage 3+: Build and install in chroot
    if [[ "${stage}" -ge 3 ]]; then
        local build_order=$(get_pkg_build_order "${pkg}")
        # Use safe flags for most packages (build_order < 50)
        # LTO causes issues with glibc, gmp, acl, and many others
        # Only enable for well-tested packages with high build_order
        if [[ -n "${build_order}" && "${build_order}" -lt 50 ]]; then
            export CFLAGS="${CFLAGS_SAFE}"
            export CXXFLAGS="${CXXFLAGS_SAFE}"
            export LDFLAGS="${LDFLAGS_SAFE}"
        else
            # Use LTO flags for later Stage 3+ packages
            export CFLAGS="${CFLAGS_LTO}"
            export CXXFLAGS="${CXXFLAGS_LTO}"
            export LDFLAGS="${LDFLAGS_LTO}"
        fi

        if ! pkg_cached "${pkg}" "${version}"; then
            build_package_chroot "${pkg}"
        else
            log "Using cached package: ${pkg}"
        fi
        pkg_install_chroot "${pkg}" "${version}"
    else
        # Stage 1-2: Build on host with cross-compilation
        export CFLAGS="${CFLAGS_SAFE}"
        export CXXFLAGS="${CXXFLAGS_SAFE}"
        export LDFLAGS="${LDFLAGS_SAFE}"

        if ! pkg_cached "${pkg}" "${version}"; then
            build_package "${pkg}"
        else
            log "Using cached package: ${pkg}"
        fi
        pkg_install "${pkg}" "${version}"
    fi
}

# ============================================================
# Bootstrap pk
# ============================================================

# Ensure sys/sdt.h is available for libstdcxx cross-compilation
setup_sdt_header() {
    local sdt_target="${LFS}/usr/include/sys/sdt.h"
    if [[ -f "${sdt_target}" ]]; then
        return 0
    fi

    log "Setting up sys/sdt.h for libstdcxx..."
    mkdir -p "$(dirname "${sdt_target}")"

    # Try to copy from host first
    if [[ -f "/usr/include/sys/sdt.h" ]]; then
        cp "/usr/include/sys/sdt.h" "${sdt_target}"
        ok "Copied sys/sdt.h from host"
        return 0
    fi

    # Create minimal stub if host doesn't have it
    cat > "${sdt_target}" << 'EOF'
/* Minimal sys/sdt.h stub for libstdc++ cross-compilation */
#ifndef _SYS_SDT_H
#define _SYS_SDT_H

#define STAP_PROBE(provider, name)
#define STAP_PROBE1(provider, name, arg1)
#define STAP_PROBE2(provider, name, arg1, arg2)
#define STAP_PROBE3(provider, name, arg1, arg2, arg3)
#define STAP_PROBE4(provider, name, arg1, arg2, arg3, arg4)
#define STAP_PROBE5(provider, name, arg1, arg2, arg3, arg4, arg5)
#define STAP_PROBE6(provider, name, arg1, arg2, arg3, arg4, arg5, arg6)
#define STAP_PROBE7(provider, name, arg1, arg2, arg3, arg4, arg5, arg6, arg7)
#define STAP_PROBE8(provider, name, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
#define STAP_PROBE9(provider, name, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
#define STAP_PROBE10(provider, name, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10)
#define STAP_PROBE11(provider, name, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10, arg11)
#define STAP_PROBE12(provider, name, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10, arg11, arg12)

#define DTRACE_PROBE(provider, name) STAP_PROBE(provider, name)
#define DTRACE_PROBE1(provider, name, arg1) STAP_PROBE1(provider, name, arg1)
#define DTRACE_PROBE2(provider, name, arg1, arg2) STAP_PROBE2(provider, name, arg1, arg2)
#define DTRACE_PROBE3(provider, name, arg1, arg2, arg3) STAP_PROBE3(provider, name, arg1, arg2, arg3)
#define DTRACE_PROBE4(provider, name, arg1, arg2, arg3, arg4) STAP_PROBE4(provider, name, arg1, arg2, arg3, arg4)
#define DTRACE_PROBE5(provider, name, arg1, arg2, arg3, arg4, arg5) STAP_PROBE5(provider, name, arg1, arg2, arg3, arg4, arg5)

#endif /* _SYS_SDT_H */
EOF
    ok "Created sys/sdt.h stub"
}

# ============================================================
# Chroot environment for Stage 3+
# ============================================================

prepare_chroot() {
    [[ ${CHROOT_PREPARED} -eq 1 ]] && return 0

    stage_start "Preparing chroot environment"

    # Create essential directories
    mkdir -p "${LFS}"/{dev,proc,sys,run}

    # Ensure /bin, /lib, /sbin are symlinks to /usr counterparts
    # Merge any existing files first, then create symlinks
    for dir in bin lib sbin; do
        if [[ -d "${LFS}/${dir}" && ! -L "${LFS}/${dir}" ]]; then
            # It's a directory - move files to /usr and replace with symlink
            cp -an "${LFS}/${dir}/"* "${LFS}/usr/${dir}/" 2>/dev/null || true
            rm -rf "${LFS}/${dir}"
            ln -sv "usr/${dir}" "${LFS}/${dir}"
            log "Converted /${dir} to symlink"
        elif [[ ! -e "${LFS}/${dir}" ]]; then
            # Doesn't exist - create symlink
            ln -sv "usr/${dir}" "${LFS}/${dir}"
            log "Created /${dir} symlink"
        fi
    done

    # Create essential system files if they don't exist
    mkdir -p "${LFS}/etc"
    if [[ ! -f "${LFS}/etc/passwd" ]]; then
        cat > "${LFS}/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF
        log "Created /etc/passwd"
    fi
    if [[ ! -f "${LFS}/etc/group" ]]; then
        cat > "${LFS}/etc/group" << 'EOF'
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
kvm:x:61:
uuidd:x:80:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF
        log "Created /etc/group"
    fi

    # Mount virtual kernel filesystems
    if ! mountpoint -q "${LFS}/dev"; then
        mount --bind /dev "${LFS}/dev"
        log "Mounted /dev"
    fi

    if ! mountpoint -q "${LFS}/dev/pts"; then
        mount --bind /dev/pts "${LFS}/dev/pts"
        log "Mounted /dev/pts"
    fi

    if ! mountpoint -q "${LFS}/proc"; then
        mount -t proc proc "${LFS}/proc"
        log "Mounted /proc"
    fi

    if ! mountpoint -q "${LFS}/sys"; then
        mount -t sysfs sysfs "${LFS}/sys"
        log "Mounted /sys"
    fi

    if ! mountpoint -q "${LFS}/run"; then
        mount -t tmpfs tmpfs "${LFS}/run"
        log "Mounted /run"
    fi

    # Copy resolv.conf for network access during build
    if [[ -f /etc/resolv.conf ]]; then
        cp -f /etc/resolv.conf "${LFS}/etc/resolv.conf" 2>/dev/null || true
    fi

    # Create essential directories
    mkdir -p "${LFS}"/{root,tmp,var/{log,run,tmp}}
    chmod 1777 "${LFS}/tmp" "${LFS}/var/tmp"

    # Create basic symlinks if they don't exist
    [[ -L "${LFS}/dev/shm" ]] || ln -sf /run/shm "${LFS}/dev/shm" 2>/dev/null || true
    [[ -L "${LFS}/var/run" ]] || ln -sf ../run "${LFS}/var/run" 2>/dev/null || true

    # Symlink C++ headers from bootstrap to /usr/include so native g++ can find them
    if [[ -d "${LFS}/var/tmp/lfs-bootstrap/${TARGET}/include/c++/16.0.1" ]]; then
        mkdir -p "${LFS}/usr/include/c++"
        if [[ ! -e "${LFS}/usr/include/c++/16.0.1" ]]; then
            ln -svf "/var/tmp/lfs-bootstrap/${TARGET}/include/c++/16.0.1" "${LFS}/usr/include/c++/16.0.1"
            log "Symlinked C++ headers from bootstrap"
        fi
    fi

    CHROOT_PREPARED=1
    ok "Chroot environment ready"
}

cleanup_chroot() {
    log "Cleaning up chroot mounts..."

    # Unmount in reverse order
    for mp in run sys proc dev/pts dev; do
        mountpoint -q "${LFS}/${mp}" && umount -l "${LFS}/${mp}" 2>/dev/null || true
    done

    CHROOT_PREPARED=0
    ok "Chroot cleaned up"
}

# Run a command inside the chroot
# Usage: run_in_chroot "command to run"
run_in_chroot() {
    local cmd="$1"
    chroot "${LFS}" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM}" \
        PATH=/usr/bin:/usr/sbin \
        MAKEFLAGS="-j${NPROC}" \
        NPROC="${NPROC}" \
        CFLAGS="${CFLAGS}" \
        CXXFLAGS="${CXXFLAGS}" \
        LDFLAGS="${LDFLAGS}" \
        FORCE_UNSAFE_CONFIGURE=1 \
        PK_ROOT=/ \
        /bin/bash -c "${cmd}"
}

# Build a package inside chroot (for Stage 3+)
build_package_chroot() {
    local pkg="$1"
    local version=$(get_pkg_version "${pkg}")
    local url=$(get_pkg_url "${pkg}")
    local source_pkg=$(get_pkg_source_pkg "${pkg}")
    local build_commands=$(get_pkg_build_commands "${pkg}")

    # Use source package URL if specified
    if [[ -n "${source_pkg}" ]]; then
        url=$(get_pkg_url "${source_pkg}")
    fi

    local filename=$(basename "${url}")
    local tarball="/usr/src/${filename}"
    local work_dir="/usr/src/${pkg}"
    local pkg_dir="${work_dir}/pkg"
    local pkg_file="/var/cache/pk/${pkg}-${version}.pkg.tar.xz"

    log "Building ${pkg}-${version} in chroot..."

    # Prepare and build inside chroot
    local chroot_script="
set -e
cd /

# Clean and create work directory
rm -rf '${work_dir}'
mkdir -p '${work_dir}/src' '${pkg_dir}'

# Extract source
tar -xf '${tarball}' -C '${work_dir}/src'
cd '${work_dir}/src'
cd \"\$(ls -d */ | head -1)\" 2>/dev/null || true

export PKG='${pkg_dir}'
export DESTDIR='${pkg_dir}'
export version='${version}'
"

    # Add build commands
    if [[ -n "${build_commands}" ]]; then
        while IFS= read -r cmd; do
            [[ -z "${cmd}" ]] && continue
            # Substitute variables using sed to avoid bash brace expansion issues
            cmd=$(echo "${cmd}" | sed \
                -e "s|\\\${version}|${version}|g" \
                -e "s|\\\${NPROC}|${NPROC}|g")
            # Don't substitute ${PKG} - it will be expanded in the chroot environment
            # Escape single quotes in cmd for echo by replacing ' with '\''
            local echo_cmd="${cmd//\'/\'\\\'\'}"
            chroot_script+=$'\n'"echo '>>> ${echo_cmd}'"$'\n'"${cmd}"$'\n'
        done <<< "${build_commands}"
    else
        chroot_script+="
./configure --prefix=/usr
make -j${NPROC}
make DESTDIR=\${PKG} install
"
    fi

    # Create package
    chroot_script+="
cd '${pkg_dir}'
tar --xz -cf '${pkg_file}' .
rm -rf '${work_dir}'
echo 'Package created: ${pkg_file}'
"

    run_in_chroot "${chroot_script}"
    ok "Built ${pkg}-${version}.pkg.tar.xz (chroot)"
}

# Install package with pk inside chroot
pkg_install_chroot() {
    local pkg="$1" version="$2"
    local pkg_file="/var/cache/pk/${pkg}-${version}.pkg.tar.xz"

    log "Installing ${pkg} with pk (chroot)..."
    run_in_chroot "pk i '${pkg_file}'"
    ok "Installed ${pkg}"
}

bootstrap_pk() {
    stage_start "Setting up pk package manager"

    # pk is a shell script, just needs to be available and database initialized
    [[ -x "${PK_SCRIPT}" ]] || die "pk not found at ${PK_SCRIPT}"

    # Ensure directories exist
    mkdir -p "${LFS}/var/lib/pk"
    mkdir -p "${PKG_CACHE}"
    mkdir -p "${BOOTSTRAP}/bin"
    mkdir -p "${LFS}/usr/bin"

    # Install pk into LFS for chroot use
    cp "${PK_SCRIPT}" "${LFS}/usr/bin/pk"
    chmod +x "${LFS}/usr/bin/pk"

    ok "pk ready"
}

# ============================================================
# Download sources
# ============================================================

download_sources() {
    local max_stage="${1:-11}"
    stage_start "Downloading Sources (stages 1-${max_stage})"

    mkdir -p "${SOURCES_DIR}"

    for pkg in $(cat_packages | awk '/^\[packages\./ {gsub(/^\[packages\.|]$/, ""); print}'); do
        local stage=$(get_pkg_stage "${pkg}")
        [[ -z "${stage}" ]] && continue
        [[ "${stage}" -gt "${max_stage}" ]] && continue

        local url=$(get_pkg_url "${pkg}")
        [[ -z "${url}" ]] && continue

        local filename=$(basename "${url}")
        local target="${SOURCES_DIR}/${filename}"

        if [[ -f "${target}" ]]; then
            log "Have: ${filename}"
        else
            log "Downloading: ${filename}"
            curl -fL --connect-timeout 30 --max-time 300 --retry 3 --retry-delay 10 \
                "${url}" -o "${target}.partial" && mv "${target}.partial" "${target}" \
                || warn "Failed: ${filename}"
        fi
    done

    ok "Downloads complete"
}

# ============================================================
# Build stages
# ============================================================

build_stage() {
    local stage="$1"
    local stage_name="$2"

    stage_start "Building Stage ${stage}: ${stage_name}"

    # Prepare chroot for Stage 3+
    if [[ "${stage}" -ge 3 ]]; then
        prepare_chroot
    fi

    for pkg in $(list_packages_by_stage "${stage}"); do
        build_and_install "${pkg}"
    done

    ok "Stage ${stage} complete"
}

# ============================================================
# Main
# ============================================================

main() {
    local target="${1:-all}"
    shift || true
    local extra_args=("$@")

    log "LFS Build Started (pk-based)"
    log "Target: ${target}"
    log "LFS: ${LFS}"
    log "CPUs: ${NPROC}"

    [[ $EUID -eq 0 ]] || die "Must run as root"
    mountpoint -q "${LFS}" || die "LFS not mounted at ${LFS}"
    mkdir -p "${SOURCES_DIR}" "${PKG_CACHE}" "${BUILD_DIR}"

    # Cleanup chroot on exit
    trap cleanup_chroot EXIT

    case "${target}" in
        download)
            local max_stage="${extra_args[0]:-11}"
            download_sources "${max_stage}"
            ;;
        bootstrap)
            bootstrap_pk
            ;;
        minimal)
            download_sources 5
            bootstrap_pk
            setup_sdt_header
            build_stage 1 "Cross-Toolchain"
            build_stage 2 "Temporary Tools"
            build_stage 3 "Base System"
            build_stage 4 "System Config"
            build_stage 5 "Kernel"
            ;;
        all)
            download_sources
            bootstrap_pk
            setup_sdt_header
            build_stage 1 "Cross-Toolchain"
            build_stage 2 "Temporary Tools"
            build_stage 3 "Base System"
            build_stage 4 "System Config"
            build_stage 5 "Kernel"
            ;;
        *)
            if [[ "${target}" =~ ^[0-9]+$ ]]; then
                build_stage "${target}" "Stage ${target}"
            else
                die "Unknown target: ${target}"
            fi
            ;;
    esac

    local elapsed=$(( $(date +%s) - ${BUILD_START:-$(date +%s)} ))
    local hours=$((elapsed / 3600))
    local mins=$(((elapsed % 3600) / 60))
    local secs=$((elapsed % 60))

    echo ""
    echo "=============================================="
    ok "LFS Build Complete!"
    echo "Total time: ${hours}h ${mins}m ${secs}s"
    echo "=============================================="
}

BUILD_START=$(date +%s)
main "$@"
