#!/bin/bash
# LFS Individual Package Builder
# Builds packages with aggressive optimization flags
# Supports both release tarballs and git HEAD builds

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# Source safety library first
source "${ROOT_DIR}/scripts/lib/safety.sh"

# Source configs if available
[[ -f "${ROOT_DIR}/config/lfs.conf" ]] && source "${ROOT_DIR}/config/lfs.conf"
[[ -f "${ROOT_DIR}/config/build.conf" ]] && source "${ROOT_DIR}/config/build.conf"

# Defaults
LFS="${LFS:-/mnt/lfs}"

# Run safety checks (require Linux, validate LFS)
safety_check
LFS_SOURCES="${LFS_SOURCES:-${LFS}/sources}"
LFS_BUILD="${LFS_BUILD:-${LFS}/build}"
PACKAGES_FILE="${ROOT_DIR}/packages.toml"

# Auto parallelism
NPROC=$(nproc)
export MAKEFLAGS="-j${NPROC}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] PACKAGE [PACKAGE...]

Build LFS packages with aggressive optimizations.

Options:
    -g, --git           Build from git HEAD instead of release tarball
    -s, --safe          Use safe flags (no fast-math)
    -b, --bootstrap     Use conservative bootstrap flags
    -c, --clean         Clean build directory before building
    -t, --test          Run package tests after building
    -i, --install       Install after building (default: /usr)
    -p, --prefix DIR    Installation prefix
    -h, --help          Show this help

Optimization Modes:
    Default:    -O3 -march=native -flto -ffast-math (maximum performance)
    --safe:     -O3 -march=native -flto (IEEE-compliant)
    --bootstrap: -O2 -march=native (for toolchain)

Examples:
    $(basename "$0") gcc binutils      # Build with aggressive opts
    $(basename "$0") -g linux          # Build kernel from git
    $(basename "$0") -s openssl        # Build with safe flags
EOF
    exit 0
}

# Parse args
USE_GIT=0
FLAG_MODE="perf"  # perf, safe, bootstrap
CLEAN_BUILD=0
RUN_TESTS=0
DO_INSTALL=0
PREFIX="/usr"
PACKAGES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--git) USE_GIT=1; shift ;;
        -s|--safe) FLAG_MODE="safe"; shift ;;
        -b|--bootstrap) FLAG_MODE="bootstrap"; shift ;;
        -c|--clean) CLEAN_BUILD=1; shift ;;
        -t|--test) RUN_TESTS=1; shift ;;
        -i|--install) DO_INSTALL=1; shift ;;
        -p|--prefix) PREFIX="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*) log_error "Unknown option: $1" ;;
        *) PACKAGES+=("$1"); shift ;;
    esac
done

[[ ${#PACKAGES[@]} -eq 0 ]] && { echo "No packages specified"; usage; }

# Set optimization flags based on mode
set_flags() {
    local mode="$1"

    case "${mode}" in
        perf)
            # Maximum performance - aggressive optimizations
            export CFLAGS="-O3 -march=native -mtune=native -pipe -fomit-frame-pointer"
            export CFLAGS="${CFLAGS} -flto=${NPROC} -fuse-linker-plugin"
            export CFLAGS="${CFLAGS} -ffast-math -fno-math-errno"
            export CFLAGS="${CFLAGS} -funroll-loops -fprefetch-loop-arrays"
            export CFLAGS="${CFLAGS} -ftree-vectorize -fvect-cost-model=dynamic"
            export CFLAGS="${CFLAGS} -floop-nest-optimize"
            export CXXFLAGS="${CFLAGS}"
            export LDFLAGS="-Wl,-O2 -Wl,--as-needed -Wl,--sort-common"
            export LDFLAGS="${LDFLAGS} -flto=${NPROC} -fuse-linker-plugin"
            ;;
        safe)
            # Safe high performance - no fast-math
            export CFLAGS="-O3 -march=native -mtune=native -pipe -fomit-frame-pointer"
            export CFLAGS="${CFLAGS} -flto=${NPROC} -fuse-linker-plugin"
            export CFLAGS="${CFLAGS} -funroll-loops -fprefetch-loop-arrays"
            export CFLAGS="${CFLAGS} -ftree-vectorize"
            export CXXFLAGS="${CFLAGS}"
            export LDFLAGS="-Wl,-O2 -Wl,--as-needed -flto=${NPROC}"
            ;;
        bootstrap)
            # Conservative for toolchain bootstrap
            export CFLAGS="-O2 -march=native -mtune=native -pipe"
            export CXXFLAGS="${CFLAGS}"
            export LDFLAGS="-Wl,-O2 -Wl,--as-needed"
            ;;
    esac

    # Prefer fast linker if available
    if command -v mold >/dev/null 2>&1; then
        export LDFLAGS="${LDFLAGS} -fuse-ld=mold"
    elif command -v ld.lld >/dev/null 2>&1; then
        export LDFLAGS="${LDFLAGS} -fuse-ld=lld"
    fi

    log_info "Using ${mode} optimization flags"
    log_info "CFLAGS: ${CFLAGS}"
}

