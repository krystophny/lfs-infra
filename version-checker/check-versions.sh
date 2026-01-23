#!/bin/bash
# LFS Package Version Checker
# Uses direct source checks with fallback to Repology
# version_check formats:
#   gnu:<project>         - GNU FTP mirror
#   kernel:               - kernel.org
#   gcc-snapshot:         - GCC development snapshots
#   github:<owner/repo>   - GitHub releases
#   url:<url>|<regex>     - Direct URL scraping with regex
#   xorg:<path>           - X.org releases
#   gnome:<project>       - GNOME releases
#   xfce:<path>           - XFCE releases
#   freedesktop:<path>    - freedesktop.org GitLab
#   savannah:<project>    - GNU Savannah
#   cpan:<module>         - CPAN (Perl)
#   python:               - Python.org
#   tukaani:<project>     - Tukaani (xz)
#   zlib:                 - zlib.net
#   sourceware:<project>  - sourceware.org
#   alsa:<component>      - ALSA releases
#   kernelorg:<path>      - kernel.org subdirs

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

VERBOSE=0
CHECK_ALL=0
PACKAGE_FILTER=""
UPDATE_TOML=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [PACKAGE...]

Check LFS package versions against upstream releases.
Uses direct source checks with Repology fallback.

Options:
    -a, --all       Show all packages (default: only outdated)
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

