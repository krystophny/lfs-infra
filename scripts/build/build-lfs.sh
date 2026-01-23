#!/bin/bash
# LFS Master Build Script - pkgutils based
# Builds packages using pkgmk/pkgadd with proper caching

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
PACKAGES_FILE="${ROOT_DIR}/packages.toml"
PKGFILES_DIR="${ROOT_DIR}/packages"
PKGMK_CONF="${ROOT_DIR}/config/pkgmk.conf"

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

# Get numeric field (no quotes)
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
    echo "${url}" | sed -e "s/\${version}/${version}/g" -e "s/\${version_mm}/${version_mm}/g"
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
        /^stage *= *'${stage}'/ { print pkg }
    ' "${PACKAGES_FILE}"
}

# ============================================================
# pkgutils integration
# ============================================================

# Check if package is installed
pkg_installed() {
    local pkg="$1"
    [[ -f "${LFS}/var/lib/pkg/db" ]] && grep -q "^${pkg}$" "${LFS}/var/lib/pkg/db"
}

# Check if package file exists in cache
pkg_cached() {
    local pkg="$1" version="$2"
    [[ -f "${PKG_CACHE}/${pkg}#${version}-1.pkg.tar.xz" ]]
}

# Build package with pkgmk
pkg_build() {
    local pkg="$1"
    local pkgfile_dir="${PKGFILES_DIR}/${pkg}"

    [[ -f "${pkgfile_dir}/Pkgfile" ]] || die "No Pkgfile for ${pkg}"

    log "Building ${pkg}..."
    cd "${pkgfile_dir}"

    # Use our pkgmk.conf
    pkgmk -d -cf "${PKGMK_CONF}" || die "pkgmk failed for ${pkg}"

    ok "Built ${pkg}"
}

# Install package with pkgadd
pkg_install() {
    local pkg="$1" version="$2"
    local pkg_file="${PKG_CACHE}/${pkg}#${version}-1.pkg.tar.xz"

    [[ -f "${pkg_file}" ]] || die "Package file not found: ${pkg_file}"

    log "Installing ${pkg}..."

    if pkg_installed "${pkg}"; then
        pkgadd -u -r "${LFS}" "${pkg_file}" || die "pkgadd -u failed for ${pkg}"
    else
        pkgadd -r "${LFS}" "${pkg_file}" || die "pkgadd failed for ${pkg}"
    fi

    ok "Installed ${pkg}"
}

# Build package directly (for cross-toolchain stage)
build_direct() {
    local pkg="$1"
    local pkgfile_dir="${PKGFILES_DIR}/${pkg}"
    local version=$(get_pkg_version "${pkg}")

    [[ -f "${pkgfile_dir}/Pkgfile" ]] || die "No Pkgfile for ${pkg}"

    log "Building ${pkg} (direct install)..."

    # Get source URL and download
    local url=$(grep "^source=" "${pkgfile_dir}/Pkgfile" | sed 's/source=(\(.*\))/\1/')
    local filename=$(basename "${url}")
    local tarball="${SOURCES_DIR}/${filename}"

    # Create work directory
    local work_dir="${LFS}/build/${pkg}"
    rm -rf "${work_dir}"
    mkdir -p "${work_dir}/src"

    # Extract source
    tar -xf "${tarball}" -C "${work_dir}/src" || die "Extract failed for ${pkg}"

    # Run build function from Pkgfile
    cd "${work_dir}/src"
    (
        # Source the Pkgfile to get build()
        source "${pkgfile_dir}/Pkgfile"
        # Run build
        set -x
        build
    ) || die "Build failed for ${pkg}"

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

    # Check if first provided file exists
    local first=$(echo "${provides}" | head -1 | tr -d ' ')
    # Expand variables
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
        pkg_build "${pkg}"
    else
        log "Using cached: ${pkg}"
    fi

    pkg_install "${pkg}" "${version}"
}

# ============================================================
# Bootstrap (build pkgutils without pkgutils)
# ============================================================

bootstrap_pkgutils() {
    stage_start "Bootstrapping pkgutils and pkgmk"

    # Bootstrap pkgutils (pkgadd/pkgrm/pkginfo)
    local version=$(get_pkg_version "pkgutils")
    local url=$(get_pkg_url "pkgutils")
    local tarball="${SOURCES_DIR}/pkgutils-v${version}.tar.gz"

    if [[ ! -f "${tarball}" ]]; then
        log "Downloading pkgutils..."
        curl -fL "${url}" -o "${tarball}" || die "Download failed"
    fi

    log "Building pkgutils..."
    rm -rf "${LFS}/build/pkgutils-"*
    mkdir -p "${LFS}/build"
    tar -xf "${tarball}" -C "${LFS}/build"

    local build_dir=$(ls -d "${LFS}/build/pkgutils-"* 2>/dev/null | head -1)
    [[ -d "${build_dir}" ]] || die "pkgutils source not found after extraction"

    cd "${build_dir}"
    make pkgadd LDFLAGS="-larchive" || die "pkgutils build failed"

    # Install to LFS target
    mkdir -p "${LFS}/usr/sbin" "${LFS}/usr/bin"
    cp -f pkgadd "${LFS}/usr/sbin/"
    chmod 755 "${LFS}/usr/sbin/pkgadd"
    ln -sf pkgadd "${LFS}/usr/sbin/pkgrm"
    ln -sf ../sbin/pkgadd "${LFS}/usr/bin/pkginfo"

    # Bootstrap pkgmk (build tool - installed to host)
    local pkgmk_version="5.45"
    local pkgmk_url="https://github.com/zeppe-lin/pkgmk/archive/refs/tags/v${pkgmk_version}.tar.gz"
    local pkgmk_tarball="${SOURCES_DIR}/pkgmk-v${pkgmk_version}.tar.gz"

    if [[ ! -f "${pkgmk_tarball}" ]]; then
        log "Downloading pkgmk..."
        curl -fL "${pkgmk_url}" -o "${pkgmk_tarball}" || die "pkgmk download failed"
    fi

    log "Installing pkgmk..."
    rm -rf "${LFS}/build/pkgmk-"*
    tar -xf "${pkgmk_tarball}" -C "${LFS}/build"

    local pkgmk_dir=$(ls -d "${LFS}/build/pkgmk-"* 2>/dev/null | head -1)
    [[ -d "${pkgmk_dir}" ]] || die "pkgmk source not found"

    cd "${pkgmk_dir}"
    # Install pkgmk to /usr/local/sbin
    cd src && make PREFIX=/usr/local install
    cd ..
    # Copy sample config
    mkdir -p /usr/local/etc
    cp -f extra/pkgmk.conf.sample /usr/local/etc/pkgmk.conf

    # Initialize package database
    mkdir -p "${LFS}/var/lib/pkg"
    touch "${LFS}/var/lib/pkg/db"

    # Create package cache directory
    mkdir -p "${PKG_CACHE}"

    ok "pkgutils and pkgmk bootstrapped"
}

