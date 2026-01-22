#!/bin/bash
# Setup Live Arch Environment with XFCE, Firefox, Claude Code, SSH
# Run this after booting from Arch live USB
# Everything runs in RAM - does NOT touch your hard drives
#
# Usage: curl -sL <raw-url> | bash
#    or: ./setup-live-environment.sh [--wifi SSID PASSWORD]

set -euo pipefail

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

[[ "$(uname -s)" == "Linux" ]] || die "Must run from Linux (Arch live USB)"
[[ $EUID -eq 0 ]] || die "Must run as root"

# Parse WiFi credentials if provided
WIFI_SSID=""
WIFI_PASS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wifi)
            WIFI_SSID="$2"
            WIFI_PASS="$3"
            shift 3
            ;;
        --help|-h)
            echo "Usage: $0 [--wifi SSID PASSWORD]"
            echo ""
            echo "Sets up live Arch environment with XFCE, Firefox, Claude Code"
            echo "Everything runs in RAM - your drives are not touched"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

header "Live Arch Environment Setup"
echo "This will install XFCE, Firefox, Claude Code, and SSH"
echo "Everything runs in RAM - your hard drives will NOT be touched"
echo ""

header "Network Setup"

# Check for network
if ping -c 1 -W 2 archlinux.org &>/dev/null; then
    ok "Network already connected"
else
    # Try to connect to WiFi
    if [[ -n "${WIFI_SSID}" ]]; then
        log "Connecting to WiFi: ${WIFI_SSID}..."

        # Use iwctl if available
        if command -v iwctl &>/dev/null; then
            # Get wireless device
            WIFI_DEV=$(iwctl device list | grep -E "^\s+wlan" | awk '{print $1}' | head -1)
            if [[ -n "${WIFI_DEV}" ]]; then
                iwctl station "${WIFI_DEV}" connect "${WIFI_SSID}" --passphrase "${WIFI_PASS}" || true
                sleep 3
            fi
        fi

        # Try wpa_supplicant as fallback
        if ! ping -c 1 -W 2 archlinux.org &>/dev/null; then
            WIFI_DEV=$(ip link | grep -E "wlan|wlp" | awk -F: '{print $2}' | tr -d ' ' | head -1)
            if [[ -n "${WIFI_DEV}" ]]; then
                log "Trying wpa_supplicant..."
                wpa_passphrase "${WIFI_SSID}" "${WIFI_PASS}" > /tmp/wpa.conf
                wpa_supplicant -B -i "${WIFI_DEV}" -c /tmp/wpa.conf 2>/dev/null || true
                dhcpcd "${WIFI_DEV}" 2>/dev/null || true
                sleep 3
            fi
        fi
    fi

    # Check again
    if ! ping -c 1 -W 2 archlinux.org &>/dev/null; then
        warn "No network connection"
        echo ""
        echo "Please connect to network manually:"
        echo ""
        echo "For WiFi (using iwctl):"
        echo "  iwctl"
        echo "  station wlan0 scan"
        echo "  station wlan0 connect YOUR_SSID"
        echo "  exit"
        echo ""
        echo "For Ethernet: should be automatic"
        echo ""
        echo "Then re-run this script"
        echo ""

        # Interactive WiFi setup
        read -p "Enter WiFi SSID (or press Enter to skip): " WIFI_SSID
        if [[ -n "${WIFI_SSID}" ]]; then
            read -sp "Enter WiFi password: " WIFI_PASS
            echo ""

            WIFI_DEV=$(iwctl device list 2>/dev/null | grep -E "^\s+wlan" | awk '{print $1}' | head -1)
            if [[ -z "${WIFI_DEV}" ]]; then
                WIFI_DEV=$(ip link | grep -E "wlan|wlp" | awk -F: '{print $2}' | tr -d ' ' | head -1)
            fi

            if [[ -n "${WIFI_DEV}" ]]; then
                log "Connecting to ${WIFI_SSID} on ${WIFI_DEV}..."
                iwctl station "${WIFI_DEV}" connect "${WIFI_SSID}" --passphrase "${WIFI_PASS}" 2>/dev/null || \
                (wpa_passphrase "${WIFI_SSID}" "${WIFI_PASS}" > /tmp/wpa.conf && \
                 wpa_supplicant -B -i "${WIFI_DEV}" -c /tmp/wpa.conf && \
                 dhcpcd "${WIFI_DEV}") 2>/dev/null || true
                sleep 5
            fi
        fi

        if ! ping -c 1 -W 2 archlinux.org &>/dev/null; then
            die "Still no network. Please connect manually and re-run."
        fi
    fi
    ok "Network connected"
