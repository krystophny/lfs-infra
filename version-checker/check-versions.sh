#!/bin/bash
# LFS Package Version Checker
# Uses direct source checks with fallback to Repology
# Can compare against Fedora Rawhide to ensure bleeding-edge versions
#
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
#
# fedora_name field:
#   Maps LFS package name to Fedora package name (if different)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

# Find packages directory dynamically
if [ -n "${PK_PACKAGES_DIR:-}" ]; then
    PACKAGES_DIR="$PK_PACKAGES_DIR"
else
    PACKAGES_DIR=""
    for d in "${ROOT_DIR}/../pk/packages" "/etc/pk/packages" "/usr/share/pk/packages"; do
        [ -d "$d" ] && PACKAGES_DIR="$(cd "$d" && pwd)" && break
    done
fi
[ -n "$PACKAGES_DIR" ] || { echo "Cannot find packages directory"; exit 1; }
CACHE_DIR="${TMPDIR:-/tmp}/lfs-version-cache"

# Helper to cat all package definition files
cat_packages() {
    cat "${PACKAGES_DIR}"/*.toml
}

# Find which file contains a package
find_pkg_file() {
    local pkg="$1"
    grep -l "^\[packages\.${pkg}\]" "${PACKAGES_DIR}"/*.toml 2>/dev/null | head -1
}
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
RAWHIDE_CHECK=0
RAWHIDE_ONLY=0
PARALLEL_JOBS=8  # Default parallel jobs

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [PACKAGE...]

Check LFS package versions against upstream releases.
Uses direct source checks with Repology fallback.

Options:
    -a, --all       Show all packages (default: only outdated)
    -v, --verbose   Verbose output
    -u, --update    Update packages.toml with new versions
    -r, --rawhide   Compare against Fedora Rawhide (must be >= Rawhide)
    -R, --rawhide-only  Only check against Rawhide (skip upstream)
    -j, --jobs N    Parallel jobs (default: 8)
    -c, --clear     Clear version cache
    -h, --help      Show this help

Examples:
    $(basename "$0")              # Check all, show outdated only
    $(basename "$0") -a           # Check all, show all results
    $(basename "$0") -j 4         # Check with 4 parallel jobs
    $(basename "$0") -r           # Check against Rawhide baseline
    $(basename "$0") -R           # Only compare with Rawhide
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
        -r|--rawhide) RAWHIDE_CHECK=1; shift ;;
        -R|--rawhide-only) RAWHIDE_CHECK=1; RAWHIDE_ONLY=1; shift ;;
        -j|--jobs) PARALLEL_JOBS="$2"; shift 2 ;;
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

# Fetch with retries, timeout, and connection reuse
fetch_url() {
    local url="$1"
    local retries=2
    local timeout=10

    # Use connection keep-alive and compression
    for ((i=1; i<=retries; i++)); do
        local result
        if result=$(curl -fsSL --connect-timeout "${timeout}" --max-time 30 \
            -H "Connection: keep-alive" --compressed \
            -A "lfs-version-checker/2.0" "${url}" 2>/dev/null); then
            echo "${result}"
            return 0
        fi
        log "Retry ${i}/${retries} for ${url}"
        sleep 0.5
    done
    return 1
}

# Rate limit tracking per domain
declare -A DOMAIN_LAST_REQUEST
RATE_LIMIT_MS=200  # 200ms between requests to same domain

rate_limit_domain() {
    local url="$1"
    local domain
    domain=$(echo "$url" | sed -E 's|https?://([^/]+).*|\1|')

    local now last_req
    now=$(date +%s%3N 2>/dev/null || date +%s)000
    last_req="${DOMAIN_LAST_REQUEST[$domain]:-0}"

    local diff=$((now - last_req))
    if [[ $diff -lt $RATE_LIMIT_MS ]]; then
        sleep "0.$((RATE_LIMIT_MS - diff))"
    fi
    DOMAIN_LAST_REQUEST[$domain]=$now
}

# Fetch with rate limiting
fetch_url_rated() {
    local url="$1"
    rate_limit_domain "$url"
    fetch_url "$url"
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

# Extract version after package name (replaces grep -oP with \K)
# Usage: extract_version "prefix-"
# Input: lines containing "prefix-1.2.3.tar.gz"
# Output: 1.2.3
extract_version() {
    local prefix="$1"
    sed -n "s/.*${prefix}\([0-9][0-9.]*[0-9]\).*/\1/p" | grep -E '^[0-9]+(\.[0-9]+)*$'
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
    echo "${html}" | extract_version "${project}-" | filter_stable | latest_version
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
    echo "${html}" | extract_version "gcc-" | latest_version
}

