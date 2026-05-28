#!/usr/bin/env bash
# SignageOS x86_64 image builder
# Builds a Debian Bookworm based image with the same SignageOS stage
# applied as the pi-gen build, using debootstrap + squashfs + A/B partitions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STAGE_DIR="$PROJECT_DIR/pi-gen-stage"
OUTPUT_DIR="$PROJECT_DIR/output/x86"
CACHE_DIR="$PROJECT_DIR/.cache"
VERSION="${SIGNAEOS_VERSION:-0.1.0}"

DEBIAN_RELEASE="bookworm"
DEBIAN_MIRROR="https://deb.debian.org/debian"
BOOT_SIZE=256; ROOTFS_SIZE=768; DATA_SIZE=512

[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

R='\033[0;31m' G='\033[0;32m' C='\033[0;36m' N='\033[0m'
info() { echo -e "${G}[x86]${N} $*"; }
step() { echo -e "\n${C}══ $* ══${N}"; }

LOOP_DEV=""
cleanup() {
  for d in dev/pts dev proc sys run; do umount "$ROOT/$d" 2>/dev/null || true; done
  [[ -n "$LOOP_DEV" ]] && losetup -d "$LOOP_DEV" 2>/dev/null || true
}
trap cleanup EXIT

ROOT="$OUTPUT_DIR/work/rootfs"
mkdir -p "$ROOT" "$OUTPUT_DIR/images" "$CACHE_DIR"

chr() { chroot "$ROOT" /bin/bash -c "$*"; }

mount_chroot() {
  mount -t proc  proc    "$ROOT/proc"
  mount -t sysfs sysfs   "$ROOT/sys"
  mount --bind /dev      "$ROOT/dev"
  mount -t devpts devpts "$ROOT/dev/pts"
  mount -t tmpfs tmpfs   "$ROOT/run"
  cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
}

umount_chroot() {
  for d in dev/pts dev proc sys run; do umount "$ROOT/$d" 2>/dev/null || true; done
}

# ── Bootstrap ────────────────────────────────────────────────────────────────
step "Bootstrap Debian $DEBIAN_RELEASE (amd64)"
CACHE_TAR="$CACHE_DIR/debian-${DEBIAN_RELEASE}-amd64.tar"
if [[ -f "$CACHE_TAR" ]]; then
  info "Using cached bootstrap"
  tar -xf "$CACHE_TAR" -C "$ROOT"
else
  debootstrap --arch=amd64 "$DEBIAN_RELEASE" "$ROOT" "$DEBIAN_MIRROR"
  tar -cf "$CACHE_TAR" -C "$ROOT" .
fi

mount_chroot

# ── Apt config ────────────────────────────────────────────────────────────────
step "Configuring apt"
cat > "$ROOT/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_RELEASE-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security $DEBIAN_RELEASE-security main contrib non-free non-free-firmware
EOF
mkdir -p "$ROOT/etc/apt/apt.conf.d"
echo 'APT::Cache-Start "100663296";' > "$ROOT/etc/apt/apt.conf.d/99cache"
chr "apt-get update -q"

# ── Packages (install in small batches) ─────────────────────────────────────
step "Installing packages"
chr "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  systemd systemd-sysv dbus udev kmod openssh-server sudo \
  bash-completion curl wget ca-certificates gnupg jq socat"
chr "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  network-manager wpasupplicant vlan avahi-daemon libnss-mdns \
  cloud-guest-utils util-linux e2fsprogs dosfstools xz-utils"
chr "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  weston xwayland libwayland-client0 libwayland-server0 libinput10 \
  fonts-dejavu-core fonts-noto-color-emoji"
chr "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  chromium firefox-esr libusb-1.0-0"
chr "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  linux-image-amd64 grub-efi-amd64 \
  firmware-linux-free firmware-misc-nonfree \
  firmware-iwlwifi firmware-realtek"

# ── Node.js ───────────────────────────────────────────────────────────────────
step "Installing Node.js"
chr "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
chr "DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs"

# ── SignageOS files ───────────────────────────────────────────────────────────
step "Installing SignageOS files"
# Copy stage files
if [[ -d "$STAGE_DIR/01-signaeos-files/files" ]]; then
  cp -r "$STAGE_DIR/01-signaeos-files/files/." "$ROOT/"
fi
# Install packages from packages list
if [[ -f "$STAGE_DIR/00-packages/packages" ]]; then
  while IFS= read -r pkg; do
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    chr "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkg" || true
  done < "$STAGE_DIR/00-packages/packages"
fi

# Run the stage install script (NDI, Companion Satellite, npm deps, systemd enables)
chmod +x "$STAGE_DIR/01-signaeos-files/signaeos-install.sh"
cp "$STAGE_DIR/01-signaeos-files/signaeos-install.sh" "$ROOT/tmp/signaeos-install.sh"
sed -i "s|@@SIGNAEOS_VERSION@@|$VERSION|g" "$ROOT/tmp/signaeos-install.sh"
chr "bash /tmp/signaeos-install.sh && rm -f /tmp/signaeos-install.sh"

# ── Configure ─────────────────────────────────────────────────────────────────
step "System configuration"
echo "signaeos" > "$ROOT/etc/hostname"
chr "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends locales"
chr "echo 'en_GB.UTF-8 UTF-8' >> /etc/locale.gen && locale-gen"
chr "ln -sf /usr/share/zoneinfo/UTC /etc/localtime"
chr "passwd -d root; passwd -l root"
chr "apt-get clean && rm -rf /var/lib/apt/lists/*"

umount_chroot

# ── Squashfs ──────────────────────────────────────────────────────────────────
step "Creating squashfs"
SQFS="$OUTPUT_DIR/work/rootfs.squashfs"
mksquashfs "$ROOT" "$SQFS" -comp zstd -Xcompression-level 15 -noappend \
  -wildcards -e "proc/*" "sys/*" "dev/*" "run/*" "tmp/*" \
  "var/cache/apt/*" "var/lib/apt/lists/*" "usr/share/doc/*" "usr/share/man/*"
info "squashfs: $(du -sh "$SQFS" | cut -f1)"

# ── Disk image ────────────────────────────────────────────────────────────────
step "Assembling disk image"
IMG="$OUTPUT_DIR/images/signaeos-x86-${VERSION}.img"
TOTAL=$(( 2 + BOOT_SIZE + ROOTFS_SIZE + ROOTFS_SIZE + DATA_SIZE ))
dd if=/dev/zero of="$IMG" bs=1M count="$TOTAL" status=progress
parted -s "$IMG" mklabel gpt \
  mkpart ESP  fat32  2MiB                        $(( 2+BOOT_SIZE ))MiB \
  mkpart rootfs-a    $(( 2+BOOT_SIZE ))MiB       $(( 2+BOOT_SIZE+ROOTFS_SIZE ))MiB \
  mkpart rootfs-b    $(( 2+BOOT_SIZE+ROOTFS_SIZE ))MiB $(( 2+BOOT_SIZE+ROOTFS_SIZE*2 ))MiB \
  mkpart data  ext4  $(( 2+BOOT_SIZE+ROOTFS_SIZE*2 ))MiB 100% \
  set 1 boot on set 1 esp on

LOOP_DEV=$(losetup -f --show -P "$IMG")
mkfs.vfat -F32 -n SGNOS-EFI "${LOOP_DEV}p1"
mkfs.ext4 -L data -q "${LOOP_DEV}p4"
dd if="$SQFS" of="${LOOP_DEV}p2" bs=4M status=progress; sync

EFI=$(mktemp -d); mount "${LOOP_DEV}p1" "$EFI"
mkdir -p "$EFI/EFI/BOOT" "$EFI/grub"
KIMG=$(find "$ROOT/boot" -name "vmlinuz-*" | sort | tail -1)
INITRD=$(find "$ROOT/boot" -name "initrd.img-*" | sort | tail -1)
[[ -n "$KIMG"  ]] && cp "$KIMG"  "$EFI/vmlinuz"
[[ -n "$INITRD" ]] && cp "$INITRD" "$EFI/initrd.img"
grub-mkimage -O x86_64-efi -o "$EFI/EFI/BOOT/bootx64.efi" -p /grub \
  boot linux ext2 fat squash4 part_gpt normal configfile echo search search_label loadenv test
cat > "$EFI/grub/grub.cfg" <<'EOF'
set default=0
set timeout=0
search --no-floppy --label --set=root SGNOS-EFI
if [ -f /signaeos.env ]; then load_env -f /signaeos.env; fi
if [ "${active_slot}" = "b" ]; then set rp="rootfs-b"; else set rp="rootfs-a"; fi
menuentry "SignageOS" {
  linux  /vmlinuz  root=PARTLABEL=${rp} rootfstype=squashfs ro quiet loglevel=3 signaeos.data=PARTLABEL=data
  initrd /initrd.img
}
EOF
printf "active_slot=a\nboot_attempts=0\n" > "$EFI/signaeos.env"
truncate -s 1024 "$EFI/signaeos.env"
sync; umount "$EFI"; rmdir "$EFI"
losetup -d "$LOOP_DEV"; LOOP_DEV=""

info "Compressing…"
xz -T0 -v "$IMG"
info "Done: ${IMG}.xz"
