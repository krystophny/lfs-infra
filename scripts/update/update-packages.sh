#!/bin/bash
# LFS Package Update Script
# Checks for updates, rebuilds, and installs new packages using pkgutils

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"
VERSION_CHECKER="${ROOT_DIR}/version-checker/check-versions.sh"
PACKAGES_FILE="${ROOT_DIR}/packages.toml"
BUILD_DIR="${LFS_BUILD:-/var/lfs/build}"
PKG_DIR="${LFS_PKGS:-/var/lfs/packages}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults
DRY_RUN=0
FORCE=0
PACKAGES=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [PACKAGE...]

Update LFS packages to their latest versions.

Workflow:
  1. Check for updates via version-checker (Repology + Anitya)
  2. Update packages.toml with new versions
  3. Download new source tarballs
  4. Build packages in isolated environment
  5. Verify build succeeded
  6. Remove old package version
  7. Install new package version

Options:
    -n, --dry-run     Show what would be updated, don't actually update
    -f, --force       Force rebuild even if version matches
    -y, --yes         Don't prompt for confirmation
    -h, --help        Show this help

Examples:
    $(basename "$0")              # Update all outdated packages
    $(basename "$0") gcc binutils # Update specific packages
    $(basename "$0") -n           # Dry-run to see what would be updated
EOF
    exit 0
}

YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        -f|--force) FORCE=1; shift ;;
        -y|--yes) YES=1; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1"; usage ;;
        *) PACKAGES+=("$1"); shift ;;
    esac
done

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }

