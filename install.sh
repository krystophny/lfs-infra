#!/bin/bash
# LFS Installation Script
# Run from Fedora Rawhide live USB to install LFS on target device
#
# Usage: sudo ./install.sh /dev/nvme0n1
#        sudo ./install.sh --help
#
# For unattended install, create .env file (see .env.example)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }
header() { echo -e "\n${CYAN}=== $* ===${NC}\n"; }

usage() {
    cat <<EOF
LFS Installation Script

Usage: $(basename "$0") [OPTIONS] DEVICE

Install Linux From Scratch on the target device.
Run from a Fedora Rawhide live USB.

Arguments:
    DEVICE              Target block device (e.g., /dev/nvme0n1, /dev/sda)

Options:
    -m, --mount PATH    Mount point (default: /mnt/lfs)
    -s, --swap SIZE     Swap partition size (default: 16G, 0 to disable)
    -u, --user NAME     Username
    -p, --password PASS Password
    -y, --yes           Skip confirmation prompts
    --env FILE          Load config from file (default: .env if exists)
    -h, --help          Show this help

Environment Variables (.env file):
    LFS_DEVICE          Target device
    LFS_MOUNT           Mount point
    LFS_SWAP_SIZE       Swap size (0 to disable)
    LFS_USERNAME        Username
    LFS_PASSWORD        Password
    LFS_HOSTNAME        Hostname (default: lfs)
    LFS_TIMEZONE        Timezone (default: from host)
    LFS_KERNEL_CONFIG   Custom kernel config file

Examples:
    # Interactive
    sudo ./install.sh /dev/nvme0n1

    # Unattended (configure .env first)
    sudo ./install.sh --yes /dev/nvme0n1

    # Specify options
    sudo ./install.sh -u myuser -s 32G /dev/sda

EOF
    exit 0
}

# ============================================================================
# Load .env file if present
# ============================================================================
load_env() {
    local env_file="${1:-.env}"
    if [[ -f "${SCRIPT_DIR}/${env_file}" ]]; then
        log "Loading configuration from ${env_file}..."
        set -a
        source "${SCRIPT_DIR}/${env_file}"
        set +a
    fi
}

# Load default .env first
load_env ".env"

# Defaults (can be overridden by .env or CLI)
MOUNT_POINT="${LFS_MOUNT:-/mnt/lfs}"
SWAP_SIZE="${LFS_SWAP_SIZE:-16G}"
LFS_USERNAME="${LFS_USERNAME:-}"
LFS_PASSWORD="${LFS_PASSWORD:-}"
LFS_HOSTNAME="${LFS_HOSTNAME:-lfs}"
LFS_TIMEZONE="${LFS_TIMEZONE:-}"
SKIP_CONFIRM=0
DEVICE="${LFS_DEVICE:-}"

