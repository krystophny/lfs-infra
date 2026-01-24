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
    -u, --user NAME     Username
    -p, --password PASS Password
    -y, --yes           Skip confirmation prompts
    --env FILE          Load config from file (default: .env if exists)
    -h, --help          Show this help

Environment Variables (.env file):
    LFS_DEVICE          Target device
    LFS_MOUNT           Mount point
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
    sudo ./install.sh -u myuser /dev/sda

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
echo "Hostname:    ${LFS_HOSTNAME}"
echo "CPU cores:   ${NPROC}"
echo ""

# Determine partition naming (needed for mount check)
if [[ "${DEVICE}" == *nvme* ]] || [[ "${DEVICE}" == *loop* ]]; then
    PART_PREFIX="${DEVICE}p"
else
    PART_PREFIX="${DEVICE}"
fi

EFI_PART="${PART_PREFIX}1"
ROOT_PART="${PART_PREFIX}2"

# Check if already mounted - reuse existing filesystem
REUSE_FILESYSTEM=0
if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    REUSE_FILESYSTEM=1
    log "Target already mounted at ${MOUNT_POINT} - will reuse existing filesystem"
else
    # Show current partition table
    log "Current partition table:"
    parted -s "${DEVICE}" print 2>/dev/null || true
    echo ""

    if [[ ${SKIP_CONFIRM} -eq 0 ]]; then
        warn "ALL DATA ON ${DEVICE} WILL BE ERASED!"
        read -p "Type 'ERASE' to continue: " confirm
        [[ "${confirm}" == "ERASE" ]] || die "Aborted"
    fi
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
# Step 2: Partition and Format (ext4)
# ============================================================================

# Check if already mounted - reuse existing filesystem
if [[ ${REUSE_FILESYSTEM} -eq 1 ]]; then
    header "Using Existing Filesystem"
    log "Target already mounted at ${MOUNT_POINT}"

    # Verify EFI is mounted too
    if ! mountpoint -q "${MOUNT_POINT}/boot/efi" 2>/dev/null; then
        mkdir -p "${MOUNT_POINT}/boot/efi"
        mount "${EFI_PART}" "${MOUNT_POINT}/boot/efi"
    fi

    ok "Reusing existing filesystem (cached files preserved)"
else
    header "Partitioning ${DEVICE}"

    # Unmount any existing mounts
    for part in "${DEVICE}"*; do
        umount "${part}" 2>/dev/null || true
    done

    # Create GPT partition table
    log "Creating GPT partition table..."
    parted -s "${DEVICE}" mklabel gpt

    # Create partitions: EFI (512M), Root (ext4)
    parted -s "${DEVICE}" mkpart ESP fat32 1MiB 513MiB
    parted -s "${DEVICE}" set 1 esp on
    parted -s "${DEVICE}" mkpart root ext4 513MiB 100%

    sleep 2  # Wait for partitions to appear

    # Format
    header "Formatting (ext4)"

    log "Formatting EFI partition (FAT32)..."
    mkfs.fat -F32 -n EFI "${EFI_PART}"

    log "Formatting root partition (ext4)..."
    mkfs.ext4 -L lfs-root "${ROOT_PART}"

    # Mount filesystems
    log "Mounting filesystems..."
    mkdir -p "${MOUNT_POINT}"
    mount -o noatime "${ROOT_PART}" "${MOUNT_POINT}"
    mkdir -p "${MOUNT_POINT}/boot/efi"
    mount "${EFI_PART}" "${MOUNT_POINT}/boot/efi"

    ok "Filesystem ready (ext4)"
fi

# ============================================================================
# Step 3: Create Directory Structure
# ============================================================================
header "Creating Directory Structure"

mkdir -p "${MOUNT_POINT}"/{boot,etc,home,mnt,opt,srv,run,root}
mkdir -p "${MOUNT_POINT}"/etc/{opt,sysconfig}
mkdir -p "${MOUNT_POINT}"/{lib,bin,sbin}
mkdir -p "${MOUNT_POINT}/lib64"
mkdir -p "${MOUNT_POINT}"/usr/{,local/}{bin,include,lib,sbin,src}
mkdir -p "${MOUNT_POINT}"/usr/{,local/}share/{color,dict,doc,info,locale,man}
mkdir -p "${MOUNT_POINT}"/usr/{,local/}share/{misc,terminfo,zoneinfo}
mkdir -p "${MOUNT_POINT}"/usr/{,local/}share/man/man{1..8}
mkdir -p "${MOUNT_POINT}"/var/{cache,local,log,mail,opt,spool}
mkdir -p "${MOUNT_POINT}"/var/cache/pk
mkdir -p "${MOUNT_POINT}"/var/lib/{color,misc,locate,pk}
mkdir -p "${MOUNT_POINT}"/var/log/lfs-build
install -d -m 1777 "${MOUNT_POINT}"/{var/,}tmp
mkdir -p "${MOUNT_POINT}/lib/firmware"

