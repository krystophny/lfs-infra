#!/bin/bash
# Test LFS in QEMU with UEFI boot
# Usage: sudo ./scripts/test-qemu.sh

set -e

OVMF_CODE="/usr/share/edk2/ovmf/OVMF_CODE.fd"
OVMF_VARS="/tmp/OVMF_VARS_temp.fd"
DISK="${1:-/dev/nvme0n1}"

# Copy OVMF vars (writable)
cp /usr/share/edk2/ovmf/OVMF_VARS.fd "$OVMF_VARS" 2>/dev/null || true

exec qemu-system-x86_64 \
    -enable-kvm -m 4G -cpu host -smp 4 \
    -drive if=pflash,format=raw,unit=0,file="$OVMF_CODE",readonly=on \
    -drive if=pflash,format=raw,unit=1,file="$OVMF_VARS" \
    -drive file="$DISK",format=raw,if=none,id=disk0 \
    -device ahci,id=ahci \
    -device ide-hd,drive=disk0,bus=ahci.0 \
    -net nic,model=e1000 -net user \
    -display gtk \
    -serial stdio
