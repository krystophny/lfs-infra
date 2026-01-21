# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LFS-infra is an infrastructure repository for Linux From Scratch (LFS) with bleeding-edge packages, aggressive performance optimizations, and pkgutils package management.

## Architecture

```
lfs-infra/
├── packages.toml           # Master package list with versions and URLs
├── packages/               # Pkgfile build recipes
├── config/
│   ├── lfs.conf            # LFS paths and settings
│   ├── build.conf          # Optimization flags
│   └── pkgmk.conf          # pkgutils configuration
├── scripts/
│   ├── setup/init-lfs.sh   # Initialize LFS environment
│   ├── build/
│   │   ├── download-sources.sh
│   │   ├── build-toolchain.sh
│   │   ├── build-temp-tools.sh
│   │   ├── build-package.sh
│   │   ├── chroot-setup.sh
│   │   └── generate-pkgfiles.sh
│   └── teardown/cleanup.sh
└── version-checker/check-versions.sh
```

## Build Commands

```bash
# Check package versions against upstream
./version-checker/check-versions.sh
./version-checker/check-versions.sh -a           # Show all packages
./version-checker/check-versions.sh -u gcc       # Update version in TOML

# Setup LFS environment (as root)
./scripts/setup/init-lfs.sh [device]

# Download all sources
./scripts/build/download-sources.sh

# Build cross-toolchain (as lfs user)
./scripts/build/build-toolchain.sh

# Build temporary tools
./scripts/build/build-temp-tools.sh

# Setup and enter chroot
./scripts/build/chroot-setup.sh setup
./scripts/build/chroot-setup.sh enter

# Build individual packages with optimizations
./scripts/build/build-package.sh gcc binutils
./scripts/build/build-package.sh -g linux        # Build from git
./scripts/build/build-package.sh -s openssl      # Safe flags (no fast-math)

# Generate Pkgfiles from packages.toml
./scripts/build/generate-pkgfiles.sh

# Cleanup
./scripts/teardown/cleanup.sh -b                 # Clean build dir
./scripts/teardown/cleanup.sh -a                 # Clean all artifacts
./scripts/teardown/cleanup.sh -f                 # Full teardown
```

## Optimization Flags

All builds use aggressive performance flags (config/build.conf):
- `-O3 -march=native -mtune=native`
- `-flto=$(nproc)` (Link-Time Optimization)
- `-ffast-math` (breaks IEEE compliance for speed)
- `-funroll-loops -fprefetch-loop-arrays -ftree-vectorize`
- Auto-parallel builds: `MAKEFLAGS="-j$(nproc)"`
- Prefers mold > lld > gold linker

Safe mode (`-s`) omits fast-math for IEEE-compliant packages (openssl, glibc, python).

## Package List (packages.toml)

Central package definitions with:
- `version` - Current version string
- `url` - Download URL template with `${version}` placeholder
- `git_url` - Git repository for HEAD builds
- `use_git` - Set to `true` for git builds
- `stage` - Build stage (1=toolchain, 2=temp tools, 3-5=system)

## Key Variables

- `LFS=/mnt/lfs` - LFS root mount point
- `LFS_TGT=$(uname -m)-lfs-linux-gnu` - Target triplet
- `NPROC=$(nproc)` - Auto-detected CPU cores

## Build Stages

1. **Stage 1**: Cross-toolchain (binutils, gcc, glibc, linux-headers)
2. **Stage 2**: Temporary tools (bash, coreutils, make, etc.)
3. **Stage 3**: Basic system (zlib, readline, perl, python)
4. **Stage 4**: System config (openssl, autoconf, meson, ninja)
5. **Stage 5**: Kernel and bootloader