# Check dependencies
check_deps() {
    local missing=()
    for cmd in pkgmk pkgadd pkgrm curl; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

# Get package info from packages.toml
get_pkg_info() {
    local pkg="$1"
    local field="$2"

    awk -v pkg="[packages.${pkg}]" -v field="${field}" '
        $0 == pkg { found=1; next }
        /^\[/ && found { exit }
        found && $0 ~ "^"field" *= *" {
            gsub(/.*= *"/, ""); gsub(/".*/, ""); print
        }
    ' "${PACKAGES_FILE}"
}

# Get current installed version via pkginfo
get_installed_version() {
    local pkg="$1"
    pkginfo -i 2>/dev/null | awk -v pkg="${pkg}" '$1 == pkg { print $2 }'
}

# Build a package using pkgmk
build_package() {
    local pkg="$1"
    local version="$2"
    local url="$3"

    local pkg_build_dir="${BUILD_DIR}/${pkg}"
    mkdir -p "${pkg_build_dir}"

    log "Building ${pkg} version ${version}..."

    # Create minimal Pkgfile
    cat > "${pkg_build_dir}/Pkgfile" <<PKGFILE
# Description: ${pkg}
# URL: ${url}
# Maintainer: LFS Auto-Update

name=${pkg}
version=${version}
release=1
source=(${url})

build() {
    cd \${name}-\${version}
    ./configure --prefix=/usr
    make -j\$(nproc)
    make DESTDIR=\${PKG} install
}
PKGFILE

    # Run pkgmk
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log "[DRY-RUN] Would build ${pkg}-${version}"
        return 0
    fi

    cd "${pkg_build_dir}"
    if pkgmk -d; then
        ok "Built ${pkg}-${version} successfully"
        return 0
    else
        error "Build failed for ${pkg}-${version}"
        return 1
    fi
}

# Install/upgrade package
install_package() {
    local pkg="$1"
    local pkg_file
    pkg_file=$(ls "${BUILD_DIR}/${pkg}/"*.pkg.tar.* 2>/dev/null | head -1)

    if [[ -z "${pkg_file}" ]]; then
        error "No package file found for ${pkg}"
        return 1
    fi

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log "[DRY-RUN] Would install ${pkg_file}"
        return 0
    fi

    local installed_ver
    installed_ver=$(get_installed_version "${pkg}")

    if [[ -n "${installed_ver}" ]]; then
        log "Upgrading ${pkg} from ${installed_ver}..."
        pkgadd -u "${pkg_file}"
    else
        log "Installing ${pkg}..."
        pkgadd "${pkg_file}"
    fi

    ok "Installed ${pkg}"
}

# Update a single package
update_package() {
    local pkg="$1"
    local new_version="$2"

    local url
    url=$(get_pkg_info "${pkg}" "url")
    url="${url//\$\{version\}/${new_version}}"

    log "Updating ${pkg} to ${new_version}..."

    # Update packages.toml
    if [[ ${DRY_RUN} -eq 0 ]]; then
        sed -i "/^\[packages\.${pkg}\]/,/^\[/{s/^version = \"[^\"]*\"/version = \"${new_version}\"/}" "${PACKAGES_FILE}"
    fi

    # Build
    if ! build_package "${pkg}" "${new_version}" "${url}"; then
        error "Failed to build ${pkg}"
        return 1
    fi

    # Install
    if ! install_package "${pkg}"; then
        error "Failed to install ${pkg}"
        return 1
    fi

    ok "Updated ${pkg} to ${new_version}"
}

main() {
    echo -e "${BLUE}LFS Package Updater${NC}"
    echo "========================================"

    check_deps

    # Get list of outdated packages
    log "Checking for updates..."

    local -a outdated=()
    local pkg_filter=""
    if [[ ${#PACKAGES[@]} -gt 0 ]]; then
        pkg_filter="${PACKAGES[*]}"
    fi

    while IFS= read -r line; do
        # Parse version checker output: "package  local  upstream  status"
        local pkg local_ver upstream_ver status
        pkg=$(echo "${line}" | awk '{print $1}')
        local_ver=$(echo "${line}" | awk '{print $2}')
        upstream_ver=$(echo "${line}" | awk '{print $3}')
        status=$(echo "${line}" | awk '{print $4}')

        # Skip header lines and non-outdated
        [[ "${pkg}" == "PACKAGE" || "${pkg}" == "-------" ]] && continue
        [[ -z "${upstream_ver}" || "${upstream_ver}" == "?" ]] && continue

        # Check if outdated or force rebuild
        if [[ "${status}" == *"outdated"* ]] || [[ ${FORCE} -eq 1 ]]; then
            outdated+=("${pkg}:${local_ver}:${upstream_ver}")
        fi
    done < <("${VERSION_CHECKER}" -a ${pkg_filter} 2>/dev/null | grep -v "^\[" | grep -v "^$" | grep -v "^Sources:" | grep -v "^==")

    if [[ ${#outdated[@]} -eq 0 ]]; then
        ok "All packages are up to date!"
        exit 0
    fi

    # Show what will be updated
    echo ""
    echo -e "${CYAN}Packages to update:${NC}"
    printf "%-20s %-15s %-15s\n" "PACKAGE" "CURRENT" "NEW"
    printf "%-20s %-15s %-15s\n" "-------" "-------" "---"
    for entry in "${outdated[@]}"; do
        IFS=':' read -r pkg local_ver upstream_ver <<< "${entry}"
        printf "%-20s %-15s %-15s\n" "${pkg}" "${local_ver}" "${upstream_ver}"
    done
    echo ""

    # Confirm
    if [[ ${YES} -eq 0 && ${DRY_RUN} -eq 0 ]]; then
        read -p "Proceed with updates? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Aborted."
            exit 0
        fi
    fi

    # Update each package
    local success=0
    local failed=0
    for entry in "${outdated[@]}"; do
        IFS=':' read -r pkg _ upstream_ver <<< "${entry}"
        if update_package "${pkg}" "${upstream_ver}"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    echo "========================================"
    echo -e "Updated: ${GREEN}${success}${NC} | Failed: ${RED}${failed}${NC}"

    [[ ${failed} -gt 0 ]] && exit 1
    exit 0
}

main "$@"
