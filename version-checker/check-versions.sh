#!/bin/bash
# LFS Package Version Checker
# Uses Repology API (repology.org) as the single source of truth
# Repology aggregates version info from 300+ repositories

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
CYAN='\033[0;36m'
NC='\033[0m'

# Parse command line
VERBOSE=0
CHECK_ALL=0
PACKAGE_FILTER=""
UPDATE_TOML=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [PACKAGE...]

Check LFS package versions against upstream releases via Repology API.

Repology (repology.org) aggregates version information from 300+ repositories
including Arch, Fedora, Debian, Alpine, Gentoo, FreeBSD, and many more.

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

# Parallel job control
MAX_PARALLEL=${MAX_PARALLEL:-16}
FETCH_PIDS=()

log() {
    [[ ${VERBOSE} -eq 1 ]] && echo -e "${CYAN}[DEBUG]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Parse TOML file and extract package info
# Returns: pkg_name=version|repology_name
parse_packages() {
    local current_pkg=""
    local current_version=""
    local repology_name=""
    local in_packages=0

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

        # Package section header
        if [[ "${line}" =~ ^\[packages\.([a-zA-Z0-9_-]+)\] ]]; then
            # Output previous package if we have one
            if [[ -n "${current_pkg}" && -n "${current_version}" ]]; then
                echo "${current_pkg}=${current_version}|${repology_name:-${current_pkg}}"
            fi
            current_pkg="${BASH_REMATCH[1]}"
            current_version=""
            repology_name=""
            in_packages=1
            continue
        fi

        # End of packages section
        if [[ "${line}" =~ ^\[[^p] ]] && [[ ${in_packages} -eq 1 ]]; then
            if [[ -n "${current_pkg}" && -n "${current_version}" ]]; then
                echo "${current_pkg}=${current_version}|${repology_name:-${current_pkg}}"
            fi
            in_packages=0
            current_pkg=""
            current_version=""
            repology_name=""
            continue
        fi

        # Extract version
        if [[ -n "${current_pkg}" && "${line}" =~ ^version[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            current_version="${BASH_REMATCH[1]}"
        fi

        # Extract repology name override
        if [[ -n "${current_pkg}" && "${line}" =~ ^repology[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            repology_name="${BASH_REMATCH[1]}"
        fi
    done < "${PACKAGES_FILE}"

    # Output last package
    if [[ -n "${current_pkg}" && -n "${current_version}" ]]; then
        echo "${current_pkg}=${current_version}|${repology_name:-${current_pkg}}"
    fi
}

# Get cached version
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

# Fetch latest version from Repology API
# Uses jq for proper JSON parsing
check_repology_version() {
    local repology_name="$1"

    log "Checking Repology for ${repology_name}"

    local api_url="https://repology.org/api/v1/project/${repology_name}"
    local response
    response=$(curl -fsSL -A "lfs-version-checker/1.0" "${api_url}" 2>/dev/null) || return 1

    # Use jq to extract versions with status "newest" (upstream latest)
    # Sort by version and take the highest
    local version
    version=$(echo "${response}" | \
        jq -r '.[] | select(.status == "newest") | .version' 2>/dev/null | \
        sort -V | uniq | tail -1)

    # If no "newest" status found, try "devel" (for rolling release repos)
    if [[ -z "${version}" ]]; then
        version=$(echo "${response}" | \
            jq -r '.[] | select(.status == "devel") | .version' 2>/dev/null | \
            sort -V | uniq | tail -1)
    fi

    if [[ -n "${version}" ]]; then
        echo "${version}"
        return 0
    fi

    return 1
}

# Fetch latest version from release-monitoring.org (Anitya)
# Fedora's upstream release monitoring - good for freshly released packages
check_anitya_version() {
    local pkg_name="$1"

    log "Checking Anitya for ${pkg_name}"

    # Search for the project
    local api_url="https://release-monitoring.org/api/v2/projects/?name=${pkg_name}"
    local response
    response=$(curl -fsSL -A "lfs-version-checker/1.0" "${api_url}" 2>/dev/null) || return 1

    # Get the latest version from the first matching project
    local version
    version=$(echo "${response}" | \
        jq -r '.items[0].stable_version // .items[0].version // empty' 2>/dev/null)

    if [[ -n "${version}" ]]; then
        echo "${version}"
        return 0
    fi

    return 1
}

# Direct version checks for proprietary/special packages
check_nvidia_version() {
    log "Checking NVIDIA driver version"

    # Check NVIDIA's download page for latest driver
    local version
    version=$(curl -fsSL "https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt" 2>/dev/null | \
        head -1)

    if [[ -n "${version}" ]]; then
        echo "${version}"
        return 0
    fi

    return 1
}

check_intel_oneapi_version() {
    log "Checking Intel oneAPI version"

    # Intel oneAPI releases are tracked on GitHub
    local version
    version=$(curl -fsSL "https://api.github.com/repos/oneapi-src/oneAPI-samples/releases/latest" 2>/dev/null | \
        jq -r '.tag_name' 2>/dev/null | sed 's/^v//')

    if [[ -n "${version}" ]]; then
        echo "${version}"
        return 0
    fi

    return 1
}

check_nvidia_hpc_version() {
    log "Checking NVIDIA HPC SDK version"

    # NVIDIA HPC SDK version from their downloads page
    local version
    version=$(curl -fsSL "https://developer.nvidia.com/hpc-sdk-downloads" 2>/dev/null | \
        grep -oP 'NVIDIA HPC SDK \K[0-9]+\.[0-9]+' | head -1)

    if [[ -n "${version}" ]]; then
        echo "${version}"
        return 0
    fi

    return 1
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
# Get upstream version with fallback chain:
# 1. Cache -> 2. Repology -> 3. Anitya -> 4. Special handlers
get_upstream_version() {
    local pkg="$1"
    local repology_name="$2"
    local upstream=""

    # Try cache first
    if upstream=$(get_cached_version "${pkg}"); then
        echo "${upstream}"
        return 0
    fi

    # Special handling for proprietary/non-standard packages
    case "${pkg}" in
        nvidia-driver|nvidia-*)
            upstream=$(check_nvidia_version 2>/dev/null) || true
            ;;
        nvidia-hpc*|nvhpc*)
            upstream=$(check_nvidia_hpc_version 2>/dev/null) || true
            ;;
        intel-oneapi*|oneapi*)
            upstream=$(check_intel_oneapi_version 2>/dev/null) || true
            ;;
        *)
            # Try Repology first (most comprehensive)
            upstream=$(check_repology_version "${repology_name}" 2>/dev/null) || true

            # Fallback to Anitya if Repology failed
            if [[ -z "${upstream}" ]]; then
                log "Repology failed, trying Anitya for ${pkg}"
                upstream=$(check_anitya_version "${pkg}" 2>/dev/null) || true
            fi
            ;;
    esac

    if [[ -n "${upstream}" ]]; then
        cache_version "${pkg}" "${upstream}"
        echo "${upstream}"
        return 0
    fi

    return 1
}

# Fetch a single package version in background and store result
fetch_version_bg() {
    local pkg="$1"
    local repology_name="$2"
    local result_file="${CACHE_DIR}/.fetch_${pkg}"

    # Get version (uses cache if available)
    local version
    version=$(get_upstream_version "${pkg}" "${repology_name}" 2>/dev/null) || true
    echo "${version}" > "${result_file}"
}

# Parallel fetch all package versions
parallel_fetch_versions() {
    local jobs=0

    echo -e "${CYAN}Fetching versions in parallel (max ${MAX_PARALLEL} jobs)...${NC}" >&2

    for entry in "${PACKAGES_TO_CHECK[@]}"; do
        local pkg="${entry%%=*}"
        local version_info="${entry#*=}"
        local repology_name="${version_info#*|}"

        # Check if already cached
        if get_cached_version "${pkg}" &>/dev/null; then
            continue
        fi

        # Launch background job
        fetch_version_bg "${pkg}" "${repology_name}" &
        FETCH_PIDS+=($!)
        jobs=$((jobs + 1))

        # Limit parallel jobs
        if [[ ${jobs} -ge ${MAX_PARALLEL} ]]; then
            wait -n 2>/dev/null || true
            jobs=$((jobs - 1))
        fi
    done

    # Wait for all remaining jobs
    for pid in "${FETCH_PIDS[@]}"; do
        wait "${pid}" 2>/dev/null || true
    done

    echo -e "${GREEN}Done fetching.${NC}" >&2
}

# Global array for packages to check
declare -a PACKAGES_TO_CHECK=()

main() {
    echo -e "${BLUE}LFS Package Version Checker${NC}"
    echo -e "Sources: ${CYAN}repology.org${NC} + ${CYAN}release-monitoring.org${NC}"
    echo "========================================"
    echo ""

    local outdated=0
    local checked=0
    local errors=0

    # Parse packages into global array
    PACKAGES_TO_CHECK=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] && PACKAGES_TO_CHECK+=("${line}")
    done < <(parse_packages)

    # Filter if needed
    if [[ -n "${PACKAGE_FILTER}" ]]; then
        local -a filtered=()
        for entry in "${PACKAGES_TO_CHECK[@]}"; do
            local pkg="${entry%%=*}"
            if [[ " ${PACKAGE_FILTER} " =~ " ${pkg} " ]]; then
                filtered+=("${entry}")
            fi
        done
        PACKAGES_TO_CHECK=("${filtered[@]}")
    fi

    # Parallel fetch all versions first
    parallel_fetch_versions

    # Now display results
    if [[ ${VERBOSE} -eq 1 ]]; then
        printf "%-20s %-15s %-15s %-20s %s\n" "PACKAGE" "LOCAL" "UPSTREAM" "REPOLOGY NAME" "STATUS"
        printf "%-20s %-15s %-15s %-20s %s\n" "-------" "-----" "--------" "-------------" "------"
    else
        printf "%-20s %-15s %-15s %s\n" "PACKAGE" "LOCAL" "UPSTREAM" "STATUS"
        printf "%-20s %-15s %-15s %s\n" "-------" "-----" "--------" "------"
    fi

    for entry in "${PACKAGES_TO_CHECK[@]}"; do
        local pkg="${entry%%=*}"
        local version_info="${entry#*=}"
        local version="${version_info%|*}"
        local repology_name="${version_info#*|}"

        checked=$((checked + 1))

        # Get cached result
        local upstream
        upstream=$(get_cached_version "${pkg}" 2>/dev/null) || true

        # Also check .fetch file if cache missed
        if [[ -z "${upstream}" ]] && [[ -f "${CACHE_DIR}/.fetch_${pkg}" ]]; then
            upstream=$(cat "${CACHE_DIR}/.fetch_${pkg}")
            rm -f "${CACHE_DIR}/.fetch_${pkg}"
            [[ -n "${upstream}" ]] && cache_version "${pkg}" "${upstream}"
        fi

        if [[ -z "${upstream}" ]]; then
            if [[ ${CHECK_ALL} -eq 1 ]]; then
                if [[ ${VERBOSE} -eq 1 ]]; then
                    printf "%-20s %-15s %-15s %-20s %b\n" "${pkg}" "${version}" "?" "${repology_name}" "${YELLOW}unknown${NC}"
                else
                    printf "%-20s %-15s %-15s %b\n" "${pkg}" "${version}" "?" "${YELLOW}unknown${NC}"
                fi
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

        if [[ ${VERBOSE} -eq 1 ]]; then
            printf "%-20s %-15s %-15s %-20s %b\n" "${pkg}" "${version}" "${upstream}" "${repology_name}" "${status}"
        else
            printf "%-20s %-15s %-15s %b\n" "${pkg}" "${version}" "${upstream}" "${status}"
        fi

    done

    echo ""
    echo "========================================"
    echo "Checked: ${checked} | Outdated: ${outdated} | Not in Repology: ${errors}"

    if [[ ${UPDATE_TOML} -eq 1 ]] && [[ ${outdated} -gt 0 ]]; then
        echo -e "${YELLOW}packages.toml has been updated${NC}"
    fi

    return ${outdated}
}

main "$@"
