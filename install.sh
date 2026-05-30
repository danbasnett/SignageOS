#!/usr/bin/env bash
# =============================================================================
# SignageOS Installer
# =============================================================================
# Run on a fresh Raspberry Pi OS Lite (Bookworm) or Debian Bookworm x86_64:
#
#   curl -fsSL https://raw.githubusercontent.com/@@GITHUB_REPO@@/main/install.sh | sudo bash
#
# Or download and run manually:
#   sudo bash install.sh
# =============================================================================
set -euo pipefail

SIGNAEOS_VERSION="${SIGNAEOS_VERSION:-dev}"
GITHUB_REPO="${GITHUB_REPO:-danbasnett/SignageOS}"
NODE_VERSION="20"

# ── Colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'
info()  { echo -e "${G}✓${N}  $*"; }
warn()  { echo -e "${Y}!${N}  $*"; }
error() { echo -e "${R}✗${N}  $*" >&2; exit 1; }
step()  { echo -e "\n${C}${B}▶ $*${N}"; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${C}${B}"
echo "  ███████╗██╗ ██████╗ ███╗   ██╗ █████╗  ██████╗ ███████╗ ██████╗ ███████╗"
echo "  ██╔════╝██║██╔════╝ ████╗  ██║██╔══██╗██╔════╝ ██╔════╝██╔═══██╗██╔════╝"
echo "  ███████╗██║██║  ███╗██╔██╗ ██║███████║██║  ███╗█████╗  ██║   ██║███████╗"
echo "  ╚════██║██║██║   ██║██║╚██╗██║██╔══██║██║   ██║██╔══╝  ██║   ██║╚════██║"
echo "  ███████║██║╚██████╔╝██║ ╚████║██║  ██║╚██████╔╝███████╗╚██████╔╝███████║"
echo "  ╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝"
echo -e "${N}"
echo -e "  Digital Signage OS  •  Version ${B}${SIGNAEOS_VERSION}${N}"
echo ""

# ── Checks ────────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash install.sh"

OS=$(. /etc/os-release && echo "$ID $VERSION_CODENAME")
info "OS: $OS"

ARCH=$(uname -m)
case "$ARCH" in
  aarch64) PLATFORM="linux-arm64" ;;
  armv7l)  PLATFORM="linux-arm" ;;
  x86_64)  PLATFORM="linux-x64" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac
info "Architecture: $ARCH"

# Check internet
ping -c1 -W3 8.8.8.8 &>/dev/null || error "No internet connection"
info "Network: OK"

# ── Packages ──────────────────────────────────────────────────────────────────
step "Installing packages"

apt-get update -q

# Core utilities
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  curl wget ca-certificates gnupg \
  jq socat \
  vlan \
  usbutils libusb-1.0-0 \
  unzip xz-utils \
  network-manager wpasupplicant \
  avahi-daemon libnss-mdns

info "Core utilities installed"

# Display stack — Weston Wayland compositor
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  weston \
  xwayland \
  libwayland-client0 \
  libinput10 \
  fonts-dejavu-core \
  fonts-noto-color-emoji

info "Display stack installed"

# Browsers
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  chromium-browser 2>/dev/null || \
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  chromium

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  firefox-esr 2>/dev/null || true

info "Browsers installed"

# ── Node.js ───────────────────────────────────────────────────────────────────
step "Installing Node.js $NODE_VERSION"

