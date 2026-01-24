#!/bin/bash
# Test LFS boot in QEMU with both graphical and serial output

OVMF_CODE="/usr/share/edk2/ovmf/OVMF_CODE.fd"
OVMF_VARS="/usr/share/edk2/ovmf/OVMF_VARS.fd"

cp "${OVMF_VARS}" /tmp/OVMF_VARS_temp.fd 2>/dev/null

echo "Starting QEMU... (serial output will appear here too)"
echo "Close window or Ctrl-C to exit"

sudo qemu-system-x86_64 \
    -enable-kvm \
    -m 4G \
    -cpu host \
    -smp 4 \
    -drive if=pflash,format=raw,unit=0,file="${OVMF_CODE}",readonly=on \
    -drive if=pflash,format=raw,unit=1,file=/tmp/OVMF_VARS_temp.fd \
    -drive file=/dev/nvme0n1,format=raw,if=none,id=disk0 \
    -device ahci,id=ahci \
    -device ide-hd,drive=disk0,bus=ahci.0 \
    -net nic -net user \
    -vga std \
    -serial stdio

rm -f /tmp/OVMF_VARS_temp.fd
