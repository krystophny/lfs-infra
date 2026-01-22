#!/bin/bash
# LFS Chroot Setup Script
# Prepares and enters the LFS chroot environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# Source safety library first
source "${ROOT_DIR}/scripts/lib/safety.sh"
safety_check

source "${ROOT_DIR}/config/lfs.conf"
source "${ROOT_DIR}/config/build.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check root
if [[ ${EUID} -ne 0 ]]; then
    log_error "This script must be run as root"
fi

# Change ownership
change_ownership() {
    log_info "Changing ownership to root..."

    chown -R root:root "${LFS}"/{usr,lib,var,etc,bin,sbin}
    [[ -d "${LFS}/lib64" ]] && chown -R root:root "${LFS}/lib64"
    chown -R root:root "${LFS}/tools"

    log_ok "Ownership changed"
}

# Create virtual filesystems
setup_virtual_fs() {
    log_info "Setting up virtual filesystems..."

    mkdir -pv "${LFS}"/{dev,proc,sys,run}

    # /dev
    mount -v --bind /dev "${LFS}/dev"
    mount -vt devpts devpts -o gid=5,mode=0620 "${LFS}/dev/pts"

    # /proc
    mount -vt proc proc "${LFS}/proc"

    # /sys
    mount -vt sysfs sysfs "${LFS}/sys"

    # /run
    mount -vt tmpfs tmpfs "${LFS}/run"

    # Symlink /dev/shm
    if [ -h "${LFS}/dev/shm" ]; then
        install -v -d -m 1777 "${LFS}$(realpath /dev/shm)"
    else
        mount -vt tmpfs -o nosuid,nodev tmpfs "${LFS}/dev/shm"
    fi

    log_ok "Virtual filesystems mounted"
}

# Create essential files
create_essential_files() {
    log_info "Creating essential files..."

    # /etc/passwd
    cat > "${LFS}/etc/passwd" << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

    # /etc/group
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

    # Test files
    echo "127.0.0.1 localhost $(hostname)" > "${LFS}/etc/hosts"
    touch "${LFS}/var/log"/{btmp,lastlog,faillog,wtmp}
    chgrp -v utmp "${LFS}/var/log/lastlog"
    chmod -v 664 "${LFS}/var/log/lastlog"
    chmod -v 600 "${LFS}/var/log/btmp"

    log_ok "Essential files created"
}

