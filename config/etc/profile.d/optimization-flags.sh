# /etc/profile.d/optimization-flags.sh
# System-wide compiler optimization for AMD Ryzen 9 5950X (Zen 3)
#
# These flags are inherited by compilers and build systems that
# respect standard environment variables.

# C/C++ compiler flags (safe defaults, no -ffast-math)
export CFLAGS="-O3 -march=znver3 -mtune=znver3 -pipe -flto=auto -fuse-linker-plugin"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O2 -Wl,--as-needed -flto=auto -fuse-linker-plugin"

# Fortran (gfortran, flang)
export FFLAGS="-O3 -march=znver3 -mtune=znver3 -pipe"
export FCFLAGS="${FFLAGS}"

# Rust
export RUSTFLAGS="-C target-cpu=znver3 -C opt-level=3"

# Go
export GOAMD64="v3"

# Zig
export ZIG_FLAGS="-O ReleaseFast -target x86_64-linux"

# Nim
export NIMFLAGS="--opt:speed --passC:-march=znver3"

# Julia (JIT at runtime)
export JULIA_CPU_TARGET="znver3"

# .NET / C# (uses RyuJIT, auto-detects CPU)
export DOTNET_EnableAVX2=1
export DOTNET_TieredCompilation=1

# Java/Scala (HotSpot/GraalVM auto-detect CPU)
# Hint: can use -XX:+UseAVX2 if needed

# Vala/GNOME (compiles to C, uses CFLAGS) - inherited ✓

# Node.js/V8 (auto-detects AVX2)
export NODE_OPTIONS="--max-old-space-size=8192"

# Make: use all cores
export MAKEFLAGS="-j$(nproc)"

# ccache: use if available
if command -v ccache >/dev/null 2>&1; then
    export PATH="/usr/lib/ccache/bin:${PATH}"
fi