check_github() {
    local repo="$1"
    log "Checking GitHub: ${repo}"

    local json result
    # Try API first
    json=$(fetch_url "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null) || json=""

    if [[ -n "${json}" ]] && ! echo "${json}" | grep -q "rate limit"; then
        result=$(echo "${json}" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^[vV]//' | filter_stable)
        [[ -n "${result}" ]] && { echo "${result}"; return 0; }
    fi

    # Fallback: scrape tags page (works without API key)
    log "GitHub API unavailable, scraping tags page for ${repo}"
    local html
    html=$(fetch_url "https://github.com/${repo}/tags") || return 1

    # Extract version from tag links (handles v1.2.3, 1.2.3, release-1.2.3, curl-8_18_0, etc.)
    local name
    name=$(basename "${repo}")
    echo "${html}" | grep -oE "/${repo}/releases/tag/[^\"']+" | \
        sed "s|.*tag/||" | sed 's/^[vV]//' | \
        sed "s/^${name}-//" | sed 's/^release-//' | \
        sed 's/_/./g' | \
        filter_stable | latest_version
}

check_url_regex() {
    local url="$1"
    local regex="$2"
    log "Checking URL: ${url} with pattern: ${regex}"

    [[ "${regex}" == "skip" || "${regex}" == "stable" ]] && return 1

    local html
    html=$(fetch_url "${url}") || return 1

    # Convert TOML escaped backslashes (\\) to single backslashes (\) for grep
    regex="${regex//\\\\/\\}"

    # Match the pattern
    local matches
    matches=$(echo "${html}" | grep -oE "${regex}" | head -50)

    [[ -z "${matches}" ]] && return 1

    # Extract version from each match
    # Handles various formats:
    # - go1.23.4.linux -> 1.23.4
    # - FILE5_46 -> 5.46
    # - libnl3_10_0 -> 3.10.0
    # - llvmorg-18.1.8 -> 18.1.8
    # - OpenSSH 9.9p1 -> 9.9p1
    # - V3-6-0 -> 3.6.0
    # - cacert-2025-12-02.pem -> 2025-12-02 (dates preserved)
    echo "${matches}" | while read -r match; do
        # Remove leading non-digits (prefixes like "go", "FILE", "llvmorg-", etc.)
        match="${match#"${match%%[0-9]*}"}"
        # Remove common file extensions
        match="${match%.pem}"
        match="${match%.tar*}"
        match="${match%.linux*}"
        match="${match%.src*}"
        match="${match%.gz}"
        match="${match%.xz}"
        match="${match%.bz2}"

        # Check if it's a date format (YYYY-MM-DD) - preserve hyphens
        if [[ "$match" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            echo "$match"
        else
            # Replace underscores with dots (version separators like FILE5_46 -> 5.46)
            match="${match//_/.}"
            # For non-date hyphens between single/double digits, convert to dots (e.g., V3-6-0 -> 3.6.0)
            # But preserve hyphens in versions like 16-20260118 (GCC snapshots)
            if [[ "$match" =~ ^[0-9]{1,2}-[0-9]{1,2}-[0-9]{1,2}$ ]]; then
                match="${match//-/.}"
            fi
            match="${match%.}"  # Remove trailing dot if any
            # Extract version-like pattern (numbers with dots, optionally ending with pN for patches)
            # The grep handles trailing letter removal by only matching valid version patterns
            echo "$match" | grep -oE '^[0-9]+(\.[0-9]+)*([p][0-9]+)?(-[0-9]+)?' | head -1
        fi
    done | filter_stable | latest_version
}

check_xorg() {
    local path="$1"
    log "Checking X.org: ${path}"

    local url="https://xorg.freedesktop.org/releases/individual/${path}/"
    local html
    html=$(fetch_url "${url}") || return 1

    local name
    name=$(basename "${path}")
    echo "${html}" | extract_version "${name}-" | filter_stable | latest_version
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
    latest_dir=$(echo "${html}" | sed -n 's/.*href="\([0-9]\+\.[0-9]\+\)".*/\1/p' | latest_version)

    if [[ -n "${latest_dir}" ]]; then
        html=$(fetch_url "${url}${latest_dir}/") || return 1
        local name
        name=$(basename "${path}")
        echo "${html}" | extract_version "${name}-" | filter_stable | latest_version
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

    echo "${html}" | extract_version "${project}-" | filter_stable | latest_version
}

check_sqlite() {
    log "Checking SQLite"

    local html
    html=$(fetch_url "https://www.sqlite.org/download.html") || return 1

    # Extract numeric version (e.g., 3510200) and convert to dotted format (3.51.2)
    local num
    num=$(echo "${html}" | grep -oE 'sqlite-autoconf-([0-9]+)' | head -1 | grep -oE '[0-9]+$')
    [[ -z "${num}" ]] && return 1

    # Convert XYYZZWW to X.YY.ZZ (drop WW subpatch)
    local major minor patch
    major=$((num / 1000000))
    minor=$(((num / 10000) % 100))
    patch=$(((num / 100) % 100))
    echo "${major}.${minor}.${patch}"
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

    echo "${html}" | sed -n 's/.*Python \([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' | filter_stable | latest_version
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

    echo "${html}" | extract_version "zlib-" | filter_stable | latest_version
}

check_sourceware() {
    local project="$1"
    log "Checking sourceware: ${project}"

    local url="https://sourceware.org/pub/${project}/"
    local html
    html=$(fetch_url "${url}") || return 1

    echo "${html}" | extract_version "${project}-" | filter_stable | latest_version
}

check_alsa() {
    local component="$1"
    log "Checking ALSA: ${component}"

    local url="https://www.alsa-project.org/files/pub/${component}/"
    local html
    html=$(fetch_url "${url}") || return 1

    echo "${html}" | extract_version "alsa-${component}-" | filter_stable | latest_version
}

check_kernelorg() {
    local path="$1"
    local name="$2"
    log "Checking kernel.org: ${path}/${name}"

    local url="https://www.kernel.org/pub/${path}/"
    local html
    html=$(fetch_url "${url}") || return 1

    echo "${html}" | extract_version "${name}-" | filter_stable | latest_version
}

check_sourceforge() {
    local project="$1"
    log "Checking SourceForge: ${project}"

    local url="https://sourceforge.net/projects/${project}/rss?path=/"
    local xml
    xml=$(fetch_url "${url}") || return 1

    echo "${xml}" | extract_version "${project}-" | filter_stable | latest_version
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
# Fedora Rawhide version check
# ============================================================

# Package name mappings: LFS name -> Fedora name
declare -A FEDORA_NAME_MAP=(
    ["linux"]="kernel"
    ["linux-headers"]="kernel-headers"
    ["linux-firmware"]="linux-firmware"
    ["man-pages"]="man-pages"
    ["iana-etc"]="iana-etc"
    ["tcl"]="tcl"
    ["expect"]="expect"
    ["dejagnu"]="dejagnu"
    ["pkgconf"]="pkgconf"
    ["binutils"]="binutils"
    ["gmp"]="gmp"
    ["mpfr"]="mpfr"
    ["mpc"]="libmpc"
    ["isl"]="isl"
    ["zstd"]="zstd"
    ["gcc"]="gcc"
    ["ncurses"]="ncurses"
    ["sed"]="sed"
    ["psmisc"]="psmisc"
    ["gettext"]="gettext"
    ["bison"]="bison"
    ["grep"]="grep"
    ["bash"]="bash"
    ["libtool"]="libtool"
    ["gdbm"]="gdbm"
    ["gperf"]="gperf"
    ["expat"]="expat"
    ["inetutils"]="inetutils"
    ["less"]="less"
    ["perl"]="perl"
    ["xml-parser"]="perl-XML-Parser"
    ["intltool"]="intltool"
    ["autoconf"]="autoconf"
    ["automake"]="automake"
    ["openssl"]="openssl"
    ["kmod"]="kmod"
    ["libelf"]="elfutils-libelf"
    ["libffi"]="libffi"
    ["python"]="python3"
    ["flit-core"]="python-flit-core"
    ["wheel"]="python-wheel"
    ["setuptools"]="python-setuptools"
    ["ninja"]="ninja-build"
    ["meson"]="meson"
    ["coreutils"]="coreutils"
    ["diffutils"]="diffutils"
    ["gawk"]="gawk"
    ["findutils"]="findutils"
    ["glibc"]="glibc"
    ["zlib"]="zlib"
    ["bzip2"]="bzip2"
    ["xz"]="xz"
    ["lz4"]="lz4"
    ["file"]="file"
    ["readline"]="readline"
    ["m4"]="m4"
    ["bc"]="bc"
    ["flex"]="flex"
    ["texinfo"]="texinfo"
    ["grub"]="grub2"
    ["patch"]="patch"
    ["tar"]="tar"
    ["gzip"]="gzip"
    ["make"]="make"
    ["vim"]="vim"
    ["e2fsprogs"]="e2fsprogs"
    ["procps-ng"]="procps-ng"
    ["util-linux"]="util-linux"
    ["sysklogd"]="rsyslog"
    ["sysvinit"]="sysvinit"
    ["eudev"]="systemd"
    ["shadow"]="shadow-utils"
    ["acl"]="acl"
    ["attr"]="attr"
    ["libcap"]="libcap"
    ["libpipeline"]="libpipeline"
    ["man-db"]="man-db"
    ["cmake"]="cmake"
    ["curl"]="curl"
    ["git"]="git"
    ["wget"]="wget"
    ["which"]="which"
    ["sudo"]="sudo"
    ["openssh"]="openssh"
    ["dbus"]="dbus"
    ["efivar"]="efivar"
    ["efibootmgr"]="efibootmgr"
    ["popt"]="popt"
    ["libtasn1"]="libtasn1"
    ["p11-kit"]="p11-kit"
    ["ca-certificates"]="ca-certificates"
    ["gnutls"]="gnutls"
    ["nettle"]="nettle"
    ["libunistring"]="libunistring"
    ["libidn2"]="libidn2"
    ["libpsl"]="libpsl"
    ["nghttp2"]="nghttp2"
    ["brotli"]="brotli"
    ["sqlite"]="sqlite"
    ["nspr"]="nspr"
    ["nss"]="nss"
    ["pciutils"]="pciutils"
    ["usbutils"]="usbutils"
    ["hwdata"]="hwdata"
    ["libusb"]="libusb1"
    ["pcre2"]="pcre2"
    ["libxml2"]="libxml2"
    ["libxslt"]="libxslt"
    ["iproute2"]="iproute"
    ["kbd"]="kbd"
    ["libarchive"]="libarchive"
    ["llvm"]="llvm"
    ["clang"]="clang"
    ["rust"]="rust"
    ["go"]="golang"
    ["lua"]="lua"
    ["ruby"]="ruby"
    ["mesa"]="mesa"
    ["wayland"]="wayland"
    ["wayland-protocols"]="wayland-protocols"
    ["libdrm"]="libdrm"
    ["libinput"]="libinput"
    ["libevdev"]="libevdev"
    ["mtdev"]="mtdev"
    ["pixman"]="pixman"
    ["freetype"]="freetype"
    ["fontconfig"]="fontconfig"
    ["harfbuzz"]="harfbuzz"
    ["cairo"]="cairo"
    ["pango"]="pango"
    ["gdk-pixbuf"]="gdk-pixbuf2"
    ["gtk3"]="gtk3"
    ["gtk4"]="gtk4"
    ["glib"]="glib2"
    ["gobject-introspection"]="gobject-introspection"
    ["at-spi2-core"]="at-spi2-core"
    ["json-glib"]="json-glib"
    ["libnotify"]="libnotify"
    ["vte"]="vte291"
    ["ffmpeg"]="ffmpeg-free"
    ["gstreamer"]="gstreamer1"
    ["pipewire"]="pipewire"
    ["pulseaudio"]="pulseaudio"
    ["alsa-lib"]="alsa-lib"
    ["alsa-utils"]="alsa-utils"
    ["NetworkManager"]="NetworkManager"
    ["wpa_supplicant"]="wpa_supplicant"
    ["bluez"]="bluez"
    ["cups"]="cups"
    ["avahi"]="avahi"
    ["samba"]="samba"
)

check_fedora_rawhide() {
    local pkg="$1"
    local fedora_name="${2:-}"

    # Use mapping if no explicit name given
    if [[ -z "${fedora_name}" ]]; then
        fedora_name="${FEDORA_NAME_MAP[${pkg}]:-${pkg}}"
    fi

    log "Checking Fedora Rawhide: ${fedora_name}"

    local json
    json=$(fetch_url "https://mdapi.fedoraproject.org/rawhide/pkg/${fedora_name}") || return 1

    # Extract version, handling epoch:version-release format
    local version
    version=$(echo "${json}" | jq -r '.version // empty' 2>/dev/null)

    if [[ -z "${version}" ]]; then
        # Try srcpkg endpoint
        json=$(fetch_url "https://mdapi.fedoraproject.org/rawhide/srcpkg/${fedora_name}") || return 1
        version=$(echo "${json}" | jq -r '.version // empty' 2>/dev/null)
    fi

    [[ -n "${version}" ]] && echo "${version}"
}

# Get fedora_name from packages.toml if specified
get_fedora_name() {
    local pkg="$1"
    cat_packages | awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[/ && found { exit }
        found && /^fedora_name *= *"/ { gsub(/.*= *"|".*/, ""); print; exit }
    '
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
        sqlite:*)
            result=$(check_sqlite) ;;
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
    done < <(cat_packages)

    if [[ -n "${current_pkg}" && -n "${current_version}" ]]; then
        echo "${current_pkg}=${current_version}|${version_check:-repology:${current_pkg}}"
    fi
}

# Version comparison (normalizes hyphens to dots for comparison)
version_ge() {
    local v1="${1//-/.}"
    local v2="${2//-/.}"
    [[ "$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -1)" == "$v2" ]]
}

# Get URL template for a package
get_pkg_url() {
    local pkg="$1"
    cat_packages | awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[/ && found { exit }
        found && /^url *= *"/ { gsub(/.*= *"|".*/, ""); print; exit }
    '
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

    local pkg_file
    pkg_file=$(find_pkg_file "${pkg}")
    if [[ -z "${pkg_file}" ]]; then
        warn "Cannot find file for package ${pkg}"
        return 1
    fi
    # Use | as sed delimiter to avoid issues with special characters in versions
    sed -i "/^\[packages\.${pkg}\]/,/^\[/{s|^version = \"[^\"]*\"|version = \"${new_version}\"|}" "${pkg_file}"
    log "Updated ${pkg} to ${new_version} in ${pkg_file}"
}

# Check a single package and write result to temp file
check_package_worker() {
    local entry="$1"
    local result_file="$2"

    local pkg="${entry%%=*}"
    local info="${entry#*=}"
    local version="${info%%|*}"
    local version_check="${info#*|}"

    # Skip -pass1, -pass2 variants
    [[ "${pkg}" =~ -pass[12]$ ]] && return

    local upstream=""
    upstream=$(check_version "${pkg}" "${version_check}" 2>/dev/null) || true

    # Write result: pkg|version|upstream
    echo "${pkg}|${version}|${upstream}" >> "${result_file}"
}

# Parallel version checking with semaphore
parallel_check_versions() {
    local -n pkgs=$1
    local result_file="$2"
    local max_jobs="${PARALLEL_JOBS}"

    local running=0
    local pids=()

    for entry in "${pkgs[@]}"; do
        # Start worker in background
        check_package_worker "${entry}" "${result_file}" &
        pids+=($!)
        running=$((running + 1))

        # Wait if we've hit max jobs
        if [[ $running -ge $max_jobs ]]; then
            wait "${pids[0]}"
            pids=("${pids[@]:1}")
            running=$((running - 1))
        fi
    done

    # Wait for remaining jobs
    wait
}

# Main
main() {
    echo -e "${BLUE}LFS Package Version Checker${NC}"
    if [[ ${RAWHIDE_CHECK} -eq 1 ]]; then
        echo -e "Comparing against Fedora Rawhide baseline"
    else
        echo -e "Direct source checks with Repology fallback (${PARALLEL_JOBS} parallel jobs)"
    fi
    echo "========================================"
    echo ""

    local outdated=0 checked=0 errors=0 behind_rawhide=0

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

    # Print header based on mode
    if [[ ${RAWHIDE_CHECK} -eq 1 ]]; then
        if [[ ${RAWHIDE_ONLY} -eq 1 ]]; then
            printf "%-25s %-15s %-15s %s\n" "PACKAGE" "LOCAL" "RAWHIDE" "STATUS"
            printf "%-25s %-15s %-15s %s\n" "-------" "-----" "-------" "------"
        else
            printf "%-25s %-12s %-12s %-12s %s\n" "PACKAGE" "LOCAL" "UPSTREAM" "RAWHIDE" "STATUS"
            printf "%-25s %-12s %-12s %-12s %s\n" "-------" "-----" "--------" "-------" "------"
        fi
    else
        printf "%-25s %-15s %-15s %s\n" "PACKAGE" "LOCAL" "UPSTREAM" "STATUS"
        printf "%-25s %-15s %-15s %s\n" "-------" "-----" "--------" "------"
    fi

    # Use parallel checking for standard upstream-only mode
    if [[ ${RAWHIDE_CHECK} -eq 0 ]]; then
        local result_file
        result_file=$(mktemp)
        trap "rm -f '${result_file}'" EXIT

        # Run parallel version checks
        echo -ne "Checking versions" >&2
        parallel_check_versions packages "${result_file}"
        echo -e "\r\033[K" >&2  # Clear the progress line

        # Process results from temp file
        while IFS='|' read -r pkg version upstream; do
            [[ -z "${pkg}" ]] && continue
            checked=$((checked + 1))

            local status=""
            if [[ -z "${upstream}" ]]; then
                [[ ${CHECK_ALL} -eq 1 ]] && printf "%-25s %-15s %-15s %b\n" "${pkg}" "${version}" "?" "${YELLOW}unknown${NC}"
                errors=$((errors + 1))
                continue
            fi

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
        done < "${result_file}"
    else
        # Sequential mode for Rawhide checks
        for entry in "${packages[@]}"; do
            local pkg="${entry%%=*}"
            local info="${entry#*=}"
            local version="${info%%|*}"
            local version_check="${info#*|}"

            # Skip -pass1, -pass2 variants (they use same source as base package)
            [[ "${pkg}" =~ -pass[12]$ ]] && continue

            checked=$((checked + 1))

            local upstream="" rawhide="" fedora_name=""

            # Get Rawhide version if requested
            fedora_name=$(get_fedora_name "${pkg}")
            rawhide=$(check_fedora_rawhide "${pkg}" "${fedora_name}" 2>/dev/null) || true

            # Get upstream version (unless rawhide-only mode)
            if [[ ${RAWHIDE_ONLY} -eq 0 ]]; then
                upstream=$(check_version "${pkg}" "${version_check}" 2>/dev/null) || true
            fi

            # Determine status
            local status="" show_line=0

            if [[ ${RAWHIDE_ONLY} -eq 1 ]]; then
                # Rawhide-only mode
                if [[ -z "${rawhide}" ]]; then
                    [[ ${CHECK_ALL} -eq 1 ]] && printf "%-25s %-15s %-15s %b\n" "${pkg}" "${version}" "?" "${YELLOW}not-in-rawhide${NC}"
                    errors=$((errors + 1))
                    continue
                fi

                if version_ge "${version}" "${rawhide}"; then
                    status="${GREEN}>=rawhide${NC}"
                    [[ ${CHECK_ALL} -eq 1 ]] && show_line=1
                else
                    status="${RED}<rawhide${NC}"
                    behind_rawhide=$((behind_rawhide + 1))
                    show_line=1
                fi

                [[ ${show_line} -eq 1 ]] && printf "%-25s %-15s %-15s %b\n" "${pkg}" "${version}" "${rawhide}" "${status}"
            else
                # Both upstream and Rawhide comparison
                if [[ -z "${upstream}" && -z "${rawhide}" ]]; then
                    [[ ${CHECK_ALL} -eq 1 ]] && printf "%-25s %-12s %-12s %-12s %b\n" "${pkg}" "${version}" "?" "?" "${YELLOW}unknown${NC}"
                    errors=$((errors + 1))
                    continue
                fi

                local up_status="" rh_status=""

                if [[ -n "${upstream}" ]]; then
                    if version_ge "${version}" "${upstream}"; then
                        up_status="ok"
                    else
                        up_status="old"
                        outdated=$((outdated + 1))
                    fi
                fi

                if [[ -n "${rawhide}" ]]; then
                    if version_ge "${version}" "${rawhide}"; then
                        rh_status="ok"
                    else
                        rh_status="old"
                        behind_rawhide=$((behind_rawhide + 1))
                    fi
                fi

                if [[ "${up_status}" == "old" || "${rh_status}" == "old" ]]; then
                    if [[ "${rh_status}" == "old" ]]; then
                        status="${RED}<rawhide${NC}"
                    else
                        status="${YELLOW}outdated${NC}"
                    fi
                    show_line=1
                else
                    status="${GREEN}up-to-date${NC}"
                    [[ ${CHECK_ALL} -eq 1 ]] && show_line=1
                fi

                [[ ${show_line} -eq 1 ]] && printf "%-25s %-12s %-12s %-12s %b\n" "${pkg}" "${version}" "${upstream:-?}" "${rawhide:-?}" "${status}"
            fi
        done
    fi

    echo ""
    echo "========================================"
    if [[ ${RAWHIDE_CHECK} -eq 1 ]]; then
        echo "Checked: ${checked} | Outdated: ${outdated} | Behind Rawhide: ${behind_rawhide} | Errors: ${errors}"
        if [[ ${behind_rawhide} -gt 0 ]]; then
            echo -e "${RED}WARNING: ${behind_rawhide} packages are older than Fedora Rawhide!${NC}"
        fi
    else
        echo "Checked: ${checked} | Outdated: ${outdated} | Errors: ${errors}"
    fi

    [[ ${UPDATE_TOML} -eq 1 ]] && [[ ${outdated} -gt 0 ]] && echo -e "${YELLOW}packages.toml updated${NC}"

    # Return error if behind rawhide (when checking rawhide)
    if [[ ${RAWHIDE_CHECK} -eq 1 ]]; then
        return ${behind_rawhide}
    fi
    return ${outdated}
}

main "$@"