# Copy build scripts to LFS
copy_build_scripts() {
    log_info "Copying build scripts to LFS..."

    mkdir -p "${LFS}/lfs-infra"
    cp -r "${ROOT_DIR}"/* "${LFS}/lfs-infra/"

    log_ok "Build scripts copied"
}

# Create chroot build script
create_chroot_build_script() {
    log_info "Creating chroot build script..."

    cat > "${LFS}/lfs-infra/scripts/build/build-system.sh" << 'BUILDSCRIPT'
#!/bin/bash
# LFS Final System Build (runs inside chroot)

set -euo pipefail

NPROC=$(nproc)
export MAKEFLAGS="-j${NPROC}"

# Aggressive optimization flags
export CFLAGS="-O3 -march=native -mtune=native -pipe -fomit-frame-pointer -flto=${NPROC}"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O2 -Wl,--as-needed -flto=${NPROC}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_step() {
    echo ""
    echo "========================================"
    echo -e "${BLUE}STEP: $*${NC}"
    echo "========================================"
}

SRC_DIR="/sources"

extract() {
    local pkg="$1"
    local tarball=$(ls ${SRC_DIR}/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -z "${tarball}" ]] && { echo "No tarball for ${pkg}"; return 1; }
    local dir=$(tar -tf "${tarball}" | head -1 | cut -d/ -f1)
    rm -rf "${dir}"
    tar -xf "${tarball}"
    cd "${dir}"
}

cleanup() {
    cd /
    rm -rf "$1"
}

# Build gettext
build_gettext() {
    log_step "Building Gettext"
    extract "gettext"
    ./configure --disable-shared
    make -j"${NPROC}"
    cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
    cleanup "gettext-*"
    log_ok "Gettext complete"
}

# Build bison
build_bison() {
    log_step "Building Bison"
    extract "bison"
    ./configure --prefix=/usr --docdir=/usr/share/doc/bison
    make -j"${NPROC}"
    make install
    cleanup "bison-*"
    log_ok "Bison complete"
}

# Build perl
build_perl() {
    log_step "Building Perl"
    extract "perl"
    sh Configure -des \
        -D prefix=/usr \
        -D vendorprefix=/usr \
        -D useshrplib \
        -D privlib=/usr/lib/perl5/5.42/core_perl \
        -D archlib=/usr/lib/perl5/5.42/core_perl \
        -D sitelib=/usr/lib/perl5/5.42/site_perl \
        -D sitearch=/usr/lib/perl5/5.42/site_perl \
        -D vendorlib=/usr/lib/perl5/5.42/vendor_perl \
        -D vendorarch=/usr/lib/perl5/5.42/vendor_perl
    make -j"${NPROC}"
    make install
    cleanup "perl-*"
    log_ok "Perl complete"
}

# Build Python
build_python() {
    log_step "Building Python"
    extract "Python"
    ./configure --prefix=/usr \
        --enable-shared \
        --without-ensurepip \
        --enable-optimizations \
        --with-lto
    make -j"${NPROC}"
    make install
    cleanup "Python-*"
    log_ok "Python complete"
}

# Build texinfo
build_texinfo() {
    log_step "Building Texinfo"
    extract "texinfo"
    ./configure --prefix=/usr
    make -j"${NPROC}"
    make install
    cleanup "texinfo-*"
    log_ok "Texinfo complete"
}

# Build util-linux
build_util_linux() {
    log_step "Building Util-linux"
    extract "util-linux"
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
        --disable-liblastlog2 \
        --disable-static \
        --without-python \
        ADJTIME_PATH=/var/lib/hwclock/adjtime \
        --docdir=/usr/share/doc/util-linux
    make -j"${NPROC}"
    make install
    cleanup "util-linux-*"
    log_ok "Util-linux complete"
}

# Cleanup temp tools
cleanup_temp() {
    log_step "Cleaning up temporary tools"
    rm -rf /usr/share/{info,man,doc}/*
    find /usr/{lib,libexec} -name \*.la -delete
    rm -rf /tools
    log_ok "Cleanup complete"
}

# Main
main() {
    cd /sources

    build_gettext
    build_bison
    build_perl
    build_python
    build_texinfo
    build_util_linux
    cleanup_temp

    echo ""
    echo "========================================"
    echo -e "${GREEN}Basic System Build Complete${NC}"
    echo "========================================"
    echo ""
    echo "Continue with build-final-system.sh for remaining packages"
}

main "$@"
BUILDSCRIPT

    chmod +x "${LFS}/lfs-infra/scripts/build/build-system.sh"
    log_ok "Chroot build script created"
}

# Enter chroot
enter_chroot() {
    log_info "Entering chroot environment..."

    chroot "${LFS}" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM}" \
        PS1='(lfs chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        MAKEFLAGS="-j$(nproc)" \
        /bin/bash --login
}

# Main
main() {
    local action="${1:-enter}"

    echo -e "${BLUE}LFS Chroot Setup${NC}"
    echo "========================================"

    case "${action}" in
        setup)
            change_ownership
            setup_virtual_fs
            create_essential_files
            copy_build_scripts
            create_chroot_build_script
            log_ok "Chroot environment ready"
            echo ""
            echo "Run: $0 enter"
            ;;
        enter)
            enter_chroot
            ;;
        umount)
            log_info "Unmounting virtual filesystems..."
            umount -v "${LFS}/dev/shm" 2>/dev/null || true
            umount -v "${LFS}/dev/pts" 2>/dev/null || true
            umount -v "${LFS}/run" 2>/dev/null || true
            umount -v "${LFS}/sys" 2>/dev/null || true
            umount -v "${LFS}/proc" 2>/dev/null || true
            umount -v "${LFS}/dev" 2>/dev/null || true
            log_ok "Virtual filesystems unmounted"
            ;;
        *)
            echo "Usage: $0 {setup|enter|umount}"
            exit 1
            ;;
    esac
}

main "$@"
