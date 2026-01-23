# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

LFS-infra is an automated Linux From Scratch build system with bleeding-edge packages (GCC 16, Linux 6.18, glibc 2.42), btrfs snapshots, and aggressive performance optimizations.

**Primary workflow**: Boot from Fedora Rawhide live USB, run `./install.sh /dev/nvme0n1` to install LFS on target device.

Uses **pk** - a minimal POSIX shell package manager (120 lines, zero dependencies).

## Architecture

```
lfs-infra/
├── install.sh              # Main installation script (run this!)
├── pk                      # Package manager (shell script)
├── packages.toml           # Package definitions
├── .env.example            # Configuration template
├── config/
│   ├── lfs.conf            # Build configuration
│   ├── build.conf          # Optimization flags
│   ├── etc/                # System config templates
│   ├── iwd/                # WiFi configuration
│   ├── kernel/             # Kernel configs
│   └── runit/              # Init system
├── scripts/
│   ├── build/
│   │   ├── build-lfs.sh    # Build orchestrator
│   │   └── download-sources.sh
│   └── lib/
│       └── safety.sh       # Safety library
└── version-checker/
    └── check-versions.sh   # Version checker
```

## Quick Start

```bash
# From Fedora Rawhide live USB
sudo ./install.sh /dev/nvme0n1

# Or with .env for unattended install
cp .env.example .env
# Edit .env
sudo ./install.sh --yes /dev/nvme0n1
```

## pk - Package Manager

```bash
pk i <pkg.tar.xz>    # Install package
pk r <pkgname>       # Remove package
pk l                 # List installed
pk q <pkgname>       # Query package info
pk f <pkgname>       # List package files
```

Database: `/var/lib/pk/<pkgname>/` with `info` and `files`

## Environment Variables

From `.env` or command line:

| Variable | Default | Description |
|----------|---------|-------------|
| LFS_DEVICE | (required) | Target device |
| LFS_MOUNT | /mnt/lfs | Mount point |
| LFS_USERNAME | (prompt) | Username |
| LFS_PASSWORD | (prompt) | Password |
| LFS_HOSTNAME | lfs | Hostname |
| LFS_SWAP_SIZE | 16G | Swap size (0 to disable) |
| WIFI_SSID | - | WiFi network |
| WIFI_PASSWORD | - | WiFi password |
| LAN_IP | - | Static IP |
| LAN_INTERFACE | eth0 | LAN interface |

## Package Definition (packages.toml)

```toml
[packages.example]
version = "1.0.0"
url = "https://example.com/pkg-${version}.tar.xz"
stage = 4
build_commands = [
    "./configure --prefix=/usr",
    "make -j${NPROC}",
    "make DESTDIR=${PKG} install"
]
```

## Build Stages

1. **Stage 1**: Cross-toolchain (binutils, gcc, glibc, linux-headers)
2. **Stage 2**: Temporary tools (bash, coreutils, make, etc.)
3. **Stage 3**: Basic system (zlib, readline, perl, python)
4. **Stage 4**: System packages (openssl, meson, cmake)
5. **Stage 5**: Kernel and bootloader

## Filesystem

- **btrfs** with zstd compression
- Subvolumes: `@` (root), `@home`, `@snapshots`
- Automatic `fresh-install` snapshot created

## Key Commands

```bash
# Check for package updates
./version-checker/check-versions.sh -r    # Compare with Fedora Rawhide

# Build specific package
./scripts/build/build-lfs.sh <package>

# Build all
./scripts/build/build-lfs.sh all
```
