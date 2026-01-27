# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## CRITICAL: Package Installation Rules

**ALWAYS use pk for ALL package installations. NEVER install anything ad-hoc.**

1. Package definitions are in **pk repo**: `/home/ert/code/pk/packages/*.toml` (split alphabetically: a.toml, b.toml, etc.)
2. If a package exists, use `pk b <pkgname>` (build) and `pk i <pkg.pk.tar.xz>` (install)
3. If a package does NOT exist, ADD IT FIRST to the appropriate `<letter>.toml` file, then build/install via pk
4. NEVER run `make install`, `pip install`, `cargo install` or any other installer directly
5. NEVER copy binaries or libraries manually to system directories
6. All installed files MUST be tracked by pk - verify with `pk check`
7. Package archives use `.pk.tar.xz` extension

```bash
# Correct workflow for new packages:
# 1. Add to pk/packages/<letter>.toml (e.g., tmux goes in t.toml)
# 2. Download: pk d <pkgname>
# 3. Build:    pk b <pkgname>
# 4. Install:  pk i /var/cache/pk/<pkgname>-<version>.pk.tar.xz
# 5. Verify:   pk check
```

## Project Overview

LFS-infra is an automated Linux From Scratch build system with bleeding-edge packages (GCC 16, Linux 6.18.7, glibc 2.40), ext4 filesystem, and aggressive Zen 3 performance optimizations.

**Primary workflow**: Boot from Fedora Rawhide live USB, run `./install.sh /dev/nvme0n1` to install LFS on target device.

Uses **pk** - a minimal POSIX shell package manager (modular git-like architecture) from `/home/ert/code/pk/`.

**Current status**: 260 packages defined across 20 build stages, desktop-ready with XFCE4.

## Architecture

```
lfs-infra/                          pk/ (separate repo)
├── install.sh                      ├── pk                    # Package manager
├── test-qemu.sh                    ├── pk.d/                 # Subcommands
├── .env.example                    │   ├── pk-build
├── config/                         │   ├── pk-download
│   ├── lfs.conf                    │   ├── pk-install
│   └── ...                         │   ├── pk-sync           # Sync from git
├── scripts/                        │   ├── pk-check-updates  # Version checker
│   ├── build/                      │   ├── pk-upgrade        # Upgrade packages
│   └── lib/                        │   └── pk-push-updates   # Push changes
└── ...                             └── packages/             # Package definitions
                                        ├── a.toml            # 260 packages split
                                        ├── b.toml            # alphabetically
                                        ├── ...
                                        └── z.toml
```

## Quick Start

```bash
# From Fedora Rawhide live USB
sudo ./install.sh /dev/nvme0n1

# Or with .env for unattended install
cp .env.example .env
# Edit .env
sudo ./install.sh --yes /dev/nvme0n1

# Test in QEMU (after build)
./test-qemu.sh
```

## pk - Package Manager

Located at `/home/ert/code/pk/`. Package definitions in `pk/packages/*.toml`.

```bash
# Package commands
pk i <pkg.pk.tar.xz>   # Install package
pk r <pkgname>         # Remove package
pk l                   # List installed
pk q <pkgname>         # Query package info
pk f <pkgname>         # List package files

# Build commands
pk b <pkgname>         # Build package from packages/*.toml
pk d <pkgname>         # Download package source

# Update commands (apt-like workflow)
pk sync                # Pull latest package definitions from git
pk check-updates       # Check for outdated packages (like apt list --upgradable)
pk check-updates -r    # Compare against Fedora Rawhide
pk upgrade             # Build and install all outdated packages
pk upgrade gcc         # Upgrade specific package
pk push-updates        # Commit and push TOML changes (maintainers)

# System commands
pk c [dirs...]         # Check for untracked files
pk v                   # Show version
```

Database: `/var/lib/pk/<pkgname>/` with `info` (name\nversion) and `files` (file list)

Repository: `/var/lib/pk/repo/` - git clone for package definitions (symlinked to /etc/pk/packages)

