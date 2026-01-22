#!/bin/bash
# Test LFS image in QEMU on macOS
# Boots the built image without needing physical USB

set -euo pipefail

IMAGE="${1:-${HOME}/lfs-build/lfs-minimal.img}"
MEMORY="${MEMORY:-4G}"
CPUS="${CPUS:-4}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
die() { echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

# Check image exists
[[ -f "${IMAGE}" ]] || die "Image not found: ${IMAGE}
Build it first: ./scripts/macos/build-lfs-docker.sh -b"

# Check QEMU installed
if ! command -v qemu-system-x86_64 &>/dev/null; then
    die "QEMU not installed. Install with: brew install qemu"
fi

# Find UEFI firmware
OVMF=""
for path in \
    /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
    /usr/local/share/qemu/edk2-x86_64-code.fd \
    /opt/homebrew/Cellar/qemu/*/share/qemu/edk2-x86_64-code.fd; do
    if [[ -f "${path}" ]]; then
        OVMF="${path}"
        break
    fi
done

[[ -n "${OVMF}" ]] || die "UEFI firmware not found. Reinstall QEMU: brew reinstall qemu"

log "Booting: ${IMAGE}"
log "Memory: ${MEMORY}, CPUs: ${CPUS}"
log "UEFI: ${OVMF}"
echo ""
ok "Starting QEMU... (Ctrl+A, X to quit)"
echo ""

exec qemu-system-x86_64 \
    -m "${MEMORY}" \
    -smp "${CPUS}" \
    -drive file="${IMAGE}",format=raw,if=virtio \
    -bios "${OVMF}" \
    -device virtio-vga \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -usb -device usb-tablet \
    -audiodev coreaudio,id=audio0 \
    -device ich9-intel-hda -device hda-output,audiodev=audio0
