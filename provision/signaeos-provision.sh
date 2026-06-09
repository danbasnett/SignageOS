#!/bin/bash
# =============================================================================
# SignageOS Provisioning Script
# =============================================================================
# Place this file on the boot partition of a fresh Raspberry Pi OS Lite image.
# It runs automatically on first boot via the signaeos-firstboot systemd service,
# installs everything, then reboots into SignageOS.
#
# Supported: Raspberry Pi OS Lite (Bookworm) — 32-bit or 64-bit
#            Debian Bookworm x86_64
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/signaeos-provision.log"
SIGNAEOS_VERSION="@@VERSION@@"
NODE_VERSION="20"
COMPANION_SATELLITE_VERSION="2.2.1"
GITHUB_REPO="@@GITHUB_REPO@@"

# ── Logging ───────────────────────────────────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
info()  { echo -e "${G}[signaeos]${N} $*"; }
warn()  { echo -e "${Y}[signaeos]${N} $*"; }
error() { echo -e "${R}[signaeos]${N} $*"; exit 1; }
step()  { echo -e "\n${C}══ $* ══${N}"; }

info "SignageOS provisioning started — version $SIGNAEOS_VERSION"
info "Log: $LOG_FILE"

# ── Detect arch ───────────────────────────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) PLATFORM="linux-arm64" ;;
  armv7l|armhf)  PLATFORM="linux-arm" ;;
  x86_64)        PLATFORM="linux-x64" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac
info "Architecture: $ARCH ($PLATFORM)"

# ── Wait for network ──────────────────────────────────────────────────────────
step "Waiting for network"
for i in $(seq 1 30); do
  ping -c1 -W2 8.8.8.8 &>/dev/null && break
  info "Waiting for network... ($i/30)"
  sleep 5
done
ping -c1 -W2 8.8.8.8 &>/dev/null || error "No network after 150s — check WiFi/ethernet"
info "Network ready."

# ── System update ─────────────────────────────────────────────────────────────
step "Updating system packages"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q --no-install-recommends

# ── Core packages ─────────────────────────────────────────────────────────────
step "Installing core packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  curl wget ca-certificates gnupg \
  jq socat \
  network-manager wpasupplicant \
  avahi-daemon libnss-mdns \
  vlan \
  seatd \
  cloud-guest-utils \
  usbutils libusb-1.0-0 \
  alsa-utils \
  unzip xz-utils

# ── Display stack ─────────────────────────────────────────────────────────────
step "Installing display stack"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  sway \
  xwayland \
  libwayland-client0 \
  libinput10 \
  libgles2 \
  fonts-dejavu-core \
  fonts-noto-color-emoji

# ── Browsers ─────────────────────────────────────────────────────────────────
step "Installing browsers"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  chromium-browser \
  firefox-esr 2>/dev/null || \
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  chromium \
  firefox-esr

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential \
  pkg-config \
  libsdl2-2.0-0 \
  libsdl2-dev

# ── Node.js ───────────────────────────────────────────────────────────────────
step "Installing Node.js $NODE_VERSION"
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
node --version && npm --version

# ── Companion Satellite ───────────────────────────────────────────────────────
step "Installing Companion Satellite"
SAT_URL="https://github.com/bitfocus/companion-satellite/releases/download/v${COMPANION_SATELLITE_VERSION}/companion-satellite-${PLATFORM}.tar.gz"
mkdir -p /opt/companion-satellite
curl -fsSL "$SAT_URL" | tar -xzf - -C /opt/companion-satellite --strip-components=1
info "Companion Satellite installed."

# ── NDI SDK ───────────────────────────────────────────────────────────────────
step "Installing NDI SDK"
NDI_URL="https://downloads.ndi.tv/SDK/NDI_SDK_Linux/Install_NDI_SDK_v6_Linux.tar.gz"
TMP=$(mktemp -d)
if curl -fsSL --connect-timeout 30 "$NDI_URL" -o "$TMP/ndi.tar.gz"; then
  tar -xzf "$TMP/ndi.tar.gz" -C "$TMP"
  ACCEPT_NDI_LICENSE=y "$TMP"/Install_NDI_SDK_v6_Linux.sh || true
  echo "/usr/local/lib" > /etc/ld.so.conf.d/ndi.conf
  ldconfig
  info "NDI SDK installed."
else
  warn "NDI SDK download failed — NDI features unavailable until installed manually."
fi
rm -rf "$TMP"

# ── Download SignageOS files from GitHub ─────────────────────────────────────
step "Installing SignageOS files"
RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/download/v${SIGNAEOS_VERSION}/signaeos-files.tar.gz"
TMP=$(mktemp -d)

if curl -fsSL "$RELEASE_URL" -o "$TMP/signaeos-files.tar.gz" 2>/dev/null; then
  info "Downloading from release: $RELEASE_URL"
  tar -xzf "$TMP/signaeos-files.tar.gz" -C /
