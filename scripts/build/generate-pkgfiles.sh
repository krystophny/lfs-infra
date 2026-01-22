#!/bin/bash
# Generate Pkgfiles from packages.toml
# Creates pkgutils-compatible build recipes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# Source safety library - require Linux
source "${ROOT_DIR}/scripts/lib/safety.sh"
require_linux

PACKAGES_FILE="${ROOT_DIR}/packages.toml"
PACKAGES_DIR="${ROOT_DIR}/packages"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }

# Parse package from TOML
parse_package() {
    local pkg="$1"
    local in_pkg=0

    declare -gA PKG_INFO

    while IFS= read -r line; do
        if [[ "${line}" =~ ^\[packages\.${pkg}\] ]]; then
            in_pkg=1
            continue
        fi
        if [[ ${in_pkg} -eq 1 ]] && [[ "${line}" =~ ^\[ ]]; then
            break
        fi
        if [[ ${in_pkg} -eq 1 ]]; then
            if [[ "${line}" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
                PKG_INFO["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
            fi
        fi
    done < "${PACKAGES_FILE}"
}

# Expand URL with version
expand_url() {
    local url="$1"
    local version="$2"
    echo "${url//\$\{version\}/${version}}"
}

# Generate Pkgfile for a package
generate_pkgfile() {
    local pkg="$1"
    local pkg_dir="${PACKAGES_DIR}/${pkg}"

    declare -gA PKG_INFO
    PKG_INFO=()
    parse_package "${pkg}"

    local version="${PKG_INFO[version]:-}"
    local description="${PKG_INFO[description]:-}"
    local url="${PKG_INFO[url]:-}"
    local git_url="${PKG_INFO[git_url]:-}"
    local depends="${PKG_INFO[depends]:-}"

    if [[ -z "${version}" ]]; then
        return 1
    fi

    mkdir -p "${pkg_dir}"

    local source_url=$(expand_url "${url}" "${version}")

    # Determine build type based on package
    local build_system="autotools"
    case "${pkg}" in
        ninja|zstd|bc) build_system="cmake" ;;
        meson|python) build_system="python" ;;
        linux|linux-headers) build_system="kernel" ;;
    esac

    cat > "${pkg_dir}/Pkgfile" << EOF
# Description: ${description}
# URL: ${git_url:-${url}}
# Maintainer: LFS Infrastructure
# Depends on: ${depends}

name=${pkg}
version=${version}
release=1
source=(${source_url})

build() {
    cd \${name}-\${version}

    # Auto-detect CPU cores for parallelism
    NPROC=\$(nproc)

    # Aggressive optimization flags
    export CFLAGS="\${CFLAGS} -O3 -march=native -mtune=native -flto=\${NPROC}"
    export CXXFLAGS="\${CFLAGS}"
    export LDFLAGS="\${LDFLAGS} -flto=\${NPROC}"
    export MAKEFLAGS="-j\${NPROC}"

EOF

    case "${build_system}" in
        autotools)
            cat >> "${pkg_dir}/Pkgfile" << 'EOF'
    ./configure \
        --prefix=/usr \
        --disable-static \
        --enable-shared

    make
    make DESTDIR=$PKG install
EOF
            ;;
        cmake)
            cat >> "${pkg_dir}/Pkgfile" << 'EOF'
    mkdir build && cd build

    cmake .. \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DBUILD_SHARED_LIBS=ON

    ninja
    DESTDIR=$PKG ninja install
EOF
            ;;
        kernel)
            cat >> "${pkg_dir}/Pkgfile" << 'EOF'
    # Kernel uses its own optimization system
    unset CFLAGS CXXFLAGS LDFLAGS

    make mrproper

    # Use localmodconfig for minimal kernel or defconfig
    if [ -f /proc/config.gz ]; then
        zcat /proc/config.gz > .config
        make LSMOD=/dev/null localmodconfig
    else
        make defconfig
    fi

    # Enable native CPU optimizations
    scripts/config --enable CONFIG_MNATIVE_INTEL
    scripts/config --enable CONFIG_MNATIVE_AMD

    make -j${NPROC}
    make INSTALL_MOD_PATH=$PKG modules_install

    install -Dm644 arch/x86/boot/bzImage $PKG/boot/vmlinuz-${version}
    install -Dm644 System.map $PKG/boot/System.map-${version}
    install -Dm644 .config $PKG/boot/config-${version}
EOF
            ;;
        python)
            cat >> "${pkg_dir}/Pkgfile" << 'EOF'
    ./configure \
        --prefix=/usr \
        --enable-shared \
        --enable-optimizations \
        --with-lto \
        --enable-loadable-sqlite-extensions \
        --with-system-expat \
        --with-system-ffi

    make
    make DESTDIR=$PKG install
EOF
            ;;
    esac

    echo "}" >> "${pkg_dir}/Pkgfile"

    log_ok "Generated Pkgfile for ${pkg}"
}

# List all packages from TOML
list_packages() {
    grep -oP '^\[packages\.\K[a-zA-Z0-9_-]+(?=\])' "${PACKAGES_FILE}"
}

# Main
main() {
    local packages=("$@")

    echo -e "${BLUE}Pkgfile Generator${NC}"
    echo "========================================"

    if [[ ${#packages[@]} -eq 0 ]]; then
        # Generate for all packages
        mapfile -t packages < <(list_packages)
    fi

    log_info "Generating Pkgfiles for ${#packages[@]} packages"

    local count=0
    for pkg in "${packages[@]}"; do
        if generate_pkgfile "${pkg}"; then
            count=$((count + 1))
        fi
    done

    echo ""
    echo "========================================"
    echo -e "${GREEN}Generated ${count} Pkgfiles${NC}"
}

main "$@"
