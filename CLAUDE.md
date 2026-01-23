# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LFS-infra is an infrastructure repository for Linux From Scratch (LFS) with bleeding-edge packages, aggressive performance optimizations, btrfs snapshots, and fully automated builds.

All builds run **sandboxed in Docker** for safety - no risk to the host system.

## Architecture

```
lfs-infra/
├── packages.toml           # Master package list with versions, URLs, and build commands
├── config/
│   ├── lfs.conf            # LFS build configuration
│   ├── pkgmk.conf          # Package manager configuration
│   ├── etc/                # System configuration files (init, fstab, etc.)
│   └── user/               # User config (XFCE, themes, etc.)
├── docker/
│   └── build-lfs-docker.sh # Main USB build script (runs in Docker)
├── scripts/
│   ├── lib/safety.sh       # Safety library
│   ├── build/
│   │   ├── build-lfs.sh    # Master build orchestrator
│   │   └── ...             # Other build scripts
│   └── vm/
│       ├── setup-disk.sh   # Create disk with btrfs + snapshots
│       └── run-vm.sh       # Run LFS in QEMU/KVM
└── version-checker/check-versions.sh
```

## Quick Start (USB Creation via Docker)

This is the recommended workflow - everything runs sandboxed in Docker.

```bash
# 1. Configure (optional - can be done interactively)
cp .env.example .env
# Edit .env with username, password, WiFi settings

# 2. Build USB image (runs in Docker, outputs to output/)
./docker/build-lfs-docker.sh --build-only

# 3. Write to USB drive
sudo dd if=output/lfs-minimal.img of=/dev/sdX bs=4M status=progress conv=fsync

# 4. Boot from USB, then install full LFS to target machine:
sudo lfs-install /dev/nvme0n1
```

## Quick Start (VM Build)

For testing or building directly (requires Linux host):

```bash
# 1. Create disk image with btrfs (supports snapshots)
sudo ./scripts/vm/setup-disk.sh create

# 2. Mount the disk
sudo ./scripts/vm/setup-disk.sh mount
export LFS=/mnt/lfs

# 3. Run full automatic build
sudo ./scripts/build/build-lfs.sh all

# 4. Create a snapshot before testing
sudo ./scripts/vm/setup-disk.sh snapshot pre-boot

# 5. Run in VM (direct kernel boot)
./scripts/vm/run-vm.sh kernel

# 6. If something breaks, rollback
sudo ./scripts/vm/setup-disk.sh rollback pre-boot
```

## Docker Build (Sandboxed)

All USB builds run inside an Arch Linux Docker container:
- Host system is never at risk
- Works on Linux and macOS (via Rosetta)
- Loop devices and partitioning happen inside container
- Output is a raw disk image that can be dd'd to USB

```bash
# Build image only (no USB write)
./docker/build-lfs-docker.sh --build-only

# Build and write to USB
./docker/build-lfs-docker.sh --device /dev/sdb

# List USB drives
./docker/build-lfs-docker.sh --list

# Clear caches and rebuild
./docker/build-lfs-docker.sh --no-cache --build-only
```

## Environment Variables (.env)

```bash
LFS_BUILD_DIR=/var/tmp/ert    # Build directory (inside Docker)
LFS_USERNAME=lfs              # USB system username
LFS_PASSWORD=                 # User password
WIFI_SSID=                    # WiFi network (optional)
WIFI_PASSWORD=                # WiFi password
LAN_MODE=1                    # 1=DHCP, 2=Static
LAN_IP=                       # Static IP (if LAN_MODE=2)
LAN_GATEWAY=                  # Gateway (if LAN_MODE=2)
LAN_DNS=1.1.1.1               # DNS server
```

## Disk Management (btrfs with snapshots)

