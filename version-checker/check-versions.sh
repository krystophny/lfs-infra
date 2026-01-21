#!/bin/bash
# LFS Package Version Checker
# Compares local package versions against upstream releases

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
PACKAGES_FILE="${ROOT_DIR}/packages.toml"
CACHE_DIR="${TMPDIR:-/tmp}/lfs-version-cache"
CACHE_TTL=3600  # 1 hour cache

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse command line
VERBOSE=0
CHECK_ALL=0
PACKAGE_FILTER=""
UPDATE_TOML=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [PACKAGE...]

Check LFS package versions against upstream releases.

Options:
    -a, --all       Check all packages (default: only show outdated)
    -v, --verbose   Verbose output
    -u, --update    Update packages.toml with new versions
    -c, --clear     Clear version cache
    -h, --help      Show this help

Examples:
    $(basename "$0")              # Check all, show outdated only
    $(basename "$0") -a           # Check all, show all results
    $(basename "$0") gcc binutils # Check specific packages
    $(basename "$0") -u gcc       # Update gcc version in packages.toml
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all) CHECK_ALL=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -u|--update) UPDATE_TOML=1; shift ;;
        -c|--clear) rm -rf "${CACHE_DIR}"; echo "Cache cleared"; exit 0 ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1"; usage ;;
        *) PACKAGE_FILTER="${PACKAGE_FILTER} $1"; shift ;;
    esac
done

mkdir -p "${CACHE_DIR}"

log() {
    [[ ${VERBOSE} -eq 1 ]] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Parse TOML file and extract package info
parse_packages() {
    local current_pkg=""
    local in_packages=0

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

        # Package section header
        if [[ "${line}" =~ ^\[packages\.([a-zA-Z0-9_-]+)\] ]]; then
            current_pkg="${BASH_REMATCH[1]}"
            in_packages=1
            continue
        fi

        # End of packages section
        if [[ "${line}" =~ ^\[[^p] ]] && [[ ${in_packages} -eq 1 ]]; then
            in_packages=0
            current_pkg=""
            continue
        fi

        # Extract version
        if [[ -n "${current_pkg}" && "${line}" =~ ^version[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            echo "${current_pkg}=${BASH_REMATCH[1]}"
        fi
    done < "${PACKAGES_FILE}"
}

# Get cached version or fetch new
get_cached_version() {
    local pkg="$1"
    local cache_file="${CACHE_DIR}/${pkg}.version"

    if [[ -f "${cache_file}" ]]; then
        local age=$(($(date +%s) - $(stat -c %Y "${cache_file}" 2>/dev/null || echo 0)))
        if [[ ${age} -lt ${CACHE_TTL} ]]; then
            cat "${cache_file}"
            return 0
        fi
    fi
    return 1
}

cache_version() {
    local pkg="$1"
    local version="$2"
    echo "${version}" > "${CACHE_DIR}/${pkg}.version"
}

# Fetch latest version from GNU FTP
check_gnu_version() {
    local pkg="$1"
    local url="https://ftp.gnu.org/gnu/${pkg}/"

    log "Checking GNU FTP for ${pkg}"

    local versions=$(curl -fsSL "${url}" 2>/dev/null | \
        grep -oP "${pkg}-\K[0-9]+\.[0-9]+(\.[0-9]+)?" | \
        sort -V | tail -1)

    echo "${versions}"
}

# Fetch latest version from GitHub releases
check_github_version() {
    local repo="$1"
    local prefix="${2:-v}"

    log "Checking GitHub releases for ${repo}"

    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    local tag=$(curl -fsSL "${api_url}" 2>/dev/null | \
        grep -oP '"tag_name":\s*"\K[^"]+' | head -1)

    # Strip common prefixes
    tag="${tag#v}"
    tag="${tag#release-}"
    tag="${tag#rel-}"

    echo "${tag}"
}

# Fetch latest kernel version
check_kernel_version() {
    log "Checking kernel.org for latest stable"

    local version=$(curl -fsSL "https://www.kernel.org/" 2>/dev/null | \
        grep -oP 'linux-\K[0-9]+\.[0-9]+\.[0-9]+' | \
        head -1)

    echo "${version}"
}

# Fetch latest Python version
check_python_version() {
    log "Checking python.org for latest stable"

    local version=$(curl -fsSL "https://www.python.org/downloads/" 2>/dev/null | \
        grep -oP 'Python \K3\.[0-9]+\.[0-9]+' | \
        sort -V | tail -1)

    echo "${version}"
}

# Fetch latest Perl version
check_perl_version() {
    log "Checking CPAN for latest Perl"

    local version=$(curl -fsSL "https://www.cpan.org/src/" 2>/dev/null | \
        grep -oP 'perl-\K5\.[0-9]+\.[0-9]+' | \
        sort -V | tail -1)

    echo "${version}"
}

# Main version check dispatcher
check_upstream_version() {
    local pkg="$1"
    local current="$2"
    local upstream=""

    # Try cache first
    if upstream=$(get_cached_version "${pkg}"); then
        echo "${upstream}"
        return 0
    fi

    # Package-specific checks
    case "${pkg}" in
        # GNU packages
        binutils|gcc|glibc|bash|coreutils|diffutils|findutils|gawk|grep|gzip|make|patch|sed|tar|m4|ncurses|readline|gettext|bison|texinfo|autoconf|automake|libtool|gmp|mpfr|mpc)
            upstream=$(check_gnu_version "${pkg}")
            ;;

        # Kernel
        linux|linux-headers)
            upstream=$(check_kernel_version)
            ;;

        # GitHub releases
        zstd)
            upstream=$(check_github_version "facebook/zstd")
            ;;
        xz)
            upstream=$(check_github_version "tukaani-project/xz")
            ;;
        zlib)
            upstream=$(check_github_version "madler/zlib")
            ;;
        ninja)
            upstream=$(check_github_version "ninja-build/ninja")
            ;;
        meson)
            upstream=$(check_github_version "mesonbuild/meson")
            ;;
        openssl)
            upstream=$(check_github_version "openssl/openssl" "openssl-")
            upstream="${upstream#openssl-}"
            ;;
        libffi)
            upstream=$(check_github_version "libffi/libffi")
            ;;
        expat)
            upstream=$(check_github_version "libexpat/libexpat" "R_")
            upstream="${upstream//_/.}"
            upstream="${upstream#R.}"
            ;;
        bc)
            upstream=$(check_github_version "gavinhoward/bc")
            ;;
        flex)
            upstream=$(check_github_version "westes/flex")
            ;;
        file)
            upstream=$(check_github_version "file/file" "FILE")
            upstream="${upstream#FILE}"
            upstream="${upstream//_/.}"
            ;;
        util-linux)
            upstream=$(check_github_version "util-linux/util-linux")
            ;;
        pkgconf)
            upstream=$(check_github_version "pkgconf/pkgconf" "pkgconf-")
            upstream="${upstream#pkgconf-}"
            ;;
        pkgutils)
            upstream=$(check_github_version "zeppe-lin/pkgutils")
            ;;

        # Python
        python)
            upstream=$(check_python_version)
            ;;

        # Perl
        perl)
            upstream=$(check_perl_version)
            ;;

        # ISL
        isl)
            log "Checking ISL version"
            upstream=$(curl -fsSL "https://libisl.sourceforge.io/" 2>/dev/null | \
                grep -oP 'isl-\K[0-9]+\.[0-9]+' | sort -V | tail -1)
            ;;

        # bzip2
        bzip2)
            upstream=$(curl -fsSL "https://sourceware.org/pub/bzip2/" 2>/dev/null | \
                grep -oP 'bzip2-\K[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
            ;;

        *)
            log "No upstream check defined for ${pkg}"
            upstream=""
            ;;
    esac

    if [[ -n "${upstream}" ]]; then
        cache_version "${pkg}" "${upstream}"
    fi

    echo "${upstream}"
}

