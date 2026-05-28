#!/bin/bash -e
# SignageOS pi-gen stage — run.sh
# Runs inside the chroot after packages are installed

on_chroot << 'EOF'

# ── Node.js LTS via NodeSource ────────────────────────────────────────────────
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
node --version

# ── NDI SDK for Linux ─────────────────────────────────────────────────────────
# NDI SDK is not redistributable so we install the runtime from the
# official install script at build time.
# The install script drops libraries into /usr/local/lib and tools into
# /usr/local/bin (including ndiplay, ndi-receive, NDI_Find etc.)
NDI_SDK_URL="https://downloads.ndi.tv/SDK/NDI_SDK_Linux/Install_NDI_SDK_v6_Linux.tar.gz"
TMP_NDI=$(mktemp -d)
curl -fsSL "$NDI_SDK_URL" -o "$TMP_NDI/ndi.tar.gz" || {
  echo "WARNING: NDI SDK download failed — NDI support will be unavailable."
  echo "Download manually from https://ndi.video/for-developers/ndi-sdk/ and"
  echo "run /opt/signaeos/install-ndi.sh on the device."
  rm -rf "$TMP_NDI"
  exit 0
}
tar -xzf "$TMP_NDI/ndi.tar.gz" -C "$TMP_NDI"
# Accept EULA non-interactively and install
ACCEPT_NDI_LICENSE=y "$TMP_NDI"/Install_NDI_SDK_v6_Linux.sh || true
# Add NDI libs to ldconfig
echo "/usr/local/lib" > /etc/ld.so.conf.d/ndi.conf
ldconfig
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

# ── Enable kernel module for 802.1q VLANs ────────────────────────────────────
echo "8021q" >> /etc/modules

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
EOF
