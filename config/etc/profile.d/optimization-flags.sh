# /etc/profile.d/optimization-flags.sh
# System-wide compiler flags: only -O3 and LTO (what actually matters)

# C/C++ compiler flags
export CFLAGS="-O3 -march=native -mtune=native -pipe -flto=auto -fuse-linker-plugin"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O2 -Wl,--as-needed -flto=auto -fuse-linker-plugin"

# Fortran
export FFLAGS="-O3 -march=native -mtune=native -pipe"
export FCFLAGS="${FFLAGS}"

# Rust (native CPU detection)
export RUSTFLAGS="-C target-cpu=native -C opt-level=3"

# Go (auto-detects CPU features)
export GOAMD64="v3"

# Make: use all cores
export MAKEFLAGS="-j$(nproc)"

# ccache: use if available
if command -v ccache >/dev/null 2>&1; then
    export PATH="/usr/lib/ccache/bin:${PATH}"
fi