Environment:
- `PK_ROOT=/` - system install (absolute paths)
- `PK_ROOT=/mnt/lfs/` - chroot install
- `PK_ROOT=""` - local/safe mode (relative paths, harmless)
- `PK_REPO_URL` - git repo for pk sync (default: github.com/krystophny/pk.git)
- `PK_REPO_DIR` - local clone directory (default: /var/lib/pk/repo)

## Environment Variables

From `.env` or command line:

| Variable | Default | Description |
|----------|---------|-------------|
| LFS_DEVICE | (required) | Target device |
| LFS_MOUNT | /mnt/lfs | Mount point |
| LFS_USERNAME | (prompt) | Username |
| LFS_PASSWORD | (prompt) | Password |
| LFS_HOSTNAME | lfs | Hostname |
| LFS_KERNEL_CONFIG | - | Custom kernel config path |
| WIFI_SSID | - | WiFi network (wpa_supplicant) |
| WIFI_PASSWORD | - | WiFi password |
| LAN_IP | - | Static IP (alternative to DHCP) |
| LAN_INTERFACE | eth0 | LAN interface |
| LAN_NETMASK | - | Netmask for static IP |
| LAN_GATEWAY | - | Gateway for static IP |
| LAN_DNS | - | DNS for static IP |

## Package Definition (pk/packages/*.toml)

Package definitions are split alphabetically in `/home/ert/code/pk/packages/`:
- `a.toml` - packages starting with 'a' (acl, attr, autoconf, etc.)
- `b.toml` - packages starting with 'b' (bash, binutils, bison, etc.)
- ... through `z.toml`

```toml
[packages.example]
version = "1.0.0"
description = "Package description"
url = "https://example.com/pkg-${version}.tar.xz"
git_url = "https://github.com/example/repo.git"  # Alternative to url
use_git = false
checksum_url = "https://example.com/pkg-${version}.tar.xz.sig"
version_check = "gnu:project"  # or "github:owner/repo", "kernel:", etc.
stage = 4
build_order = 5                # Priority within stage
depends = ["dep1", "dep2"]
build_system = "autotools"     # or "meson", "cmake", "make", "custom"
configure_flags = "--flag=value"
meson_flags = "-Doption=true"
cmake_flags = "-DFLAG=ON"
build_commands = [             # Custom build (overrides build_system)
    "./configure --prefix=/usr",
    "make -j${NPROC}",
    "make DESTDIR=${PKG} install"
]
provides = ["/usr/lib/libfoo.so"]  # Files to check for idempotency
source_pkg = "pkgname"             # Use sources from different package
```

Variables: `${version}`, `${version_mm}` (major.minor), `${srcdir}`, `${pkgdir}`, `${NPROC}`

## Build Stages

| Stage | Description | Key Packages |
|-------|-------------|--------------|
| 1 | Cross-toolchain | binutils-pass1, gcc-pass1, linux-headers, glibc-pass1, libstdc++-pass1 |
| 2 | Temporary tools | gcc-pass2, m4, ncurses, bash, coreutils, grep, make, perl, python |
| 3 | Basic system | Final gcc, glibc, binutils, zlib, readline, flex, bison, autoconf |
| 4 | System packages | openssl, cmake, meson, ninja, curl, wget, pcre2, glib |
| 5 | Kernel & bootloader | linux 6.18.7, grub, efibootmgr |
| 6 | Init system | runit |
| 7 | Networking | wpa_supplicant, dhcpcd, iproute2, dbus |
| 8 | Desktop base | mesa, xorg, gtk3, cairo, pango, fontconfig, freetype |
| 9 | Desktop environment | XFCE4 (xfdesktop, xfwm4, xfce4-panel, xfce4-terminal) |
| 10 | Development | git, ninja, texinfo |
| 11+ | Applications | Firefox, VS Code, Rust, LLVM, Wine, Steam, Julia, Octave |
| 99 | Deferred | Packages with bootstrap issues |

