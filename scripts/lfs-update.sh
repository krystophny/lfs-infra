#!/bin/bash
# LFS Package Update System
# Usage: lfs-update [options] [package...]
#
# Examples:
#   lfs-update              # Check and upgrade all (like pacman -Syu)
#   lfs-update -Syu         # Same as above
#   lfs-update gcc binutils # Update specific packages
#   lfs-update -c           # Check only, don't update

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
PACKAGES_FILE="${ROOT_DIR}/packages.toml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}::${NC} $*"; }
ok() { echo -e "${GREEN}::${NC} $*"; }
warn() { echo -e "${YELLOW}warning:${NC} $*"; }
die() { echo -e "${RED}error:${NC} $*"; exit 1; }

SYNC=0
YES=0
UPGRADE=0
CHECK_ONLY=0
PACKAGES=()

usage() {
    cat <<'USAGE'
Usage: lfs-update [options] [package...]

Sync and update LFS packages (pacman-style)

Options:
    -S, --sync      Sync package versions from upstream
    -y, --yes       Skip confirmation prompts
    -u, --upgrade   Upgrade outdated packages
    -c, --check     Check for updates only (no changes)
    -l, --list      List all packages and versions
    -h, --help      Show this help

Examples:
    lfs-update              # Sync + upgrade all (default)
    lfs-update -Syu         # Same as above, explicit
    lfs-update gcc          # Update only gcc
    lfs-update -c           # Check what would be updated
USAGE
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -S|--sync) SYNC=1; shift ;;
        -y|--yes) YES=1; shift ;;
        -u|--upgrade) UPGRADE=1; shift ;;
        -Syu|-Suy|-ySu|-yuS|-uSy|-uyS) SYNC=1; YES=1; UPGRADE=1; shift ;;
        -Sy|-yS) SYNC=1; YES=1; shift ;;
        -Su|-uS) SYNC=1; UPGRADE=1; shift ;;
        -c|--check) CHECK_ONLY=1; shift ;;
        -l|--list) list_packages; exit 0 ;;
        -h|--help) usage ;;
        -*) die "Unknown option: $1" ;;
        *) PACKAGES+=("$1"); shift ;;
    esac
done

# Default: -Syu if no options given
if [[ ${SYNC} -eq 0 && ${UPGRADE} -eq 0 && ${CHECK_ONLY} -eq 0 && ${#PACKAGES[@]} -eq 0 ]]; then
    SYNC=1
    UPGRADE=1
fi

# If specific packages given, sync+upgrade those
if [[ ${#PACKAGES[@]} -gt 0 ]]; then
    SYNC=1
    UPGRADE=1
fi

# Get version from packages.toml
get_local_version() {
    local pkg="$1"
    awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[/ && found { exit }
        found && /^version/ { gsub(/.*= *"|".*/, ""); print; exit }
    ' "${PACKAGES_FILE}"
}

# Map package names to Repology names
get_repology_name() {
    local pkg="$1"
    case "${pkg}" in
        linux-headers) echo "linux" ;;
        gcc-pass1|gcc-pass2|libstdcxx) echo "gcc" ;;
        binutils-pass2) echo "binutils" ;;
        util-linux) echo "util-linux" ;;
        xorg-server) echo "xorg-server" ;;
        xorg-*) echo "${pkg#xorg-}" ;;
        lib*) echo "${pkg}" ;;
        *) echo "${pkg}" ;;
    esac
}

