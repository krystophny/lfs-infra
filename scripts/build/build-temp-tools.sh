#!/bin/bash
# LFS Temporary Tools Build Script
# Builds cross-compiled temporary tools (Stage 2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# Source safety library first
source "${ROOT_DIR}/scripts/lib/safety.sh"
safety_check

source "${ROOT_DIR}/config/lfs.conf"
source "${ROOT_DIR}/config/build.conf"

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

extract_source() {
    local pkg="$1"
    local build_dir="${LFS_BUILD}/${pkg}"

    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    local tarball=$(ls "${LFS_SOURCES}"/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -z "${tarball}" ]] && log_error "Tarball not found for ${pkg}"

    tar -xf "${tarball}" -C "${build_dir}" --strip-components=1
    echo "${build_dir}"
}

# Build M4
build_m4() {
    log_step "Building M4"

    local src_dir=$(extract_source "m4")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "M4 complete"
}

# Build Ncurses
build_ncurses() {
    log_step "Building Ncurses"

    local src_dir=$(extract_source "ncurses")
    cd "${src_dir}"

    # Build tic for host
    mkdir build
    pushd build
    ../configure
    make -C include
    make -C progs tic
    popd

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(./config.guess)" \
        --mandir=/usr/share/man \
        --with-manpage-format=normal \
        --with-shared \
        --without-normal \
        --with-cxx-shared \
        --without-debug \
        --without-ada \
        --disable-stripping

    make -j"${NPROC}"
    make DESTDIR="${LFS}" TIC_PATH="$(pwd)/build/progs/tic" install

    ln -sv libncursesw.so "${LFS}/usr/lib/libncurses.so"
    sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "${LFS}/usr/include/curses.h"

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Ncurses complete"
}

# Build Bash
build_bash() {
    log_step "Building Bash"

    local src_dir=$(extract_source "bash")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --build="$(sh support/config.guess)" \
        --host="${LFS_TGT}" \
        --without-bash-malloc \
        bash_cv_strtold_broken=no

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    ln -sv bash "${LFS}/bin/sh"

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Bash complete"
}

# Build Coreutils
build_coreutils() {
    log_step "Building Coreutils"

    local src_dir=$(extract_source "coreutils")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)" \
        --enable-install-program=hostname \
        --enable-no-install-program=kill,uptime

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    mv -v "${LFS}/usr/bin/chroot" "${LFS}/usr/sbin"
    mkdir -pv "${LFS}/usr/share/man/man8"
    mv -v "${LFS}/usr/share/man/man1/chroot.1" "${LFS}/usr/share/man/man8/chroot.8"
    sed -i 's/"1"/"8"/' "${LFS}/usr/share/man/man8/chroot.8"

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Coreutils complete"
}

# Build Diffutils
build_diffutils() {
    log_step "Building Diffutils"

    local src_dir=$(extract_source "diffutils")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(./build-aux/config.guess)"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Diffutils complete"
}

# Build File
build_file() {
    log_step "Building File"

    local src_dir=$(extract_source "file")
    cd "${src_dir}"

    mkdir build
    pushd build
    ../configure --disable-bzlib --disable-libseccomp --disable-xzlib --disable-zlib
    make
    popd

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(./config.guess)"

    make FILE_COMPILE="$(pwd)/build/src/file" -j"${NPROC}"
    make DESTDIR="${LFS}" install

    rm -v "${LFS}/usr/lib/libmagic.la"

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "File complete"
}

# Build Findutils
build_findutils() {
    log_step "Building Findutils"

    local src_dir=$(extract_source "findutils")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --localstatedir=/var/lib/locate \
        --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Findutils complete"
}

# Build Gawk
build_gawk() {
    log_step "Building Gawk"

    local src_dir=$(extract_source "gawk")
    cd "${src_dir}"

    sed -i 's/extras//' Makefile.in

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Gawk complete"
}

# Build Grep
build_grep() {
    log_step "Building Grep"

    local src_dir=$(extract_source "grep")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(./build-aux/config.guess)"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Grep complete"
}

# Build Gzip
build_gzip() {
    log_step "Building Gzip"

    local src_dir=$(extract_source "gzip")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Gzip complete"
}

