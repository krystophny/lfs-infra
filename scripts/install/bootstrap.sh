#!/bin/bash
# Ultra-minimal bootstrap - just type: curl -sL bit.ly/lfs-setup | bash
# Or the full URL from your repo
#
# This script:
# 1. Connects to WiFi (prompts if needed)
# 2. Installs XFCE + Firefox + Claude Code + SSH
# 3. Starts the desktop
#
# All runs in RAM - your drives are untouched

set -e

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

echo -e "${B}=== Arch Live Environment Bootstrap ===${N}"
echo ""

# Check root
[ $EUID -eq 0 ] || { echo -e "${R}Run as root: sudo bash${N}"; exit 1; }

# Network check and WiFi setup
if ! ping -c1 -W2 archlinux.org &>/dev/null; then
    echo -e "${Y}No network. Setting up WiFi...${N}"
    echo ""

    # Get WiFi interface
    WIFI=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1)
    [ -z "$WIFI" ] && WIFI=$(ip link | grep -E "wlan|wlp" | awk -F: '{print $2}' | tr -d ' ' | head -1)

    if [ -n "$WIFI" ]; then
        # Scan and show networks
        echo "Scanning for WiFi networks..."
        iwctl station "$WIFI" scan 2>/dev/null || true
        sleep 2
        iwctl station "$WIFI" get-networks 2>/dev/null || \
            iw dev "$WIFI" scan | grep SSID | head -10

        echo ""
        read -p "WiFi SSID: " SSID
        read -sp "Password: " PASS
        echo ""

        echo "Connecting..."
        iwctl station "$WIFI" connect "$SSID" --passphrase "$PASS" 2>/dev/null || \
            (wpa_passphrase "$SSID" "$PASS" > /tmp/w.conf && \
             ip link set "$WIFI" up && \
             wpa_supplicant -B -i "$WIFI" -c /tmp/w.conf && \
             dhcpcd "$WIFI") 2>/dev/null

        sleep 5
    fi

    ping -c1 -W2 archlinux.org &>/dev/null || { echo -e "${R}No network. Connect manually and retry.${N}"; exit 1; }
fi

echo -e "${G}Network OK${N}"
echo ""

# Install everything
echo -e "${B}Installing packages (5-10 min)...${N}"
pacman -Sy --noconfirm
pacman -S --noconfirm --needed \
    xorg-server xorg-xinit xfce4 xfce4-terminal lightdm lightdm-gtk-greeter \
    firefox ttf-dejavu pulseaudio pavucontrol \
    nodejs npm git vim openssh curl wget htop

# Claude Code
echo -e "${B}Installing Claude Code...${N}"
npm install -g @anthropic-ai/claude-code

# SSH
systemctl start sshd
echo "root:live" | chpasswd

# Desktop shortcut
mkdir -p /root/Desktop
cat > /root/Desktop/Claude.desktop <<EOF
[Desktop Entry]
Name=Claude Code
Exec=xfce4-terminal -e "claude"
Type=Application
EOF
chmod +x /root/Desktop/Claude.desktop

IP=$(ip -4 addr show | grep -v 127.0.0.1 | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)

echo ""
echo -e "${G}=========================================${N}"
echo -e "${G} READY! Starting desktop...${N}"
echo -e "${G}=========================================${N}"
echo ""
echo "SSH: ssh root@$IP (password: live)"
echo "Claude: Open terminal, type 'claude'"
echo ""

sleep 2
exec startxfce4
