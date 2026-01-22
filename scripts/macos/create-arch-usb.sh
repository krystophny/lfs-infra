#!/bin/bash
# Create Arch Linux bootable USB from macOS
# Downloads latest Arch ISO and writes to USB drive

set -euo pipefail

# Colors
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

# Check we're on macOS
[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS only"

ARCH_VERSION="${ARCH_VERSION:-2026.01.01}"
ARCH_MIRROR="${ARCH_MIRROR:-https://geo.mirror.pkgbuild.com}"
ISO_NAME="archlinux-${ARCH_VERSION}-x86_64.iso"
ISO_URL="${ARCH_MIRROR}/iso/${ARCH_VERSION}/${ISO_NAME}"
SIG_URL="${ISO_URL}.sig"
SHA256_URL="${ARCH_MIRROR}/iso/${ARCH_VERSION}/sha256sums.txt"

DOWNLOAD_DIR="${HOME}/Downloads"
ISO_PATH="${DOWNLOAD_DIR}/${ISO_NAME}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create Arch Linux bootable USB from macOS.

Options:
    -d, --device DISK   Specify disk (e.g., disk2). If not specified, lists available disks.
    -v, --version VER   Arch Linux version (default: ${ARCH_VERSION})
    -k, --keep          Keep downloaded ISO after writing
    -l, --list          List USB drives and exit
    -h, --help          Show this help

Examples:
    $(basename "$0")                    # Interactive - lists drives, prompts for selection
    $(basename "$0") -d disk2           # Write to /dev/disk2
    $(basename "$0") -v 2026.01.01      # Use specific version

Notes:
    - Requires internet connection to download Arch ISO (~900MB)
    - Will ERASE ALL DATA on the target USB drive
    - May require sudo password for dd and diskutil commands
EOF
    exit 0
}

DEVICE=""
KEEP_ISO=0
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device) DEVICE="$2"; shift 2 ;;
        -v|--version) ARCH_VERSION="$2"; shift 2 ;;
        -k|--keep) KEEP_ISO=1; shift ;;
        -l|--list) LIST_ONLY=1; shift ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

# List external/USB disks
list_usb_drives() {
    header "Available USB/External Drives"

    # Get list of external disks
    local disks
    disks=$(diskutil list external 2>/dev/null || diskutil list)

    if [[ -z "${disks}" ]] || ! echo "${disks}" | grep -q "/dev/disk"; then
        warn "No external drives found"
        echo ""
        echo "Make sure your USB drive is:"
        echo "  1. Plugged in"
        echo "  2. Not ejected"
        echo "  3. Visible in Disk Utility"
        return 1
    fi

    echo "${disks}"
    echo ""

    # Parse and show summary
    echo "Summary of external disks:"
    echo ""
    printf "%-10s %-10s %-20s %s\n" "DISK" "SIZE" "TYPE" "NAME"
    echo "--------------------------------------------------------------"

    for disk in /dev/disk[0-9]*; do
        local disknum="${disk#/dev/}"
        # Skip internal disks and partitions
        [[ "${disknum}" == *s* ]] && continue

        local info
        info=$(diskutil info "${disk}" 2>/dev/null) || continue

        # Check if external/removable
        if echo "${info}" | grep -q "Removable Media:.*Yes\|Protocol:.*USB\|Location:.*External"; then
            local size name type
            size=$(echo "${info}" | grep "Disk Size:" | awk -F: '{print $2}' | xargs | cut -d'(' -f1 | xargs)
            name=$(echo "${info}" | grep "Volume Name:" | awk -F: '{print $2}' | xargs)
            type=$(echo "${info}" | grep "Protocol:" | awk -F: '{print $2}' | xargs)
            [[ -z "${name}" ]] && name="(unnamed)"
            [[ -z "${type}" ]] && type="Unknown"

            printf "%-10s %-10s %-20s %s\n" "${disknum}" "${size:-?}" "${type}" "${name}"
        fi
    done

    echo ""
    return 0
}

# Validate selected disk
validate_disk() {
    local disk="$1"

    # Normalize disk name
    disk="${disk#/dev/}"
    disk="${disk#disk}"
    disk="disk${disk}"

    local disk_path="/dev/${disk}"

    # Check disk exists
    if [[ ! -e "${disk_path}" ]]; then
        die "Disk ${disk_path} does not exist"
    fi

    # Get disk info
    local info
    info=$(diskutil info "${disk_path}" 2>/dev/null) || die "Cannot get info for ${disk_path}"

    # Safety: Check it's external/removable
    if ! echo "${info}" | grep -q "Removable Media:.*Yes\|Protocol:.*USB\|Location:.*External"; then
        die "SAFETY: ${disk_path} does not appear to be an external/USB drive!
Only external drives are allowed to prevent accidental data loss.
If this is wrong, check 'diskutil info ${disk_path}'"
    fi

    # Safety: Check it's not the boot disk
    local boot_disk
    boot_disk=$(diskutil info / | grep "Part of Whole:" | awk '{print $4}')
    if [[ "${disk}" == "${boot_disk}" ]]; then
        die "SAFETY: ${disk_path} is your boot disk! Cannot write to it."
    fi

    # Get size for warning
    local size
    size=$(echo "${info}" | grep "Disk Size:" | awk -F: '{print $2}' | xargs | cut -d'(' -f1 | xargs)

    echo "${disk}|${size}"
}

