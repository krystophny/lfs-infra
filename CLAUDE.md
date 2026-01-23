# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LFS-infra is an infrastructure repository for Linux From Scratch (LFS) with bleeding-edge packages, aggressive performance optimizations, btrfs snapshots, and fully automated builds.

Uses **fay** (Fast Archive Yielder) - a minimal Fortran package manager for .pkg.tar.xz files.

All builds run **sandboxed in Docker** for safety - no risk to the host system.

## Architecture

```
lfs-infra/
├── packages.toml           # Master package list with versions, URLs, and build commands
├── fay/                    # Fast Archive Yielder package manager (Fortran)
│   ├── fay.f90             # Single-file package manager
│   └── Makefile            # Builds fay with static libarchive
├── config/
│   ├── lfs.conf            # LFS build configuration
│   ├── etc/                # System configuration files (init, fstab, etc.)
│   └── user/               # User config (XFCE, themes, etc.)
├── docker/
│   └── build-lfs-docker.sh # Main USB build script (runs in Docker)
├── scripts/
│   ├── lib/safety.sh       # Safety library
│   ├── build/
│   │   └── build-lfs.sh    # Master build orchestrator (fay-based)
│   └── vm/
│       ├── setup-disk.sh   # Create disk with btrfs + snapshots
│       └── run-vm.sh       # Run LFS in QEMU/KVM
└── version-checker/check-versions.sh
```

## fay - Fast Archive Yielder

Minimal package manager written in Fortran with iso_c_binding to libarchive:

```bash
fay i <pkg.tar.xz>    # Install package
fay r <pkgname>       # Remove package
fay l                 # List installed
fay q <pkgname>       # Query package info
fay f <pkgname>       # List package files
fay v                 # Version
```

Database: `/var/lib/fay/<pkgname>/` with `info` and `files`

Build fay:
```bash
cd fay
make bootstrap                    # Minimal (zlib only)
make full                         # Full (all compression)
LFS_GENERIC_BUILD=1 make          # Portable USB build
```

## Optimization Flags

**USB Build** (`LFS_GENERIC_BUILD=1`):
- `-O3 -march=x86-64-v2 -mtune=generic`
- Portable, boots on any x86-64-v2+ CPU

**Final Install** (default):
- `-O3 -march=native -mtune=native`
- Maximum performance for target hardware

## Quick Start (USB Creation via Docker)

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

```bash
# 1. Create disk image with btrfs
sudo ./scripts/vm/setup-disk.sh create

# 2. Mount the disk
sudo ./scripts/vm/setup-disk.sh mount
export LFS=/mnt/lfs

# 3. Run full automatic build
sudo ./scripts/build/build-lfs.sh all

# 4. Create snapshot and test in VM
sudo ./scripts/vm/setup-disk.sh snapshot pre-boot
./scripts/vm/run-vm.sh kernel

# 5. If something breaks, rollback
sudo ./scripts/vm/setup-disk.sh rollback pre-boot
```

## Environment Variables (.env)

```bash
LFS_BUILD_DIR=/var/tmp/ert        # Build directory
LFS_GENERIC_BUILD=1               # Use portable flags for USB
LFS_USERNAME=lfs                  # USB system username
LFS_PASSWORD=                     # User password
WIFI_SSID=                        # WiFi network (optional)
WIFI_PASSWORD=                    # WiFi password
LAN_MODE=1                        # 1=DHCP, 2=Static
```

## Package Definition Schema (packages.toml)

```toml
[packages.example]
version = "1.0.0"
description = "Example package"
url = "https://example.com/pkg-${version}.tar.xz"
stage = 4

# Custom build commands
build_commands = [
    "./configure --prefix=/usr",
    "make -j${NPROC}",
    "make DESTDIR=${PKG} install"
]

# Files to check for idempotency
provides = ["/usr/lib/libexample.so", "/usr/bin/example"]
```

## Build Stages

1. **Stage 1**: Cross-toolchain (binutils, gcc, glibc, linux-headers) - direct install
2. **Stage 2**: Temporary tools (bash, coreutils, make, etc.)
3. **Stage 3**: Basic system (zlib, readline, perl, python)
4. **Stage 4**: System config (openssl, gnutls, meson, ninja, cmake)
5. **Stage 5**: Kernel and bootloader

Stage 1 installs directly (no packaging). Stages 2+ use fay for .pkg.tar.xz management.

## Key Variables

- `LFS=/var/tmp/ert` - Default LFS build directory
- `LFS_TGT=$(uname -m)-lfs-linux-gnu` - Target triplet
- `NPROC=$(nproc)` - Auto-detected CPU cores
- `PKG` - Package install directory (for DESTDIR)
- `FAY_ROOT` - Root prefix for fay database

## Idempotent Builds

- Stage 1: checks `provides` files exist
- Stage 2+: checks `/var/lib/fay/<pkg>/` exists
- Re-running `build-lfs.sh` only builds missing packages
- Use btrfs snapshots for safe experimentation
