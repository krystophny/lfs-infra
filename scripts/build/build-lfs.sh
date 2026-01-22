#!/bin/bash
# LFS Master Build Script
# Orchestrates the complete LFS build from start to finish

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# Build configuration
export LFS="${LFS:-/mnt/lfs}"
export LFS_TGT="$(uname -m)-lfs-linux-gnu"
export MAKEFLAGS="-j$(nproc)"
export NPROC="$(nproc)"

# Paths
SOURCES_DIR="${LFS}/sources"
TOOLS_DIR="${LFS}/tools"
PATCHES_DIR="${ROOT_DIR}/patches"
PACKAGES_FILE="${ROOT_DIR}/packages.toml"
LOG_DIR="/tmp/lfs-build-logs"
BUILD_STATE="${LFS}/.build-state"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Timing
BUILD_START=$(date +%s)

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

stage_start() { echo -e "\n${CYAN}========== $* ==========${NC}\n"; }
stage_end() { ok "Completed: $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [STAGE]

Build LFS from scratch. Run as root with LFS disk mounted.

Stages (run in order):
    all             Run all stages (default)
    download        Download all source tarballs
    toolchain       Build cross-compilation toolchain
    temptools       Build temporary tools
    chroot-prep     Prepare chroot environment
    base            Build base system in chroot
    config          Configure system (fstab, network, etc.)
    kernel          Build and install kernel
    bootloader      Install bootloader (GRUB)
    desktop         Build X11 and XFCE desktop

Options:
    -c, --continue      Continue from last successful stage
    -f, --force         Force rebuild even if stage completed
    -s, --skip STAGE    Skip specific stage
    -l, --list          List all stages and status
    -h, --help          Show this help

Environment:
    LFS=${LFS}
    LFS_TGT=${LFS_TGT}
    MAKEFLAGS=${MAKEFLAGS}

Examples:
    $(basename "$0")                    # Build everything
    $(basename "$0") -c                 # Continue from last stage
    $(basename "$0") toolchain          # Build only toolchain
    $(basename "$0") -s download all    # Skip download, build all
EOF
    exit 0
}

# Parse arguments
CONTINUE=0
FORCE=0
SKIP_STAGES=()
TARGET_STAGE="all"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--continue) CONTINUE=1; shift ;;
        -f|--force) FORCE=1; shift ;;
        -s|--skip) SKIP_STAGES+=("$2"); shift 2 ;;
        -l|--list) list_stages; exit 0 ;;
        -h|--help) usage ;;
        all|download|toolchain|temptools|chroot-prep|base|config|kernel|bootloader|desktop)
            TARGET_STAGE="$1"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

# State management
mark_stage_done() {
    local stage="$1"
    mkdir -p "$(dirname "${BUILD_STATE}")"
    echo "${stage}" >> "${BUILD_STATE}"
    log "Stage '${stage}' marked complete"
}

is_stage_done() {
    local stage="$1"
    [[ -f "${BUILD_STATE}" ]] && grep -q "^${stage}$" "${BUILD_STATE}"
}

should_run_stage() {
    local stage="$1"

    # Check if skipped
    for s in "${SKIP_STAGES[@]:-}"; do
        [[ "${s}" == "${stage}" ]] && return 1
    done

    # Force overrides continue
    [[ ${FORCE} -eq 1 ]] && return 0

    # Continue mode skips completed stages
    if [[ ${CONTINUE} -eq 1 ]] && is_stage_done "${stage}"; then
        log "Skipping completed stage: ${stage}"
        return 1
    fi

    return 0
}

list_stages() {
    echo "Build stages:"
    local stages=(download toolchain temptools chroot-prep base config kernel bootloader desktop)
    for s in "${stages[@]}"; do
        if is_stage_done "${s}"; then
            echo -e "  ${GREEN}[done]${NC} ${s}"
        else
            echo -e "  ${YELLOW}[pending]${NC} ${s}"
        fi
    done
}

# Check prerequisites
check_prereqs() {
    log "Checking prerequisites..."

    # Must be root
    [[ $EUID -eq 0 ]] || die "Must run as root"

    # LFS must be mounted
    mountpoint -q "${LFS}" || die "LFS not mounted at ${LFS}"

    # Check disk space (need at least 15GB free)
    local free_space
    free_space=$(df -BG "${LFS}" | awk 'NR==2 {print $4}' | tr -d 'G')
    [[ ${free_space} -ge 15 ]] || warn "Low disk space: ${free_space}GB free (need 15GB+)"

    # Create directories
    mkdir -p "${SOURCES_DIR}" "${LOG_DIR}"

    ok "Prerequisites checked"
}

