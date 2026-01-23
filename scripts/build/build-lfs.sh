#!/bin/bash
# LFS Master Build Script - fay based
# Builds packages directly from packages.toml using fay package manager

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

# Cross-compilation variables (standard names for packages.toml)
# TARGET: target triplet for cross-compilation
# SYSROOT: where target system files go (headers, libraries)
# CROSS_TOOLS: where cross-toolchain binaries install
# SOURCES: source tarballs location
export TARGET="$(uname -m)-lfs-linux-gnu"
export SYSROOT="${LFS}"
export CROSS_TOOLS="${LFS}/tools"
export SOURCES="${LFS}/sources"

# Legacy alias for internal use
export LFS_TGT="${TARGET}"
export TOOLS="${CROSS_TOOLS}"

# Add cross-tools to PATH so later builds can find cross-assembler, etc.
export PATH="${TOOLS}/bin:${PATH}"

# Paths
SOURCES_DIR="${SOURCES}"
PKG_CACHE="${LFS}/pkg"
BUILD_DIR="${LFS}/build"
PACKAGES_FILE="${ROOT_DIR}/packages.toml"
FAY_DIR="${ROOT_DIR}/fay"

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
    awk -v pkg="[packages.${pkg}]" -v field="${field}" '
        $0 == pkg { found=1; next }
        /^\[/ && found { exit }
        found && $0 ~ "^"field" *= *\"" { gsub(/.*= *"|".*/, ""); print; exit }
    ' "${PACKAGES_FILE}"
}

get_pkg_num_field() {
    local pkg="$1" field="$2"
    awk -v pkg="[packages.${pkg}]" -v field="${field}" '
        $0 == pkg { found=1; next }
        /^\[/ && found { exit }
        found && $0 ~ "^"field" *= *[0-9]" { gsub(/.*= */, ""); print; exit }
    ' "${PACKAGES_FILE}"
}

get_pkg_version() { get_pkg_field "$1" "version"; }
get_pkg_description() { get_pkg_field "$1" "description"; }
get_pkg_stage() { get_pkg_num_field "$1" "stage"; }
get_pkg_source_pkg() { get_pkg_field "$1" "source_pkg"; }
get_pkg_build_order() { get_pkg_num_field "$1" "build_order"; }

# Get package dependencies (comma-separated list)
get_pkg_depends() {
    local pkg="$1"
    awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[/ && found { exit }
        found && /^depends *= *\[/ {
            gsub(/^depends *= *\[|\]$/, "")
            gsub(/[" ]/, "")
            print
            exit
        }
    ' "${PACKAGES_FILE}"
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
    awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[packages\./ && found { exit }
        found && /^build_commands/ { in_array=1; next }
        in_array && /^\]/ { exit }
        in_array { gsub(/^[[:space:]]*"|"[[:space:]]*,?$/, ""); if (length($0) > 0) print }
    ' "${PACKAGES_FILE}"
}

# List packages by stage, sorted by build_order (packages without build_order come last)
list_packages_by_stage() {
    local stage="$1"
    awk -v target_stage="${stage}" -f <(cat <<'AWKSCRIPT'
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
AWKSCRIPT
) "${PACKAGES_FILE}" | sort -n | cut -d' ' -f2
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
# fay integration
# ============================================================

# Check if package is installed (via fay database)
pkg_installed() {
    local pkg="$1"
    [[ -d "${LFS}/var/lib/fay/${pkg}" ]]
}

# Check if package file exists in cache
pkg_cached() {
    local pkg="$1" version="$2"
    [[ -f "${PKG_CACHE}/${pkg}-${version}.pkg.tar.xz" ]]
}

# Install package with fay
pkg_install() {
    local pkg="$1" version="$2"
    local pkg_file="${PKG_CACHE}/${pkg}-${version}.pkg.tar.xz"

    [[ -f "${pkg_file}" ]] || die "Package file not found: ${pkg_file}"

    log "Installing ${pkg} with fay..."
    FAY_ROOT="${LFS}" fay i "${pkg_file}" || die "fay install failed for ${pkg}"
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
                -e "s|\\\${CROSS_TOOLS}|${CROSS_TOOLS}|g" \
                -e "s|\\\${TOOLS}|${TOOLS}|g" \
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

# Build and install a package (all stages use fay)
build_and_install() {
    local pkg="$1"
    local version=$(get_pkg_version "${pkg}")
    local desc=$(get_pkg_description "${pkg}")

    echo ""
    log ">>> Package: ${pkg}-${version}"
    log "    ${desc}"

    if pkg_installed "${pkg}"; then
        ok "Already installed: ${pkg}"
        return 0
    fi

    # Check dependencies before building
    check_dependencies "${pkg}"

    if ! pkg_cached "${pkg}" "${version}"; then
        log "Building ${pkg}..."
        build_package "${pkg}"
    else
        log "Using cached package: ${pkg}"
    fi

    pkg_install "${pkg}" "${version}"
}

# ============================================================
# Bootstrap fay
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

bootstrap_fay() {
    stage_start "Bootstrapping fay (Fast Archive Yielder)"

    # Check if fay already built
    if [[ -x "${LFS}/tools/bin/fay" ]] || command -v fay &>/dev/null; then
        ok "fay already available"
        return 0
    fi

    # Need host gfortran and libarchive-dev to build fay
    if ! command -v gfortran &>/dev/null; then
        die "gfortran required to build fay (install: apt install gfortran)"
    fi

    log "Building fay..."
    cd "${FAY_DIR}"

    # Build fay with static libarchive
    make clean 2>/dev/null || true
    make bootstrap || die "fay build failed"

    # Install to host (for building packages) and LFS tools
    mkdir -p "${LFS}/tools/bin" /usr/local/bin
    cp -f fay "${LFS}/tools/bin/"
    cp -f fay /usr/local/bin/
    chmod 755 "${LFS}/tools/bin/fay" /usr/local/bin/fay

    # Initialize fay database
    mkdir -p "${LFS}/var/lib/fay"

    # Create package cache
    mkdir -p "${PKG_CACHE}"

    make clean
    ok "fay bootstrapped"
}

# ============================================================
# Download sources
# ============================================================

download_sources() {
    local max_stage="${1:-11}"
    stage_start "Downloading Sources (stages 1-${max_stage})"

    mkdir -p "${SOURCES_DIR}"

    for pkg in $(awk '/^\[packages\./ {gsub(/^\[packages\.|]$/, ""); print}' "${PACKAGES_FILE}"); do
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

    log "LFS Build Started (fay-based)"
    log "Target: ${target}"
    log "LFS: ${LFS}"
    log "CPUs: ${NPROC}"

    [[ $EUID -eq 0 ]] || die "Must run as root"
    mountpoint -q "${LFS}" || die "LFS not mounted at ${LFS}"
    mkdir -p "${SOURCES_DIR}" "${PKG_CACHE}" "${BUILD_DIR}"

    case "${target}" in
        download)
            local max_stage="${extra_args[0]:-11}"
            download_sources "${max_stage}"
            ;;
        bootstrap)
            bootstrap_fay
            ;;
        minimal)
            download_sources 5
            bootstrap_fay
            setup_sdt_header
            build_stage 1 "Cross-Toolchain"
            build_stage 2 "Temporary Tools"
            build_stage 3 "Base System"
            build_stage 4 "System Config"
            build_stage 5 "Kernel"
            ;;
        all)
            download_sources
            bootstrap_fay
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
