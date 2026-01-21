#!/bin/bash
# LFS Source Download Script
# Downloads all package sources based on packages.toml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# Source configurations
source "${ROOT_DIR}/config/lfs.conf" 2>/dev/null || true
source "${ROOT_DIR}/config/build.conf" 2>/dev/null || true

# Defaults if not sourced
LFS="${LFS:-/mnt/lfs}"
LFS_SOURCES="${LFS_SOURCES:-${LFS}/sources}"
PACKAGES_FILE="${ROOT_DIR}/packages.toml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parallel downloads
MAX_PARALLEL="${MAX_PARALLEL:-4}"

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Parse packages.toml and extract download info
parse_packages() {
    local current_pkg=""

    declare -gA PKG_VERSION
    declare -gA PKG_URL
    declare -gA PKG_GIT_URL
    declare -gA PKG_USE_GIT

    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

        if [[ "${line}" =~ ^\[packages\.([a-zA-Z0-9_-]+)\] ]]; then
            current_pkg="${BASH_REMATCH[1]}"
            continue
        fi

        [[ -z "${current_pkg}" ]] && continue

        if [[ "${line}" =~ ^version[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            PKG_VERSION["${current_pkg}"]="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^url[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            PKG_URL["${current_pkg}"]="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^git_url[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            PKG_GIT_URL["${current_pkg}"]="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^use_git[[:space:]]*=[[:space:]]*(true|false) ]]; then
            PKG_USE_GIT["${current_pkg}"]="${BASH_REMATCH[1]}"
        fi
    done < "${PACKAGES_FILE}"
}

# Expand version variable in URL
expand_url() {
    local url="$1"
    local version="$2"

    # Replace ${version} with actual version
    url="${url//\$\{version\}/${version}}"

    echo "${url}"
}

# Download file with retries
download_file() {
    local url="$1"
    local output="$2"
    local retries=3

    for ((i=1; i<=retries; i++)); do
        log_info "Downloading: $(basename "${output}") (attempt ${i}/${retries})"

        if curl -fSL --retry 3 --retry-delay 5 -o "${output}.tmp" "${url}"; then
            mv "${output}.tmp" "${output}"
            log_ok "Downloaded: $(basename "${output}")"
            return 0
        fi

        rm -f "${output}.tmp"
        sleep 2
    done

    log_error "Failed to download: ${url}"
    return 1
}

# Clone git repository
clone_git() {
    local git_url="$1"
    local output_dir="$2"
    local depth="${3:-1}"

    log_info "Cloning: ${git_url}"

    if [[ -d "${output_dir}" ]]; then
        log_info "Git repo exists, pulling latest..."
        cd "${output_dir}"
        git fetch --depth="${depth}" origin
        git reset --hard origin/HEAD
        cd -
    else
        if [[ ${depth} -gt 0 ]]; then
            git clone --depth="${depth}" "${git_url}" "${output_dir}"
        else
            git clone "${git_url}" "${output_dir}"
        fi
    fi

    log_ok "Cloned: $(basename "${output_dir}")"
}

# Get filename from URL
get_filename() {
    local url="$1"
    basename "${url}"
}

# Download a single package
download_package() {
    local pkg="$1"
    local version="${PKG_VERSION[${pkg}]:-}"
    local url="${PKG_URL[${pkg}]:-}"
    local git_url="${PKG_GIT_URL[${pkg}]:-}"
    local use_git="${PKG_USE_GIT[${pkg}]:-false}"

    if [[ -z "${version}" ]]; then
        log_warn "No version for ${pkg}, skipping"
        return 0
    fi

    # Use git if specified
    if [[ "${use_git}" == "true" ]] && [[ -n "${git_url}" ]]; then
        local git_dir="${LFS_SOURCES}/${pkg}"
        clone_git "${git_url}" "${git_dir}"
        return 0
    fi

    # Otherwise download tarball
    if [[ -z "${url}" ]]; then
        log_warn "No URL for ${pkg}, skipping"
        return 0
    fi

    local expanded_url=$(expand_url "${url}" "${version}")
    local filename=$(get_filename "${expanded_url}")
    local output="${LFS_SOURCES}/${filename}"

    # Skip if already downloaded
    if [[ -f "${output}" ]]; then
        log_info "Already exists: ${filename}"
        return 0
    fi

    download_file "${expanded_url}" "${output}"
}

# Verify checksums (if available)
verify_checksums() {
    log_info "Verifying checksums..."

    local checksum_file="${LFS_SOURCES}/SHA256SUMS"

    if [[ -f "${checksum_file}" ]]; then
        cd "${LFS_SOURCES}"
        sha256sum -c "${checksum_file}" --ignore-missing || true
        cd -
    else
        log_warn "No checksum file found, skipping verification"
    fi
}

# Generate checksum file for downloaded sources
generate_checksums() {
    log_info "Generating checksums..."

    cd "${LFS_SOURCES}"
    sha256sum *.tar.* *.tgz 2>/dev/null > SHA256SUMS || true
    cd -

    log_ok "Checksums saved to ${LFS_SOURCES}/SHA256SUMS"
}

# Main
main() {
    local packages_to_download=("$@")

    echo -e "${BLUE}LFS Source Download${NC}"
    echo "========================================"

    mkdir -p "${LFS_SOURCES}"

    # Parse packages
    declare -gA PKG_VERSION PKG_URL PKG_GIT_URL PKG_USE_GIT
    parse_packages

    # Get list of packages
    local all_packages=("${!PKG_VERSION[@]}")

    if [[ ${#packages_to_download[@]} -gt 0 ]]; then
        all_packages=("${packages_to_download[@]}")
    fi

    log_info "Downloading ${#all_packages[@]} packages to ${LFS_SOURCES}"
    echo ""

    # Download each package
    local failed=()
    for pkg in "${all_packages[@]}"; do
        if ! download_package "${pkg}"; then
            failed+=("${pkg}")
        fi
    done

    echo ""

    # Generate checksums
    generate_checksums

    # Summary
    echo ""
    echo "========================================"
    echo -e "${GREEN}Download Complete${NC}"
    echo "========================================"
    echo "Downloaded: $((${#all_packages[@]} - ${#failed[@]})) packages"

    if [[ ${#failed[@]} -gt 0 ]]; then
        echo -e "${RED}Failed: ${#failed[@]} packages${NC}"
        echo "  ${failed[*]}"
        return 1
    fi

    return 0
}

main "$@"