# ============================================================
# Generate Pkgfiles from packages.toml
# ============================================================

generate_pkgfile() {
    local pkg="$1"
    local version=$(get_pkg_version "${pkg}")
    local description=$(get_pkg_description "${pkg}")
    local url=$(get_pkg_url "${pkg}")
    local build_commands=$(get_pkg_build_commands "${pkg}")
    local source_pkg=$(get_pkg_source_pkg "${pkg}")

    [[ -z "${version}" ]] && return 1

    local pkg_dir="${PKGFILES_DIR}/${pkg}"
    mkdir -p "${pkg_dir}"

    # Use source package URL if specified
    if [[ -n "${source_pkg}" ]]; then
        url=$(get_pkg_url "${source_pkg}")
    fi

    cat > "${pkg_dir}/Pkgfile" << EOF
# Description: ${description}
# Maintainer: LFS-infra

name=${pkg}
version=${version}
release=1
source=(${url})

build() {
    cd \$(ls -d */ | head -1)

EOF

    if [[ -n "${build_commands}" ]]; then
        # Use custom build commands
        while IFS= read -r cmd; do
            [[ -z "${cmd}" ]] && continue
            # Expand variables using sed (safer than bash parameter expansion)
            cmd=$(echo "${cmd}" | sed \
                -e "s|\\\${LFS}|${LFS}|g" \
                -e "s|\\\${LFS_TGT}|${LFS_TGT}|g" \
                -e "s|\\\${NPROC}|${NPROC}|g" \
                -e "s|\\\${version}|${version}|g")
            echo "    ${cmd}"
        done <<< "${build_commands}" >> "${pkg_dir}/Pkgfile"
    else
        # Default autotools build
        cat >> "${pkg_dir}/Pkgfile" << 'EOF'
    ./configure --prefix=/usr
    make -j${NPROC}
    make DESTDIR=$PKG install
EOF
    fi

    echo "}" >> "${pkg_dir}/Pkgfile"
}

generate_all_pkgfiles() {
    stage_start "Generating Pkgfiles"

    local count=0
    for pkg in $(awk '/^\[packages\./ {gsub(/^\[packages\.|]$/, ""); print}' "${PACKAGES_FILE}"); do
        if generate_pkgfile "${pkg}" 2>/dev/null; then
            count=$((count + 1))
        fi
    done

    ok "Generated ${count} Pkgfiles"
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
        # Skip packages with stage > max_stage or no stage defined
        [[ -z "${stage}" ]] && continue
        [[ "${stage}" -gt "${max_stage}" ]] && continue

        local url=$(get_pkg_url "${pkg}")
        [[ -z "${url}" ]] && continue

        local filename=$(basename "${url}")
        local target="${SOURCES_DIR}/${filename}"

        if [[ -f "${target}" ]]; then
            log "Already downloaded: ${filename}"
        else
            log "Downloading: ${filename}"
            curl -fL "${url}" -o "${target}.partial" && mv "${target}.partial" "${target}" || warn "Failed: ${filename}"
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

    log "LFS Build Started (pkgutils-based)"
    log "Target: ${target}"
    log "LFS: ${LFS}"
    log "CPUs: ${NPROC}"

    # Prerequisites
    [[ $EUID -eq 0 ]] || die "Must run as root"
    mountpoint -q "${LFS}" || die "LFS not mounted at ${LFS}"
    mkdir -p "${SOURCES_DIR}" "${PKG_CACHE}"

    case "${target}" in
        download)
            download_sources
            ;;
        pkgfiles)
            generate_all_pkgfiles
            ;;
        bootstrap)
            bootstrap_pkgutils
            ;;
        all)
            download_sources
            generate_all_pkgfiles
            bootstrap_pkgutils

            # Build all stages in order
            build_stage 1 "Cross-Toolchain"
            build_stage 2 "Temporary Tools"
            build_stage 3 "Base System"
            build_stage 4 "System Config"
            build_stage 5 "Kernel"
            ;;
        *)
            # Build specific stage
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