# Parse arguments (override .env)
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mount) MOUNT_POINT="$2"; shift 2 ;;
        -s|--swap) SWAP_SIZE="$2"; shift 2 ;;
        -u|--user) LFS_USERNAME="$2"; shift 2 ;;
        -p|--password) LFS_PASSWORD="$2"; shift 2 ;;
        -y|--yes) SKIP_CONFIRM=1; shift ;;
        --env) load_env "$2"; shift 2 ;;
        -h|--help) usage ;;
        /dev/*) DEVICE="$1"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -z "${DEVICE}" ]] && usage

# Must be root
[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"

# Validate we're on Linux
[[ "$(uname -s)" == "Linux" ]] || die "This script requires Linux"

# Validate device exists
[[ -b "${DEVICE}" ]] || die "Device not found: ${DEVICE}"

# Safety check - not the boot device
BOOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//' || true)
[[ "${DEVICE}" == "${BOOT_DEV}" ]] && die "Cannot install to boot device!"

# Export for build scripts
export LFS="${MOUNT_POINT}"
export NPROC=$(nproc)
export MAKEFLAGS="-j${NPROC}"

header "LFS Installation"
echo "Target:      ${DEVICE}"
echo "Mount:       ${MOUNT_POINT}"
echo "Swap:        ${SWAP_SIZE}"
echo "Hostname:    ${LFS_HOSTNAME}"
echo "CPU cores:   ${NPROC}"
echo ""

# Show current partition table
log "Current partition table:"
parted -s "${DEVICE}" print 2>/dev/null || true
echo ""

if [[ ${SKIP_CONFIRM} -eq 0 ]]; then
    warn "ALL DATA ON ${DEVICE} WILL BE ERASED!"
    read -p "Type 'ERASE' to continue: " confirm
    [[ "${confirm}" == "ERASE" ]] || die "Aborted"
fi

# ============================================================================
# Step 1: User Configuration
# ============================================================================
header "User Configuration"

if [[ -z "${LFS_USERNAME}" ]]; then
    read -p "Username [default: user]: " LFS_USERNAME
    LFS_USERNAME="${LFS_USERNAME:-user}"
fi

while [[ -z "${LFS_PASSWORD}" ]]; do
    read -sp "Password for ${LFS_USERNAME}: " LFS_PASSWORD
    echo ""
    read -sp "Confirm password: " LFS_PASSWORD2
    echo ""
    if [[ "${LFS_PASSWORD}" != "${LFS_PASSWORD2}" ]]; then
        warn "Passwords don't match, try again"
        LFS_PASSWORD=""
    fi
done

export LFS_USERNAME LFS_PASSWORD
ok "User: ${LFS_USERNAME}"

# ============================================================================
# Step 2: Partition and Format (btrfs)
# ============================================================================
header "Partitioning ${DEVICE}"

# Unmount any existing mounts
for part in "${DEVICE}"*; do
    umount "${part}" 2>/dev/null || true
done
swapoff -a 2>/dev/null || true

# Create GPT partition table
log "Creating GPT partition table..."
parted -s "${DEVICE}" mklabel gpt

# Determine partition naming
if [[ "${DEVICE}" == *nvme* ]] || [[ "${DEVICE}" == *loop* ]]; then
    PART_PREFIX="${DEVICE}p"
else
    PART_PREFIX="${DEVICE}"
fi

# Create partitions: EFI (512M), Swap (optional), Root (btrfs)
parted -s "${DEVICE}" mkpart ESP fat32 1MiB 513MiB
parted -s "${DEVICE}" set 1 esp on

NEXT_START=513
if [[ "${SWAP_SIZE}" != "0" ]]; then
    case "${SWAP_SIZE}" in
        *M) SWAP_MIB="${SWAP_SIZE%M}" ;;
        *G) SWAP_MIB="$((${SWAP_SIZE%G} * 1024))" ;;
        *) SWAP_MIB="${SWAP_SIZE}" ;;
    esac
    SWAP_END=$((NEXT_START + SWAP_MIB))
    parted -s "${DEVICE}" mkpart swap linux-swap "${NEXT_START}MiB" "${SWAP_END}MiB"
    NEXT_START="${SWAP_END}"
    SWAP_PART="${PART_PREFIX}2"
    ROOT_PART="${PART_PREFIX}3"
else
    ROOT_PART="${PART_PREFIX}2"
    SWAP_PART=""
fi

parted -s "${DEVICE}" mkpart root btrfs "${NEXT_START}MiB" 100%
EFI_PART="${PART_PREFIX}1"

sleep 2  # Wait for partitions to appear

# Format
header "Formatting (btrfs)"

log "Formatting EFI partition (FAT32)..."
mkfs.fat -F32 -n EFI "${EFI_PART}"

if [[ -n "${SWAP_PART}" ]]; then
    log "Setting up swap..."
    mkswap -L swap "${SWAP_PART}"
fi

log "Formatting root partition (btrfs)..."
mkfs.btrfs -f -L lfs-root "${ROOT_PART}"

# Create btrfs subvolumes
log "Creating btrfs subvolumes..."
mkdir -p "${MOUNT_POINT}"
mount "${ROOT_PART}" "${MOUNT_POINT}"
btrfs subvolume create "${MOUNT_POINT}/@"
btrfs subvolume create "${MOUNT_POINT}/@home"
btrfs subvolume create "${MOUNT_POINT}/@snapshots"
umount "${MOUNT_POINT}"

# Mount with subvolumes and compression
log "Mounting filesystems..."
mount -o subvol=@,compress=lzo,noatime "${ROOT_PART}" "${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}/home" "${MOUNT_POINT}/.snapshots" "${MOUNT_POINT}/boot/efi"
mount -o subvol=@home,compress=lzo,noatime "${ROOT_PART}" "${MOUNT_POINT}/home"
mount -o subvol=@snapshots,compress=lzo,noatime "${ROOT_PART}" "${MOUNT_POINT}/.snapshots"
mount "${EFI_PART}" "${MOUNT_POINT}/boot/efi"

[[ -n "${SWAP_PART}" ]] && swapon "${SWAP_PART}"

ok "Filesystem ready (btrfs with lzo compression)"

# ============================================================================
# Step 3: Create Directory Structure
# ============================================================================
header "Creating Directory Structure"

mkdir -p "${MOUNT_POINT}"/{sources,tools,build,pkg,logs}
mkdir -p "${MOUNT_POINT}"/{boot,etc,home,mnt,opt,srv,run,root}
mkdir -p "${MOUNT_POINT}"/etc/{opt,sysconfig}
mkdir -p "${MOUNT_POINT}"/{lib,bin,sbin}
mkdir -p "${MOUNT_POINT}/lib64"
mkdir -p "${MOUNT_POINT}"/usr/{,local/}{bin,include,lib,sbin,src}
mkdir -p "${MOUNT_POINT}"/usr/{,local/}share/{color,dict,doc,info,locale,man}
mkdir -p "${MOUNT_POINT}"/usr/{,local/}share/{misc,terminfo,zoneinfo}
mkdir -p "${MOUNT_POINT}"/usr/{,local/}share/man/man{1..8}
mkdir -p "${MOUNT_POINT}"/var/{cache,local,log,mail,opt,spool}
mkdir -p "${MOUNT_POINT}"/var/lib/{color,misc,locate,pk}
install -d -m 1777 "${MOUNT_POINT}"/{var/,}tmp
mkdir -p "${MOUNT_POINT}/lib/firmware"

ok "Directory structure created"

# ============================================================================
# Step 4: Generate fstab
# ============================================================================
header "Generating fstab"

ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}")
EFI_UUID=$(blkid -s UUID -o value "${EFI_PART}")

cat > "${MOUNT_POINT}/etc/fstab" << EOF
# /etc/fstab - LFS (btrfs with lzo compression)
UUID=${ROOT_UUID}  /            btrfs  subvol=@,compress=lzo,noatime  0 1
UUID=${ROOT_UUID}  /home        btrfs  subvol=@home,compress=lzo,noatime  0 2
UUID=${ROOT_UUID}  /.snapshots  btrfs  subvol=@snapshots,compress=lzo,noatime  0 2
UUID=${EFI_UUID}   /boot/efi    vfat   umask=0077  0 2
EOF

if [[ -n "${SWAP_PART}" ]]; then
    SWAP_UUID=$(blkid -s UUID -o value "${SWAP_PART}")
    echo "UUID=${SWAP_UUID}  none         swap   sw  0 0" >> "${MOUNT_POINT}/etc/fstab"
fi

cat >> "${MOUNT_POINT}/etc/fstab" << EOF

# Virtual filesystems
proc           /proc         proc   nosuid,noexec,nodev  0 0
sysfs          /sys          sysfs  nosuid,noexec,nodev  0 0
devpts         /dev/pts      devpts gid=5,mode=620       0 0
tmpfs          /run          tmpfs  defaults             0 0
EOF

ok "fstab generated"

# ============================================================================
# Step 5: Install pk (package manager)
# ============================================================================
header "Installing pk Package Manager"

cp "${SCRIPT_DIR}/pk" "${MOUNT_POINT}/tools/bin/pk"
chmod +x "${MOUNT_POINT}/tools/bin/pk"
mkdir -p "${MOUNT_POINT}/var/lib/pk"

ok "pk installed"

# ============================================================================
# Step 6: Download Sources
# ============================================================================
header "Downloading Sources"

export LFS_SOURCES="${MOUNT_POINT}/sources"
"${SCRIPT_DIR}/scripts/build/download-sources.sh"

ok "Sources downloaded"

# ============================================================================
# Step 7: Build LFS (directly into target filesystem)
# ============================================================================
header "Building LFS"

"${SCRIPT_DIR}/scripts/build/build-lfs.sh" all

ok "LFS build complete"

# ============================================================================
# Step 8: Install Bootloader
# ============================================================================
header "Installing Bootloader (GRUB)"

grub-install --target=x86_64-efi \
    --efi-directory="${MOUNT_POINT}/boot/efi" \
    --boot-directory="${MOUNT_POINT}/boot" \
    --bootloader-id=LFS \
    --removable

cat > "${MOUNT_POINT}/boot/grub/grub.cfg" << EOF
set default=0
set timeout=3

menuentry "LFS" {
    linux /boot/vmlinuz root=UUID=${ROOT_UUID} rootflags=subvol=@ ro quiet
    initrd /boot/initrd.img
}

menuentry "LFS (recovery)" {
    linux /boot/vmlinuz root=UUID=${ROOT_UUID} rootflags=subvol=@ ro single
    initrd /boot/initrd.img
}
EOF

ok "GRUB installed"

# ============================================================================
# Step 9: System Configuration
# ============================================================================
header "System Configuration"

# Hostname
echo "${LFS_HOSTNAME}" > "${MOUNT_POINT}/etc/hostname"
cat > "${MOUNT_POINT}/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   ${LFS_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
EOF

# Timezone
if [[ -n "${LFS_TIMEZONE}" ]]; then
    ln -sf "/usr/share/zoneinfo/${LFS_TIMEZONE}" "${MOUNT_POINT}/etc/localtime"
elif [[ -L /etc/localtime ]]; then
    cp -P /etc/localtime "${MOUNT_POINT}/etc/"
fi

# Network configuration
mkdir -p "${MOUNT_POINT}/etc/iwd" "${MOUNT_POINT}/var/lib/iwd"

# Copy iwd config
if [[ -d "${SCRIPT_DIR}/config/iwd" ]]; then
    cp -r "${SCRIPT_DIR}/config/iwd/"* "${MOUNT_POINT}/etc/iwd/"
fi

# WiFi configuration
if [[ -n "${WIFI_SSID:-}" && -n "${WIFI_PASSWORD:-}" ]]; then
    log "Configuring WiFi: ${WIFI_SSID}"
    # Create iwd network file (PSK format)
    WIFI_PSK=$(wpa_passphrase "${WIFI_SSID}" "${WIFI_PASSWORD}" 2>/dev/null | grep -E "^\s*psk=" | cut -d= -f2)
    cat > "${MOUNT_POINT}/var/lib/iwd/${WIFI_SSID}.psk" << EOF
[Security]
PreSharedKey=${WIFI_PSK}
EOF
    chmod 600 "${MOUNT_POINT}/var/lib/iwd/${WIFI_SSID}.psk"
    ok "WiFi configured: ${WIFI_SSID}"
fi

# Static LAN configuration
if [[ -n "${LAN_IP:-}" ]]; then
    log "Configuring static LAN: ${LAN_IP}"
    LAN_INTERFACE="${LAN_INTERFACE:-eth0}"
    LAN_NETMASK="${LAN_NETMASK:-255.255.255.0}"

    mkdir -p "${MOUNT_POINT}/etc/network"
    cat > "${MOUNT_POINT}/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto ${LAN_INTERFACE}
iface ${LAN_INTERFACE} inet static
    address ${LAN_IP}
    netmask ${LAN_NETMASK}
EOF

    # Add gateway if specified
    [[ -n "${LAN_GATEWAY:-}" ]] && echo "    gateway ${LAN_GATEWAY}" >> "${MOUNT_POINT}/etc/network/interfaces"

    # DNS configuration
    if [[ -n "${LAN_DNS:-}" ]]; then
        echo "nameserver ${LAN_DNS}" > "${MOUNT_POINT}/etc/resolv.conf"
    fi

    ok "Static LAN configured: ${LAN_INTERFACE} = ${LAN_IP}"
fi

ok "System configured"

# ============================================================================
# Done
# ============================================================================
header "Installation Complete!"

# Create snapshot of fresh install
log "Creating snapshot of fresh install..."
btrfs subvolume snapshot -r "${MOUNT_POINT}" "${MOUNT_POINT}/.snapshots/fresh-install"

# Unmount
log "Unmounting filesystems..."
sync
umount -R "${MOUNT_POINT}" || umount -l "${MOUNT_POINT}"
[[ -n "${SWAP_PART}" ]] && swapoff "${SWAP_PART}" 2>/dev/null || true

echo ""
ok "LFS installed to ${DEVICE}"
echo ""
echo "Btrfs subvolumes:"
echo "  @           - Root filesystem"
echo "  @home       - Home directories"
echo "  @snapshots  - Snapshots (fresh-install created)"
echo ""
echo "Next steps:"
echo "  1. Remove the USB drive"
echo "  2. Reboot into your new system"
echo "  3. Login as: ${LFS_USERNAME}"
echo ""
echo "Enjoy your new Linux From Scratch system!"
