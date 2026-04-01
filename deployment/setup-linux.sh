#!/usr/bin/env bash
#
# Baraka Printer Proxy — Linux Setup
# ====================================
# Sets up USB printer permissions, installs system deps,
# creates Python venv, and optionally installs a systemd service.
#
# Usage: sudo bash setup-linux.sh
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }

# ─── Root check ──────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (sudo bash setup-linux.sh)"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "============================================"
echo "  Baraka Printer Proxy — Linux Setup"
echo "============================================"
echo ""
echo "  Project dir:  $PROJECT_DIR"
echo "  Running as:   root (for user: $REAL_USER)"
echo ""

# ─── 1. System dependencies ─────────────────────────────────
info "Installing system dependencies..."

if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq python3 python3-venv python3-pip
elif command -v dnf &>/dev/null; then
    dnf install -y python3 python3-pip
elif command -v pacman &>/dev/null; then
    pacman -S --noconfirm --needed python python-pip
elif command -v zypper &>/dev/null; then
    zypper install -y python3 python3-pip
else
    warn "Unknown package manager — please install python3 and pip manually"
fi

info "System dependencies installed"

# ─── 2. USB printer permissions (udev) ──────────────────────
info "Setting up USB printer permissions..."

UDEV_RULES="/etc/udev/rules.d/99-thermal-printer.rules"

# Detect serial group (dialout on Debian/Ubuntu/Fedora, uucp on Arch)
if getent group dialout >/dev/null 2>&1; then
    SERIAL_GRP="dialout"
elif getent group uucp >/dev/null 2>&1; then
    SERIAL_GRP="uucp"
else
    SERIAL_GRP="root"
fi

cat > "$UDEV_RULES" << RULES
# Baraka Printer Proxy — allow user access to USB printer devices
#
# /dev/usb/lp* devices (created by usblp kernel module)
SUBSYSTEM=="usbmisc", KERNEL=="lp*", MODE="0666", GROUP="lp"

# Serial adapters commonly used in thermal printers (CH340, PL2303, CP2102, FTDI)
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", MODE="0666", GROUP="$SERIAL_GRP"
SUBSYSTEM=="tty", ATTRS{idVendor}=="067b", MODE="0666", GROUP="$SERIAL_GRP"
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", MODE="0666", GROUP="$SERIAL_GRP"
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", MODE="0666", GROUP="$SERIAL_GRP"
RULES

udevadm control --reload-rules
udevadm trigger

info "Udev rules installed at $UDEV_RULES"

# ─── 3. Add user to lp group ────────────────────────────────
if getent group lp >/dev/null 2>&1; then
    if id -nG "$REAL_USER" | grep -qw "lp"; then
        info "User '$REAL_USER' is already in the 'lp' group"
    else
        usermod -aG lp "$REAL_USER"
        info "Added '$REAL_USER' to 'lp' group (re-login required for full effect)"
    fi
else
    warn "'lp' group does not exist — USB printer access may need manual permission setup"
fi

# ─── 4. Ensure usblp kernel module is loaded ────────────────
# usblp creates /dev/usb/lp* devices that we write to directly.
# Remove any old blacklist from previous setup versions.
if [ -f /etc/modprobe.d/no-usblp.conf ]; then
    rm /etc/modprobe.d/no-usblp.conf
    info "Removed old usblp blacklist (we need usblp now)"
fi

if ! lsmod | grep -q usblp; then
    modprobe usblp 2>/dev/null || true
    info "Loaded usblp kernel module"
else
    info "usblp kernel module already loaded"
fi

# ─── 4b. Add user to serial group (for serial printers) ─────
# Arch uses 'uucp', Debian/Ubuntu uses 'dialout'
SERIAL_GROUP=""
if getent group dialout >/dev/null 2>&1; then
    SERIAL_GROUP="dialout"
elif getent group uucp >/dev/null 2>&1; then
    SERIAL_GROUP="uucp"
fi

if [ -n "$SERIAL_GROUP" ]; then
    if id -nG "$REAL_USER" | grep -qw "$SERIAL_GROUP"; then
        info "User '$REAL_USER' is already in the '$SERIAL_GROUP' group"
    else
        usermod -aG "$SERIAL_GROUP" "$REAL_USER"
        info "Added '$REAL_USER' to '$SERIAL_GROUP' group (for serial printers)"
    fi
else
    warn "No serial group found (dialout/uucp) — serial printers may need manual permission setup"
fi

# ─── 5. Python virtual environment ──────────────────────────
VENV_DIR="$PROJECT_DIR/venv"

if [ ! -d "$VENV_DIR" ]; then
    info "Creating Python virtual environment..."
    sudo -u "$REAL_USER" python3 -m venv "$VENV_DIR"
    info "Venv created at $VENV_DIR"
else
    info "Venv already exists at $VENV_DIR"
fi

info "Installing Python dependencies..."
sudo -u "$REAL_USER" "$VENV_DIR/bin/pip" install -q -r "$PROJECT_DIR/requirements.txt"
info "Python dependencies installed"

# ─── 6. Systemd service (auto-start on boot) ────────────────
info "Setting up systemd service..."

SERVICE_FILE="/etc/systemd/system/baraka-printer.service"

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Baraka Printer Proxy Server
After=network.target

[Service]
Type=simple
User=$REAL_USER
Group=$REAL_USER
WorkingDirectory=$PROJECT_DIR
ExecStart=$VENV_DIR/bin/python $PROJECT_DIR/app.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable baraka-printer.service
systemctl restart baraka-printer.service

info "Systemd service installed and started"
info "  Status:  systemctl status baraka-printer"
info "  Logs:    journalctl -u baraka-printer -f"
info "  Stop:    systemctl stop baraka-printer"
info "  Restart: systemctl restart baraka-printer"

# ─── Done ────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  Server:  http://localhost:3006"
echo "  Health:  http://localhost:3006/api/health"
echo ""

if ! id -nG "$REAL_USER" | grep -qw "lp"; then
    warn "You need to log out and back in for USB permissions to take effect"
    warn "Or run: newgrp lp"
fi

echo ""
info "Done."
