# /etc/profile.d/optimization-flags.sh
# System-wide compiler optimization for AMD Ryzen 9 5950X (Zen 3)
#
# These flags are inherited by pip, cargo, go, and any build that
# respects standard environment variables.

# C/C++ compiler flags (safe defaults, no -ffast-math)
export CFLAGS="-O3 -march=znver3 -mtune=znver3 -pipe -flto=auto -fuse-linker-plugin"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O2 -Wl,--as-needed -flto=auto -fuse-linker-plugin"

# Rust: target Zen 3
export RUSTFLAGS="-C target-cpu=znver3 -C opt-level=3"

# Go: use x86-64-v3 (AVX2, etc.)
export GOAMD64="v3"

# Make: use all cores by default
export MAKEFLAGS="-j$(nproc)"

# ccache: use if available
if command -v ccache >/dev/null 2>&1; then
    export PATH="/usr/lib/ccache/bin:${PATH}"
fi