Stage 1 builds to `/var/tmp/lfs-bootstrap/` (temporary, deleted after build).

## Filesystem & Directory Structure

- **ext4** with noatime - simple, fast, stable
- **/tmp** as tmpfs (90% of RAM) - fast compilation
- **Boot**: GRUB2 UEFI/GPT, PARTUUID (no initramfs needed)

| Path | Purpose |
|------|---------|
| `/usr/src` | Source tarballs and extracted code |
| `/var/tmp/lfs-bootstrap` | Cross-compiler (temporary) |
| `/var/cache/pk` | Built .pkg.tar.xz packages |
| `/var/lib/pk` | Package database |
| `/var/log/lfs-build` | Build logs |

User is in `src` group (GID 50) with write access to `/usr/src` - build as user, install as root.

## Optimization Flags (build.conf)

Aggressive Zen 3 optimizations:

```bash
CFLAGS_PERF="-O3 -march=znver3 -mtune=znver3 -ffast-math -flto=${NPROC} -funroll-loops ..."
CFLAGS_SAFE="-O3 -march=znver3 -flto=${NPROC} ..."  # No fast-math (IEEE-compliant)
CFLAGS_BOOTSTRAP="-O2 -march=native -pipe"          # Conservative for cross-compile
```

System-wide flags set in `/etc/profile.d/optimization-flags.sh` (CFLAGS, RUSTFLAGS, GOAMD64, etc.)

Linker preference: mold > lld > gold > bfd

## Profile-Guided Optimization (PGO)

| Package | Method | Gains |
|---------|--------|-------|
| GCC | `make profiledbootstrap` | ~10% faster compilation |
| Python | `--enable-optimizations` | ~10% faster runtime |
| LLVM/Clang | `LLVM_BUILD_INSTRUMENTED` | ~15-20% faster compilation |
| zstd | `-fprofile-generate/-use` | ~5-10% faster compression |
| SQLite | `-fprofile-generate/-use` | ~10-30% faster queries |
| OpenSSL | `-fprofile-generate/-use` | ~5% faster crypto |

PGO builds take 2-4x longer but produce significantly faster binaries.

## Hardware Support

| Category | Packages |
|----------|----------|
| Firmware | linux-firmware, amd-ucode, intel-ucode |
| AMD GPU | mesa, amdgpu driver |
| NVIDIA | nvidia-driver, nvidia-driver-beta, cuda-toolkit |
| Intel | intel-oneapi |

## Desktop & Applications

- **Desktop**: XFCE4 with Chicago95 theme
- **Session**: Auto-login on tty1, auto-start X11
- **Gaming**: Wine, Proton GE, DXVK, VKD3D-Proton, Gamescope, Mangohud, Steam
- **Multimedia**: FFmpeg, PulseAudio + ALSA
- **Development**: GCC 16, Rust, LLVM/Clang, GHC, Go
- **Scientific**: Julia, Octave, R
- **Applications**: Firefox, VS Code

## Key Commands

```bash
# Install to target device
sudo ./install.sh /dev/nvme0n1

# Test in QEMU
./test-qemu.sh

# Check for package updates (now via pk)
pk sync                      # Pull latest package definitions
pk check-updates             # Show outdated packages
pk check-updates -r          # Compare with Fedora Rawhide
pk check-updates -u gcc      # Update gcc version in TOML
pk upgrade                   # Build and install all outdated

# Build specific package
./scripts/build/build-lfs.sh <package>

# Build all
./scripts/build/build-lfs.sh all
```

## Version Checking

Version checking is now integrated into pk via `pk check-updates`.

Supports multiple upstream formats in `version_check` field:

- `gnu:project` - GNU FTP
- `kernel:` - kernel.org
- `gcc-snapshot:` - GCC snapshots
- `github:owner/repo` - GitHub releases
- `xorg:path` - X.org releases
- `gnome:project` - GNOME
- `python:` - Python.org
- `url:https://...|regex` - Direct URL scraping
