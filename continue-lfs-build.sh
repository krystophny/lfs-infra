#!/bin/bash
# LFS Build Continuation Script
# Run this script to continue the LFS build after glibc-pass1 completed
#
# Usage: sudo ./continue-lfs-build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source safety library for validated operations
source "${SCRIPT_DIR}/scripts/lib/safety.sh"

# Configuration
export LFS="${LFS:-/mnt/lfs}"
TARGET=x86_64-lfs-linux-gnu

# Run safety checks from library
safety_check

# Verify cross-toolchain exists
if [ ! -d "$LFS/var/tmp/lfs-bootstrap/bin" ]; then
    _safety_die "Cross-toolchain not found at $LFS/var/tmp/lfs-bootstrap/bin"
fi

SYSROOT=$LFS
SOURCES=$LFS/usr/src
NPROC=$(nproc)

# Cross-toolchain is IN $LFS, not on host!
export PATH=$LFS/var/tmp/lfs-bootstrap/bin:$PATH

# pk installs to PK_ROOT - MUST be set for pk safety check
export PK_ROOT=$LFS

# Full path to pk script (never use bare 'pk')
PK="${SCRIPT_DIR}/pk"

echo "=== LFS Build Continuation Script ==="
echo "LFS=$LFS"
echo "TARGET=$TARGET"
echo "PK_ROOT=$PK_ROOT"
echo "PATH includes: $LFS/var/tmp/lfs-bootstrap/bin"
echo "NPROC=$NPROC"
echo "PK=$PK"

# Verify cross-compiler works
echo ""
echo "=== Verifying cross-toolchain ==="
${TARGET}-gcc --version | head -1

# Step 1: Complete glibc-pass1 post-install steps
echo ""
echo "=== Step 1: Completing glibc-pass1 post-install ==="

PKG=$LFS/usr/src/glibc-pass1/pkg

if [ -d "$PKG/usr/lib" ] && [ -f "$PKG/usr/lib/libc.so.6" ]; then
    echo "glibc-pass1 package found, completing post-install..."

    # Create lib64 directory and symlinks
    mkdir -pv "$PKG/lib64"
    ln -sfv ../lib/ld-linux-x86-64.so.2 "$PKG/lib64/ld-linux-x86-64.so.2"
    ln -sfv ../lib/ld-linux-x86-64.so.2 "$PKG/lib64/ld-lsb-x86-64.so.3"

    # Fix ldd RTLDLIST - remove /usr prefix
    if [ -f "$PKG/usr/bin/ldd" ]; then
        sed -i '/RTLDLIST=/s@/usr@@g' "$PKG/usr/bin/ldd"
        echo "Fixed ldd RTLDLIST:"
        grep RTLDLIST "$PKG/usr/bin/ldd"
    fi

    echo "glibc-pass1 post-install complete!"
else
    echo "ERROR: glibc-pass1 package not found at $PKG"
    echo "Please build glibc-pass1 first."
    exit 1
fi

# Step 2: Install glibc-pass1 to LFS sysroot using pk
echo ""
echo "=== Step 2: Installing glibc-pass1 to $LFS ==="

cd "$LFS/usr/src/glibc-pass1"
if [ ! -f "glibc-pass1-2.40.pkg.tar.xz" ]; then
    echo "Creating glibc-pass1 package..."
    tar -C pkg -cvJf glibc-pass1-2.40.pkg.tar.xz .
fi

# Install with pk - PK_ROOT=$LFS ensures it goes to $LFS, not host!
echo "Installing glibc-pass1 with pk (PK_ROOT=$PK_ROOT)..."
"$PK" i glibc-pass1-2.40.pkg.tar.xz

echo "glibc-pass1 installed to $LFS!"
ls -la $LFS/lib64/

# Step 3: Build libstdc++-pass1
echo ""
echo "=== Step 3: Building libstdc++-pass1 ==="

GCCVER=$(ls $SOURCES | grep -E '^gcc-[0-9]' | head -1 | sed 's/gcc-//')

# Check if GCC source exists
if [ ! -d "$SOURCES/gcc-$GCCVER" ]; then
    echo "Looking for GCC source..."
    for f in $SOURCES/gcc-*.tar.*; do
        if [ -f "$f" ]; then
            echo "Extracting $f..."
            cd $SOURCES
            tar xf "$f"
            break
        fi
    done
    GCCVER=$(ls $SOURCES | grep -E '^gcc-[0-9]' | head -1 | sed 's/gcc-//')
fi

if [ -z "$GCCVER" ]; then
    echo "ERROR: GCC source not found in $SOURCES"
    exit 1
fi

echo "Using GCC version: $GCCVER"

LIBSTDCXX_DIR="$LFS/usr/src/libstdcxx-pass1"
mkdir -p "$LIBSTDCXX_DIR"

# Use safe_rm_rf from safety library to ensure paths are within LFS
safe_rm_rf "$LIBSTDCXX_DIR/build"
safe_rm_rf "$LIBSTDCXX_DIR/pkg"
mkdir -p "$LIBSTDCXX_DIR/build" "$LIBSTDCXX_DIR/pkg"

GCCSRC="$SOURCES/gcc-$GCCVER"

# Get GCC C++ version for include path
GCCPPVER=$(grep 'version_string' $GCCSRC/gcc/version.c 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "16.0.1")
echo "GCC C++ version: $GCCPPVER"

cd "$LIBSTDCXX_DIR/build"

PKG="$LIBSTDCXX_DIR/pkg"

# Configure libstdc++
# --prefix=/usr because files go to $LFS/usr via DESTDIR or pk
# --with-gxx-include-dir puts headers where cross-compiler can find them
# Note: This path is INSIDE $LFS since cross-compiler sysroot is $LFS
$GCCSRC/libstdc++-v3/configure \
    --host=$TARGET \
    --build=$($GCCSRC/config.guess) \
    --prefix=/usr \
    --disable-multilib \
    --disable-nls \
    --disable-libstdcxx-pch \
    --with-gxx-include-dir=/var/tmp/lfs-bootstrap/$TARGET/include/c++/$GCCPPVER

# Build libstdc++
make -j$NPROC

# Install libstdc++ to package directory
make DESTDIR=$PKG install

# Remove .la files
rm -fv $PKG/usr/lib/lib{stdc++{,exp,fs},supc++}.la

echo "libstdc++-pass1 build complete!"

# Create package and install with pk
cd "$LIBSTDCXX_DIR"
tar -C pkg -cvJf libstdcxx-pass1-$GCCVER.pkg.tar.xz .

# Install with pk (PK_ROOT=$LFS)
echo "Installing libstdc++-pass1 with pk (PK_ROOT=$PK_ROOT)..."
"$PK" i libstdcxx-pass1-$GCCVER.pkg.tar.xz

echo ""
echo "=== Stage 1 Bootstrap Complete! ==="
echo ""
echo "Installed packages (in $LFS):"
"$PK" l
echo ""
echo "Cross-toolchain: $LFS/var/tmp/lfs-bootstrap"
echo "Sysroot libraries: $LFS/usr/lib"
echo ""
echo "Next steps:"
echo "  1. Build Stage 2 temporary tools (m4, ncurses, bash, etc.)"
echo "  2. Enter chroot and build Stage 3+ packages"
echo ""
