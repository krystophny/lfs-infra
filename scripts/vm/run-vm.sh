#!/bin/bash
# LFS VM Test Runner
# Runs the LFS system in QEMU/KVM for testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"

# VM Configuration - optimized for build server (94GB RAM, 32 cores)
VM_NAME="${VM_NAME:-lfs-test}"
VM_MEMORY="${VM_MEMORY:-80G}"
VM_CPUS="${VM_CPUS:-$(nproc)}"
VM_DISK="${VM_DISK:-/mnt/storage/lfs.qcow2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-512G}"

# Display
VM_DISPLAY="${VM_DISPLAY:-sdl}"  # sdl, gtk, spice, vnc
VM_RESOLUTION="${VM_RESOLUTION:-1920x1080}"

# Networking
VM_NET="${VM_NET:-user}"  # user, tap, bridge

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [COMMAND]

Run LFS in a QEMU/KVM virtual machine.

Commands:
    create      Create a new VM disk image
    run         Start the VM (default)
    install     Boot from ISO to install
    ssh         SSH into running VM

Options:
    -m, --memory SIZE    VM memory (default: 4G)
    -c, --cpus NUM       Number of CPUs (default: all)
    -d, --disk FILE      Disk image path
    -s, --size SIZE      New disk size (default: 20G)
    -i, --iso FILE       Boot from ISO
    --spice              Use SPICE display (better performance)
    --vnc PORT           Use VNC on port
    -h, --help           Show this help

Examples:
    $(basename "$0") create                    # Create new disk
    $(basename "$0") run                       # Start VM
    $(basename "$0") -m 8G -c 4 run           # Custom resources
    $(basename "$0") --spice run              # SPICE display
    $(basename "$0") -i lfs.iso install       # Install from ISO
EOF
    exit 0
}

ISO_FILE=""
COMMAND="run"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--memory) VM_MEMORY="$2"; shift 2 ;;
        -c|--cpus) VM_CPUS="$2"; shift 2 ;;
        -d|--disk) VM_DISK="$2"; shift 2 ;;
        -s|--size) VM_DISK_SIZE="$2"; shift 2 ;;
        -i|--iso) ISO_FILE="$2"; shift 2 ;;
        --spice) VM_DISPLAY="spice"; shift ;;
        --vnc) VM_DISPLAY="vnc"; VNC_PORT="$2"; shift 2 ;;
        -h|--help) usage ;;
        create|run|install|ssh) COMMAND="$1"; shift ;;
        *) log_error "Unknown option: $1" ;;
    esac
done

# Check QEMU is available
check_qemu() {
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        log_error "QEMU not found. Install with: pacman -S qemu-full"
    fi

    # Check KVM support
    if [[ -r /dev/kvm ]]; then
        KVM_OPTS="-enable-kvm -cpu host"
        log_info "KVM acceleration enabled"
    else
        KVM_OPTS="-cpu max"
        log_info "KVM not available, using software emulation"
    fi
}

# Create disk image
create_disk() {
    log_info "Creating disk image: ${VM_DISK}"

    mkdir -p "$(dirname "${VM_DISK}")"
    qemu-img create -f qcow2 "${VM_DISK}" "${VM_DISK_SIZE}"

    log_ok "Disk created: ${VM_DISK} (${VM_DISK_SIZE})"
}

# Build QEMU command
build_qemu_cmd() {
    local cmd=(
        qemu-system-x86_64
        ${KVM_OPTS}
        -name "${VM_NAME}"
        -m "${VM_MEMORY}"
        -smp "${VM_CPUS}"
        -machine q35,accel=kvm:tcg

        # Firmware (UEFI if available, fallback to BIOS)
        # -bios /usr/share/ovmf/OVMF.fd

        # Boot drive
        -drive file="${VM_DISK}",if=virtio,format=qcow2,cache=writeback

        # VirtIO GPU
        -device virtio-vga-gl
        -display "${VM_DISPLAY},gl=on"

        # Network
        -netdev user,id=net0,hostfwd=tcp::2222-:22
        -device virtio-net-pci,netdev=net0

        # Input
        -device virtio-keyboard-pci
        -device virtio-mouse-pci

        # Audio
        -audiodev sdl,id=audio0
        -device ich9-intel-hda
        -device hda-duplex,audiodev=audio0

        # RNG
        -device virtio-rng-pci

        # Serial console (for debugging)
        -serial mon:stdio

        # QEMU guest agent
        -chardev socket,path=/tmp/qga.sock,server=on,wait=off,id=qga0
        -device virtio-serial
        -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
    )

    # SPICE display
    if [[ "${VM_DISPLAY}" == "spice" ]]; then
        cmd+=(
            -spice port=5900,disable-ticketing=on
            -device virtio-serial-pci
            -chardev spicevmc,id=vdagent,name=vdagent
            -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
        )
        log_info "SPICE available at: spice://localhost:5900"
    fi

    # VNC display
    if [[ "${VM_DISPLAY}" == "vnc" ]]; then
        cmd+=(-vnc ":${VNC_PORT:-0}")
        log_info "VNC available at: localhost:$((5900 + ${VNC_PORT:-0}))"
    fi

    # ISO boot
    if [[ -n "${ISO_FILE}" ]]; then
        cmd+=(-cdrom "${ISO_FILE}" -boot d)
    fi

    echo "${cmd[@]}"
}

# Run VM
run_vm() {
    check_qemu

    if [[ ! -f "${VM_DISK}" ]]; then
        log_info "Disk not found, creating..."
        create_disk
    fi

    log_info "Starting VM: ${VM_NAME}"
    log_info "Memory: ${VM_MEMORY}, CPUs: ${VM_CPUS}"
    log_info "Disk: ${VM_DISK}"
    log_info "SSH: ssh -p 2222 user@localhost"
    echo ""

    eval "$(build_qemu_cmd)"
}

# SSH into VM
ssh_vm() {
    ssh -p 2222 -o StrictHostKeyChecking=no user@localhost
}

# Main
case "${COMMAND}" in
    create)
        create_disk
        ;;
    run)
        run_vm
        ;;
    install)
        if [[ -z "${ISO_FILE}" ]]; then
            log_error "No ISO specified. Use: $0 -i file.iso install"
        fi
        run_vm
        ;;
    ssh)
        ssh_vm
        ;;
    *)
        usage
        ;;
esac