log() { [[ ${VERBOSE} -eq 1 ]] && echo -e "${CYAN}[DEBUG]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Fetch with retries and timeout
fetch_url() {
    local url="$1"
    local retries=3
    local timeout=15

    for ((i=1; i<=retries; i++)); do
        local result
        if result=$(curl -fsSL --connect-timeout "${timeout}" -A "lfs-version-checker/2.0" "${url}" 2>/dev/null); then
            echo "${result}"
            return 0
        fi
        log "Retry ${i}/${retries} for ${url}"
        sleep 1
    done
    return 1
}

# Filter unstable versions
filter_stable() {
    grep -viE '(rc|alpha|beta|pre|dev|snapshot|git|svn|cvs|test|nightly|exp|trunk)' | \
    grep -vE '^9999$|^0\.0\.' | \
    grep -E '^[0-9]' || true
}

# Sort versions and get latest
latest_version() {
    sort -V | tail -1
}

# Cache functions
get_cached() {
    local key="$1"
    local cache_file="${CACHE_DIR}/${key//\//_}.version"
    if [[ -f "${cache_file}" ]]; then
        local age=$(($(date +%s) - $(stat -c %Y "${cache_file}" 2>/dev/null || echo 0)))
        if [[ ${age} -lt ${CACHE_TTL} ]]; then
            cat "${cache_file}"
            return 0
        fi
    fi
    return 1
}

set_cache() {
    local key="$1"
    local value="$2"
    echo "${value}" > "${CACHE_DIR}/${key//\//_}.version"
}

# ============================================================
# Direct version check handlers
# ============================================================

check_gnu() {
    local project="$1"
    log "Checking GNU: ${project}"

    local url="https://ftpmirror.gnu.org/gnu/${project}/"
    local html
    html=$(fetch_url "${url}") || return 1

    # Extract version from tarball names
    echo "${html}" | grep -oP "${project}-\K[0-9]+(\.[0-9]+)+" | filter_stable | latest_version
}

check_kernel() {
    log "Checking kernel.org"

    local json
    json=$(fetch_url "https://www.kernel.org/releases.json") || return 1

    # Get latest stable (not RC)
    echo "${json}" | jq -r '.releases[] | select(.moniker == "stable") | .version' 2>/dev/null | head -1
}

check_gcc_snapshot() {
    log "Checking GCC snapshots"

    local html
    html=$(fetch_url "https://gcc.gnu.org/pub/gcc/snapshots/LATEST-16/") || return 1

    # Extract snapshot version like 16-20260118
    echo "${html}" | grep -oP 'gcc-\K16-[0-9]+' | latest_version
}

check_github() {
    local repo="$1"
    log "Checking GitHub: ${repo}"

    local json
    json=$(fetch_url "https://api.github.com/repos/${repo}/releases/latest") || {
        # Try tags if no releases
        json=$(fetch_url "https://api.github.com/repos/${repo}/tags") || return 1
        echo "${json}" | jq -r '.[0].name' 2>/dev/null | sed 's/^[vV]//' | filter_stable | head -1
        return
    }

    echo "${json}" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^[vV]//' | filter_stable
}

check_url_regex() {
    local url="$1"
    local regex="$2"
    log "Checking URL: ${url} with pattern: ${regex}"

    [[ "${regex}" == "skip" ]] && return 1

    local html
    html=$(fetch_url "${url}") || return 1

    # Handle different regex formats
    if [[ "${regex}" =~ \([0-9] ]]; then
        # Regex with capture groups - extract version parts
        echo "${html}" | grep -oP "${regex}" | \
            sed -E 's/.*\(([0-9]+)\).*\(([0-9]+)\).*/\1.\2/' | \
            filter_stable | latest_version
    else
        # Simple pattern - extract directly
        echo "${html}" | grep -oE "${regex}" | \
            grep -oE '[0-9]+(\.[0-9]+)+' | \
            filter_stable | latest_version
    fi
}

check_xorg() {
    local path="$1"
    log "Checking X.org: ${path}"

    local url="https://xorg.freedesktop.org/releases/individual/${path}/"
    local html
    html=$(fetch_url "${url}") || return 1

    local name
    name=$(basename "${path}")
    echo "${html}" | grep -oP "${name}-\K[0-9]+(\.[0-9]+)+" | filter_stable | latest_version
}

check_gnome() {
    local project="$1"
    log "Checking GNOME: ${project}"

    local json
    json=$(fetch_url "https://download.gnome.org/sources/${project}/cache.json") || return 1

    # Get latest stable version (even minor = stable)
    echo "${json}" | jq -r '.[1] | keys[]' 2>/dev/null | \
        grep -E '^[0-9]+\.[0-9]*[02468](\.[0-9]+)?$' | \
        filter_stable | latest_version
}

check_xfce() {
    local path="$1"
    log "Checking XFCE: ${path}"

    local url="https://archive.xfce.org/src/${path}/"
    local html
    html=$(fetch_url "${url}") || return 1

    # Get version dirs, then latest tarball
    local latest_dir
    latest_dir=$(echo "${html}" | grep -oP 'href="\K[0-9]+\.[0-9]+' | latest_version)

    if [[ -n "${latest_dir}" ]]; then
        html=$(fetch_url "${url}${latest_dir}/") || return 1
        local name
        name=$(basename "${path}")
        echo "${html}" | grep -oP "${name}-\K[0-9]+(\.[0-9]+)+" | filter_stable | latest_version
    fi
}

check_freedesktop() {
    local path="$1"
    log "Checking freedesktop.org: ${path}"

    local json
    json=$(fetch_url "https://gitlab.freedesktop.org/api/v4/projects/${path//\//%2F}/releases") || return 1

    echo "${json}" | jq -r '.[0].tag_name // empty' 2>/dev/null | sed 's/^[vV]//' | filter_stable
}

check_savannah() {
    local project="$1"
    log "Checking Savannah: ${project}"

    local url="https://download.savannah.gnu.org/releases/${project}/"
    local html
    html=$(fetch_url "${url}") || return 1

    echo "${html}" | grep -oP "${project}-\K[0-9]+(\.[0-9]+)+" | filter_stable | latest_version
}

check_cpan() {
    local module="$1"
    log "Checking CPAN: ${module}"

    local json
    json=$(fetch_url "https://fastapi.metacpan.org/v1/release/${module}") || return 1

    echo "${json}" | jq -r '.version // empty' 2>/dev/null | filter_stable
}

check_python() {
    log "Checking Python.org"

    local html
    html=$(fetch_url "https://www.python.org/downloads/") || return 1

    echo "${html}" | grep -oP 'Python \K[0-9]+\.[0-9]+\.[0-9]+' | filter_stable | latest_version
}

check_tukaani() {
    local project="$1"
    log "Checking Tukaani: ${project}"

    local url="https://github.com/tukaani-project/${project}/releases"
    check_github "tukaani-project/${project}"
}

check_zlib() {
    log "Checking zlib.net"

    local html
    html=$(fetch_url "https://zlib.net/") || return 1

    echo "${html}" | grep -oP 'zlib-\K[0-9]+(\.[0-9]+)+' | filter_stable | latest_version
}

check_sourceware() {
    local project="$1"
    log "Checking sourceware: ${project}"

    local url="https://sourceware.org/pub/${project}/"
    local html
    html=$(fetch_url "${url}") || return 1

    echo "${html}" | grep -oP "${project}-\K[0-9]+(\.[0-9]+)+" | filter_stable | latest_version
}

check_alsa() {
    local component="$1"
    log "Checking ALSA: ${component}"

    local url="https://www.alsa-project.org/files/pub/${component}/"
    local html
    html=$(fetch_url "${url}") || return 1

    echo "${html}" | grep -oP "alsa-${component}-\K[0-9]+(\.[0-9]+)+" | filter_stable | latest_version
}

check_kernelorg() {
    local path="$1"
    local name="$2"
    log "Checking kernel.org: ${path}/${name}"

    local url="https://www.kernel.org/pub/${path}/"
    local html
    html=$(fetch_url "${url}") || return 1

    echo "${html}" | grep -oP "${name}-\K[0-9]+(\.[0-9]+)+" | filter_stable | latest_version
}

check_sourceforge() {
    local project="$1"
    log "Checking SourceForge: ${project}"

    local url="https://sourceforge.net/projects/${project}/rss?path=/"
    local xml
    xml=$(fetch_url "${url}") || return 1

    echo "${xml}" | grep -oP "${project}-\K[0-9]+(\.[0-9]+)+" | filter_stable | latest_version
}

check_repology() {
    local pkg="$1"
    log "Checking Repology: ${pkg}"

    local json
    json=$(fetch_url "https://repology.org/api/v1/project/${pkg}") || return 1

    echo "${json}" | jq -r '.[] | select(.status == "newest") | .version' 2>/dev/null | \
        filter_stable | latest_version
}

# ============================================================
# Main version check dispatcher
# ============================================================

check_version() {
    local pkg="$1"
    local version_check="$2"

    # Try cache first
    local cached
    if cached=$(get_cached "${pkg}"); then
        echo "${cached}"
        return 0
    fi

    local result=""

    case "${version_check}" in
        gnu:*)
            result=$(check_gnu "${version_check#gnu:}") ;;
        kernel:*)
            result=$(check_kernel) ;;
        gcc-snapshot:*)
            result=$(check_gcc_snapshot) ;;
        github:*)
            result=$(check_github "${version_check#github:}") ;;
        url:*)
            local spec="${version_check#url:}"
            local url="${spec%|*}"
            local regex="${spec#*|}"
            result=$(check_url_regex "${url}" "${regex}") ;;
        xorg:*)
            result=$(check_xorg "${version_check#xorg:}") ;;
        gnome:*)
            result=$(check_gnome "${version_check#gnome:}") ;;
        xfce:*)
            result=$(check_xfce "${version_check#xfce:}") ;;
        freedesktop:*)
            result=$(check_freedesktop "${version_check#freedesktop:}") ;;
        savannah:*)
            result=$(check_savannah "${version_check#savannah:}") ;;
        cpan:*)
            result=$(check_cpan "${version_check#cpan:}") ;;
        python:*)
            result=$(check_python) ;;
        tukaani:*)
            result=$(check_tukaani "${version_check#tukaani:}") ;;
        zlib:*)
            result=$(check_zlib) ;;
        sourceware:*)
            result=$(check_sourceware "${version_check#sourceware:}") ;;
        alsa:*)
            result=$(check_alsa "${version_check#alsa:}") ;;
        kernelorg:*)
            local spec="${version_check#kernelorg:}"
            local path="${spec%|*}"
            local name="${spec#*|}"
            result=$(check_kernelorg "${path}" "${name}") ;;
        sourceforge:*)
            result=$(check_sourceforge "${version_check#sourceforge:}") ;;
        *)
            # Fallback to Repology
            result=$(check_repology "${pkg}") ;;
    esac

    if [[ -n "${result}" ]]; then
        set_cache "${pkg}" "${result}"
        echo "${result}"
        return 0
    fi

    # Final fallback: Repology
    if [[ "${version_check}" != repology:* ]]; then
        log "Falling back to Repology for ${pkg}"
        result=$(check_repology "${pkg}") || true
        if [[ -n "${result}" ]]; then
            set_cache "${pkg}" "${result}"
            echo "${result}"
            return 0
        fi
    fi

    return 1
}

