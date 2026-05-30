#!/usr/bin/env bash
# =============================================================================
# SignageOS SD Card Installer
# =============================================================================
# Run this on your Mac or Linux machine after flashing Raspberry Pi OS Lite.
# It copies the provisioning files to the boot partition so SignageOS
# installs itself on first boot.
#
# Usage:
#   ./install.sh                    # auto-detects SD card boot partition
#   ./install.sh /Volumes/bootfs    # specify mount point manually
# =============================================================================
set -euo pipefail

VERSION="@@VERSION@@"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' C='\033[0;36m' N='\033[0m'
info()  { echo -e "${G}✓${N} $*"; }
warn()  { echo -e "${Y}!${N} $*"; }
error() { echo -e "${R}✗${N} $*" >&2; exit 1; }
step()  { echo -e "\n${C}$*${N}"; }

echo ""
echo "  ╔═══════════════════════════════════╗"
echo "  ║   SignageOS SD Card Installer     ║"
echo "  ║   Version: $VERSION               ║"
echo "  ╚═══════════════════════════════════╝"
echo ""

# ── Find boot partition ───────────────────────────────────────────────────────
if [[ -n "${1:-}" ]]; then
  BOOT="$1"
else
  # Auto-detect on macOS
  if [[ "$(uname)" == "Darwin" ]]; then
    BOOT=$(find /Volumes -maxdepth 1 -name "bootfs" -o -name "boot" 2>/dev/null | head -1)
  else
    # Linux — look for vfat partition labelled bootfs
    BOOT=$(findmnt -rn -o TARGET -S LABEL=bootfs 2>/dev/null || true)
  fi
fi

if [[ -z "$BOOT" ]] || [[ ! -d "$BOOT" ]]; then
  error "Could not find boot partition. Is the SD card inserted?\nTry: ./install.sh /Volumes/bootfs"
fi

info "Boot partition: $BOOT"

# ── Verify it's a Pi boot partition ──────────────────────────────────────────
if [[ ! -f "$BOOT/cmdline.txt" ]] && [[ ! -f "$BOOT/config.txt" ]]; then
  error "$BOOT doesn't look like a Raspberry Pi boot partition (no cmdline.txt or config.txt)"
fi

# ── Copy provisioning files ───────────────────────────────────────────────────
step "Copying provisioning files..."

cp "$SCRIPT_DIR/signaeos-provision.sh" "$BOOT/signaeos-provision.sh"
chmod +x "$BOOT/signaeos-provision.sh" 2>/dev/null || true

cp "$SCRIPT_DIR/signaeos-firstboot.service" "$BOOT/signaeos-firstboot.service"

# Copy the signaeos rootfs files tarball if present
if [[ -f "$SCRIPT_DIR/signaeos-files.tar.gz" ]]; then
  cp "$SCRIPT_DIR/signaeos-files.tar.gz" "$BOOT/signaeos-files.tar.gz"
  info "Copied signaeos-files.tar.gz"
fi

info "Provisioning script copied."

# ── Add firstboot service to cmdline ─────────────────────────────────────────
# We use a custom init script approach — add systemd unit via os-cmdline
# Actually: write a custom-service file that pi OS picks up
step "Setting up first boot trigger..."

# Raspberry Pi OS supports placing .service files in /boot/firmware that
# get copied to systemd on first boot via raspberrypi-sys-mods
# We use the simpler approach: add to /etc/rc.local equivalent via cmdline

# Write a firstboot trigger that cloud-init style picks up
cat > "$BOOT/signaeos-install.txt" <<EOF
# SignageOS installation marker
# This file triggers provisioning on first boot
VERSION=$VERSION
EOF

info "First boot trigger created."

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${G}═══════════════════════════════════════${N}"
echo -e "${G}  SD card prepared successfully!${N}"
echo -e "${G}═══════════════════════════════════════${N}"
echo ""
echo "  Next steps:"
echo "  1. Eject the SD card safely"
echo "  2. Insert into Raspberry Pi"
echo "  3. Connect ethernet (recommended for first boot)"
echo "  4. Power on — provisioning takes ~10-15 minutes"
echo "  5. Browse to http://signaeos.local:3000"
echo ""
echo "  To monitor progress:"
echo "  ssh pi@signaeos.local"
echo "  sudo journalctl -u signaeos-firstboot -f"
echo ""
