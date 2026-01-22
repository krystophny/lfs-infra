#!/bin/bash
# LFS Version Checker - Direct Upstream Queries
# Fast, clean, no third-party APIs
#
# Each package in packages.toml can have:
#   version_check = "github:owner/repo"      # GitHub releases
#   version_check = "gnu:package"            # GNU FTP
#   version_check = "kernel:"                # kernel.org
#   version_check = "pypi:package"           # PyPI
#   version_check = "url:https://...|regex"  # Custom URL + regex

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
PACKAGES_FILE="${ROOT_DIR}/packages.toml"
CACHE_DIR="${TMPDIR:-/tmp}/lfs-versions"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p "${CACHE_DIR}"

# Get local version from packages.toml
get_local_version() {
    local pkg="$1"
    awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[packages\./ && found { exit }
        found && /^version *= *"/ { gsub(/.*= *"|".*/, ""); print; exit }
    ' "${PACKAGES_FILE}"
}

# Get version_check field from packages.toml
get_version_check() {
    local pkg="$1"
    awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[packages\./ && found { exit }
        found && /^version_check *= *"/ { gsub(/.*= *"|".*/, ""); print; exit }
    ' "${PACKAGES_FILE}"
}

# Get git_url to infer GitHub repo
get_git_url() {
    local pkg="$1"
    awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[packages\./ && found { exit }
        found && /^git_url *= *"/ { gsub(/.*= *"|".*/, ""); print; exit }
    ' "${PACKAGES_FILE}"
}

# Fetch with caching (1 hour TTL)
fetch_cached() {
    local url="$1"
    local cache_key
    cache_key=$(echo "$url" | md5sum | cut -c1-16)
    local cache_file="${CACHE_DIR}/${cache_key}"

    if [[ -f "${cache_file}" ]]; then
        local age now
        now=$(date +%s)
        age=$((now - $(stat -f %m "${cache_file}" 2>/dev/null || stat -c %Y "${cache_file}" 2>/dev/null || echo 0)))
        if [[ ${age} -lt 3600 ]]; then
            cat "${cache_file}"
            return 0
        fi
    fi

    local content
    if content=$(curl -sfL --max-time 10 "$url" 2>/dev/null); then
        echo "$content" > "${cache_file}"
        echo "$content"
        return 0
    fi
    return 1
}

# GitHub releases (scrapes HTML, no rate limits)
check_github() {
    local repo="$1"  # owner/repo
    local content tags version

    # Try releases page first
    content=$(fetch_cached "https://github.com/${repo}/releases" 2>/dev/null) || content=""
    tags=$(echo "$content" | grep -oE '/releases/tag/[^"]+' | head -30 | sed 's|.*/tag/||')

    # Fallback to tags page if no releases
    if [[ -z "$tags" ]]; then
        content=$(fetch_cached "https://github.com/${repo}/tags" 2>/dev/null) || return 1
        tags=$(echo "$content" | grep -oE "/${repo}/releases/tag/[^\"]+" | head -30 | sed 's|.*/tag/||')
    fi

    [[ -z "$tags" ]] && return 1

    # Extract version numbers, converting underscores to dots
    # Handle: v1.2.3, 1.2.3, pkg-1.2.3, pkg-1_2_3, release-1.2.3
    echo "$tags" | sed -E 's/^[a-zA-Z_-]+//; s/_/./g; s/^v//' | \
        grep -E '^[0-9]+\.[0-9]+' | sort -V | tail -1
}

# GNU FTP directory
check_gnu() {
    local pkg="$1"
    local url="https://ftp.gnu.org/gnu/${pkg}/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    # Extract latest version from directory listing
    # Handles: pkg-1.2.3.tar.xz (tarballs), pkg-1.2.3/ (directories like gcc)
    echo "$content" | grep -oE "${pkg}-[0-9]+\.[0-9]+(\.[0-9]+)?(\.tar|/|\")" | \
        sed "s/${pkg}-//;s|\.tar||;s|[/\"]||" | sort -V | tail -1
}

# Kernel.org
check_kernel() {
    local url="https://www.kernel.org/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    # Get latest stable
    echo "$content" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# PyPI (for actual PyPI packages)
check_pypi() {
    local pkg="$1"
    local url="https://pypi.org/pypi/${pkg}/json"
    fetch_cached "$url" 2>/dev/null | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/'
}

# Python.org (for Python itself)
check_python() {
    local url="https://www.python.org/ftp/python/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    echo "$content" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+/' | sed 's|/||' | sort -V | tail -1
}

# CPAN Perl source
check_cpan() {
    local pkg="$1"
    local url="https://www.cpan.org/src/5.0/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    echo "$content" | grep -oE 'perl-[0-9]+\.[0-9]+\.[0-9]+\.tar' | \
        sed 's/perl-//;s/\.tar//' | sort -V | tail -1
}

# Sourceware (glibc, binutils, bzip2, etc.)
check_sourceware() {
    local pkg="$1"
    local url="https://sourceware.org/pub/${pkg}/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    echo "$content" | grep -oE "${pkg}-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar" | \
        sed "s/${pkg}-//;s/\.tar//" | sort -V | tail -1
}

# freedesktop.org (mesa, etc.)
check_freedesktop() {
    local pkg="$1"
    local url="https://gitlab.freedesktop.org/${pkg}/-/tags?format=atom"
    fetch_cached "$url" 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1
}

# X.org releases
check_xorg() {
    local spec="$1"  # category/pkg or just pkg
    local category pkg
    if [[ "$spec" == */* ]]; then
        category="${spec%%/*}"
        pkg="${spec#*/}"
    else
        pkg="$spec"
        category="lib"  # default
    fi
    local url="https://www.x.org/releases/individual/${category}/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    echo "$content" | grep -oE "${pkg}-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar" | \
        sed "s/${pkg}-//;s/\.tar//" | sort -V | tail -1
}

# XFCE releases
check_xfce() {
    local spec="$1"  # category/pkg
    local category="${spec%%/*}"
    local pkg="${spec#*/}"
    local url="https://archive.xfce.org/src/${category}/${pkg}/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    # XFCE uses x.y directories
    echo "$content" | grep -oE '[0-9]+\.[0-9]+/' | sed 's|/||' | sort -V | tail -1
}

# GNOME releases
check_gnome() {
    local pkg="$1"
    local url="https://download.gnome.org/sources/${pkg}/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    # GNOME uses x.y directories
    echo "$content" | grep -oE '[0-9]+\.[0-9]+/' | sed 's|/||' | sort -V | tail -1
}

# ALSA releases
check_alsa() {
    local pkg="$1"
    local url="https://www.alsa-project.org/files/pub/${pkg}/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    echo "$content" | grep -oE "${pkg}-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar" | \
        sed "s/${pkg}-//;s/\.tar//" | sort -V | tail -1
}

# Savannah nongnu
check_savannah() {
    local pkg="$1"
    local url="https://download.savannah.nongnu.org/releases/${pkg}/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    echo "$content" | grep -oE "${pkg}-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar" | \
        sed "s/${pkg}-//;s/\.tar//" | sort -V | tail -1
}

# SourceForge (tricky - try to get from RSS)
check_sourceforge() {
    local pkg="$1"
    local url="https://sourceforge.net/projects/${pkg}/rss?path=/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    echo "$content" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V | tail -1
}

# tukaani.org (xz)
check_tukaani() {
    local pkg="$1"
    local url="https://tukaani.org/${pkg}/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    echo "$content" | grep -oE "${pkg}-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar" | \
        sed "s/${pkg}-//;s/\.tar//" | sort -V | tail -1
}

# zlib.net
check_zlib() {
    local url="https://zlib.net/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    echo "$content" | grep -oE 'zlib-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar' | \
        sed 's/zlib-//;s/\.tar//' | sort -V | tail -1
}

# Generic FTP/directory listing
check_ftp() {
    local spec="$1"  # url|pkg
    local url="${spec%%|*}"
    local pkg="${spec#*|}"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    echo "$content" | grep -oE "${pkg}-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar" | \
        sed "s/${pkg}-//;s/\.tar//" | sort -V | tail -1
}

# Custom URL with pattern
check_url() {
    local spec="$1"
    local url pattern
    url="${spec%%|*}"
    pattern="${spec#*|}"

    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    if [[ "$pattern" != "$spec" ]]; then
        # Handle patterns with capture groups - extract and join with dots
        # First try to match and extract all versions
        local versions
        versions=$(echo "$content" | grep -oE "$pattern" | head -30)

        # Convert formats like FILE5_46 -> 5.46, V3-6-0 -> 3.6.0
        echo "$versions" | sed -E '
            s/^[A-Za-z_-]*//
            s/_/./g
            s/-/./g
            s/^\.//
        ' | grep -E '^[0-9]+\.[0-9]+' | sort -V | tail -1
    else
        echo "$content" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V | tail -1
    fi
}

# Get url field from packages.toml
get_url() {
    local pkg="$1"
    awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[packages\./ && found { exit }
        found && /^url *= *"/ { gsub(/.*= *"|".*/, ""); print; exit }
    ' "${PACKAGES_FILE}"
}

# kernel.org pub (non-kernel packages like iwd, bluez)
check_kernelorg() {
    local spec="$1"  # e.g., linux/network/wireless|iwd
    local path="${spec%%|*}"
    local pkg="${spec#*|}"
    local url="https://www.kernel.org/pub/${path}/"
    local content
    content=$(fetch_cached "$url" 2>/dev/null) || return 1

    echo "$content" | grep -oE "${pkg}-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar" | \
        sed "s/${pkg}-//;s/\.tar//" | sort -V | tail -1
}

# Infer check method from git_url or url if no version_check specified
infer_check_method() {
    local pkg="$1"
    local git_url url
    git_url=$(get_git_url "$pkg")
    url=$(get_url "$pkg")

    # Check download URL FIRST - prefer authoritative source over mirrors
    case "$url" in
        # GNU sources
        *ftpmirror.gnu.org*|*ftp.gnu.org*)
            echo "gnu:${pkg}"
            return
            ;;
        # Linux kernel
        *kernel.org/pub/linux/kernel/*)
            echo "kernel:"
            return
            ;;
        # Other kernel.org packages (iwd, bluez, etc.)
        *kernel.org/pub/*)
            local kpath
            kpath=$(echo "$url" | sed -E 's|.*kernel\.org/pub/([^/]+(/[^/]+)*)/[^/]+\.tar.*|\1|')
            echo "kernelorg:${kpath}|${pkg}"
            return
            ;;
        # X.org packages
        *x.org/releases/individual/*)
            local xcat
            xcat=$(echo "$url" | sed -E 's|.*individual/([^/]+)/.*|\1|')
            echo "xorg:${xcat}/${pkg}"
            return
            ;;
        *x.org/archive/individual/*)
            local xcat
            xcat=$(echo "$url" | sed -E 's|.*individual/([^/]+)/.*|\1|')
            echo "xorg:${xcat}/${pkg}"
            return
            ;;
        # XFCE packages
        *archive.xfce.org/src/*)
            local xfcat
            xfcat=$(echo "$url" | sed -E 's|.*src/([^/]+)/([^/]+)/.*|\1/\2|')
            echo "xfce:${xfcat}"
            return
            ;;
        # GNOME packages
        *download.gnome.org/sources/*)
            local gpkg
            gpkg=$(echo "$url" | sed -E 's|.*sources/([^/]+)/.*|\1|')
            echo "gnome:${gpkg}"
            return
            ;;
        # freedesktop.org
        *freedesktop.org/software/*)
            local fdpkg
            fdpkg=$(echo "$url" | sed -E 's|.*software/([^/]+)/.*|\1|')
            echo "ftp:${url%/*}/|${pkg}"
            return
            ;;
        *mesa.freedesktop.org*)
            echo "ftp:https://mesa.freedesktop.org/archive/|mesa"
            return
            ;;
        *gitlab.freedesktop.org*)
            local fdrepo
            fdrepo=$(echo "$url" | sed -E 's|.*gitlab\.freedesktop\.org/([^/]+/[^/]+).*|\1|')
            echo "freedesktop:${fdrepo}"
            return
            ;;
        # ALSA
        *alsa-project.org*)
            local apkg
            apkg=$(echo "$url" | sed -E 's|.*pub/([^/]+)/.*|\1|')
            echo "alsa:${apkg}"
            return
            ;;
        # Savannah nongnu
        *savannah.nongnu.org*)
            local spkg
            spkg=$(echo "$url" | sed -E 's|.*releases/([^/]+)/.*|\1|')
            echo "savannah:${spkg}"
            return
            ;;
        # SourceForge
        *sourceforge.net/projects/*)
            local sfpkg
            sfpkg=$(echo "$url" | sed -E 's|.*projects/([^/]+)/.*|\1|')
            echo "sourceforge:${sfpkg}"
            return
            ;;
        # tukaani (xz)
        *tukaani.org/*)
            echo "tukaani:${pkg}"
            return
            ;;
        # zlib
        *zlib.net*)
            echo "zlib:"
            return
            ;;
        # Python
        *python.org*)
            echo "python:"
            return
            ;;
        # CPAN (Perl)
        *cpan.org*)
            echo "cpan:${pkg}"
            return
            ;;
        # Sourceware
        *sourceware.org*)
            echo "sourceware:${pkg}"
            return
            ;;
        # GitHub releases/archives
        *github.com/*/*)
            echo "github:$(echo "$url" | sed -E 's|.*github\.com/([^/]+/[^/]+)/.*|\1|')"
            return
            ;;
    esac

    # Fallback: check git_url for other patterns
    case "$git_url" in
        *git.savannah.gnu.org*)
            echo "gnu:${pkg}"
            return
            ;;
        *savannah.nongnu.org*)
            echo "savannah:${pkg}"
            return
            ;;
        *sourceware.org*)
            echo "sourceware:${pkg}"
            return
            ;;
        *gitlab.freedesktop.org*)
            local fdrepo
            fdrepo=$(echo "$git_url" | sed -E 's|.*gitlab\.freedesktop\.org/([^/]+/[^/]+).*|\1|')
            echo "freedesktop:${fdrepo}"
            return
            ;;
        *github.com/*/*)
            echo "github:$(echo "$git_url" | sed -E 's|.*github\.com[:/]([^/]+/[^/]+).*|\1|' | sed 's/\.git$//')"
            return
            ;;
    esac

    echo ""
}

# Get upstream version for a package
get_upstream_version() {
    local pkg="$1"
    local check_spec

    # First try explicit version_check field
    check_spec=$(get_version_check "$pkg")

    # If not specified, try to infer from git_url
    if [[ -z "$check_spec" ]]; then
        check_spec=$(infer_check_method "$pkg")
    fi

    [[ -z "$check_spec" ]] && return 1

    local method arg
    method="${check_spec%%:*}"
    arg="${check_spec#*:}"

    case "$method" in
        github) check_github "$arg" ;;
        gnu) check_gnu "$arg" ;;
        kernel) check_kernel ;;
        kernelorg) check_kernelorg "$arg" ;;
        xorg) check_xorg "$arg" ;;
        xfce) check_xfce "$arg" ;;
        gnome) check_gnome "$arg" ;;
        alsa) check_alsa "$arg" ;;
        savannah) check_savannah "$arg" ;;
        sourceforge) check_sourceforge "$arg" ;;
        tukaani) check_tukaani "$arg" ;;
        zlib) check_zlib ;;
        ftp) check_ftp "$arg" ;;
        python) check_python ;;
        pypi) check_pypi "$arg" ;;
        cpan) check_cpan "$arg" ;;
        sourceware) check_sourceware "$arg" ;;
        freedesktop) check_freedesktop "$arg" ;;
        url) check_url "$arg" ;;
        *) return 1 ;;
    esac
}

# Normalize version (strip trailing .0 for comparison)
normalize_version() {
    echo "$1" | sed -E 's/\.0+$//'
}

# Compare versions (returns 0 if v1 < v2)
version_lt() {
    local v1 v2
    v1=$(normalize_version "$1")
    v2=$(normalize_version "$2")
    [[ "$v1" != "$v2" ]] && [[ "$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -1)" == "$v1" ]]
}

# Check if versions are equal (after normalization)
version_eq() {
    [[ "$(normalize_version "$1")" == "$(normalize_version "$2")" ]]
}

# Main
main() {
    local filter=("$@")
    local show_all=0
    local update_toml=0

    # Parse flags
    while [[ ${#filter[@]} -gt 0 ]]; do
        case "${filter[0]}" in
            -a|--all) show_all=1; filter=("${filter[@]:1}") ;;
            -u|--update) update_toml=1; filter=("${filter[@]:1}") ;;
            -c|--clear) rm -rf "${CACHE_DIR}"; echo "Cache cleared"; exit 0 ;;
            -h|--help)
                echo "Usage: $(basename "$0") [-a] [-u] [-c] [package...]"
                echo "  -a  Show all packages (not just outdated)"
                echo "  -u  Update packages.toml with new versions"
                echo "  -c  Clear version cache"
                exit 0
                ;;
            -*) echo "Unknown option: ${filter[0]}"; exit 1 ;;
            *) break ;;
        esac
    done

    echo -e "${BOLD}LFS Version Checker${NC} - Direct Upstream Queries"
    echo "================================================"
    echo ""

    # Get package list
    local packages=()
    if [[ ${#filter[@]} -gt 0 ]]; then
        packages=("${filter[@]}")
    else
        while IFS= read -r pkg; do
            packages+=("$pkg")
        done < <(grep -E '^\[packages\.' "${PACKAGES_FILE}" | sed 's/\[packages\.\(.*\)\]/\1/')
    fi

    local outdated=()
    local checked=0
    local skipped=0

    printf "${BOLD}%-28s %-14s %-14s %s${NC}\n" "PACKAGE" "LOCAL" "UPSTREAM" "STATUS"
    printf "%-28s %-14s %-14s %s\n" "-------" "-----" "--------" "------"

    for pkg in "${packages[@]}"; do
        local local_ver upstream_ver status color
        local_ver=$(get_local_version "$pkg")

        # Skip meta-packages (no version or pass variants)
        [[ -z "$local_ver" ]] && continue
        [[ "$pkg" == *-pass[12] ]] && continue
        [[ "$pkg" == "libstdcxx" ]] && continue

        upstream_ver=$(get_upstream_version "$pkg" 2>/dev/null) || upstream_ver=""

        ((checked++))

        if [[ -z "$upstream_ver" ]]; then
            ((skipped++))
            [[ $show_all -eq 1 ]] && printf "%-28s %-14s %-14s ${YELLOW}%s${NC}\n" "$pkg" "$local_ver" "-" "no check"
            continue
        fi

        if version_eq "$local_ver" "$upstream_ver"; then
            status="up to date"
            color="${GREEN}"
            [[ $show_all -eq 1 ]] && printf "%-28s %-14s %-14s ${color}%s${NC}\n" "$pkg" "$local_ver" "$upstream_ver" "$status"
        elif version_lt "$local_ver" "$upstream_ver"; then
            status="UPDATE"
            color="${RED}"
            outdated+=("$pkg|$local_ver|$upstream_ver")
            printf "%-28s %-14s ${color}%-14s %s${NC}\n" "$pkg" "$local_ver" "$upstream_ver" "$status"
        else
            status="newer"
            color="${CYAN}"
            [[ $show_all -eq 1 ]] && printf "%-28s %-14s %-14s ${color}%s${NC}\n" "$pkg" "$local_ver" "$upstream_ver" "$status"
        fi
    done

    echo ""
    echo "================================================"
    echo -e "Checked: ${checked} | Outdated: ${RED}${#outdated[@]}${NC} | No upstream check: ${skipped}"

    if [[ ${#outdated[@]} -gt 0 && $update_toml -eq 1 ]]; then
        echo ""
        echo "Updating packages.toml..."
        for entry in "${outdated[@]}"; do
            IFS='|' read -r pkg old new <<< "$entry"
            sed -i.bak -E "/^\[packages\.${pkg}\]/,/^\[packages\./{s/^(version *= *\").*(\")/\1${new}\2/}" "${PACKAGES_FILE}"
            echo "  $pkg: $old -> $new"
        done
        rm -f "${PACKAGES_FILE}.bak"
        echo -e "${GREEN}Done!${NC} Run build to apply updates."
    fi
}

main "$@"
