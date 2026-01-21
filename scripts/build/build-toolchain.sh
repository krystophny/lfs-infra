#!/bin/bash
# LFS Toolchain Build Script
# Builds the cross-compilation toolchain (Stage 1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

source "${ROOT_DIR}/config/lfs.conf"
source "${ROOT_DIR}/config/build.conf"

# Aggressive parallelism
NPROC=$(nproc)
export MAKEFLAGS="-j${NPROC}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

log_step() {
    echo ""
    echo "========================================"
    echo -e "${BLUE}STEP: $*${NC}"
    echo "========================================"
}

# Extract source tarball
extract_source() {
    local pkg="$1"
    local build_dir="${LFS_BUILD}/${pkg}"

    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    local tarball=$(ls "${LFS_SOURCES}"/${pkg}-*.tar.* 2>/dev/null | head -1)

    if [[ -z "${tarball}" ]]; then
        log_error "Tarball not found for ${pkg}"
    fi

    log_info "Extracting $(basename "${tarball}")..."
    tar -xf "${tarball}" -C "${build_dir}" --strip-components=1

    echo "${build_dir}"
}

# Build binutils (Pass 1)
build_binutils_pass1() {
    log_step "Building Binutils Pass 1"

    local src_dir=$(extract_source "binutils")
    local build_dir="${src_dir}/build"

    mkdir -p "${build_dir}"
    cd "${build_dir}"

    ../configure \
        --prefix="${LFS_TOOLS}" \
        --with-sysroot="${LFS}" \
        --target="${LFS_TGT}" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu

    make -j"${NPROC}"
    make install

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"

    log_ok "Binutils Pass 1 complete"
}

# Build GCC (Pass 1)
build_gcc_pass1() {
    log_step "Building GCC Pass 1"

    local src_dir=$(extract_source "gcc")

    # Extract and link GCC prerequisites
    for dep in gmp mpfr mpc; do
        local dep_tarball=$(ls "${LFS_SOURCES}"/${dep}-*.tar.* 2>/dev/null | head -1)
        if [[ -n "${dep_tarball}" ]]; then
            log_info "Extracting ${dep}..."
            tar -xf "${dep_tarball}" -C "${src_dir}"
            mv "${src_dir}/${dep}"-* "${src_dir}/${dep}"
        fi
    done

    # Apply x86_64 specific fix
    if [[ "$(uname -m)" == "x86_64" ]]; then
        sed -e '/m64=/s/lib64/lib/' -i.orig "${src_dir}/gcc/config/i386/t-linux64"
    fi

    local build_dir="${src_dir}/build"
    mkdir -p "${build_dir}"
    cd "${build_dir}"

    ../configure \
        --target="${LFS_TGT}" \
        --prefix="${LFS_TOOLS}" \
        --with-glibc-version=2.42 \
        --with-sysroot="${LFS}" \
        --with-newlib \
        --without-headers \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --enable-languages=c,c++

    make -j"${NPROC}"
    make install

    # Create limits.h
    cd ..
    cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
        "$(dirname "$("${LFS_TGT}"-gcc -print-libgcc-file-name)")"/include/limits.h

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"

    log_ok "GCC Pass 1 complete"
}

# Install Linux headers
build_linux_headers() {
    log_step "Installing Linux Headers"

    local src_dir=$(extract_source "linux")
    cd "${src_dir}"

    make mrproper
    make headers

    find usr/include -type f ! -name '*.h' -delete
    cp -rv usr/include "${LFS}/usr"

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"

    log_ok "Linux headers installed"
}

# Build glibc
build_glibc() {
    log_step "Building Glibc"

    local src_dir=$(extract_source "glibc")

    # Ensure LSB compliance
    case $(uname -m) in
        x86_64) ln -sfv ../lib/ld-linux-x86-64.so.2 "${LFS}/lib64"
                ln -sfv ../lib/ld-linux-x86-64.so.2 "${LFS}/lib64/ld-lsb-x86-64.so.3"
                ;;
    esac

    local build_dir="${src_dir}/build"
    mkdir -p "${build_dir}"
    cd "${build_dir}"

    echo "rootsbindir=/usr/sbin" > configparms

    # glibc needs conservative flags
    CFLAGS="-O2 -pipe" \
    CXXFLAGS="-O2 -pipe" \
    ../configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(../scripts/config.guess)" \
        --enable-kernel=4.19 \
        --with-headers="${LFS}/usr/include" \
        --disable-nscd \
        libc_cv_slibdir=/usr/lib

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    # Fix hardcoded path
    sed '/RTLDLIST=/s@/usr@@g' -i "${LFS}/usr/bin/ldd"

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"

    log_ok "Glibc complete"
}

# Build libstdc++ (from GCC)
build_libstdcxx() {
    log_step "Building Libstdc++"

    local src_dir=$(extract_source "gcc")
    local build_dir="${src_dir}/build"

    mkdir -p "${build_dir}"
    cd "${build_dir}"

    ../libstdc++-v3/configure \
        --host="${LFS_TGT}" \
        --build="$(../config.guess)" \
        --prefix=/usr \
        --disable-multilib \
        --disable-nls \
        --disable-libstdcxx-pch \
        --with-gxx-include-dir="/tools/${LFS_TGT}/include/c++/15.2.0"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    # Remove libtool archives
    rm -v "${LFS}"/usr/lib/lib{stdc++{,exp,fs},supc++}.la

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"

    log_ok "Libstdc++ complete"
}

# Sanity check
sanity_check() {
    log_step "Running sanity check"

    echo 'int main(){}' | "${LFS_TGT}"-gcc -xc - -o /tmp/test_toolchain

    if ! readelf -l /tmp/test_toolchain | grep -q 'ld-linux'; then
        log_error "Toolchain sanity check failed"
    fi

    rm -f /tmp/test_toolchain

    log_ok "Toolchain sanity check passed"
}

# Main
main() {
    echo -e "${BLUE}LFS Toolchain Build${NC}"
    echo "========================================"
    echo "Target: ${LFS_TGT}"
    echo "Jobs:   ${NPROC}"
    echo "Tools:  ${LFS_TOOLS}"
    echo ""

    # Verify environment
    if [[ -z "${LFS}" ]]; then
        log_error "LFS variable not set"
    fi

    build_binutils_pass1
    build_gcc_pass1
    build_linux_headers
    build_glibc
    build_libstdcxx
    sanity_check

    echo ""
    echo "========================================"
    echo -e "${GREEN}Toolchain Build Complete${NC}"
    echo "========================================"
    echo ""
    echo "Next: Run build-temp-tools.sh to build temporary tools"
}

main "$@"