ok "Directory structure created"

# Set /usr/src writable by src group (GID 50) - user can build without root
chown -R root:50 "${MOUNT_POINT}/usr/src"
chmod -R g+w "${MOUNT_POINT}/usr/src"
chmod g+s "${MOUNT_POINT}/usr/src"  # setgid so new files inherit src group

ok "Build directories configured (user can write to /usr/src)"

# ============================================================================
# Step 4: Generate fstab
# ============================================================================
header "Generating fstab"

ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}")
EFI_UUID=$(blkid -s UUID -o value "${EFI_PART}")

cat > "${MOUNT_POINT}/etc/fstab" << EOF
# /etc/fstab - LFS (ext4, no swap - 96GB RAM is plenty)
UUID=${ROOT_UUID}  /            ext4   noatime      0 1
UUID=${EFI_UUID}   /boot/efi    vfat   umask=0077   0 2
EOF

cat >> "${MOUNT_POINT}/etc/fstab" << EOF

# Virtual filesystems
proc           /proc         proc   nosuid,noexec,nodev  0 0
sysfs          /sys          sysfs  nosuid,noexec,nodev  0 0
devpts         /dev/pts      devpts gid=5,mode=620       0 0
tmpfs          /run          tmpfs  defaults             0 0
tmpfs          /tmp          tmpfs  defaults,noatime,nosuid,nodev,size=90%  0 0
EOF

ok "fstab generated"

# ============================================================================
# Step 5: Install pk (package manager)
# ============================================================================
header "Installing pk Package Manager"

cp "${SCRIPT_DIR}/pk" "${MOUNT_POINT}/usr/bin/pk"
chmod +x "${MOUNT_POINT}/usr/bin/pk"

ok "pk installed"

# ============================================================================
# Step 6: Download Sources
# ============================================================================
header "Downloading Sources"

export LFS_SOURCES="${MOUNT_POINT}/usr/src"
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
# GRUB config for LFS - instant boot (hold SHIFT for menu)
set default=0
set timeout=0
set timeout_style=hidden

menuentry "LFS" {
    linux /boot/vmlinuz root=UUID=${ROOT_UUID} ro quiet loglevel=3 amd_pstate=active
}