# Get package info from TOML
get_pkg_version() {
    local pkg="$1"
    awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[/ && found { exit }
        found && /^version/ { gsub(/.*= *"|".*/, ""); print }
    ' "${PACKAGES_FILE}"
}

get_pkg_url() {
    local pkg="$1"
    local version
    version=$(get_pkg_version "${pkg}")
    awk -v pkg="[packages.${pkg}]" '
        $0 == pkg { found=1; next }
        /^\[/ && found { exit }
        found && /^url/ { gsub(/.*= *"|".*/, ""); print }
    ' "${PACKAGES_FILE}" | sed "s/\${version}/${version}/g"
}

# Download a package
download_pkg() {
    local pkg="$1"
    local url
    url=$(get_pkg_url "${pkg}")

    [[ -z "${url}" ]] && { warn "No URL for ${pkg}"; return 0; }

    local filename
    filename=$(basename "${url}")
    local target="${SOURCES_DIR}/${filename}"

    if [[ -f "${target}" ]]; then
        log "Already downloaded: ${filename}"
        return 0
    fi

    log "Downloading: ${pkg} -> ${filename}"
    curl -fSL -o "${target}" "${url}" || {
        warn "Failed to download ${pkg} from ${url}"
        return 1
    }

    ok "Downloaded: ${filename}"
}

# Apply patches for a package
apply_patches() {
    local pkg="$1"
    local src_dir="$2"
    local patch_dir="${PATCHES_DIR}/${pkg}"

    [[ -d "${patch_dir}" ]] || return 0

    log "Applying patches for ${pkg}..."
    for patch in "${patch_dir}"/*.patch; do
        [[ -f "${patch}" ]] || continue
        log "  Applying: $(basename "${patch}")"
        patch -d "${src_dir}" -p1 < "${patch}" || die "Patch failed: ${patch}"
    done
}

# Extract package source
extract_pkg() {
    local pkg="$1"
    local dest="$2"
    local url
    url=$(get_pkg_url "${pkg}")
    local filename
    filename=$(basename "${url}")
    local archive="${SOURCES_DIR}/${filename}"

    [[ -f "${archive}" ]] || die "Archive not found: ${archive}"

    log "Extracting: ${filename}"
    mkdir -p "${dest}"

    case "${filename}" in
        *.tar.xz|*.txz)  tar -xf "${archive}" -C "${dest}" ;;
        *.tar.gz|*.tgz)  tar -xzf "${archive}" -C "${dest}" ;;
        *.tar.bz2|*.tbz) tar -xjf "${archive}" -C "${dest}" ;;
        *.tar.zst)       tar --zstd -xf "${archive}" -C "${dest}" ;;
        *)               die "Unknown archive format: ${filename}" ;;
    esac

    # Apply patches
    local src_dir
    src_dir=$(find "${dest}" -maxdepth 1 -type d -name "${pkg}*" | head -1)
    [[ -n "${src_dir}" ]] && apply_patches "${pkg}" "${src_dir}"
}

# ============================================================================
# STAGE: Download all sources
# ============================================================================
stage_download() {
    stage_start "Downloading Sources"

    # Core packages for each stage
    local stage1_pkgs=(binutils gcc linux glibc)
    local stage2_pkgs=(m4 ncurses bash coreutils diffutils file findutils gawk grep gzip make patch sed tar xz)
    local stage3_pkgs=(gettext bison perl python texinfo util-linux)

    # Download all
    local all_pkgs=(
        "${stage1_pkgs[@]}"
        "${stage2_pkgs[@]}"
        "${stage3_pkgs[@]}"
        # Additional dependencies
        gmp mpfr mpc isl zlib bzip2 zstd readline bc flex expat
        openssl libffi pkgconf acl attr autoconf automake libtool
        # Build tools
        ninja meson cmake
    )

    local failed=0
    for pkg in "${all_pkgs[@]}"; do
        download_pkg "${pkg}" || ((failed++))
    done

    [[ ${failed} -eq 0 ]] || warn "${failed} packages failed to download"

    stage_end "Download"
    mark_stage_done "download"
}

# ============================================================================
# STAGE: Build cross-compilation toolchain
# ============================================================================
stage_toolchain() {
    stage_start "Building Cross-Compilation Toolchain"

    local build_dir="${LFS}/build"
    mkdir -p "${build_dir}"

    # Pass 1: Binutils
    log "Building binutils (pass 1)..."
    extract_pkg binutils "${build_dir}"
    pushd "${build_dir}/binutils-"* > /dev/null

    mkdir -p build && cd build
    ../configure \
        --prefix="${LFS}/tools" \
        --with-sysroot="${LFS}" \
        --target="${LFS_TGT}" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu

    make -j"${NPROC}"
    make install
    popd > /dev/null
    rm -rf "${build_dir}/binutils-"*

    # GCC (pass 1)
    log "Building GCC (pass 1)..."
    extract_pkg gcc "${build_dir}"
    extract_pkg gmp "${build_dir}"
    extract_pkg mpfr "${build_dir}"
    extract_pkg mpc "${build_dir}"

    pushd "${build_dir}/gcc-"* > /dev/null

    # Move support libraries
    mv ../gmp-* gmp
    mv ../mpfr-* mpfr
    mv ../mpc-* mpc

    # Fix for x86_64
    case $(uname -m) in
        x86_64)
            sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
            ;;
    esac

    mkdir -p build && cd build
    ../configure \
        --target="${LFS_TGT}" \
        --prefix="${LFS}/tools" \
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
        "$(dirname "$("${LFS}/tools/bin/${LFS_TGT}-gcc" -print-libgcc-file-name)")"/include/limits.h

    popd > /dev/null
    rm -rf "${build_dir}/gcc-"*

    # Linux headers
    log "Installing Linux headers..."
    extract_pkg linux "${build_dir}"
    pushd "${build_dir}/linux-"* > /dev/null

    make mrproper
    make headers
    find usr/include -type f ! -name '*.h' -delete
    cp -rv usr/include "${LFS}/usr"

    popd > /dev/null
    rm -rf "${build_dir}/linux-"*

    # Glibc
    log "Building glibc..."
    extract_pkg glibc "${build_dir}"
    pushd "${build_dir}/glibc-"* > /dev/null

    # Create symlinks
    case $(uname -m) in
        x86_64) ln -sfv ../lib/ld-linux-x86-64.so.2 "${LFS}/lib64"
                ln -sfv ../lib/ld-linux-x86-64.so.2 "${LFS}/lib64/ld-lsb-x86-64.so.3" ;;
    esac

    mkdir -p build && cd build
    echo "rootsbindir=/usr/sbin" > configparms

    ../configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(../scripts/config.guess)" \
        --enable-kernel=5.4 \
        --with-headers="${LFS}/usr/include" \
        --disable-nscd \
        libc_cv_slibdir=/usr/lib

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    # Fix ldd path
    sed '/RTLDLIST=/s@/usr@@g' -i "${LFS}/usr/bin/ldd"

    popd > /dev/null
    rm -rf "${build_dir}/glibc-"*

    # Libstdc++ (from GCC)
    log "Building libstdc++..."
    extract_pkg gcc "${build_dir}"
    pushd "${build_dir}/gcc-"* > /dev/null

    mkdir -p build && cd build
    ../libstdc++-v3/configure \
        --host="${LFS_TGT}" \
        --build="$(../config.guess)" \
        --prefix=/usr \
        --disable-multilib \
        --disable-nls \
        --disable-libstdcxx-pch \
        --with-gxx-include-dir="/tools/${LFS_TGT}/include/c++/$(cat ../gcc/BASE-VER)"

    make -j"${NPROC}"
    make DESTDIR="${LFS}" install

    # Remove libtool archives
    rm -v "${LFS}"/usr/lib/lib{stdc++{,exp,fs},supc++}.la

    popd > /dev/null
    rm -rf "${build_dir}/gcc-"*

    stage_end "Toolchain"
    mark_stage_done "toolchain"
}

# ============================================================================
# STAGE: Build temporary tools
# ============================================================================
stage_temptools() {
    stage_start "Building Temporary Tools"

    local build_dir="${LFS}/build"
    mkdir -p "${build_dir}"

    # Set up cross-compilation environment
    export PATH="${LFS}/tools/bin:${PATH}"
    export CONFIG_SITE="${LFS}/usr/share/config.site"

    # Create config.site
    cat > "${CONFIG_SITE}" << "EOF"
# config.site for LFS cross-compilation
ac_cv_func_mmap_fixed_mapped=yes
ac_cv_func_strcoll_works=yes
bash_cv_func_sigsetjmp=present
bash_cv_getcwd_malloc=yes
bash_cv_job_control_missing=present
bash_cv_printf_a_format=yes
bash_cv_sys_named_pipes=present
bash_cv_ulimit_maxfds=yes
bash_cv_under_sys_siglist=yes
bash_cv_unusable_rtsigs=no
gt_cv_int_divbyzero_sigfpe=yes
EOF

    # Build each temporary tool
    local temp_tools=(
        m4 ncurses bash coreutils diffutils file findutils
        gawk grep gzip make patch sed tar xz
        binutils gcc
    )

    for pkg in "${temp_tools[@]}"; do
        log "Building temporary tool: ${pkg}..."

        extract_pkg "${pkg}" "${build_dir}"
        pushd "${build_dir}/${pkg}-"* > /dev/null

        case "${pkg}" in
            m4)
                ./configure --prefix=/usr --host="${LFS_TGT}" --build="$(build-aux/config.guess)"
                make -j"${NPROC}"
                make DESTDIR="${LFS}" install
                ;;
            ncurses)
                mkdir -p build
                pushd build > /dev/null
                ../configure AWK=gawk
                make -C include
                make -C progs tic
                popd > /dev/null

                ./configure \
                    --prefix=/usr \
                    --host="${LFS_TGT}" \
                    --build="$(./config.guess)" \
                    --mandir=/usr/share/man \
                    --with-manpage-format=normal \
                    --with-shared \
                    --without-normal \
                    --without-cxx-binding \
                    --without-debug \
                    --without-ada \
                    --disable-stripping

                make -j"${NPROC}"
                make DESTDIR="${LFS}" TIC_PATH="$(pwd)/build/progs/tic" install
                ln -svf libncursesw.so "${LFS}/usr/lib/libncurses.so"
                sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "${LFS}/usr/include/curses.h"
                ;;
            bash)
                ./configure \
                    --prefix=/usr \
                    --build="$(sh support/config.guess)" \
                    --host="${LFS_TGT}" \
                    --without-bash-malloc \
                    bash_cv_strtold_broken=no

                make -j"${NPROC}"
                make DESTDIR="${LFS}" install
                ln -svf bash "${LFS}/bin/sh"
                ;;
            coreutils)
                ./configure \
                    --prefix=/usr \
                    --host="${LFS_TGT}" \
                    --build="$(build-aux/config.guess)" \
                    --enable-install-program=hostname

                make -j"${NPROC}"
                make DESTDIR="${LFS}" install
                mv -v "${LFS}/usr/bin/chroot" "${LFS}/usr/sbin"
                ;;
            diffutils)
                ./configure --prefix=/usr --host="${LFS_TGT}" --build="$(./config.guess)" \
                    gl_cv_func_strcasecmp_works=yes
                make -j"${NPROC}"
                make DESTDIR="${LFS}" install
                ;;
            file)
                mkdir -p build
                pushd build > /dev/null
                ../configure --disable-bzlib --disable-libseccomp \
                    --disable-xzlib --disable-zlib
                make
                popd > /dev/null
                ./configure --prefix=/usr --host="${LFS_TGT}" --build="$(./config.guess)"
                make FILE_COMPILE="$(pwd)/build/src/file" -j"${NPROC}"
                make DESTDIR="${LFS}" install
                rm -v "${LFS}/usr/lib/libmagic.la"
                ;;
            findutils)
                ./configure --prefix=/usr --host="${LFS_TGT}" --build="$(./config.guess)" \
                    --localstatedir=/var/lib/locate \
                    gl_cv_func_wcwidth_works=yes
                make -j"${NPROC}"
                make DESTDIR="${LFS}" install
                ;;
            gawk)
                sed -i 's/extras//' Makefile.in
                ./configure --prefix=/usr --host="${LFS_TGT}" --build="$(./config.guess)"
                make -j"${NPROC}"
                make DESTDIR="${LFS}" install
                ;;
            grep|gzip|make|patch|sed|tar|xz)
                ./configure --prefix=/usr --host="${LFS_TGT}" --build="$(./config.guess 2>/dev/null || build-aux/config.guess)"
                make -j"${NPROC}"
                make DESTDIR="${LFS}" install
                ;;
            binutils)
                mkdir -p build && cd build
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
                ;;
            gcc)
                # Extract support libraries
                extract_pkg gmp "${build_dir}"
                extract_pkg mpfr "${build_dir}"
                extract_pkg mpc "${build_dir}"

                mv ../gmp-* gmp
                mv ../mpfr-* mpfr
                mv ../mpc-* mpc

                case $(uname -m) in
                    x86_64)
                        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
                        ;;
                esac

                mkdir -p build && cd build
                ../configure \
                    --build="$(../config.guess)" \
                    --host="${LFS_TGT}" \
                    --target="${LFS_TGT}" \
                    LDFLAGS_FOR_TARGET=-L"${PWD}/${LFS_TGT}/libgcc" \
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
                ln -svf gcc "${LFS}/usr/bin/cc"
                ;;
        esac

        popd > /dev/null
        rm -rf "${build_dir}/${pkg}-"*
    done

    stage_end "Temporary Tools"
    mark_stage_done "temptools"
}

# ============================================================================
# STAGE: Prepare chroot environment
# ============================================================================
stage_chroot_prep() {
    stage_start "Preparing Chroot Environment"

    # Change ownership to root
    chown -R root:root "${LFS}"/{usr,var,etc,tools}

    # Create essential directory symlinks (modern LFS structure)
    # /lib -> usr/lib, /lib64 -> usr/lib, /bin -> usr/bin, /sbin -> usr/sbin
    for dir in lib bin sbin; do
        if [[ -d "${LFS}/${dir}" ]] && [[ ! -L "${LFS}/${dir}" ]]; then
            rm -rf "${LFS}/${dir}"
        fi
    done
    [[ -L "${LFS}/lib" ]] || ln -sv /usr/lib "${LFS}/lib"
    [[ -L "${LFS}/bin" ]] || ln -sv usr/bin "${LFS}/bin"
    [[ -L "${LFS}/sbin" ]] || ln -sv usr/sbin "${LFS}/sbin"

    case $(uname -m) in
        x86_64)
            if [[ -d "${LFS}/lib64" ]] && [[ ! -L "${LFS}/lib64" ]]; then
                rm -rf "${LFS}/lib64"
            fi
            [[ -L "${LFS}/lib64" ]] || ln -sv /usr/lib "${LFS}/lib64"
            ;;
    esac

    # Ensure /usr/bin/sh exists
    [[ -e "${LFS}/usr/bin/sh" ]] || ln -sv bash "${LFS}/usr/bin/sh"

    # Create directories
    mkdir -pv "${LFS}"/{dev,proc,sys,run,tmp}
    chmod 1777 "${LFS}/tmp"

    # Create device nodes
    if [[ ! -c "${LFS}/dev/console" ]]; then
        mknod -m 600 "${LFS}/dev/console" c 5 1
    fi
    if [[ ! -c "${LFS}/dev/null" ]]; then
        mknod -m 666 "${LFS}/dev/null" c 1 3
    fi

    # Mount virtual filesystems
    mount -v --bind /dev "${LFS}/dev"
    mount -vt devpts devpts -o gid=5,mode=0620 "${LFS}/dev/pts"
    mount -vt proc proc "${LFS}/proc"
    mount -vt sysfs sysfs "${LFS}/sys"
    mount -vt tmpfs tmpfs "${LFS}/run"

    # Create essential files
    cat > "${LFS}/etc/passwd" << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

    cat > "${LFS}/etc/group" << "EOF"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
kvm:x:61:
uuidd:x:80:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF

    # Touch log files
    mkdir -p "${LFS}/var/log"
    touch "${LFS}/var/log"/{btmp,lastlog,faillog,wtmp}
    chgrp -v 13 "${LFS}/var/log/lastlog"
    chmod -v 664 "${LFS}/var/log/lastlog"
    chmod -v 600 "${LFS}/var/log/btmp"

    stage_end "Chroot Preparation"
    mark_stage_done "chroot-prep"
}

# ============================================================================
# STAGE: Build base system (in chroot)
# ============================================================================
stage_base() {
    stage_start "Building Base System"

    # This stage should be run inside chroot
    # Create a script to run inside chroot
    cat > "${LFS}/build-base.sh" << 'CHROOT_SCRIPT'
#!/bin/bash
set -e

export MAKEFLAGS="-j$(nproc)"

# Build zlib first (required for linker)
cd /sources
rm -rf zlib-[0-9]*/
tar xf zlib-*.tar.gz
cd zlib-[0-9]*/
./configure --prefix=/usr
make -j$(nproc)
make install
rm -f /usr/lib/libz.a
cd /sources && rm -rf zlib-[0-9]*/

# Build gettext
cd /sources
rm -rf gettext-[0-9]*/
tar xf gettext-*.tar.xz
cd gettext-[0-9]*/
./configure --disable-shared
make -j$(nproc)
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
cd /sources && rm -rf gettext-[0-9]*/

# Build bison
rm -rf bison-[0-9]*/
tar xf bison-*.tar.xz
cd bison-[0-9]*/
./configure --prefix=/usr --docdir=/usr/share/doc/bison
make -j$(nproc)
make install
cd /sources && rm -rf bison-[0-9]*/

# Build perl
rm -rf perl-[0-9]*/
tar xf perl-*.tar.xz
cd perl-[0-9]*/
sh Configure -des \
    -D prefix=/usr \
    -D vendorprefix=/usr \
    -D useshrplib \
    -D privlib=/usr/lib/perl5/core_perl \
    -D archlib=/usr/lib/perl5/core_perl \
    -D sitelib=/usr/lib/perl5/site_perl \
    -D sitearch=/usr/lib/perl5/site_perl \
    -D vendorlib=/usr/lib/perl5/vendor_perl \
    -D vendorarch=/usr/lib/perl5/vendor_perl
make -j$(nproc)
make install
cd /sources && rm -rf perl-[0-9]*/

# Build Python
rm -rf Python-[0-9]*/
tar xf Python-*.tar.xz
cd Python-[0-9]*/
./configure --prefix=/usr --enable-shared --without-ensurepip
make -j$(nproc)
make install
cd /sources && rm -rf Python-[0-9]*/

# Build texinfo
rm -rf texinfo-[0-9]*/
tar xf texinfo-*.tar.xz
cd texinfo-[0-9]*/
./configure --prefix=/usr
make -j$(nproc)
make install
cd /sources && rm -rf texinfo-[0-9]*/

# Build util-linux
rm -rf util-linux-[0-9]*/
tar xf util-linux-*.tar.xz
cd util-linux-[0-9]*/
mkdir -pv /var/lib/hwclock
./configure \
    --libdir=/usr/lib \
    --runstatedir=/run \
    --disable-chfn-chsh \
    --disable-login \
    --disable-nologin \
    --disable-su \
    --disable-setpriv \
    --disable-runuser \
    --disable-pylibmount \
    --disable-static \
    --disable-liblastlog2 \
    --without-python \
    ADJTIME_PATH=/var/lib/hwclock/adjtime \
    --docdir=/usr/share/doc/util-linux
make -j$(nproc)
make install
cd /sources && rm -rf util-linux-[0-9]*/

echo "Base system build complete"
CHROOT_SCRIPT

    chmod +x "${LFS}/build-base.sh"

    # Enter chroot and run the script
    chroot "${LFS}" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM}" \
        PS1='(lfs chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        MAKEFLAGS="-j$(nproc)" \
        /bin/bash /build-base.sh

    rm "${LFS}/build-base.sh"

    stage_end "Base System"
    mark_stage_done "base"
}

# ============================================================================
# STAGE: System configuration
# ============================================================================
stage_config() {
    stage_start "Configuring System"

    # Copy configuration files
    cp -v "${ROOT_DIR}/config/etc/fstab" "${LFS}/etc/"
    cp -v "${ROOT_DIR}/config/etc/hosts" "${LFS}/etc/"
    cp -v "${ROOT_DIR}/config/etc/passwd" "${LFS}/etc/"
    cp -v "${ROOT_DIR}/config/etc/group" "${LFS}/etc/"

    # Create hostname
    echo "lfs" > "${LFS}/etc/hostname"

    # Create /etc/os-release
    cat > "${LFS}/etc/os-release" << EOF
NAME="LFS"
VERSION="12.2"
ID=lfs
PRETTY_NAME="Linux From Scratch 12.2"
VERSION_CODENAME="bleeding-edge"
HOME_URL="https://www.linuxfromscratch.org"
EOF

    # Network configuration
    mkdir -p "${LFS}/etc/network"
    cat > "${LFS}/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

    # Copy runit services
    if [[ -d "${ROOT_DIR}/config/runit" ]]; then
        cp -av "${ROOT_DIR}/config/runit"/* "${LFS}/etc/runit/" 2>/dev/null || true
    fi

    # Install init script for XFCE desktop
    if [[ -f "${ROOT_DIR}/config/etc/init" ]]; then
        install -m 755 "${ROOT_DIR}/config/etc/init" "${LFS}/sbin/init"
        log "Installed init script with XFCE desktop support"
    fi

    stage_end "Configuration"
    mark_stage_done "config"
}

# ============================================================================
# STAGE: Build kernel
# ============================================================================
stage_kernel() {
    stage_start "Building Linux Kernel"

    local build_dir="${LFS}/build"
    mkdir -p "${build_dir}"

    extract_pkg linux "${build_dir}"
    pushd "${build_dir}/linux-"* > /dev/null

    make mrproper

    # Use default config as base, enable virtio for VM
    make defconfig

    # Enable additional options for VM and desktop
    scripts/config --enable CONFIG_DRM_VIRTIO_GPU
    scripts/config --enable CONFIG_VIRTIO_PCI
    scripts/config --enable CONFIG_VIRTIO_BLK
    scripts/config --enable CONFIG_VIRTIO_NET
    scripts/config --enable CONFIG_VIRTIO_CONSOLE
    scripts/config --enable CONFIG_HW_RANDOM_VIRTIO
    scripts/config --enable CONFIG_DRM_FBDEV_EMULATION
    scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
    scripts/config --enable CONFIG_EFI
    scripts/config --enable CONFIG_EFI_STUB

    make -j"${NPROC}"
    make INSTALL_MOD_PATH="${LFS}" modules_install

    # Install kernel
    cp -v arch/x86/boot/bzImage "${LFS}/boot/vmlinuz-lfs"
    cp -v System.map "${LFS}/boot/System.map-lfs"
    cp -v .config "${LFS}/boot/config-lfs"

    popd > /dev/null
    rm -rf "${build_dir}/linux-"*

    stage_end "Kernel"
    mark_stage_done "kernel"
}

# ============================================================================
# STAGE: Install bootloader
# ============================================================================
stage_bootloader() {
    stage_start "Installing Bootloader (GRUB)"

    # Enter chroot to install GRUB
    chroot "${LFS}" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM}" \
        PATH=/usr/bin:/usr/sbin \
        /bin/bash -c '
        # Install GRUB for EFI
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=LFS --removable 2>/dev/null || \
        grub-install --target=i386-pc /dev/loop0 2>/dev/null || \
        echo "GRUB install may need manual configuration"

        # Generate GRUB config
        cat > /boot/grub/grub.cfg << "EOF"
set default=0
set timeout=5

menuentry "LFS - Linux From Scratch" {
    linux /boot/vmlinuz-lfs root=/dev/vda2 ro quiet
    # initrd /boot/initramfs-lfs.img
}

menuentry "LFS - Linux From Scratch (verbose)" {
    linux /boot/vmlinuz-lfs root=/dev/vda2 ro
}
EOF
        '

    stage_end "Bootloader"
    mark_stage_done "bootloader"
}

# ============================================================================
# STAGE: Build desktop
# ============================================================================

# Helper to run commands in chroot
run_in_chroot() {
    chroot "${LFS}" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM}" \
        PS1='(lfs chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        MAKEFLAGS="-j${NPROC}" \
        /bin/bash -c "$1"
}

# Helper to download a package source
download_pkg() {
    local name="$1"
    local url="$2"
    local srcdir="${LFS}/sources"
    local filename=$(basename "$url")

    if [[ -f "${srcdir}/${filename}" ]]; then
        log "Already downloaded: ${filename}"
        return 0
    fi

    log "Downloading: ${name}"
    curl -L -o "${srcdir}/${filename}" "$url" || {
        warn "Failed to download ${name}"
        return 1
    }
}

# Helper to build a package in chroot with meson
build_meson_pkg() {
    local name="$1"
    local tarball="$2"
    local opts="${3:-}"

    log "Building ${name} (meson)"
    run_in_chroot "
        cd /sources
        rm -rf ${name}-[0-9]*/
        tar xf ${tarball}
        cd ${name}-[0-9]*/
        mkdir -p build
        cd build
        meson setup --prefix=/usr --buildtype=release ${opts} ..
        ninja -j${NPROC}
        ninja install
        cd /sources
        rm -rf ${name}-[0-9]*/
    "
}

# Helper to build a package in chroot with autotools
build_autotools_pkg() {
    local name="$1"
    local tarball="$2"
    local opts="${3:-}"

    log "Building ${name} (autotools)"
    run_in_chroot "
        cd /sources
        rm -rf ${name}-[0-9]*/
        tar xf ${tarball}
        cd ${name}-[0-9]*/
        ./configure --prefix=/usr ${opts}
        make -j${NPROC}
        make install
        cd /sources
        rm -rf ${name}-[0-9]*/
    "
}

# Helper to build a package in chroot with cmake
build_cmake_pkg() {
    local name="$1"
    local tarball="$2"
    local opts="${3:-}"

    log "Building ${name} (cmake)"
    run_in_chroot "
        cd /sources
        rm -rf ${name}-[0-9]*/
        tar xf ${tarball}
        cd ${name}-[0-9]*/
        mkdir -p build
        cd build
        cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release ${opts} ..
        make -j${NPROC}
        make install
        cd /sources
        rm -rf ${name}-[0-9]*/
    "
}

stage_desktop() {
    stage_start "Building Desktop Environment"

    log "This stage builds X11, Mesa, XFCE, and applications"
    log "This is a large undertaking - expect several hours"

    # Ensure chroot mounts are set up
    if ! mountpoint -q "${LFS}/proc"; then
        mount -vt proc proc "${LFS}/proc"
    fi
    if ! mountpoint -q "${LFS}/sys"; then
        mount -vt sysfs sysfs "${LFS}/sys"
    fi
    if ! mountpoint -q "${LFS}/dev"; then
        mount -v --bind /dev "${LFS}/dev"
    fi
    if ! mountpoint -q "${LFS}/dev/pts"; then
        mount -vt devpts devpts -o gid=5,mode=0620 "${LFS}/dev/pts"
    fi
    if ! mountpoint -q "${LFS}/run"; then
        mount -vt tmpfs tmpfs "${LFS}/run"
    fi

    # First, build essential build tools (always build, skip conditionals)
    log "========== Building Build Tools =========="

    # pkgconf (modern pkg-config replacement, GCC 15 compatible)
    if [[ ! -x "${LFS}/usr/bin/pkg-config" ]]; then
        log "Building pkgconf..."
        download_pkg "pkgconf" "https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz"
        run_in_chroot "
            cd /sources
            rm -rf pkgconf-[0-9]*/
            tar xf pkgconf-*.tar.xz
            cd pkgconf-[0-9]*/
            ./configure --prefix=/usr --disable-static
            make -j${NPROC}
            make install
            ln -svf pkgconf /usr/bin/pkg-config
            cd /sources && rm -rf pkgconf-[0-9]*/
        " || die "Failed to build pkgconf"
        ok "pkgconf (pkg-config) installed"
    else
        log "pkg-config already installed"
    fi

    # Ninja
    if [[ ! -x "${LFS}/usr/bin/ninja" ]]; then
        log "Building ninja..."
        download_pkg "ninja" "https://github.com/ninja-build/ninja/archive/refs/tags/v1.12.1.tar.gz"
        run_in_chroot "
            cd /sources
            rm -rf ninja-[0-9]*/
            tar xf v1.12.1.tar.gz || tar xf ninja-*.tar.gz
            cd ninja-[0-9]*/
            python3 configure.py --bootstrap
            install -vm755 ninja /usr/bin/
            cd /sources && rm -rf ninja-[0-9]*/
        " || die "Failed to build ninja"
        ok "ninja installed"
    else
        log "ninja already installed"
    fi

    # Meson (install via setup.py since pip may not be available)
    if [[ ! -x "${LFS}/usr/bin/meson" ]]; then
        log "Building meson..."
        download_pkg "meson" "https://github.com/mesonbuild/meson/releases/download/1.6.1/meson-1.6.1.tar.gz"
        run_in_chroot "
            cd /sources
            rm -rf meson-[0-9]*/
            tar xf meson-*.tar.gz
            cd meson-[0-9]*/
            python3 setup.py build
            python3 setup.py install --prefix=/usr
            cd /sources && rm -rf meson-[0-9]*/
        " || die "Failed to build meson"
        ok "meson installed"
    else
        log "meson already installed"
    fi

    # Autoconf
    if [[ ! -x "${LFS}/usr/bin/autoconf" ]]; then
        log "Building autoconf..."
        download_pkg "autoconf" "https://ftp.gnu.org/gnu/autoconf/autoconf-2.72.tar.xz"
        run_in_chroot "
            cd /sources
            rm -rf autoconf-[0-9]*/
            tar xf autoconf-*.tar.xz
            cd autoconf-[0-9]*/
            ./configure --prefix=/usr
            make -j${NPROC}
            make install
            cd /sources && rm -rf autoconf-[0-9]*/
        " || die "Failed to build autoconf"
        ok "autoconf installed"
    else
        log "autoconf already installed"
    fi

    # Automake
    if [[ ! -x "${LFS}/usr/bin/automake" ]]; then
        log "Building automake..."
        download_pkg "automake" "https://ftp.gnu.org/gnu/automake/automake-1.17.tar.xz"
        run_in_chroot "
            cd /sources
            rm -rf automake-[0-9]*/
            tar xf automake-*.tar.xz
            cd automake-[0-9]*/
            ./configure --prefix=/usr
            make -j${NPROC}
            make install
            cd /sources && rm -rf automake-[0-9]*/
        " || die "Failed to build automake"
        ok "automake installed"
    else
        log "automake already installed"
    fi

    # Libtool
    if [[ ! -x "${LFS}/usr/bin/libtool" ]]; then
        log "Building libtool..."
        download_pkg "libtool" "https://ftp.gnu.org/gnu/libtool/libtool-2.5.4.tar.xz"
        run_in_chroot "
            cd /sources
            rm -rf libtool-[0-9]*/
            tar xf libtool-*.tar.xz
            cd libtool-[0-9]*/
            ./configure --prefix=/usr
            make -j${NPROC}
            make install
            cd /sources && rm -rf libtool-[0-9]*/
        " || die "Failed to build libtool"
        ok "libtool installed"
    else
        log "libtool already installed"
    fi

    ok "Build tools ready"

    # Build essential system libraries
    log "========== Building System Libraries =========="

    # libmd (required for libbsd)
    if [[ ! -f "${LFS}/usr/lib/libmd.so" ]]; then
        log "Building libmd..."
        download_pkg "libmd" "https://libbsd.freedesktop.org/releases/libmd-1.1.0.tar.xz"
        run_in_chroot "
            cd /sources
            rm -rf libmd-[0-9]*/
            tar xf libmd-*.tar.xz
            cd libmd-[0-9]*/
            ./configure --prefix=/usr --disable-static
            make -j${NPROC}
            make install
            cd /sources && rm -rf libmd-[0-9]*/
        " || die "Failed to build libmd"
        ok "libmd installed"
    else
        log "libmd already installed"
    fi

    # libbsd (BSD portability library, requires libmd)
    if [[ ! -f "${LFS}/usr/lib/libbsd.so" ]]; then
        log "Building libbsd..."
        download_pkg "libbsd" "https://libbsd.freedesktop.org/releases/libbsd-0.12.2.tar.xz"
        run_in_chroot "
            cd /sources
            rm -rf libbsd-[0-9]*/
            tar xf libbsd-*.tar.xz
            cd libbsd-[0-9]*/
            ./configure --prefix=/usr --disable-static
            make -j${NPROC}
            make install
            cd /sources && rm -rf libbsd-[0-9]*/
        " || die "Failed to build libbsd"
        ok "libbsd installed"
    else
        log "libbsd already installed"
    fi

    # libtirpc (Transport-Independent RPC library)
    if [[ ! -f "${LFS}/usr/lib/libtirpc.so" ]]; then
        log "Building libtirpc..."
        download_pkg "libtirpc" "https://downloads.sourceforge.net/libtirpc/libtirpc-1.3.7.tar.bz2"
        run_in_chroot "
            cd /sources
            rm -rf libtirpc-[0-9]*/
            tar xf libtirpc-*.tar.bz2 || { bunzip2 -k libtirpc-*.tar.bz2 && tar xf libtirpc-*.tar; }
            cd libtirpc-[0-9]*/
            # GCC 15 compatibility
            CFLAGS='-O2 -Wno-error=incompatible-pointer-types -Wno-error=int-conversion' \
            ./configure --prefix=/usr --sysconfdir=/etc --disable-static --disable-gssapi
            make -j${NPROC}
            make install
            cd /sources && rm -rf libtirpc-[0-9]*/
        " || die "Failed to build libtirpc"
        ok "libtirpc installed"
    else
        log "libtirpc already installed"
    fi

    # procps-ng (ps, top, pgrep, etc.)
    if [[ ! -x "${LFS}/usr/bin/pgrep" ]]; then
        log "Building procps-ng..."
        download_pkg "procps-ng" "https://sourceforge.net/projects/procps-ng/files/Production/procps-ng-4.0.4.tar.xz"
        run_in_chroot "
            cd /sources
            rm -rf procps-ng-[0-9]*/
            tar xf procps-ng-*.tar.xz
            cd procps-ng-[0-9]*/
            ./configure --prefix=/usr --disable-static --disable-kill --without-ncurses
            make -j${NPROC}
            make install
            cd /sources && rm -rf procps-ng-[0-9]*/
        " || die "Failed to build procps-ng"
        ok "procps-ng installed"
    else
        log "procps-ng already installed"
    fi

    # libglvnd (GL Vendor-Neutral Dispatch)
    if [[ ! -f "${LFS}/usr/lib/libGL.so" ]] || [[ ! -f "${LFS}/usr/lib/pkgconfig/gl.pc" ]]; then
        log "Building libglvnd..."
        download_pkg "libglvnd" "https://gitlab.freedesktop.org/glvnd/libglvnd/-/archive/v1.7.0/libglvnd-v1.7.0.tar.gz"
        run_in_chroot "
            cd /sources
            rm -rf libglvnd-*/
            tar xf libglvnd-*.tar.gz
            cd libglvnd-*/
            mkdir -p build && cd build
            meson setup --prefix=/usr --buildtype=release ..
            ninja -j${NPROC}
            ninja install
            cd /sources && rm -rf libglvnd-*/
        " || die "Failed to build libglvnd"
        ok "libglvnd installed"
    else
        log "libglvnd already installed"
    fi

    # libepoxy (OpenGL function pointer management)
    if [[ ! -f "${LFS}/usr/lib/libepoxy.so" ]]; then
        log "Building libepoxy..."
        download_pkg "libepoxy" "https://github.com/anholt/libepoxy/releases/download/1.5.10/libepoxy-1.5.10.tar.xz"
        run_in_chroot "
            cd /sources
            rm -rf libepoxy-[0-9]*/
            tar xf libepoxy-*.tar.xz
            cd libepoxy-[0-9]*/
            mkdir -p build && cd build
            # Enable both EGL and GLX for glamor support
            meson setup --prefix=/usr --buildtype=release -Degl=yes -Dglx=yes ..
            ninja -j${NPROC}
            ninja install
            cd /sources && rm -rf libepoxy-[0-9]*/
        " || die "Failed to build libepoxy"
        ok "libepoxy installed"
    else
        log "libepoxy already installed"
    fi

    ok "System libraries ready"

    # Build D-Bus (required for XFCE)
    log "========== Building D-Bus =========="
    download_pkg "dbus" "https://dbus.freedesktop.org/releases/dbus/dbus-1.16.0.tar.xz"
    run_in_chroot "
        cd /sources
        rm -rf dbus-[0-9]*/
        tar xf dbus-*.tar.xz
        cd dbus-[0-9]*/
        ./configure --prefix=/usr \
            --sysconfdir=/etc \
            --localstatedir=/var \
            --runstatedir=/run \
            --disable-static \
            --with-system-socket=/run/dbus/system_bus_socket
        make -j${NPROC}
        make install
        # Create machine-id
        dbus-uuidgen --ensure=/etc/machine-id
        dbus-uuidgen --ensure=/var/lib/dbus/machine-id
        cd /sources && rm -rf dbus-[0-9]*/
    "
    ok "dbus built"

    # Build X11 Foundation
    log "========== Building X11 Foundation =========="

    # XML/XSLT libraries needed for many X11 packages
    download_pkg "expat" "https://github.com/libexpat/libexpat/releases/download/R_2_6_6/expat-2.6.6.tar.xz"
    download_pkg "libxml2" "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.6.tar.xz"

    run_in_chroot "
        # expat
        cd /sources
        rm -rf expat-[0-9]*/
        tar xf expat-*.tar.xz
        cd expat-[0-9]*/
        ./configure --prefix=/usr --disable-static
        make -j${NPROC}
        make install
        cd /sources && rm -rf expat-[0-9]*/
    "
    ok "expat built"

    run_in_chroot "
        # libxml2
        cd /sources
        rm -rf libxml2-[0-9]*/
        tar xf libxml2-*.tar.xz
        cd libxml2-[0-9]*/
        ./configure --prefix=/usr --disable-static --with-history --without-python
        make -j${NPROC}
        make install
        cd /sources && rm -rf libxml2-[0-9]*/
    "
    ok "libxml2 built"

    # X11 protocol headers
    download_pkg "xorgproto" "https://xorg.freedesktop.org/archive/individual/proto/xorgproto-2024.1.tar.xz"
    download_pkg "xcb-proto" "https://xorg.freedesktop.org/archive/individual/proto/xcb-proto-1.17.0.tar.xz"

    run_in_chroot "
        cd /sources
        rm -rf xorgproto-[0-9]*/
        tar xf xorgproto-*.tar.xz
        cd xorgproto-[0-9]*/
        mkdir build && cd build
        meson setup --prefix=/usr ..
        ninja
        ninja install
        cd /sources && rm -rf xorgproto-[0-9]*/
    "
    ok "xorgproto built"

    run_in_chroot "
        cd /sources
        rm -rf xcb-proto-[0-9]*/
        tar xf xcb-proto-*.tar.xz
        cd xcb-proto-[0-9]*/
        ./configure --prefix=/usr
        make install
        cd /sources && rm -rf xcb-proto-[0-9]*/
    "
    ok "xcb-proto built"

    # X11 utility macros
    download_pkg "util-macros" "https://www.x.org/releases/individual/util/util-macros-1.20.2.tar.xz"
    run_in_chroot "
        cd /sources
        rm -rf util-macros-[0-9]*/
        tar xf util-macros-*.tar.xz
        cd util-macros-[0-9]*/
        ./configure --prefix=/usr
        make install
        cd /sources && rm -rf util-macros-[0-9]*/
    "
    ok "util-macros built"

    # libXau, libXdmcp
    download_pkg "libXau" "https://www.x.org/releases/individual/lib/libXau-1.0.12.tar.xz"
    download_pkg "libXdmcp" "https://www.x.org/releases/individual/lib/libXdmcp-1.1.5.tar.xz"

    run_in_chroot "
        cd /sources
        rm -rf libXau-[0-9]*/
        tar xf libXau-*.tar.xz
        cd libXau-[0-9]*/
        ./configure --prefix=/usr --disable-static
        make -j${NPROC}
        make install
        cd /sources && rm -rf libXau-[0-9]*/
    "
    ok "libXau built"

    run_in_chroot "
        cd /sources
        rm -rf libXdmcp-[0-9]*/
        tar xf libXdmcp-*.tar.xz
        cd libXdmcp-[0-9]*/
        ./configure --prefix=/usr --disable-static
        make -j${NPROC}
        make install
        cd /sources && rm -rf libXdmcp-[0-9]*/
    "
    ok "libXdmcp built"

    # libxcb
    download_pkg "libxcb" "https://xorg.freedesktop.org/archive/individual/lib/libxcb-1.17.0.tar.xz"
    run_in_chroot "
        cd /sources
        rm -rf libxcb-[0-9]*/
        tar xf libxcb-*.tar.xz
        cd libxcb-[0-9]*/
        ./configure --prefix=/usr --disable-static --without-doxygen
        make -j${NPROC}
        make install
        cd /sources && rm -rf libxcb-[0-9]*/
    "
    ok "libxcb built"

    # xtrans
    download_pkg "xtrans" "https://www.x.org/releases/individual/lib/xtrans-1.5.2.tar.xz"
    run_in_chroot "
        cd /sources
        rm -rf xtrans-[0-9]*/
        tar xf xtrans-*.tar.xz
        cd xtrans-[0-9]*/
        ./configure --prefix=/usr
        make install
        cd /sources && rm -rf xtrans-[0-9]*/
    "
    ok "xtrans built"

    # libX11
    download_pkg "libX11" "https://www.x.org/releases/individual/lib/libX11-1.8.10.tar.xz"
    run_in_chroot "
        cd /sources
        rm -rf libX11-[0-9]*/
        tar xf libX11-*.tar.xz
        cd libX11-[0-9]*/
        ./configure --prefix=/usr --disable-static --without-doc
        make -j${NPROC}
        make install
        cd /sources && rm -rf libX11-[0-9]*/
    "
    ok "libX11 built"

    # X11 extension libraries
    for lib in libXext libXfixes libXrender libXi libXrandr libXcursor libXinerama libXcomposite libXdamage libXtst; do
        download_pkg "${lib}" "https://www.x.org/releases/individual/lib/${lib}-*.tar.xz" 2>/dev/null || true
    done

    # Build them
    download_pkg "libXext" "https://www.x.org/releases/individual/lib/libXext-1.3.6.tar.xz"
    download_pkg "libXfixes" "https://www.x.org/releases/individual/lib/libXfixes-6.0.1.tar.xz"
    download_pkg "libXrender" "https://www.x.org/releases/individual/lib/libXrender-0.9.12.tar.xz"

    for lib in libXext libXfixes libXrender; do
        run_in_chroot "
            cd /sources
            rm -rf ${lib}-[0-9]*/
            tar xf ${lib}-*.tar.xz
            cd ${lib}-[0-9]*/
            ./configure --prefix=/usr --disable-static
            make -j${NPROC}
            make install
            cd /sources && rm -rf ${lib}-[0-9]*/
        "
        ok "${lib} built"
    done

    # Font libraries
    log "========== Building Font Stack =========="

    download_pkg "freetype" "https://downloads.sourceforge.net/freetype/freetype-2.13.3.tar.xz"
    download_pkg "fontconfig" "https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.xz"
    download_pkg "libpng" "https://downloads.sourceforge.net/libpng/libpng-1.6.47.tar.xz"

    run_in_chroot "
        cd /sources
        rm -rf libpng-[0-9]*/
        tar xf libpng-*.tar.xz
        cd libpng-[0-9]*/
        ./configure --prefix=/usr --disable-static
        make -j${NPROC}
        make install
        cd /sources && rm -rf libpng-[0-9]*/
    "
    ok "libpng built"

    run_in_chroot "
        cd /sources
        rm -rf freetype-[0-9]*/
        tar xf freetype-*.tar.xz
        cd freetype-[0-9]*/
        ./configure --prefix=/usr --enable-freetype-config --disable-static
        make -j${NPROC}
        make install
        cd /sources && rm -rf freetype-[0-9]*/
    "
    ok "freetype built"

    # gperf needed for fontconfig
    download_pkg "gperf" "https://ftp.gnu.org/gnu/gperf/gperf-3.1.tar.gz"
    run_in_chroot "
        cd /sources
        rm -rf gperf-[0-9]*/
        tar xf gperf-*.tar.gz
        cd gperf-[0-9]*/
        ./configure --prefix=/usr
        make -j${NPROC}
        make install
        cd /sources && rm -rf gperf-[0-9]*/
    "

    run_in_chroot "
        cd /sources
        rm -rf fontconfig-[0-9]*/
        tar xf fontconfig-*.tar.xz
        cd fontconfig-[0-9]*/
        ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static --disable-docs
        make -j${NPROC}
        make install
        cd /sources && rm -rf fontconfig-[0-9]*/
    "
    ok "fontconfig built"

    # Cairo and Pixman
    log "========== Building Graphics Stack =========="

    download_pkg "pixman" "https://www.cairographics.org/releases/pixman-0.44.2.tar.gz"
    download_pkg "cairo" "https://cairographics.org/releases/cairo-1.18.2.tar.xz"

    run_in_chroot "
        cd /sources
        rm -rf pixman-[0-9]*/
        tar xf pixman-*.tar.gz
        cd pixman-[0-9]*/
        mkdir build && cd build
        meson setup --prefix=/usr --buildtype=release ..
        ninja -j${NPROC}
        ninja install
        cd /sources && rm -rf pixman-[0-9]*/
    "
    ok "pixman built"

    run_in_chroot "
        cd /sources
        rm -rf cairo-[0-9]*/
        tar xf cairo-*.tar.xz
        cd cairo-[0-9]*/
        mkdir build && cd build
        meson setup --prefix=/usr --buildtype=release -Dtee=enabled ..
        ninja -j${NPROC}
        ninja install
        cd /sources && rm -rf cairo-[0-9]*/
    "
    ok "cairo built"

    # More X11 libraries needed for Mesa and Xorg
    log "========== Building Additional X11 Libraries =========="

    download_pkg "libXi" "https://www.x.org/releases/individual/lib/libXi-1.8.2.tar.xz"
    download_pkg "libXrandr" "https://www.x.org/releases/individual/lib/libXrandr-1.5.4.tar.xz"
    download_pkg "libXcursor" "https://www.x.org/releases/individual/lib/libXcursor-1.2.3.tar.xz"
    download_pkg "libXinerama" "https://www.x.org/releases/individual/lib/libXinerama-1.1.5.tar.xz"
    download_pkg "libXcomposite" "https://www.x.org/releases/individual/lib/libXcomposite-0.4.6.tar.xz"
    download_pkg "libXdamage" "https://www.x.org/releases/individual/lib/libXdamage-1.1.6.tar.xz"
    download_pkg "libXtst" "https://www.x.org/releases/individual/lib/libXtst-1.2.5.tar.xz"
    download_pkg "libXt" "https://www.x.org/releases/individual/lib/libXt-1.3.1.tar.xz"
    download_pkg "libXmu" "https://www.x.org/releases/individual/lib/libXmu-1.2.1.tar.xz"
    download_pkg "libXpm" "https://www.x.org/releases/individual/lib/libXpm-3.5.17.tar.xz"
    download_pkg "libXaw" "https://www.x.org/releases/individual/lib/libXaw-1.0.16.tar.xz"
    download_pkg "libxshmfence" "https://www.x.org/releases/individual/lib/libxshmfence-1.3.3.tar.xz"
    download_pkg "libxkbfile" "https://www.x.org/releases/individual/lib/libxkbfile-1.1.3.tar.xz"
    download_pkg "libpciaccess" "https://www.x.org/releases/individual/lib/libpciaccess-0.18.1.tar.xz"
    download_pkg "libxcvt" "https://www.x.org/releases/individual/lib/libxcvt-0.1.3.tar.xz"
    download_pkg "libfontenc" "https://www.x.org/releases/individual/lib/libfontenc-1.1.8.tar.xz"
    download_pkg "libXfont2" "https://www.x.org/releases/individual/lib/libXfont2-2.0.7.tar.xz"
    download_pkg "libICE" "https://www.x.org/releases/individual/lib/libICE-1.1.2.tar.xz"
    download_pkg "libSM" "https://www.x.org/releases/individual/lib/libSM-1.2.5.tar.xz"

    # Build these X11 libraries
    for lib in libXi libXrandr libXcursor libXinerama libXcomposite libXdamage libXtst libxshmfence libxkbfile libpciaccess libfontenc libICE; do
        run_in_chroot "
            cd /sources
            rm -rf ${lib}-[0-9]*/
            tar xf ${lib}-*.tar.xz
            cd ${lib}-[0-9]*/
            ./configure --prefix=/usr --disable-static
            make -j${NPROC}
            make install
            cd /sources && rm -rf ${lib}-[0-9]*/
        "
        ok "${lib} built"
    done

    # libSM needs libICE first
    run_in_chroot "
        cd /sources
        rm -rf libSM-[0-9]*/
        tar xf libSM-*.tar.xz
        cd libSM-[0-9]*/
        ./configure --prefix=/usr --disable-static
        make -j${NPROC}
        make install
        cd /sources && rm -rf libSM-[0-9]*/
    "
    ok "libSM built"

    # libXt needs libICE/libSM
    run_in_chroot "
        cd /sources
        rm -rf libXt-[0-9]*/
        tar xf libXt-*.tar.xz
        cd libXt-[0-9]*/
        ./configure --prefix=/usr --disable-static
        make -j${NPROC}
        make install
        cd /sources && rm -rf libXt-[0-9]*/
    "
    ok "libXt built"

    # libXmu needs libXt
    run_in_chroot "
        cd /sources
        rm -rf libXmu-[0-9]*/
        tar xf libXmu-*.tar.xz
        cd libXmu-[0-9]*/
        ./configure --prefix=/usr --disable-static
        make -j${NPROC}
        make install
        cd /sources && rm -rf libXmu-[0-9]*/
    "
    ok "libXmu built"

    # libXpm and libXaw
    for lib in libXpm libXaw; do
        run_in_chroot "
            cd /sources
            rm -rf ${lib}-[0-9]*/
            tar xf ${lib}-*.tar.xz
            cd ${lib}-[0-9]*/
            ./configure --prefix=/usr --disable-static
            make -j${NPROC}
            make install
            cd /sources && rm -rf ${lib}-[0-9]*/
        "
        ok "${lib} built"
    done

    # libxcvt (meson)
    run_in_chroot "
        cd /sources
        rm -rf libxcvt-[0-9]*/
        tar xf libxcvt-*.tar.xz
        cd libxcvt-[0-9]*/
        mkdir build && cd build
        meson setup --prefix=/usr --buildtype=release ..
        ninja -j${NPROC}
        ninja install
        cd /sources && rm -rf libxcvt-[0-9]*/
    "
    ok "libxcvt built"

    # libXfont2 needs libfontenc and freetype
    run_in_chroot "
        cd /sources
        rm -rf libXfont2-[0-9]*/
        tar xf libXfont2-*.tar.xz
        cd libXfont2-[0-9]*/
        ./configure --prefix=/usr --disable-static
        make -j${NPROC}
        make install
        cd /sources && rm -rf libXfont2-[0-9]*/
    "
    ok "libXfont2 built"

    # drm library needed for Mesa
    download_pkg "libdrm" "https://dri.freedesktop.org/libdrm/libdrm-2.4.124.tar.xz"
    run_in_chroot "
        cd /sources
        rm -rf libdrm-[0-9]*/
        tar xf libdrm-*.tar.xz
        cd libdrm-[0-9]*/
        mkdir build && cd build
        meson setup --prefix=/usr --buildtype=release -Dudev=false ..
        ninja -j${NPROC}
        ninja install
        cd /sources && rm -rf libdrm-[0-9]*/
    "
    ok "libdrm built"

    log "========== Building Mesa (with GBM/EGL/glamor) =========="

    # Install mako Python module for Mesa
    run_in_chroot "
        pip3 install mako 2>/dev/null || python3 -m pip install mako || {
            cd /sources
            curl -LO https://files.pythonhosted.org/packages/source/M/Mako/mako-1.3.8.tar.gz
            tar xf mako-*.tar.gz
            cd Mako-[0-9]*/
            python3 setup.py install
            cd /sources && rm -rf Mako-[0-9]*/
        }
    "
    ok "mako installed"

    # Download and build Mesa with GBM/EGL/virgl for VM support
    download_pkg "mesa" "https://archive.mesa3d.org/mesa-24.3.4.tar.xz"
    run_in_chroot "
        cd /sources
        rm -rf mesa-[0-9]*/
        tar xf mesa-*.tar.xz
        cd mesa-[0-9]*/
        mkdir build && cd build

        # Build Mesa with GBM, EGL, GLX for glamor acceleration
        # softpipe = CPU fallback, virgl = VM GPU passthrough
        meson setup --prefix=/usr --buildtype=release \
            -Dplatforms=x11 \
            -Dgallium-drivers=softpipe,virgl \
            -Degl=enabled \
            -Dgbm=enabled \
            -Dglx=dri \
            -Dgles1=disabled \
            -Dgles2=disabled \
            -Dllvm=disabled \
            -Dvalgrind=disabled \
            -Dvulkan-drivers= \
            ..

        ninja -j${NPROC}
        ninja install
        cd /sources && rm -rf mesa-[0-9]*/
    "
    ok "Mesa built with GBM/EGL/virgl support"

    log "========== Building Xorg Server (with glamor) =========="

    # xkbcomp and xkeyboard-config needed for keyboard support
    download_pkg "xkbcomp" "https://www.x.org/releases/individual/app/xkbcomp-1.4.7.tar.xz"
    download_pkg "xkeyboard-config" "https://www.x.org/releases/individual/data/xkeyboard-config/xkeyboard-config-2.43.tar.xz"

    run_in_chroot "
        cd /sources
        rm -rf xkbcomp-[0-9]*/
        tar xf xkbcomp-*.tar.xz
        cd xkbcomp-[0-9]*/
        ./configure --prefix=/usr
        make -j${NPROC}
        make install
        cd /sources && rm -rf xkbcomp-[0-9]*/
    "
    ok "xkbcomp built"

    run_in_chroot "
        cd /sources
        rm -rf xkeyboard-config-[0-9]*/
        tar xf xkeyboard-config-*.tar.xz
        cd xkeyboard-config-[0-9]*/
        mkdir build && cd build
        meson setup --prefix=/usr --buildtype=release ..
        ninja -j${NPROC}
        ninja install
        cd /sources && rm -rf xkeyboard-config-[0-9]*/
    "
    ok "xkeyboard-config built"

    # font-util needed for fonts
    download_pkg "font-util" "https://www.x.org/releases/individual/font/font-util-1.4.1.tar.xz"
    run_in_chroot "
        cd /sources
        rm -rf font-util-[0-9]*/
        tar xf font-util-*.tar.xz
        cd font-util-[0-9]*/
        ./configure --prefix=/usr
        make -j${NPROC}
        make install
        cd /sources && rm -rf font-util-[0-9]*/
    "
    ok "font-util built"

    # Xorg server with glamor for modesetting acceleration
    download_pkg "xorg-server" "https://www.x.org/releases/individual/xserver/xorg-server-21.1.15.tar.xz"
    run_in_chroot "
        cd /sources
        rm -rf xorg-server-[0-9]*/
        tar xf xorg-server-*.tar.xz
        cd xorg-server-[0-9]*/
        mkdir build && cd build

        # Build Xorg with glamor for GPU acceleration via modesetting driver
        # Disable udev (requires systemd), use built-in device detection
        meson setup --prefix=/usr --buildtype=release \
            -Dglamor=true \
            -Dxorg=true \
            -Dxephyr=false \
            -Dxnest=false \
            -Dxvfb=false \
            -Dudev=false \
            -Dudev_kms=false \
            -Dhal=false \
            -Dsystemd_logind=false \
            -Ddri2=true \
            -Ddri3=true \
            -Dglx=true \
            -Dlibunwind=false \
            -Dsuid_wrapper=false \
            -Ddefault_font_path=/usr/share/fonts/X11 \
            ..

        ninja -j${NPROC}
        ninja install
        cd /sources && rm -rf xorg-server-[0-9]*/
    "
    ok "Xorg server built with glamor support"

    # Create Xorg config for modesetting driver
    run_in_chroot "
        mkdir -p /etc/X11/xorg.conf.d

        # Modesetting driver config (uses glamor for acceleration)
        cat > /etc/X11/xorg.conf.d/20-modesetting.conf << 'XCONF'
Section \"Device\"
    Identifier  \"Modesetting Graphics\"
    Driver      \"modesetting\"
    Option      \"AccelMethod\" \"glamor\"
    Option      \"DRI\" \"3\"
EndSection
XCONF

        # Input device config using evdev
        cat > /etc/X11/xorg.conf.d/10-evdev.conf << 'XCONF'
Section \"InputClass\"
    Identifier \"evdev keyboard catchall\"
    MatchIsKeyboard \"on\"
    MatchDevicePath \"/dev/input/event*\"
    Driver \"evdev\"
EndSection

Section \"InputClass\"
    Identifier \"evdev pointer catchall\"
    MatchIsPointer \"on\"
    MatchDevicePath \"/dev/input/event*\"
    Driver \"evdev\"
EndSection
XCONF
    "
    ok "Xorg configuration created"

    # evdev input driver
    download_pkg "xf86-input-evdev" "https://www.x.org/releases/individual/driver/xf86-input-evdev-2.10.6.tar.bz2"
    run_in_chroot "
        cd /sources
        rm -rf xf86-input-evdev-[0-9]*/
        tar xf xf86-input-evdev-*.tar.bz2
        cd xf86-input-evdev-[0-9]*/
        ./configure --prefix=/usr
        make -j${NPROC}
        make install
        cd /sources && rm -rf xf86-input-evdev-[0-9]*/
    "
    ok "xf86-input-evdev built"

    log "========== X11 and Mesa Complete =========="
    log "Modesetting driver with glamor acceleration enabled"
    log "VirtIO GPU driver available for VM graphics"

    stage_end "Desktop"
    mark_stage_done "desktop"
}

# ============================================================================
# Main execution
# ============================================================================
main() {
    log "LFS Build Started"
    log "Target: ${TARGET_STAGE}"
    log "LFS mount: ${LFS}"
    log "CPUs: ${NPROC}"
    log ""

    check_prereqs

    case "${TARGET_STAGE}" in
        all)
            should_run_stage download && stage_download
            should_run_stage toolchain && stage_toolchain
            should_run_stage temptools && stage_temptools
            should_run_stage chroot-prep && stage_chroot_prep
            should_run_stage base && stage_base
            should_run_stage config && stage_config
            should_run_stage kernel && stage_kernel
            should_run_stage bootloader && stage_bootloader
            should_run_stage desktop && stage_desktop
            ;;
        download) stage_download ;;
        toolchain) stage_toolchain ;;
        temptools) stage_temptools ;;
        chroot-prep) stage_chroot_prep ;;
        base) stage_base ;;
        config) stage_config ;;
        kernel) stage_kernel ;;
        bootloader) stage_bootloader ;;
        desktop) stage_desktop ;;
    esac

    # Report timing
    local build_end=$(date +%s)
    local duration=$((build_end - BUILD_START))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))

    echo ""
    echo "=============================================="
    ok "LFS Build Complete!"
    echo "Total time: ${hours}h ${minutes}m ${seconds}s"
    echo "=============================================="
}

main "$@"