# Build Make
build_make() {
    log_step "Building Make"

    local src_dir=$(extract_source "make")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --without-guile \
        --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Make complete"
}

# Build Patch
build_patch() {
    log_step "Building Patch"

    local src_dir=$(extract_source "patch")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Patch complete"
}

# Build Sed
build_sed() {
    log_step "Building Sed"

    local src_dir=$(extract_source "sed")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(./build-aux/config.guess)"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Sed complete"
}

# Build Tar
build_tar() {
    log_step "Building Tar"

    local src_dir=$(extract_source "tar")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Tar complete"
}

# Build Xz
build_xz() {
    log_step "Building Xz"

    local src_dir=$(extract_source "xz")
    cd "${src_dir}"

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)" \
        --disable-static \
        --docdir=/usr/share/doc/xz

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    rm -v "${LFS}/usr/lib/liblzma.la"

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Xz complete"
}

# Build Binutils Pass 2
build_binutils_pass2() {
    log_step "Building Binutils Pass 2"

    local src_dir=$(extract_source "binutils")
    local build_dir="${src_dir}/build"

    sed '6009s/$add_dir//' -i "${src_dir}/ltmain.sh"

    mkdir -p "${build_dir}"
    cd "${build_dir}"

    ../configure \
        --prefix=/usr \
        --build="$(../config.guess)" \
        --host="${LFS_TGT}" \
        --disable-nls \
        --enable-shared \
        --enable-gprofng=no \
        --disable-werror \
        --enable-64-bit-bfd \
        --enable-new-dtags \
        --enable-default-hash-style=gnu

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    rm -v "${LFS}"/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "Binutils Pass 2 complete"
}

# Build GCC Pass 2
build_gcc_pass2() {
    log_step "Building GCC Pass 2"

    local src_dir=$(extract_source "gcc")

    for dep in gmp mpfr mpc; do
        local dep_tarball=$(ls "${LFS_SOURCES}"/${dep}-*.tar.* 2>/dev/null | head -1)
        if [[ -n "${dep_tarball}" ]]; then
            tar -xf "${dep_tarball}" -C "${src_dir}"
            mv "${src_dir}/${dep}"-* "${src_dir}/${dep}"
        fi
    done

    if [[ "$(uname -m)" == "x86_64" ]]; then
        sed -e '/m64=/s/lib64/lib/' -i.orig "${src_dir}/gcc/config/i386/t-linux64"
    fi

    sed '/thread_header =/s/@.*@/gthr-posix.h/' \
        -i "${src_dir}/libgcc/Makefile.in" "${src_dir}/libstdc++-v3/include/Makefile.in"

    local build_dir="${src_dir}/build"
    mkdir -p "${build_dir}"
    cd "${build_dir}"

    ../configure \
        --build="$(../config.guess)" \
        --host="${LFS_TGT}" \
        --target="${LFS_TGT}" \
        LDFLAGS_FOR_TARGET="-L${PWD}/${LFS_TGT}/libgcc" \
        --prefix=/usr \
        --with-build-sysroot="${LFS}" \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-multilib \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libsanitizer \
        --disable-libssp \
        --disable-libvtv \
        --enable-languages=c,c++

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    ln -sv gcc "${LFS}/usr/bin/cc"

    cd "${ROOT_DIR}"
    rm -rf "${src_dir}"
    log_ok "GCC Pass 2 complete"
}

# Main
main() {
    echo -e "${BLUE}LFS Temporary Tools Build${NC}"
    echo "========================================"
    echo "Jobs: ${NPROC}"
    echo ""

    build_m4
    build_ncurses
    build_bash
    build_coreutils
    build_diffutils
    build_file
    build_findutils
    build_gawk
    build_grep
    build_gzip
    build_make
    build_patch
    build_sed
    build_tar
    build_xz
    build_binutils_pass2
    build_gcc_pass2

    echo ""
    echo "========================================"
    echo -e "${GREEN}Temporary Tools Build Complete${NC}"
    echo "========================================"
    echo ""
    echo "Next: Run chroot-setup.sh to enter chroot and build final system"
}

main "$@"
