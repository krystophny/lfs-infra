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

export LFS_TGT="$(uname -m)-lfs-linux-gnu"
export NPROC="$(nproc)"
export MAKEFLAGS="-j${NPROC}"
export FORCE_UNSAFE_CONFIGURE=1

# Paths
SOURCES_DIR="${LFS}/sources"
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

list_packages_by_stage() {
    local stage="$1"
    awk -v stage="${stage}" '
        /^\[packages\./ { pkg=$0; gsub(/^\[packages\.|]$/, "", pkg) }
        /^stage *= *'${stage}'$/ { print pkg }
    ' "${PACKAGES_FILE}"
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
                -e "s|\\\${LFS}|${LFS}|g" \
                -e "s|\\\${LFS_TGT}|${LFS_TGT}|g" \
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

# Build package directly (Stage 1 cross-toolchain - no packaging)
build_direct() {
    local pkg="$1"
    local version=$(get_pkg_version "${pkg}")
    local url=$(get_pkg_url "${pkg}")
    local source_pkg=$(get_pkg_source_pkg "${pkg}")
    local build_commands=$(get_pkg_build_commands "${pkg}")

    if [[ -n "${source_pkg}" ]]; then
        url=$(get_pkg_url "${source_pkg}")
    fi

    local filename=$(basename "${url}")
    local tarball="${SOURCES_DIR}/${filename}"
    local work_dir="${BUILD_DIR}/${pkg}"

    [[ -f "${tarball}" ]] || die "Source not found: ${tarball}"

    log "Building ${pkg} (direct install)..."

    rm -rf "${work_dir}"
    mkdir -p "${work_dir}/src"

    tar -xf "${tarball}" -C "${work_dir}/src" || die "Extract failed"

    cd "${work_dir}/src"
    cd "$(ls -d */ | head -1)" 2>/dev/null || true

    export PKG="${LFS}"

    if [[ -n "${build_commands}" ]]; then
        while IFS= read -r cmd; do
            [[ -z "${cmd}" ]] && continue
            cmd=$(echo "${cmd}" | sed \
                -e "s|\\\${LFS}|${LFS}|g" \
                -e "s|\\\${LFS_TGT}|${LFS_TGT}|g" \
                -e "s|\\\${NPROC}|${NPROC}|g" \
                -e "s|\\\${version}|${version}|g" \
                -e "s|\\\${PKG}|${PKG}|g")
            log "  $ ${cmd}"
            eval "${cmd}" || die "Command failed: ${cmd}"
        done <<< "${build_commands}"
    else
        die "Stage 1 package ${pkg} requires build_commands"
    fi

    ok "Built ${pkg}"
}

# Check if Stage 1 package was built (by checking provides)
stage1_built() {
    local pkg="$1"
    local provides=$(awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[/ && found { exit }
        found && /^provides/ {
            gsub(/.*\[|\].*/, "")
            gsub(/\"/, "")
            gsub(/,/, "\n")
            print
            exit
        }
    ' "${PACKAGES_FILE}")

    [[ -z "${provides}" ]] && return 1

    local first=$(echo "${provides}" | head -1 | tr -d ' ')
    first="${first//\$\{LFS\}/${LFS}}"
    first="${first//\$\{LFS_TGT\}/${LFS_TGT}}"
    [[ -f "${first}" ]] && return 0
    return 1
}

# Build and install a package
build_and_install() {
    local pkg="$1"
    local version=$(get_pkg_version "${pkg}")
    local stage=$(get_pkg_stage "${pkg}")

    # Stage 1 packages install directly (cross-toolchain)
    if [[ "${stage}" == "1" ]]; then
        if stage1_built "${pkg}"; then
            log "Already built: ${pkg}"
            return 0
        fi
        build_direct "${pkg}"
        return 0
    fi

    if pkg_installed "${pkg}"; then
        log "Already installed: ${pkg}"
        return 0
    fi

    if ! pkg_cached "${pkg}" "${version}"; then
        build_package "${pkg}"
    else
        log "Using cached: ${pkg}"
    fi

    pkg_install "${pkg}" "${version}"
}

# ============================================================
# Bootstrap fay
# ============================================================

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
            build_stage 1 "Cross-Toolchain"
            build_stage 2 "Temporary Tools"
            build_stage 3 "Base System"
            build_stage 4 "System Config"
            build_stage 5 "Kernel"
            ;;
        all)
            download_sources
            bootstrap_fay
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
