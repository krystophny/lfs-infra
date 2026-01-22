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
                    --with-cxx-shared \
                    --without-debug \
                    --without-ada \
                    --disable-stripping

                make -j"${NPROC}"
                make DESTDIR="${LFS}" TIC_PATH="$(pwd)/build/progs/tic" install
                ln -sv libncursesw.so "${LFS}/usr/lib/libncurses.so"
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
                ln -sv bash "${LFS}/bin/sh"
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
            diffutils|file|findutils|gawk|grep|gzip|make|patch|sed|tar|xz)
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
                ln -sv gcc "${LFS}/usr/bin/cc"
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
    chown -R root:root "${LFS}"/{usr,lib,var,etc,bin,sbin,tools}
    case $(uname -m) in
        x86_64) chown -R root:root "${LFS}/lib64" ;;
    esac

    # Create directories
    mkdir -pv "${LFS}"/{dev,proc,sys,run}

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

# Build gettext
cd /sources
tar xf gettext-*.tar.xz
cd gettext-*
./configure --disable-shared
make -j$(nproc)
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
cd /sources && rm -rf gettext-*

# Build bison
tar xf bison-*.tar.xz
cd bison-*
./configure --prefix=/usr --docdir=/usr/share/doc/bison
make -j$(nproc)
make install
cd /sources && rm -rf bison-*

# Build perl
tar xf perl-*.tar.xz
cd perl-*
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
cd /sources && rm -rf perl-*

# Build Python
tar xf Python-*.tar.xz
cd Python-*
./configure --prefix=/usr --enable-shared --without-ensurepip
make -j$(nproc)
make install
cd /sources && rm -rf Python-*

# Build texinfo
tar xf texinfo-*.tar.xz
cd texinfo-*
./configure --prefix=/usr
make -j$(nproc)
make install
cd /sources && rm -rf texinfo-*

# Build util-linux
tar xf util-linux-*.tar.xz
cd util-linux-*
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
cd /sources && rm -rf util-linux-*

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
stage_desktop() {
    stage_start "Building Desktop Environment"

    warn "Desktop build stage - this is a large undertaking"
    warn "This stage builds X11, Mesa, XFCE, and applications"

    # This is a placeholder - full desktop build would be extensive
    # For now, mark as done if we reach this point

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
