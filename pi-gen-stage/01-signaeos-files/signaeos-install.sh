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
if [[ "${SIGNAEOS_INSTALL_NDI_SDK:-0}" == "1" ]]; then
  if curl -fsSL --connect-timeout 30 "$NDI_SDK_URL" -o "$TMP_NDI/ndi.tar.gz"; then
    tar -xzf "$TMP_NDI/ndi.tar.gz" -C "$TMP_NDI"
    "$TMP_NDI"/Install_NDI_SDK_v6_Linux.sh || true
    echo "/usr/local/lib" > /etc/ld.so.conf.d/ndi.conf
    ldconfig
  else
    echo "WARNING: NDI SDK download failed — NDI support unavailable until manually installed."
  fi
else
  echo "Skipping NDI SDK install. Set SIGNAEOS_INSTALL_NDI_SDK=1 to install it interactively."
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
chmod +x /usr/bin/signaeos-display1 /usr/bin/signaeos-display2 /usr/bin/signaeos-ctl /usr/bin/signaeos-build-ndi-player

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
  gcc /usr/src/signaeos/ndi-player.c -o /usr/bin/signaeos-ndi-player \
    -I"$NDI_INCLUDE_DIR" -L"$NDI_LIB_DIR" -Wl,-rpath,"$NDI_LIB_DIR" $(pkg-config --cflags --libs sdl2) -lndi || true
  chmod +x /usr/bin/signaeos-ndi-player 2>/dev/null || true
fi

# ── Version stamp ─────────────────────────────────────────────────────────────
echo "@@SIGNAEOS_VERSION@@" > /etc/signaeos-version
HOSTNAME="$(cat /etc/hostname 2>/dev/null || hostname)"
if ! grep -Eq "^[[:space:]]*127\.0\.1\.1[[:space:]].*\\b${HOSTNAME}\\b" /etc/hosts 2>/dev/null; then
  sed -i '/^[[:space:]]*127\.0\.1\.1[[:space:]]/d' /etc/hosts 2>/dev/null || true
  printf '127.0.1.1\t%s %s.local\n' "$HOSTNAME" "$HOSTNAME" >> /etc/hosts
fi

# ── Enable systemd services ───────────────────────────────────────────────────
systemctl enable \
  signaeos-display1.service \
  signaeos-display2.service \
  signaeos-webui.service \
  companion-satellite.service \
  signaeos-update.timer \
  seatd.service \
  NetworkManager.service \
  avahi-daemon.service \
  ssh.service \
  sway.service
systemctl disable weston.service 2>/dev/null || true

systemctl set-default multi-user.target

echo "SignageOS stage complete."
