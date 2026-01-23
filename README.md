# LFS Infrastructure

Automated Linux From Scratch build system with bleeding-edge packages, btrfs snapshots, and aggressive performance optimizations.

## Quick Start

### Requirements

- Fedora Rawhide live USB (provides GCC 16, latest tools)
- Target machine with UEFI boot
- 50GB+ storage on target device

### Installation

1. Boot target machine from Fedora Rawhide live USB

2. Clone this repository:
   ```bash
   sudo dnf install git
   git clone https://github.com/yourusername/lfs-infra.git
   cd lfs-infra
   ```

3. Run the installer:
   ```bash
   sudo ./install.sh /dev/nvme0n1
   ```

4. Reboot and enjoy your new system

### Unattended Installation

Create a `.env` file for fully automated installs:

```bash
cp .env.example .env
# Edit .env with your settings
sudo ./install.sh --yes /dev/nvme0n1
```

## Features

- **Bleeding-edge packages**: GCC 16, Linux 6.18, glibc 2.42
- **Ext4 filesystem**: Fast, stable, proven
- **Performance optimized**: `-O3 -march=native -mtune=native` by default
- **Minimal package manager**: `pk` - 120 lines of shell, zero dependencies

## Package Manager (pk)

```bash
pk i <pkg.tar.xz>    # Install package
pk r <pkgname>       # Remove package
pk l                 # List installed
pk q <pkgname>       # Query package info
pk f <pkgname>       # List package files
```

## Directory Structure

```
lfs-infra/
├── install.sh              # Main installation script
├── pk                      # Package manager
├── packages.toml           # Package definitions
├── config/
│   ├── lfs.conf            # Build configuration
│   ├── etc/                # System config templates
│   ├── iwd/                # WiFi configuration
│   └── kernel/             # Kernel configs
├── scripts/
│   └── build/
│       ├── build-lfs.sh    # Build orchestrator
│       └── download-sources.sh
└── version-checker/
    └── check-versions.sh   # Check for package updates
```

## Configuration

### packages.toml

All packages are defined in `packages.toml`:

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

### Build Stages

1. **Stage 1**: Cross-toolchain (binutils, gcc, glibc)
2. **Stage 2**: Temporary tools (bash, coreutils, etc.)
3. **Stage 3**: Basic system (zlib, readline, perl)
4. **Stage 4**: System packages (openssl, meson, cmake)
5. **Stage 5**: Kernel and bootloader

## Version Checking

Check for package updates:

```bash
./version-checker/check-versions.sh        # Show outdated
./version-checker/check-versions.sh -a     # Show all
./version-checker/check-versions.sh -u     # Update packages.toml
./version-checker/check-versions.sh -r     # Compare with Fedora Rawhide
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| LFS | /mnt/lfs | Build/install location |
| LFS_USERNAME | (prompt) | System username |
| LFS_PASSWORD | (prompt) | User password |
| LFS_HOSTNAME | lfs | System hostname |
| LFS_SWAP_SIZE | 16G | Swap partition size |
| LFS_TIMEZONE | (from host) | System timezone |
| NPROC | (auto) | Parallel build jobs |

## License

GPL-3.0