# Download Arch ISO
download_iso() {
    header "Downloading Arch Linux ${ARCH_VERSION}"

    # Update URLs with version
    ISO_NAME="archlinux-${ARCH_VERSION}-x86_64.iso"
    ISO_URL="${ARCH_MIRROR}/iso/${ARCH_VERSION}/${ISO_NAME}"
    SHA256_URL="${ARCH_MIRROR}/iso/${ARCH_VERSION}/sha256sums.txt"
    ISO_PATH="${DOWNLOAD_DIR}/${ISO_NAME}"

    # Check if already downloaded
    if [[ -f "${ISO_PATH}" ]]; then
        log "ISO already exists: ${ISO_PATH}"
        log "Verifying checksum..."

        # Download checksum
        local sha256_file="${DOWNLOAD_DIR}/sha256sums.txt"
        if curl -fSL -o "${sha256_file}" "${SHA256_URL}" 2>/dev/null; then
            local expected_sha256
            expected_sha256=$(grep "${ISO_NAME}" "${sha256_file}" | awk '{print $1}')

            if [[ -n "${expected_sha256}" ]]; then
                local actual_sha256
                actual_sha256=$(shasum -a 256 "${ISO_PATH}" | awk '{print $1}')

                if [[ "${expected_sha256}" == "${actual_sha256}" ]]; then
                    ok "Checksum verified"
                    rm -f "${sha256_file}"
                    return 0
                else
                    warn "Checksum mismatch, re-downloading..."
                    rm -f "${ISO_PATH}"
                fi
            fi
            rm -f "${sha256_file}"
        else
            warn "Could not verify checksum, using existing ISO"
            return 0
        fi
    fi

    # Download ISO
    log "Downloading from: ${ISO_URL}"
    log "This may take a while (~900MB)..."
    echo ""

    if ! curl -fSL --progress-bar -o "${ISO_PATH}" "${ISO_URL}"; then
        die "Failed to download ISO. Check your internet connection and try again.
URL: ${ISO_URL}"
    fi

    # Verify checksum
    log "Verifying checksum..."
    local sha256_file="${DOWNLOAD_DIR}/sha256sums.txt"
    if curl -fSL -o "${sha256_file}" "${SHA256_URL}" 2>/dev/null; then
        local expected_sha256
        expected_sha256=$(grep "${ISO_NAME}" "${sha256_file}" | awk '{print $1}')

        if [[ -n "${expected_sha256}" ]]; then
            local actual_sha256
            actual_sha256=$(shasum -a 256 "${ISO_PATH}" | awk '{print $1}')

            if [[ "${expected_sha256}" == "${actual_sha256}" ]]; then
                ok "Checksum verified"
            else
                rm -f "${ISO_PATH}"
                die "Checksum verification failed!
Expected: ${expected_sha256}
Got:      ${actual_sha256}"
            fi
        else
            warn "Could not find checksum for ${ISO_NAME} in sha256sums.txt"
        fi
        rm -f "${sha256_file}"
    else
        warn "Could not download checksum file, skipping verification"
    fi

    ok "Downloaded: ${ISO_PATH}"
}

# Write ISO to USB
write_iso() {
    local disk="$1"
    local rdisk="r${disk}"  # Raw disk for faster writes

    header "Writing ISO to /dev/${disk}"

    # Unmount all volumes on the disk
    log "Unmounting /dev/${disk}..."
    if ! diskutil unmountDisk "/dev/${disk}"; then
        die "Failed to unmount disk. Make sure no applications are using it."
    fi

    # Get ISO size for progress
    local iso_size
    iso_size=$(stat -f%z "${ISO_PATH}" 2>/dev/null || stat -c%s "${ISO_PATH}" 2>/dev/null)
    local iso_size_mb=$((iso_size / 1024 / 1024))

    log "Writing ${iso_size_mb}MB to /dev/${rdisk}..."
    warn "This will take several minutes. Do not disconnect the USB drive!"
    echo ""

    # Write ISO using dd with progress
    # Use raw disk (rdisk) for much faster writes
    if ! sudo dd if="${ISO_PATH}" of="/dev/${rdisk}" bs=4m status=progress 2>&1; then
        die "Failed to write ISO to disk"
    fi

    # Sync to ensure all data is written
    log "Syncing..."
    sync

    # Eject the disk
    log "Ejecting /dev/${disk}..."
    sleep 2
    diskutil eject "/dev/${disk}" || warn "Could not eject disk (may need manual eject)"

    ok "ISO written successfully!"
}