else
  # Fall back to copying from boot partition if files are there
  BOOT_FILES="/boot/firmware/signaeos-files.tar.gz"
  if [[ -f "$BOOT_FILES" ]]; then
    info "Using files from boot partition."
    tar -xzf "$BOOT_FILES" -C /
  else
    warn "Could not download SignageOS files — using embedded copies."
    # Files are already placed by the provision script package
  fi
fi
rm -rf "$TMP"

# ── Web UI npm dependencies ───────────────────────────────────────────────────
step "Installing web UI dependencies"
cd /usr/share/signaeos/webui
npm install --production --no-audit --no-fund
info "Web UI deps installed."

# ── Permissions ───────────────────────────────────────────────────────────────
chmod +x /usr/bin/signaeos-display1
chmod +x /usr/bin/signaeos-display2
chmod +x /usr/bin/signaeos-ctl
chmod +x /usr/bin/signaeos-update

if ! id signaeos &>/dev/null; then
  useradd -m -s /bin/bash signaeos
fi
for group in video input render audio plugdev seat; do
  getent group "$group" >/dev/null && usermod -aG "$group" signaeos || true
done
mkdir -p /data/signaeos /data/chromium-profile /data/firefox-profile /data/chromium-d2
chown -R signaeos:signaeos /data/signaeos /data/chromium-profile /data/firefox-profile /data/chromium-d2

NDI_HEADER="$(find /usr/local/include /usr/include -name Processing.NDI.Lib.h 2>/dev/null | head -1 || true)"
NDI_LIB="$(find /usr/local/lib /usr/lib -name 'libndi.so*' 2>/dev/null | sort | head -1 || true)"
if [[ -f /usr/src/signaeos/ndi-player.c ]] && [[ -n "$NDI_HEADER" ]] && [[ -n "$NDI_LIB" ]]; then
  NDI_INCLUDE_DIR="$(dirname "$NDI_HEADER")"
  NDI_LIB_DIR="$(dirname "$NDI_LIB")"
  echo "$NDI_LIB_DIR" > /etc/ld.so.conf.d/ndi.conf
  ldconfig || true
  if gcc /usr/src/signaeos/ndi-player.c -o /usr/bin/signaeos-ndi-player \
      -I"$NDI_INCLUDE_DIR" -L"$NDI_LIB_DIR" -Wl,-rpath,"$NDI_LIB_DIR" $(pkg-config --cflags --libs sdl2) -lndi; then
    chmod +x /usr/bin/signaeos-ndi-player
    info "Native NDI player installed."
  else
    warn "Native NDI player build failed — Display 2 will try VLC/ndiplay fallback."
  fi
fi

# ── System config ─────────────────────────────────────────────────────────────
step "Configuring system"

# Keep sudo happy after hostname changes.
HOSTNAME="$(cat /etc/hostname 2>/dev/null || hostname)"
if ! grep -Eq "^[[:space:]]*127\.0\.1\.1[[:space:]].*\\b${HOSTNAME}\\b" /etc/hosts 2>/dev/null; then
  sed -i '/^[[:space:]]*127\.0\.1\.1[[:space:]]/d' /etc/hosts 2>/dev/null || true
  printf '127.0.1.1\t%s %s.local\n' "$HOSTNAME" "$HOSTNAME" >> /etc/hosts
fi

# Sudoers — get current user (pi / signaeos / whatever pi imager set)
MAIN_USER=$(getent passwd 1000 | cut -d: -f1 || echo "pi")
echo "${MAIN_USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/010_signaeos
chmod 440 /etc/sudoers.d/010_signaeos
info "Sudoers configured for $MAIN_USER"

# 8021q VLAN module
echo "8021q" >> /etc/modules

# Stream Deck udev rule
cat > /etc/udev/rules.d/50-streamdeck.rules <<'UDEV'
SUBSYSTEM=="usb", ATTRS{idVendor}=="0fd9", MODE="0666", GROUP="plugdev"
UDEV

# NetworkManager — take over network management
cat > /etc/NetworkManager/conf.d/99-signaeos.conf <<'NM'
[main]
plugins=keyfile
dhcp=internal

[ifupdown]
managed=true
NM

# avahi mDNS
sed -i 's/^#*use-ipv4=.*/use-ipv4=yes/' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
sed -i 's/^#*use-ipv6=.*/use-ipv6=no/'  /etc/avahi/avahi-daemon.conf 2>/dev/null || true

# SSH — enable, allow password for initial setup
systemctl enable ssh
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Version stamp
echo "$SIGNAEOS_VERSION" > /etc/signaeos-version

# ── Enable services ───────────────────────────────────────────────────────────
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

systemctl disable weston.service 2>/dev/null || true

systemctl set-default multi-user.target

# ── Disable first-boot service so we don't run again ─────────────────────────
step "Finalising"
systemctl disable signaeos-firstboot.service
rm -f /etc/systemd/system/signaeos-firstboot.service
rm -f /boot/firmware/signaeos-provision.sh

info "SignageOS provisioning complete!"
info "Version: $SIGNAEOS_VERSION"
info "Rebooting in 5 seconds..."
sleep 5
reboot