# Parse package info from TOML
get_package_info() {
    local pkg="$1"
    local field="$2"
    local in_pkg=0

    while IFS= read -r line; do
        if [[ "${line}" =~ ^\[packages\.${pkg}\] ]]; then
            in_pkg=1
            continue
        fi
        if [[ ${in_pkg} -eq 1 ]] && [[ "${line}" =~ ^\[ ]]; then
            break
        fi
        if [[ ${in_pkg} -eq 1 ]] && [[ "${line}" =~ ^${field}[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
        if [[ ${in_pkg} -eq 1 ]] && [[ "${line}" =~ ^${field}[[:space:]]*=[[:space:]]*(true|false) ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "${PACKAGES_FILE}"
}

# Extract source
extract_source() {
    local pkg="$1"
    local version="$2"
    local build_dir="${LFS_BUILD}/${pkg}"

    [[ ${CLEAN_BUILD} -eq 1 ]] && rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    local tarball=$(ls "${LFS_SOURCES}"/${pkg}-*.tar.* 2>/dev/null | head -1)
    if [[ -z "${tarball}" ]]; then
        # Try alternative naming
        tarball=$(ls "${LFS_SOURCES}"/${pkg^}-*.tar.* 2>/dev/null | head -1)
    fi

    if [[ -z "${tarball}" ]]; then
        log_error "No tarball found for ${pkg}"
    fi

    log_info "Extracting $(basename "${tarball}")..."
    tar -xf "${tarball}" -C "${build_dir}" --strip-components=1

    echo "${build_dir}"
}

# Clone git repo
clone_git_source() {
    local pkg="$1"
    local git_url="$2"
    local build_dir="${LFS_BUILD}/${pkg}"

    [[ ${CLEAN_BUILD} -eq 1 ]] && rm -rf "${build_dir}"

    if [[ -d "${build_dir}/.git" ]]; then
        log_info "Updating git repo for ${pkg}..."
        cd "${build_dir}"
        git fetch --depth=1 origin
        git reset --hard origin/HEAD
        cd -
    else
        log_info "Cloning ${git_url}..."
        rm -rf "${build_dir}"
        git clone --depth=1 "${git_url}" "${build_dir}"
    fi

    echo "${build_dir}"
}

# Package-specific build functions
build_generic_autotools() {
    local src_dir="$1"
    local pkg="$2"

    cd "${src_dir}"

    # Regenerate configure if from git
    if [[ ${USE_GIT} -eq 1 ]] && [[ -f "autogen.sh" ]]; then
        ./autogen.sh
    elif [[ ${USE_GIT} -eq 1 ]] && [[ -f "configure.ac" ]]; then
        autoreconf -fi
    fi

    local configure_opts=(
        --prefix="${PREFIX}"
        --disable-static
        --enable-shared
    )

    if [[ -f "configure" ]]; then
        ./configure "${configure_opts[@]}"
    fi

    make -j"${NPROC}"

    if [[ ${RUN_TESTS} -eq 1 ]]; then
        make check || log_warn "Some tests failed"
    fi

    if [[ ${DO_INSTALL} -eq 1 ]]; then
        make install
    fi
}

build_cmake_package() {
    local src_dir="$1"
    local pkg="$2"

    cd "${src_dir}"
    mkdir -p build
    cd build

    cmake .. \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
        -DBUILD_SHARED_LIBS=ON

    ninja -j"${NPROC}"

    if [[ ${RUN_TESTS} -eq 1 ]]; then
        ctest --output-on-failure || log_warn "Some tests failed"
    fi

    if [[ ${DO_INSTALL} -eq 1 ]]; then
        ninja install
    fi
}

build_meson_package() {
    local src_dir="$1"
    local pkg="$2"

    cd "${src_dir}"

    meson setup build \
        --prefix="${PREFIX}" \
        --buildtype=release \
        -Ddefault_library=shared

    meson compile -C build -j"${NPROC}"

    if [[ ${RUN_TESTS} -eq 1 ]]; then
        meson test -C build || log_warn "Some tests failed"
    fi

    if [[ ${DO_INSTALL} -eq 1 ]]; then
        meson install -C build
    fi
}

# Detect build system and build
build_package() {
    local pkg="$1"
    local src_dir="$2"

    cd "${src_dir}"

    # Detect build system
    if [[ -f "meson.build" ]]; then
        log_info "Detected Meson build system"
        build_meson_package "${src_dir}" "${pkg}"
    elif [[ -f "CMakeLists.txt" ]]; then
        log_info "Detected CMake build system"
        build_cmake_package "${src_dir}" "${pkg}"
    elif [[ -f "configure" ]] || [[ -f "configure.ac" ]] || [[ -f "autogen.sh" ]]; then
        log_info "Detected Autotools build system"
        build_generic_autotools "${src_dir}" "${pkg}"
    elif [[ -f "Makefile" ]]; then
        log_info "Detected plain Makefile"
        make -j"${NPROC}"
        [[ ${DO_INSTALL} -eq 1 ]] && make PREFIX="${PREFIX}" install
    else
        log_error "Unknown build system for ${pkg}"
    fi
}

# Main build function for a single package
do_build() {
    local pkg="$1"

    echo ""
    echo "========================================"
    echo -e "${BLUE}Building: ${pkg}${NC}"
    echo "========================================"

    local version=$(get_package_info "${pkg}" "version")
    local git_url=$(get_package_info "${pkg}" "git_url")
    local src_dir=""

    log_info "Package: ${pkg}"
    log_info "Version: ${version:-unknown}"

    # Get source
    if [[ ${USE_GIT} -eq 1 ]] && [[ -n "${git_url}" ]]; then
        src_dir=$(clone_git_source "${pkg}" "${git_url}")
    else
        src_dir=$(extract_source "${pkg}" "${version}")
    fi

    # Apply package-specific flag overrides
    case "${pkg}" in
        glibc)
            log_info "Using safe flags for glibc"
            set_flags "safe"
            export CFLAGS="-O2 -march=native -mtune=native -pipe"
            export CXXFLAGS="${CFLAGS}"
            ;;
        gcc|binutils)
            if [[ "${FLAG_MODE}" == "perf" ]]; then
                log_info "Using bootstrap flags for toolchain"
                set_flags "bootstrap"
            fi
            ;;
        openssl|python)
            if [[ "${FLAG_MODE}" == "perf" ]]; then
                log_info "Using safe flags for ${pkg}"
                set_flags "safe"
            fi
            ;;
    esac

    # Build
    local start_time=$(date +%s)
    build_package "${pkg}" "${src_dir}"
    local end_time=$(date +%s)

    echo ""
    log_ok "${pkg} built successfully in $((end_time - start_time)) seconds"

    # Cleanup
    if [[ ${CLEAN_BUILD} -eq 1 ]]; then
        rm -rf "${src_dir}"
    fi
}

# Main
main() {
    echo -e "${BLUE}LFS Package Builder${NC}"
    echo "========================================"
    echo "Packages:    ${PACKAGES[*]}"
    echo "Mode:        ${FLAG_MODE}"
    echo "Git build:   ${USE_GIT}"
    echo "Parallel:    ${NPROC} jobs"
    echo ""

    set_flags "${FLAG_MODE}"

    local failed=()

    for pkg in "${PACKAGES[@]}"; do
        if ! do_build "${pkg}"; then
            failed+=("${pkg}")
        fi
    done

    echo ""
    echo "========================================"

    if [[ ${#failed[@]} -gt 0 ]]; then
        echo -e "${RED}Failed packages: ${failed[*]}${NC}"
        exit 1
    else
        echo -e "${GREEN}All packages built successfully${NC}"
    fi
}

main "$@"