if ! command -v node &>/dev/null || [[ $(node -e "process.exit(parseInt(process.version.slice(1)) >= $NODE_VERSION ? 0 : 1)" 2>/dev/null; echo $?) -ne 0 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
fi

info "Node.js $(node --version) installed"

# ── Companion Satellite ───────────────────────────────────────────────────────
step "Installing Companion Satellite"

# Use the official Companion Satellite install script
# This creates a 'satellite' user and systemd service automatically
SATELLITE_INSTALL_URL="https://raw.githubusercontent.com/bitfocus/companion-satellite/main/install.sh"

if curl -fsSL "$SATELLITE_INSTALL_URL" -o /tmp/satellite-install.sh 2>/dev/null; then
  bash /tmp/satellite-install.sh
  rm -f /tmp/satellite-install.sh
  info "Companion Satellite installed via official script"
else
  warn "Could not download Companion Satellite install script"
  warn "Install manually: curl https://raw.githubusercontent.com/bitfocus/companion-satellite/main/install.sh | bash"
fi

# ── NDI SDK ───────────────────────────────────────────────────────────────────
step "Installing NDI SDK"

NDI_URL="https://downloads.ndi.tv/SDK/NDI_SDK_Linux/Install_NDI_SDK_v6_Linux.tar.gz"
TMP=$(mktemp -d)
if curl -fsSL --connect-timeout 30 "$NDI_URL" -o "$TMP/ndi.tar.gz"; then
  tar -xzf "$TMP/ndi.tar.gz" -C "$TMP"
  ACCEPT_NDI_LICENSE=y "$TMP"/Install_NDI_SDK_v6_Linux.sh || true
  echo "/usr/local/lib" > /etc/ld.so.conf.d/ndi.conf
  ldconfig
  info "NDI SDK installed"
else
  warn "NDI SDK download failed — NDI features unavailable"
  warn "Install manually later from https://ndi.video/for-developers/ndi-sdk/"
fi
rm -rf "$TMP"

# ── SignageOS files ───────────────────────────────────────────────────────────
step "Installing SignageOS files"

FILES_URL="https://github.com/${GITHUB_REPO}/releases/download/v${SIGNAEOS_VERSION}/signaeos-files.tar.gz"
TMP=$(mktemp -d)

if curl -fsSL --head "$FILES_URL" 2>/dev/null | grep -q "200\|302"; then
  info "Downloading SignageOS files from release..."
  curl -fsSL "$FILES_URL" -o "$TMP/signaeos-files.tar.gz"
  tar -xzf "$TMP/signaeos-files.tar.gz" -C /
else
  warn "Release tarball not found — downloading files directly from repository..."
  # Download each file individually from the repo
  BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main"

  # Systemd services
  for svc in signaeos-display1 signaeos-display2 signaeos-webui \
             companion-satellite weston signaeos-update; do
    mkdir -p /etc/systemd/system
    curl -fsSL "$BASE_URL/rootfs/etc/systemd/system/${svc}.service" \
      -o "/etc/systemd/system/${svc}.service" 2>/dev/null || true
  done
  curl -fsSL "$BASE_URL/rootfs/etc/systemd/system/signaeos-update.timer" \
    -o "/etc/systemd/system/signaeos-update.timer" 2>/dev/null || true

  # Weston config
  mkdir -p /etc/weston
  curl -fsSL "$BASE_URL/rootfs/etc/weston/weston.ini" \
    -o "/etc/weston/weston.ini" 2>/dev/null || true

  # Binaries
  mkdir -p /usr/bin
  for bin in signaeos-display1 signaeos-display2 signaeos-ctl signaeos-update; do
    curl -fsSL "$BASE_URL/rootfs/usr/bin/${bin}" -o "/usr/bin/${bin}"
    chmod +x "/usr/bin/${bin}"
  done

  # Web UI
  mkdir -p /usr/share/signaeos/webui/public
  curl -fsSL "$BASE_URL/rootfs/usr/share/signaeos/webui/server.js" \
    -o "/usr/share/signaeos/webui/server.js"
  curl -fsSL "$BASE_URL/rootfs/usr/share/signaeos/webui/package.json" \
    -o "/usr/share/signaeos/webui/package.json"
  curl -fsSL "$BASE_URL/rootfs/usr/share/signaeos/webui/public/index.html" \
    -o "/usr/share/signaeos/webui/public/index.html"
fi

rm -rf "$TMP"
info "SignageOS files installed"

# ── Web UI dependencies ───────────────────────────────────────────────────────
step "Installing web UI dependencies"

cd /usr/share/signaeos/webui
npm install --production --no-audit --no-fund
info "Web UI ready"

# ── Data directory ────────────────────────────────────────────────────────────
step "Setting up data directory"
mkdir -p /data/signaeos /data/chromium-profile /data/firefox-profile

# ── System config ─────────────────────────────────────────────────────────────
step "Configuring system"

# NetworkManager — take over all network management
cat > /etc/NetworkManager/conf.d/99-signaeos.conf <<'EOF'
[main]
plugins=keyfile
dhcp=internal

[ifupdown]
managed=true
EOF

# 802.1q VLAN support
echo "8021q" >> /etc/modules-load.d/signaeos.conf

# Stream Deck udev rule
cat > /etc/udev/rules.d/50-streamdeck.rules <<'EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="0fd9", MODE="0666", GROUP="plugdev"
EOF
udevadm control --reload-rules 2>/dev/null || true

# Weston config
mkdir -p /etc/weston
cat > /etc/weston/weston.ini <<'EOF'
[core]
backend=drm-backend.so
shell=kiosk-shell.so
idle-time=0
repaint-window=8

[output]
name=HDMI-A-1
mode=1920x1080@60
transform=normal

[output]
name=HDMI-A-2
mode=1920x1080@60
transform=normal

[keyboard]
keymap_rules=evdev
keymap_layout=gb
EOF

# Version stamp
echo "$SIGNAEOS_VERSION" > /etc/signaeos-version

# ── Systemd services ──────────────────────────────────────────────────────────
step "Enabling services"

systemctl daemon-reload

systemctl enable \
  weston.service \
  signaeos-display1.service \
  signaeos-display2.service \
  signaeos-webui.service \
  companion-satellite.service \
  signaeos-update.timer \
  NetworkManager.service \
  avahi-daemon.service

# Disable conflicting services
systemctl disable lightdm 2>/dev/null || true
systemctl disable gdm    2>/dev/null || true
systemctl disable sddm   2>/dev/null || true

# Make sure we boot to multi-user (no desktop login manager)
systemctl set-default multi-user.target

info "Services enabled"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${G}${B}═══════════════════════════════════════════${N}"
echo -e "${G}${B}  SignageOS installed successfully!${N}"
echo -e "${G}${B}═══════════════════════════════════════════${N}"
echo ""
echo -e "  Version  : ${B}${SIGNAEOS_VERSION}${N}"
echo -e "  Setup UI : ${B}http://$(hostname -I | awk '{print $1}'):3000${N}"
echo -e "  Also try : ${B}http://$(hostname).local:3000${N}"
echo ""
echo "  Starting services now..."
echo ""

systemctl restart NetworkManager avahi-daemon
systemctl start weston signaeos-webui signaeos-display1 signaeos-display2 companion-satellite 2>/dev/null || true

echo -e "  ${G}Browse to http://$(hostname).local:3000 to configure SignageOS${N}"
echo ""
echo "  To check status:"
echo "    sudo systemctl status signaeos-webui"
echo "    sudo journalctl -u signaeos-display1 -f"
echo ""