```bash
# Create disk with btrfs subvolumes (@ and @snapshots)
sudo ./scripts/vm/setup-disk.sh create

# Mount (uses compression: zstd:3)
sudo ./scripts/vm/setup-disk.sh mount

# Create named snapshot
sudo ./scripts/vm/setup-disk.sh snapshot pre-desktop

# Rollback to snapshot
sudo ./scripts/vm/setup-disk.sh rollback pre-desktop

# Enter chroot for manual work
sudo ./scripts/vm/setup-disk.sh chroot

# Unmount
sudo ./scripts/vm/setup-disk.sh umount

# Show status
sudo ./scripts/vm/setup-disk.sh status
```

## Build Commands

```bash
# Full automatic build (idempotent - skips installed packages)
sudo ./scripts/build/build-lfs.sh all

# Continue from last stage
sudo ./scripts/build/build-lfs.sh -c

# Build specific stage
sudo ./scripts/build/build-lfs.sh desktop

# Check package versions against upstream
./version-checker/check-versions.sh
./version-checker/check-versions.sh -u gcc       # Update version in TOML
```

## Package Definition Schema (packages.toml)

```toml
[packages.example]
version = "1.0.0"
description = "Example package"
url = "https://example.com/pkg-${version}.tar.xz"
git_url = "https://github.com/example/pkg.git"
use_git = false
stage = 4

# Build system: autotools (default), meson, cmake, make, custom
build_system = "meson"

# Flags for each build system
configure_flags = "--disable-static --enable-feature"
meson_flags = "-Dfoo=false -Dbar=true"
cmake_flags = "-DFOO=OFF -DBAR=ON"

# Custom build commands (overrides build_system)
build_commands = [
    "./configure --prefix=/usr",
    "make -j${NPROC}",
    "make install"
]

# Files to check for idempotency (skip if all exist)
provides = ["/usr/lib/libexample.so", "/usr/bin/example"]

# Use IEEE-compliant flags (no -ffast-math)
safe_flags = true

# Dependencies (for build order)
depends = ["glib", "gtk3"]
```

## Default Build Behavior

- **autotools**: `./configure --prefix=/usr ${configure_flags} && make && make install`
- **meson**: `meson setup build --prefix=/usr ${meson_flags} && ninja -C build && ninja -C build install`
- **cmake**: `cmake -B build -DCMAKE_INSTALL_PREFIX=/usr ${cmake_flags} && cmake --build build && cmake --install build`
- **make**: `make && make PREFIX=/usr install`
- **custom**: Run each command in `build_commands` array

## Optimization Flags

All builds use aggressive performance flags:
- `-O3 -march=native -mtune=native -pipe`
- `-ffast-math` (except packages with `safe_flags = true`)
- Auto-parallel: `MAKEFLAGS="-j$(nproc)"`

Safe flags packages (no -ffast-math): openssl, glibc, python, gmp

## VM Commands

```bash
# Direct kernel boot (recommended)
./scripts/vm/run-vm.sh kernel

# Normal boot (GRUB)
./scripts/vm/run-vm.sh run

# Custom resources
./scripts/vm/run-vm.sh -m 8G -c 4 kernel

# SPICE display (better performance)
./scripts/vm/run-vm.sh --spice kernel
```

## Build Stages

1. **Stage 1**: Cross-toolchain (binutils, gcc, glibc, linux-headers)
2. **Stage 2**: Temporary tools (bash, coreutils, make, etc.)
3. **Stage 3**: Basic system (zlib, readline, perl, python)
4. **Stage 4**: System config (openssl, gnutls, meson, ninja, cmake)
5. **Stage 5**: Kernel and bootloader
6. **Stage 6-8**: System services, X11
7. **Stage 9-10**: GTK, XFCE desktop
8. **Stage 11**: Fonts and extras

## Key Variables

- `LFS=/var/tmp/ert` - Default LFS build directory
- `LFS_TGT=$(uname -m)-lfs-linux-gnu` - Target triplet
- `NPROC=$(nproc)` - Auto-detected CPU cores

## Idempotent Builds

The build system is idempotent:
- If a package has `provides` defined, it checks if those files exist
- If all provided files exist, the package is skipped
- Re-running `build-lfs.sh` only builds missing packages
- Use snapshots for safe experimentation and rollback