# Parse packages from TOML
parse_packages() {
    local current_pkg=""
    local current_version=""
    local version_check=""

    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

        if [[ "${line}" =~ ^\[packages\.([a-zA-Z0-9_-]+)\] ]]; then
            if [[ -n "${current_pkg}" && -n "${current_version}" ]]; then
                echo "${current_pkg}=${current_version}|${version_check:-repology:${current_pkg}}"
            fi
            current_pkg="${BASH_REMATCH[1]}"
            current_version=""
            version_check=""
            continue
        fi

        if [[ -n "${current_pkg}" ]]; then
            if [[ "${line}" =~ ^version[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
                current_version="${BASH_REMATCH[1]}"
            fi
            if [[ "${line}" =~ ^version_check[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
                version_check="${BASH_REMATCH[1]}"
            fi
        fi
    done < "${PACKAGES_FILE}"

    if [[ -n "${current_pkg}" && -n "${current_version}" ]]; then
        echo "${current_pkg}=${current_version}|${version_check:-repology:${current_pkg}}"
    fi
}

# Version comparison
version_ge() {
    [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

# Get URL template for a package
get_pkg_url() {
    local pkg="$1"
    awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[/ && found { exit }
        found && /^url *= *"/ { gsub(/.*= *"|".*/, ""); print; exit }
    ' "${PACKAGES_FILE}"
}

# Verify URL exists
verify_url() {
    curl -fsSL --head --connect-timeout 10 "$1" &>/dev/null
}

# Update TOML
update_toml_version() {
    local pkg="$1"
    local new_version="$2"

    local url_template
    url_template=$(get_pkg_url "${pkg}")

    if [[ -n "${url_template}" ]]; then
        local url="${url_template//\$\{version\}/${new_version}}"
        url="${url//\$\{version_mm\}/${new_version%.*}}"
        log "Verifying: ${url}"
        if ! verify_url "${url}"; then
            warn "URL verification failed for ${pkg} ${new_version}"
            return 1
        fi
    fi

    sed -i "/^\[packages\.${pkg}\]/,/^\[/{s/^version = \"[^\"]*\"/version = \"${new_version}\"/}" "${PACKAGES_FILE}"
    log "Updated ${pkg} to ${new_version}"
}

# Main
main() {
    echo -e "${BLUE}LFS Package Version Checker${NC}"
    echo -e "Direct source checks with Repology fallback"
    echo "========================================"
    echo ""

    local outdated=0 checked=0 errors=0

    declare -a packages=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] && packages+=("${line}")
    done < <(parse_packages)

    # Filter if specified
    if [[ -n "${PACKAGE_FILTER}" ]]; then
        local -a filtered=()
        for entry in "${packages[@]}"; do
            local pkg="${entry%%=*}"
            if [[ " ${PACKAGE_FILTER} " =~ " ${pkg} " ]]; then
                filtered+=("${entry}")
            fi
        done
        packages=("${filtered[@]}")
    fi

    printf "%-25s %-15s %-15s %s\n" "PACKAGE" "LOCAL" "UPSTREAM" "STATUS"
    printf "%-25s %-15s %-15s %s\n" "-------" "-----" "--------" "------"

    for entry in "${packages[@]}"; do
        local pkg="${entry%%=*}"
        local info="${entry#*=}"
        local version="${info%|*}"
        local version_check="${info#*|}"

        checked=$((checked + 1))

        local upstream
        upstream=$(check_version "${pkg}" "${version_check}" 2>/dev/null) || true

        if [[ -z "${upstream}" ]]; then
            [[ ${CHECK_ALL} -eq 1 ]] && printf "%-25s %-15s %-15s %b\n" "${pkg}" "${version}" "?" "${YELLOW}unknown${NC}"
            errors=$((errors + 1))
            continue
        fi

        local status
        if version_ge "${version}" "${upstream}"; then
            status="${GREEN}up-to-date${NC}"
            [[ ${CHECK_ALL} -eq 0 ]] && continue
        else
            status="${RED}outdated${NC}"
            outdated=$((outdated + 1))
            if [[ ${UPDATE_TOML} -eq 1 ]]; then
                if update_toml_version "${pkg}" "${upstream}"; then
                    status="${YELLOW}updated${NC}"
                fi
            fi
        fi

        printf "%-25s %-15s %-15s %b\n" "${pkg}" "${version}" "${upstream}" "${status}"
    done

    echo ""
    echo "========================================"
    echo "Checked: ${checked} | Outdated: ${outdated} | Errors: ${errors}"

    [[ ${UPDATE_TOML} -eq 1 ]] && [[ ${outdated} -gt 0 ]] && echo -e "${YELLOW}packages.toml updated${NC}"

    return ${outdated}
}

main "$@"
