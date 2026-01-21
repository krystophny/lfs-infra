#!/bin/bash
# LFS Final GCC Build (runs in chroot)
# Builds GCC with C, C++, and Fortran support + aggressive optimizations

set -euo pipefail

NPROC=$(nproc)
export MAKEFLAGS="-j${NPROC}"

# Aggressive optimizations for the compiler itself
export CFLAGS="-O3 -march=native -mtune=native -pipe"
export CFLAGS="${CFLAGS} -flto=${NPROC} -fuse-linker-plugin"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O2 -Wl,--as-needed -flto=${NPROC}"

SRC_DIR="${SRC_DIR:-/sources}"
GCC_VERSION="${GCC_VERSION:-15.2.0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_step() {
    echo ""
    echo "========================================"
    echo -e "${BLUE}$*${NC}"
    echo "========================================"
}

cd "${SRC_DIR}"

log_step "Building GCC ${GCC_VERSION} with C, C++, Fortran"

# Extract GCC
tar -xf gcc-${GCC_VERSION}.tar.xz
cd gcc-${GCC_VERSION}

# Extract and link prerequisites
for pkg in gmp mpfr mpc; do
    tarball=$(ls ../${pkg}-*.tar.* 2>/dev/null | head -1)
    if [[ -n "${tarball}" ]]; then
        log_info "Extracting ${pkg}..."
        tar -xf "${tarball}"
        mv ${pkg}-* ${pkg}
    fi
done

# Fix for x86_64
case $(uname -m) in
    x86_64)
        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
        ;;
esac

mkdir -v build
cd build

log_info "Configuring GCC..."

# Full GCC with Fortran + aggressive optimizations
../configure \
    --prefix=/usr \
    --disable-multilib \
    --disable-bootstrap \
    --disable-fixincludes \
    --with-system-zlib \
    --enable-default-pie \
    --enable-default-ssp \
    --enable-languages=c,c++,fortran \
    --enable-lto \
    --enable-plugin \
    --enable-shared \
    --enable-threads=posix \
    --enable-__cxa_atexit \
    --enable-clocale=gnu \
    --enable-gnu-indirect-function \
    --enable-linker-build-id \
    --with-linker-hash-style=gnu

log_info "Building GCC (this takes a while)..."
make -j"${NPROC}"

log_info "Installing GCC..."
make install

# Create compatibility symlinks
ln -svf ../bin/cpp /usr/lib/cpp
ln -svf gcc /usr/bin/cc
ln -svf gfortran /usr/bin/f95

# Install LTO plugin for linker
install -v -dm755 /usr/lib/bfd-plugins
ln -sfv ../../libexec/gcc/$(gcc -dumpmachine)/${GCC_VERSION}/liblto_plugin.so \
    /usr/lib/bfd-plugins/

# Sanity check
log_info "Running sanity checks..."

echo 'int main(){}' > /tmp/dummy.c
cc /tmp/dummy.c -v -Wl,--verbose &> /tmp/dummy.log
if ! readelf -l /tmp/a.out | grep -q 'interpreter:'; then
    log_error "GCC sanity check failed: no interpreter"
    exit 1
fi
rm -v /tmp/dummy.c /tmp/a.out /tmp/dummy.log

# Test Fortran
echo 'program test; print *, "Fortran works!"; end program' > /tmp/test.f90
if gfortran /tmp/test.f90 -o /tmp/test_fortran && /tmp/test_fortran | grep -q "Fortran works"; then
    log_ok "Fortran compiler working"
else
    log_error "Fortran compiler test failed"
    exit 1
fi
rm -f /tmp/test.f90 /tmp/test_fortran

# Create cc.conf for tools that need it
mkdir -pv /etc
cat > /etc/cc.conf << 'EOF'
# Compiler configuration for maximum performance
# Source this file before building performance-critical software

NPROC=$(nproc)

# Aggressive optimization flags
export CFLAGS="-O3 -march=native -mtune=native -pipe -fomit-frame-pointer"
export CFLAGS="${CFLAGS} -flto=${NPROC} -fuse-linker-plugin"
export CFLAGS="${CFLAGS} -funroll-loops -fprefetch-loop-arrays"
export CFLAGS="${CFLAGS} -ftree-vectorize -fvect-cost-model=dynamic"

export CXXFLAGS="${CFLAGS}"
export FFLAGS="${CFLAGS}"
export FCFLAGS="${CFLAGS}"

export LDFLAGS="-Wl,-O2 -Wl,--as-needed -Wl,--sort-common"
export LDFLAGS="${LDFLAGS} -flto=${NPROC} -fuse-linker-plugin"

export MAKEFLAGS="-j${NPROC}"
EOF

cd /
rm -rf "${SRC_DIR}/gcc-${GCC_VERSION}"

log_ok "GCC ${GCC_VERSION} with Fortran installed successfully"
echo ""
echo "Compilers available:"
echo "  C:       gcc, cc"
echo "  C++:     g++"
echo "  Fortran: gfortran, f95"
echo ""
echo "For maximum performance builds, source /etc/cc.conf"
