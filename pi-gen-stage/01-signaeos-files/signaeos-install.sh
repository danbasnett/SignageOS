#!/bin/bash -e
# SignageOS pi-gen stage — 00-run.sh
# This script runs directly inside the chroot (called by pi-gen or build-x86.sh)

# ── Node.js LTS via NodeSource ────────────────────────────────────────────────
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
node --version

# ── NDI SDK for Linux ─────────────────────────────────────────────────────────
NDI_SDK_URL="https://downloads.ndi.tv/SDK/NDI_SDK_Linux/Install_NDI_SDK_v6_Linux.tar.gz"
TMP_NDI=$(mktemp -d)
if curl -fsSL --connect-timeout 30 "$NDI_SDK_URL" -o "$TMP_NDI/ndi.tar.gz"; then
  tar -xzf "$TMP_NDI/ndi.tar.gz" -C "$TMP_NDI"
  ACCEPT_NDI_LICENSE=y "$TMP_NDI"/Install_NDI_SDK_v6_Linux.sh || true
  echo "/usr/local/lib" > /etc/ld.so.conf.d/ndi.conf
  ldconfig
else
  echo "WARNING: NDI SDK download failed — NDI support unavailable until manually installed."
fi
rm -rf "$TMP_NDI"

# ── Companion Satellite ───────────────────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) PLATFORM="linux-arm64" ;;
  x86_64)        PLATFORM="linux-x64" ;;
  *) echo "Unsupported arch $ARCH"; exit 1 ;;
esac
SAT_VERSION="2.2.1"
SAT_URL="https://github.com/bitfocus/companion-satellite/releases/download/v${SAT_VERSION}/companion-satellite-${PLATFORM}.tar.gz"
mkdir -p /opt/companion-satellite
curl -fsSL "$SAT_URL" | tar -xzf - -C /opt/companion-satellite --strip-components=1
echo "Companion Satellite installed."

# ── Web UI npm dependencies ───────────────────────────────────────────────────
cd /usr/share/signaeos/webui
npm install --production --no-audit --no-fund
echo "Web UI deps installed."

# ── Udev rule for Stream Deck ─────────────────────────────────────────────────
cat > /etc/udev/rules.d/50-streamdeck.rules <<'UDEV'
SUBSYSTEM=="usb", ATTRS{idVendor}=="0fd9", MODE="0666", GROUP="plugdev"
UDEV

# ── 802.1q VLAN kernel module ─────────────────────────────────────────────────
echo "8021q" >> /etc/modules

# ── Mark executables ──────────────────────────────────────────────────────────
chmod +x /usr/bin/signaeos-display1 /usr/bin/signaeos-display2 /usr/bin/signaeos-ctl

# ── Version stamp ─────────────────────────────────────────────────────────────
echo "@@SIGNAEOS_VERSION@@" > /etc/signaeos-version

# ── Enable systemd services ───────────────────────────────────────────────────
systemctl enable \
  signaeos-display1.service \
  signaeos-display2.service \
  signaeos-webui.service \
  companion-satellite.service \
  signaeos-update.timer \
  NetworkManager.service \
  avahi-daemon.service \
  ssh.service \
  weston.service

systemctl set-default multi-user.target

# ── Root account — no password, key auth only ─────────────────────────────────
passwd -d root
passwd -l root

echo "SignageOS stage complete."