fi

header "Updating Package Database"

log "Syncing package database..."
pacman -Sy --noconfirm

header "Installing Xorg and XFCE"

log "Installing display server and desktop (this takes a few minutes)..."
pacman -S --noconfirm --needed \
    xorg-server xorg-xinit xorg-xrandr xorg-xset \
    xfce4 xfce4-terminal thunar \
    lightdm lightdm-gtk-greeter \
    ttf-dejavu ttf-liberation \
    pulseaudio pulseaudio-alsa pavucontrol

header "Installing Firefox"

log "Installing Firefox..."
pacman -S --noconfirm --needed firefox

header "Installing Claude Code"

log "Installing Node.js and npm..."
pacman -S --noconfirm --needed nodejs npm

log "Installing Claude Code..."
npm install -g @anthropic-ai/claude-code

header "Installing SSH and Tools"

log "Installing development tools..."
pacman -S --noconfirm --needed \
    openssh \
    git vim nano \
    curl wget \
    htop \
    ripgrep fd \
    unzip

# Start SSH server
log "Starting SSH server..."
systemctl start sshd

# Set root password for SSH access
echo "root:live" | chpasswd
warn "SSH enabled - root password is 'live' (change if needed)"

header "Configuring Desktop"

# Create startx script
cat > /root/.xinitrc <<'EOF'
exec startxfce4
EOF

# Create a launcher script for Claude
cat > /usr/local/bin/start-desktop <<'EOF'
#!/bin/bash
# Start XFCE desktop
export XDG_SESSION_TYPE=x11
startxfce4
EOF
chmod +x /usr/local/bin/start-desktop

# Create desktop entry for Claude Code
mkdir -p /usr/share/applications
cat > /usr/share/applications/claude-code.desktop <<'EOF'
[Desktop Entry]
Name=Claude Code
Comment=AI-powered coding assistant
Exec=xfce4-terminal -e "claude"
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=Development;
EOF

# Create a welcome file on desktop
mkdir -p /root/Desktop
cat > /root/Desktop/README.txt <<'EOF'
==========================================
 Arch Linux Live Environment Ready!
==========================================

This is a live system running in RAM.
Your hard drives have NOT been modified.

Available tools:
  - Firefox: Click icon or run 'firefox'
  - Claude Code: Open terminal and run 'claude'
  - File Manager: Thunar
  - Terminal: xfce4-terminal

SSH Access:
  - SSH server is running
  - Username: root
  - Password: live
  - Connect: ssh root@<this-ip>

To install LFS on your hard drive:
  1. Open terminal
  2. git clone <your-repo> lfs-infra
  3. cd lfs-infra
  4. sudo ./scripts/install/setup-real-hardware.sh /dev/nvme0n1

Your IP address:
EOF
ip addr | grep "inet " | grep -v "127.0.0.1" | awk '{print "  " $2}' >> /root/Desktop/README.txt

chmod +x /root/Desktop/README.txt

header "Starting Desktop Environment"

ok "Installation complete!"
echo ""
echo "==========================================="
echo " Live Environment Ready!"
echo "==========================================="
echo ""
echo "Starting XFCE desktop in 3 seconds..."
echo "(Or press Ctrl+C to stay in terminal)"
echo ""
echo "SSH access: root@$(ip addr | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1 | head -1) (password: live)"
echo ""

sleep 3

# Start the desktop
exec startxfce4