menuentry "LFS (recovery)" {
    linux /boot/vmlinuz root=UUID=${ROOT_UUID} ro single
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

# Create basic passwd/group/shadow
log "Creating user accounts..."
cat > "${MOUNT_POINT}/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/bash
${LFS_USERNAME}:x:1000:1000:${LFS_USERNAME}:/home/${LFS_USERNAME}:/bin/bash
nobody:x:65534:65534:Unprivileged User:/dev/null:/bin/false
EOF

cat > "${MOUNT_POINT}/etc/group" << EOF
root:x:0:
bin:x:1:
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:${LFS_USERNAME}
video:x:12:${LFS_USERNAME}
utmp:x:13:
cdrom:x:15:
adm:x:16:
mail:x:34:
src:x:50:${LFS_USERNAME}
wheel:x:97:${LFS_USERNAME}
nogroup:x:65534:
${LFS_USERNAME}:x:1000:
EOF

# Hash password and create shadow (root locked - use sudo)
HASHED_PW=$(openssl passwd -6 "${LFS_PASSWORD}")
cat > "${MOUNT_POINT}/etc/shadow" << EOF
root:!:19000:0:99999:7:::
${LFS_USERNAME}:${HASHED_PW}:19000:0:99999:7:::
nobody:!:19000:0:99999:7:::
EOF
chmod 600 "${MOUNT_POINT}/etc/shadow"

# Configure sudo for wheel group (passwordless)
mkdir -p "${MOUNT_POINT}/etc/sudoers.d"
cat > "${MOUNT_POINT}/etc/sudoers.d/wheel" << 'EOF'
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 440 "${MOUNT_POINT}/etc/sudoers.d/wheel"

# Create home directory
mkdir -p "${MOUNT_POINT}/home/${LFS_USERNAME}"
chown 1000:1000 "${MOUNT_POINT}/home/${LFS_USERNAME}"
chmod 755 "${MOUNT_POINT}/home/${LFS_USERNAME}"

ok "User ${LFS_USERNAME} created (sudo via wheel, root locked)"

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

# Shell profile and optimization flags
log "Setting up shell profile with optimization flags..."
cp "${SCRIPT_DIR}/config/etc/profile" "${MOUNT_POINT}/etc/profile"
mkdir -p "${MOUNT_POINT}/etc/profile.d"
cp "${SCRIPT_DIR}/config/etc/profile.d/"*.sh "${MOUNT_POINT}/etc/profile.d/"
chmod 644 "${MOUNT_POINT}/etc/profile" "${MOUNT_POINT}/etc/profile.d/"*.sh
ok "Shell profile configured (Zen 3 optimizations enabled system-wide)"

ok "System configured"

# Weekly TRIM for SSD longevity
log "Setting up weekly TRIM..."
mkdir -p "${MOUNT_POINT}/etc/cron.weekly"
cat > "${MOUNT_POINT}/etc/cron.weekly/fstrim" << 'EOF'
#!/bin/sh
fstrim -av
EOF
chmod +x "${MOUNT_POINT}/etc/cron.weekly/fstrim"
ok "Weekly TRIM configured"

# ============================================================================
# Step 10: Desktop Environment Setup
# ============================================================================
header "Desktop Environment Setup"

# Copy runit init scripts
log "Setting up runit init system..."
mkdir -p "${MOUNT_POINT}/etc/runit"
cp "${SCRIPT_DIR}/config/runit/1" "${MOUNT_POINT}/etc/runit/"
cp "${SCRIPT_DIR}/config/runit/2" "${MOUNT_POINT}/etc/runit/"
cp "${SCRIPT_DIR}/config/runit/3" "${MOUNT_POINT}/etc/runit/"
chmod +x "${MOUNT_POINT}/etc/runit/"[123]

# Create runsvdir structure
mkdir -p "${MOUNT_POINT}/etc/runit/runsvdir/default"
mkdir -p "${MOUNT_POINT}/etc/sv"
ln -sf /etc/runit/runsvdir/default "${MOUNT_POINT}/etc/runit/runsvdir/current"

# Copy service definitions
for svc in dbus iwd sshd cronie; do
    if [[ -d "${SCRIPT_DIR}/config/runit/sv/${svc}" ]]; then
        cp -r "${SCRIPT_DIR}/config/runit/sv/${svc}" "${MOUNT_POINT}/etc/sv/"
        chmod +x "${MOUNT_POINT}/etc/sv/${svc}/run"
        ln -sf "/etc/sv/${svc}" "${MOUNT_POINT}/etc/runit/runsvdir/default/"
    fi
done

# Create agetty-tty1 service with auto-login for user
mkdir -p "${MOUNT_POINT}/etc/sv/agetty-tty1"
cat > "${MOUNT_POINT}/etc/sv/agetty-tty1/run" << EOF
#!/bin/sh
# Auto-login ${LFS_USERNAME} on tty1, X starts via .bash_profile
exec agetty -a ${LFS_USERNAME} -J tty1 linux
EOF
chmod +x "${MOUNT_POINT}/etc/sv/agetty-tty1/run"
ln -sf /etc/sv/agetty-tty1 "${MOUNT_POINT}/etc/runit/runsvdir/default/"

ok "Runit init configured"

# Set up user desktop environment
log "Setting up XFCE4 with Chicago95 theme..."
USER_HOME="${MOUNT_POINT}/home/${LFS_USERNAME}"

# Create .bash_profile for auto-starting X
cat > "${USER_HOME}/.bash_profile" << 'EOF'
# Auto-start X on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startxfce4
fi
EOF

# Copy XFCE4 configuration
mkdir -p "${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"
if [[ -d "${SCRIPT_DIR}/config/user/xfce4" ]]; then
    cp -r "${SCRIPT_DIR}/config/user/xfce4/"* "${USER_HOME}/.config/xfce4/"
fi

# Copy autostart entries
if [[ -d "${SCRIPT_DIR}/config/user/autostart" ]]; then
    mkdir -p "${USER_HOME}/.config/autostart"
    cp -r "${SCRIPT_DIR}/config/user/autostart/"* "${USER_HOME}/.config/autostart/"
fi

# Fix ownership
chown -R 1000:1000 "${USER_HOME}"

ok "Desktop configured (XFCE4 + Chicago95, auto-login on tty1)"

# Copy Xorg config
if [[ -d "${SCRIPT_DIR}/config/xorg" ]]; then
    mkdir -p "${MOUNT_POINT}/etc/X11/xorg.conf.d"
    cp "${SCRIPT_DIR}/config/xorg/"* "${MOUNT_POINT}/etc/X11/xorg.conf.d/"
fi

ok "Xorg configured"

# ============================================================================
# Done
# ============================================================================
header "Installation Complete!"

# Unmount
log "Unmounting filesystems..."
sync
umount -R "${MOUNT_POINT}" || umount -l "${MOUNT_POINT}"

echo ""
ok "LFS installed to ${DEVICE}"
echo ""
echo "Next steps:"
echo "  1. Remove the USB drive"
echo "  2. Reboot into your new system"
echo "  3. Login as: ${LFS_USERNAME}"
echo ""
echo "Enjoy your new Linux From Scratch system!"