# Compare versions (returns 0 if v1 >= v2)
version_ge() {
    local v1="$1"
    local v2="$2"

    [[ "$(printf '%s\n%s' "${v1}" "${v2}" | sort -V | head -1)" == "${v2}" ]]
}

# Update version in TOML file
update_toml_version() {
    local pkg="$1"
    local new_version="$2"

    log "Updating ${pkg} to ${new_version} in packages.toml"

    sed -i "/^\[packages\.${pkg}\]/,/^\[/{s/^version = \"[^\"]*\"/version = \"${new_version}\"/}" "${PACKAGES_FILE}"
}

# Main
main() {
    echo -e "${BLUE}LFS Package Version Checker${NC}"
    echo "========================================"
    echo ""

    local outdated=0
    local checked=0
    local errors=0

    # Parse packages
    local packages
    packages=$(parse_packages)

    printf "%-20s %-15s %-15s %s\n" "PACKAGE" "LOCAL" "UPSTREAM" "STATUS"
    printf "%-20s %-15s %-15s %s\n" "-------" "-----" "--------" "------"

    while IFS='=' read -r pkg version; do
        # Filter packages if specified
        if [[ -n "${PACKAGE_FILTER}" ]] && [[ ! " ${PACKAGE_FILTER} " =~ " ${pkg} " ]]; then
            continue
        fi

        checked=$((checked + 1))

        # Get upstream version
        local upstream
        upstream=$(check_upstream_version "${pkg}" "${version}" 2>/dev/null) || true

        if [[ -z "${upstream}" ]]; then
            if [[ ${CHECK_ALL} -eq 1 ]]; then
                printf "%-20s %-15s %-15s %s\n" "${pkg}" "${version}" "?" "${YELLOW}unknown${NC}"
            fi
            errors=$((errors + 1))
            continue
        fi

        # Compare versions
        local status
        if version_ge "${version}" "${upstream}"; then
            status="${GREEN}up-to-date${NC}"
            [[ ${CHECK_ALL} -eq 0 ]] && continue
        else
            status="${RED}outdated${NC}"
            outdated=$((outdated + 1))

            if [[ ${UPDATE_TOML} -eq 1 ]]; then
                update_toml_version "${pkg}" "${upstream}"
                status="${YELLOW}updated${NC}"
            fi
        fi

        printf "%-20s %-15s %-15s %b\n" "${pkg}" "${version}" "${upstream}" "${status}"

    done <<< "${packages}"

    echo ""
    echo "========================================"
    echo "Checked: ${checked} | Outdated: ${outdated} | Errors: ${errors}"

    if [[ ${UPDATE_TOML} -eq 1 ]] && [[ ${outdated} -gt 0 ]]; then
        echo -e "${YELLOW}packages.toml has been updated${NC}"
    fi

    return ${outdated}
}

main "$@"