# Get latest version from Repology
get_upstream_version() {
    local pkg="$1"
    local repology_name
    repology_name=$(get_repology_name "${pkg}")

    local cache_dir="${TMPDIR:-/tmp}/lfs-update-cache"
    mkdir -p "${cache_dir}"
    local cache_file="${cache_dir}/${repology_name}.ver"

    # Use cache if < 1 hour old
    if [[ -f "${cache_file}" ]]; then
        local now age
        now=$(date +%s)
        age=$((now - $(stat -f %m "${cache_file}" 2>/dev/null || stat -c %Y "${cache_file}" 2>/dev/null || echo 0)))
        if [[ ${age} -lt 3600 ]]; then
            cat "${cache_file}"
            return
        fi
    fi

    # Query Repology
    local json version
    json=$(curl -sf --max-time 10 "https://repology.org/api/v1/project/${repology_name}" 2>/dev/null) || return

    version=$(echo "${json}" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    versions = [r.get("version","") for r in data if r.get("status") in ("newest","unique","devel")]
    if versions:
        print(sorted(set(versions), key=lambda v: [int(x) if x.isdigit() else x for x in v.replace("-",".").split(".")], reverse=True)[0])
except: pass
' 2>/dev/null) || return

    if [[ -n "${version}" ]]; then
        echo "${version}" > "${cache_file}"
        echo "${version}"
    fi
}

# Update version in packages.toml
update_toml_version() {
    local pkg="$1"
    local new_ver="$2"

    # Use sed to update version in the package block
    local temp_file="${PACKAGES_FILE}.tmp"
    awk -v pkg="[packages.${pkg}]" -v newver="${new_ver}" '
        $0 == pkg { in_pkg=1 }
        in_pkg && /^\[packages\./ && $0 != pkg { in_pkg=0 }
        in_pkg && /^version = / { sub(/"[^"]*"/, "\"" newver "\"") }
        { print }
    ' "${PACKAGES_FILE}" > "${temp_file}"
    mv "${temp_file}" "${PACKAGES_FILE}"
}

# List all packages
list_packages() {
    log "LFS packages:"
    printf "%-30s %s\n" "PACKAGE" "VERSION"
    printf "%-30s %s\n" "-------" "-------"

    grep -E '^\[packages\.' "${PACKAGES_FILE}" | sed 's/\[packages\.\(.*\)\]/\1/' | while read -r pkg; do
        local ver
        ver=$(get_local_version "${pkg}")
        printf "%-30s %s\n" "${pkg}" "${ver}"
    done | head -50
    echo "... (use grep for full list)"
}

# Main
main() {
    log "LFS Package Manager"

    # Get package list
    local pkgs=()
    if [[ ${#PACKAGES[@]} -gt 0 ]]; then
        pkgs=("${PACKAGES[@]}")
    else
        mapfile -t pkgs < <(grep -E '^\[packages\.' "${PACKAGES_FILE}" | sed 's/\[packages\.\(.*\)\]/\1/')
    fi

    log "Checking ${#pkgs[@]} packages..."

    local updates=()
    local checked=0
    local skipped=0

    for pkg in "${pkgs[@]}"; do
        local local_ver upstream_ver
        local_ver=$(get_local_version "${pkg}")
        upstream_ver=$(get_upstream_version "${pkg}")

        ((checked++)) || true

        if [[ -z "${upstream_ver}" ]]; then
            ((skipped++)) || true
            continue
        fi

        if [[ "${local_ver}" != "${upstream_ver}" ]]; then
            updates+=("${pkg}|${local_ver}|${upstream_ver}")
        fi

        # Progress indicator
        if (( checked % 20 == 0 )); then
            echo -ne "\r${BLUE}::${NC} Checked ${checked}/${#pkgs[@]} packages..."
        fi
    done
    echo -ne "\r"

    ok "Checked ${checked} packages (${skipped} not in Repology)"

    if [[ ${#updates[@]} -eq 0 ]]; then
        ok "All packages are up to date"
        exit 0
    fi

    echo ""
    log "Updates available:"
    printf "%-25s %-15s %-15s\n" "PACKAGE" "CURRENT" "AVAILABLE"
    for u in "${updates[@]}"; do
        IFS='|' read -r pkg old new <<< "${u}"
        printf "%-25s %-15s ${GREEN}%-15s${NC}\n" "${pkg}" "${old}" "${new}"
    done
    echo ""

    if [[ ${CHECK_ONLY} -eq 1 ]]; then
        warn "${#updates[@]} packages can be upgraded"
        exit 0
    fi

    if [[ ${UPGRADE} -eq 1 ]]; then
        if [[ ${YES} -eq 0 ]]; then
            echo -n "Proceed with upgrade? [Y/n] "
            read -r reply
            [[ "${reply}" =~ ^[Nn] ]] && exit 0
        fi

        log "Updating packages.toml..."
        for u in "${updates[@]}"; do
            IFS='|' read -r pkg old new <<< "${u}"
            update_toml_version "${pkg}" "${new}"
            echo "  ${pkg}: ${old} -> ${new}"
        done

        ok "Updated ${#updates[@]} packages"
        echo ""
        warn "To rebuild, run: ./scripts/build/build-lfs.sh <stage>"
        warn "Or rebuild specific package: build_pkg <package>"
    fi
}

main