# Main
main() {
    header "Arch Linux USB Creator for macOS"

    # Just list drives?
    if [[ ${LIST_ONLY} -eq 1 ]]; then
        list_usb_drives
        exit 0
    fi

    # If no device specified, show drives and prompt
    if [[ -z "${DEVICE}" ]]; then
        if ! list_usb_drives; then
            exit 1
        fi

        echo ""
        read -p "Enter disk number to use (e.g., disk2): " DEVICE
        echo ""

        if [[ -z "${DEVICE}" ]]; then
            die "No disk specified"
        fi
    fi

    # Validate the disk
    local disk_info
    disk_info=$(validate_disk "${DEVICE}")
    local disk="${disk_info%%|*}"
    local size="${disk_info##*|}"

    echo ""
    echo "Selected disk:"
    echo "  Device: /dev/${disk}"
    echo "  Size:   ${size}"
    echo ""
    warn "ALL DATA ON /dev/${disk} WILL BE ERASED!"
    echo ""
    read -p "Type 'YES' to continue: " confirm

    if [[ "${confirm}" != "YES" ]]; then
        die "Aborted by user"
    fi

    # Download ISO
    download_iso

    # Write to USB
    write_iso "${disk}"

    header "Complete!"

    echo "Your Arch Linux USB is ready!"
    echo ""
    echo "To boot from USB:"
    echo "  1. Restart your Mac"
    echo "  2. Hold Option (Alt) key during startup"
    echo "  3. Select 'EFI Boot' or the USB drive"
    echo ""
    echo "For PC/other hardware:"
    echo "  1. Enter BIOS/UEFI setup (usually F2, F12, Del, or Esc at boot)"
    echo "  2. Select USB drive as boot device"
    echo "  3. Or use boot menu (usually F12)"
    echo ""
    echo "Once booted into Arch:"
    echo "  1. Connect to network:"
    echo "     - Ethernet: Usually automatic (dhcpcd)"
    echo "     - WiFi: iwctl device list && iwctl station wlan0 connect SSID"
    echo ""
    echo "  2. Clone lfs-infra and run setup:"
    echo "     pacman -Sy git"
    echo "     git clone <your-repo-url> lfs-infra"
    echo "     cd lfs-infra"
    echo "     ./scripts/install/setup-real-hardware.sh /dev/nvme0n1"
    echo ""

    # Cleanup ISO if not keeping
    if [[ ${KEEP_ISO} -eq 0 ]]; then
        log "Removing downloaded ISO (use -k to keep)..."
        rm -f "${ISO_PATH}"
    else
        log "ISO kept at: ${ISO_PATH}"
    fi

    # Generate the bootstrap command
    # Check if repo has a remote URL
    local REPO_URL=""
    if [[ -d "${ROOT_DIR}/.git" ]]; then
        REPO_URL=$(cd "${ROOT_DIR}" && git remote get-url origin 2>/dev/null | sed 's/git@github.com:/https:\/\/github.com\//' | sed 's/\.git$//' || true)
    fi

    local BOOTSTRAP_CMD=""
    if [[ -n "${REPO_URL}" ]]; then
        BOOTSTRAP_CMD="curl -sL ${REPO_URL}/raw/main/scripts/install/bootstrap.sh | sudo bash"
    else
        BOOTSTRAP_CMD="curl -sL https://raw.githubusercontent.com/YOUR_USER/lfs-infra/main/scripts/install/bootstrap.sh | sudo bash"
    fi

    # Copy to clipboard on macOS
    echo "${BOOTSTRAP_CMD}" | pbcopy 2>/dev/null || true

    echo ""
    echo "==========================================="
    echo " AFTER BOOTING - TYPE THIS ONE COMMAND:"
    echo "==========================================="
    echo ""
    echo "  ${BOOTSTRAP_CMD}"
    echo ""
    echo "(Command copied to clipboard!)"
    echo ""
    echo "This will:"
    echo "  1. Prompt for WiFi if needed"
    echo "  2. Install XFCE desktop"
    echo "  3. Install Firefox"
    echo "  4. Install Claude Code"
    echo "  5. Start SSH server"
    echo "  6. Launch desktop"
    echo ""
    echo "Then to install LFS on your hard drive:"
    echo "  git clone ${REPO_URL:-<your-repo>} lfs-infra"
    echo "  cd lfs-infra"
    echo "  sudo ./scripts/install/setup-real-hardware.sh /dev/nvme0n1"
    echo ""
}

main "$@"
