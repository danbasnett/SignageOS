#!/usr/bin/env bash
# =============================================================================
# SignageOS Installer
# =============================================================================
# Run on a fresh Raspberry Pi OS Lite (Bookworm) or Debian Bookworm x86_64:
#
#   curl -fsSL https://raw.githubusercontent.com/@@GITHUB_REPO@@/main/install.sh | sudo bash
#
# To test an unreleased branch:
#   curl -fsSL https://raw.githubusercontent.com/danbasnett/SignageOS/codex/pi-dual-display-ndi-url/install.sh | sudo SIGNAEOS_REF=codex/pi-dual-display-ndi-url bash
#
# Or download and run manually:
#   sudo bash install.sh
# =============================================================================
set -euo pipefail

SIGNAEOS_VERSION="${SIGNAEOS_VERSION:-dev}"
GITHUB_REPO="${GITHUB_REPO:-danbasnett/SignageOS}"
SIGNAEOS_REF="${SIGNAEOS_REF:-main}"
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
  seatd \
  usbutils libusb-1.0-0 \
  unzip xz-utils \
  network-manager wpasupplicant \
  avahi-daemon libnss-mdns

info "Core utilities installed"

# Display stack — Sway Wayland compositor. Sway lets us pin workspace 1 to
# one HDMI output and workspace 2 to the other, which is how SignageOS keeps
# web and NDI content on separate displays.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  sway \
  xwayland \
  libwayland-client0 \
  libinput10 \
  libgles2 \
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

# Native NDI player build/runtime dependencies
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential \
  pkg-config \
  libsdl2-2.0-0 \
  libsdl2-dev

info "NDI player dependencies installed"

# ── Runtime user ──────────────────────────────────────────────────────────────
step "Creating SignageOS runtime user"

if ! id signaeos &>/dev/null; then
  useradd -m -s /bin/bash signaeos
fi
for group in video input render audio plugdev seat; do
  getent group "$group" >/dev/null && usermod -aG "$group" signaeos || true
done
info "Runtime user ready"

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
  BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${SIGNAEOS_REF}"

  # Systemd services
  for svc in signaeos-display1 signaeos-display2 signaeos-webui \
             companion-satellite sway signaeos-update; do
    mkdir -p /etc/systemd/system
    curl -fsSL "$BASE_URL/rootfs/etc/systemd/system/${svc}.service" \
      -o "/etc/systemd/system/${svc}.service" 2>/dev/null || true
  done
  curl -fsSL "$BASE_URL/rootfs/etc/systemd/system/signaeos-update.timer" \
    -o "/etc/systemd/system/signaeos-update.timer" 2>/dev/null || true

  # Sway config
  mkdir -p /etc/sway
  curl -fsSL "$BASE_URL/rootfs/etc/sway/config" \
    -o "/etc/sway/config" 2>/dev/null || true

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

  # Validation script
  mkdir -p /usr/share/signaeos/scripts
  curl -fsSL "$BASE_URL/rootfs/usr/share/signaeos/scripts/validate-pi.sh" \
    -o "/usr/share/signaeos/scripts/validate-pi.sh" 2>/dev/null || true
  chmod +x /usr/share/signaeos/scripts/validate-pi.sh 2>/dev/null || true

  # Native NDI player source
  mkdir -p /usr/src/signaeos
  curl -fsSL "$BASE_URL/rootfs/usr/src/signaeos/ndi-player.c" \
    -o "/usr/src/signaeos/ndi-player.c" 2>/dev/null || true
fi

rm -rf "$TMP"
info "SignageOS files installed"

# ── Native NDI player ────────────────────────────────────────────────────────
step "Building native NDI player"

NDI_HEADER="$(find /usr/local/include /usr/include -name Processing.NDI.Lib.h 2>/dev/null | head -1 || true)"
if [[ -f /usr/src/signaeos/ndi-player.c ]] && [[ -n "$NDI_HEADER" ]]; then
  NDI_INCLUDE_DIR="$(dirname "$NDI_HEADER")"
  if gcc /usr/src/signaeos/ndi-player.c -o /usr/bin/signaeos-ndi-player \
      -I"$NDI_INCLUDE_DIR" -L/usr/local/lib $(pkg-config --cflags --libs sdl2) -lndi; then
    chmod +x /usr/bin/signaeos-ndi-player
    info "Native NDI player installed"
  else
    warn "Native NDI player build failed — Display 2 will try VLC/ndiplay fallback"
  fi
else
  warn "NDI SDK headers or player source missing — Display 2 will try VLC/ndiplay fallback"
fi

# ── Web UI dependencies ───────────────────────────────────────────────────────
step "Installing web UI dependencies"

cd /usr/share/signaeos/webui
npm install --production --no-audit --no-fund
info "Web UI ready"

# ── Data directory ────────────────────────────────────────────────────────────
step "Setting up data directory"
mkdir -p /data/signaeos /data/chromium-profile /data/firefox-profile /data/chromium-d2
chown -R signaeos:signaeos /data/signaeos /data/chromium-profile /data/firefox-profile /data/chromium-d2

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

# Sway config
mkdir -p /etc/sway
cat > /etc/sway/config <<'EOF'
output HDMI-A-1 enable position 0 0
output HDMI-A-2 enable position 1920 0

workspace 1 output HDMI-A-1
workspace 2 output HDMI-A-2

for_window [app_id="chromium"] fullscreen enable
for_window [app_id="vlc"]      fullscreen enable
for_window [title="SignageOS NDI"] fullscreen enable

default_border none
default_floating_border none
hide_edge_borders --i3 both
gaps inner 0
gaps outer 0
seat * hide_cursor 3000
focus_follows_mouse no
EOF

# Version stamp
echo "$SIGNAEOS_VERSION" > /etc/signaeos-version

# ── Systemd services ──────────────────────────────────────────────────────────
step "Enabling services"

systemctl daemon-reload

systemctl enable \
  sway.service \
  signaeos-display1.service \
  signaeos-display2.service \
  signaeos-webui.service \
  companion-satellite.service \
  signaeos-update.timer \
  seatd.service \
  NetworkManager.service \
  avahi-daemon.service

# Disable conflicting services
systemctl disable lightdm 2>/dev/null || true
systemctl disable gdm    2>/dev/null || true
systemctl disable sddm   2>/dev/null || true
systemctl disable weston 2>/dev/null || true

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
systemctl start seatd sway signaeos-webui signaeos-display1 signaeos-display2 companion-satellite 2>/dev/null || true

echo -e "  ${G}Browse to http://$(hostname).local:3000 to configure SignageOS${N}"
echo ""
echo "  To check status:"
echo "    sudo systemctl status signaeos-webui"
echo "    sudo journalctl -u signaeos-display1 -f"
echo ""
