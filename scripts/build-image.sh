#!/usr/bin/env bash
# =============================================================================
# SignageOS — Debian-based image builder
# =============================================================================
# Usage:
#   sudo ./scripts/build-image.sh rpi    # Raspberry Pi 4/5 (arm64)
#   sudo ./scripts/build-image.sh x86    # x86_64 (UEFI)
#   sudo ./scripts/build-image.sh all    # both
#
# Requirements (Ubuntu/Debian host):
#   sudo apt-get install -y debootstrap qemu-user-static binfmt-support \
#     parted squashfs-tools dosfstools grub-efi-amd64-bin mtools \
#     curl wget git xz-utils
#
# Cross-build (x86 host building arm64):
#   Requires qemu-user-static + binfmt-support (installed above)
# =============================================================================
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/output"
CACHE_DIR="$PROJECT_DIR/.cache"

SIGNAEOS_VERSION="0.1.0"
DEBIAN_RELEASE="bookworm"
DEBIAN_MIRROR="https://deb.debian.org/debian"

# Partition sizes (MiB)
BOOT_SIZE=256
ROOTFS_SIZE=768   # squashfs is compressed; raw rootfs will be ~1.2GB, squashes to ~400MB
DATA_SIZE=512     # minimum; grown on first boot

NODE_VERSION="20"   # LTS
COMPANION_SATELLITE_VERSION="2.2.1"

TARGET="${1:-all}"

# ─── Colours ─────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'
info()  { echo -e "${G}[build]${N} $*"; }
warn()  { echo -e "${Y}[warn] ${N} $*"; }
error() { echo -e "${R}[error]${N} $*" >&2; exit 1; }
step()  { echo -e "\n${C}${B}══ $* ══${N}"; }

# ─── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Must run as root (uses chroot, mount, losetup). Try: sudo $0 $*"

# ─── Dependency check ─────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in debootstrap parted mkfs.vfat mkfs.ext4 mksquashfs losetup \
             qemu-aarch64-static curl wget git xz; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing tools: ${missing[*]}\nRun: sudo apt-get install -y debootstrap qemu-user-static binfmt-support parted squashfs-tools dosfstools grub-efi-amd64-bin mtools curl wget git xz-utils"
  fi
}

# ─── Cleanup on exit ──────────────────────────────────────────────────────────
LOOP_DEV=""
CHROOT_DIR=""
MOUNTS_ACTIVE=()

cleanup() {
  info "Cleaning up..."
  # Unmount in reverse order
  for mnt in "${MOUNTS_ACTIVE[@]:+${MOUNTS_ACTIVE[@]}}"; do
    umount "$mnt" 2>/dev/null || true
  done
  MOUNTS_ACTIVE=()
  if [[ -n "$CHROOT_DIR" ]]; then
    for d in dev/pts dev proc sys run; do
      umount "$CHROOT_DIR/$d" 2>/dev/null || true
    done
  fi
  if [[ -n "$LOOP_DEV" ]]; then
    losetup -d "$LOOP_DEV" 2>/dev/null || true
    LOOP_DEV=""
  fi
}
trap cleanup EXIT

# ─── Mount chroot filesystems ─────────────────────────────────────────────────
mount_chroot() {
  local root="$1"
  mount -t proc  proc    "$root/proc"
  mount -t sysfs sysfs   "$root/sys"
  mount -t devtmpfs devtmpfs "$root/dev" 2>/dev/null || mount --bind /dev "$root/dev"
  mount -t devpts devpts  "$root/dev/pts"
  mount -t tmpfs  tmpfs   "$root/run"
  # DNS
  cp /etc/resolv.conf "$root/etc/resolv.conf"
}

umount_chroot() {
  local root="$1"
  for d in dev/pts dev proc sys run; do
    umount "$root/$d" 2>/dev/null || true
  done
}

# ─── Run command inside chroot ────────────────────────────────────────────────
chr() {
  local root="$1"; shift
  chroot "$root" /bin/bash -c "$*"
}

# ─── Bootstrap Debian ─────────────────────────────────────────────────────────
bootstrap_debian() {
  local root="$1" arch="$2"
  local cache_tar="$CACHE_DIR/debian-${DEBIAN_RELEASE}-${arch}.tar"

  step "Bootstrap Debian $DEBIAN_RELEASE ($arch)"

  mkdir -p "$CACHE_DIR" "$root"

  if [[ -f "$cache_tar" ]]; then
    info "Using cached bootstrap: $cache_tar"
    tar -xf "$cache_tar" -C "$root"
  else
    info "Running debootstrap (this takes a few minutes)..."
    if [[ "$arch" == "arm64" ]]; then
      debootstrap --arch=arm64 --foreign "$DEBIAN_RELEASE" "$root" "$DEBIAN_MIRROR"
      # Copy qemu for cross-execution
      cp "$(which qemu-aarch64-static)" "$root/usr/bin/"
      chroot "$root" /debootstrap/debootstrap --second-stage
    else
      debootstrap --arch=amd64 "$DEBIAN_RELEASE" "$root" "$DEBIAN_MIRROR"
    fi
    info "Caching bootstrap..."
    tar -cf "$cache_tar" -C "$root" .
  fi
}

# ─── Install packages ─────────────────────────────────────────────────────────
install_packages() {
  local root="$1" arch="$2"

  step "Installing packages"

  mount_chroot "$root"

  # Sources list
  cat > "$root/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_RELEASE-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security $DEBIAN_RELEASE-security main contrib non-free non-free-firmware
EOF

  chr "$root" "apt-get update -q"

  # Base system
  info "Installing base packages..."
  chr "$root" "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd systemd-sysv dbus \
    udev kmod \
    network-manager wpasupplicant \
    avahi-daemon libnss-mdns \
    openssh-server \
    sudo bash-completion \
    curl wget ca-certificates gnupg \
    jq socat \
    util-linux e2fsprogs dosfstools \
    cloud-guest-utils \
    xz-utils \
    htop less nano \
    alsa-utils \
    usbutils"

  # Wayland + compositor
  info "Installing display stack..."
  chr "$root" "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    weston \
    xwayland \
    libwayland-client0 libwayland-server0 \
    libinput10 \
    mesa-utils \
    fonts-dejavu-core fonts-liberation"

  # Platform-specific display / GPU / kernel
  if [[ "$arch" == "arm64" ]]; then
    info "Installing Raspberry Pi packages..."
    # Add RPi repo
    chr "$root" "curl -fsSL https://archive.raspberrypi.com/debian/raspberrypi.gpg.key \
      | gpg --dearmor -o /etc/apt/trusted.gpg.d/raspberrypi.gpg"
    echo "deb https://archive.raspberrypi.com/debian/ $DEBIAN_RELEASE main" \
      > "$root/etc/apt/sources.list.d/raspi.list"
    chr "$root" "apt-get update -q"
    chr "$root" "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      raspberrypi-kernel raspberrypi-bootloader \
      raspi-config raspi-firmware \
      libraspberrypi0 libraspberrypi-dev \
      pi-bluetooth \
      firmware-brcm80211"
  else
    info "Installing x86 kernel + firmware..."
    chr "$root" "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      linux-image-amd64 \
      grub-efi-amd64 \
      firmware-linux firmware-linux-nonfree \
      firmware-iwlwifi firmware-realtek firmware-atheros \
      intel-microcode amd64-microcode"
  fi

  # Browser — Chromium + Firefox
  info "Installing browsers..."
  chr "$root" "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    chromium \
    firefox-esr \
    fonts-noto-color-emoji"

  # Node.js via NodeSource
  info "Installing Node.js $NODE_VERSION..."
  chr "$root" "curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -"
  chr "$root" "DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs"

  # Companion Satellite dependencies
  chr "$root" "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libusb-1.0-0 libudev-dev"

  # Clean up
  info "Cleaning apt cache..."
  chr "$root" "apt-get clean && rm -rf /var/lib/apt/lists/*"

  umount_chroot "$root"
}

# ─── Install Companion Satellite ─────────────────────────────────────────────
install_companion_satellite() {
  local root="$1" arch="$2"

  step "Installing Companion Satellite"

  local platform
  [[ "$arch" == "arm64" ]] && platform="linux-arm64" || platform="linux-x64"

  local url="https://github.com/bitfocus/companion-satellite/releases/download/v${COMPANION_SATELLITE_VERSION}/companion-satellite-${platform}.tar.gz"
  local tarball="$CACHE_DIR/companion-satellite-${COMPANION_SATELLITE_VERSION}-${platform}.tar.gz"

  mkdir -p "$CACHE_DIR"
  if [[ ! -f "$tarball" ]]; then
    info "Downloading Companion Satellite $COMPANION_SATELLITE_VERSION ($platform)..."
    wget -q --show-progress -O "$tarball" "$url"
  else
    info "Using cached Companion Satellite."
  fi

  mkdir -p "$root/opt/companion-satellite"
  tar -xzf "$tarball" -C "$root/opt/companion-satellite" --strip-components=1
  info "Companion Satellite installed."
}

# ─── Install SignageOS files ───────────────────────────────────────────────────
install_signaeos_files() {
  local root="$1"

  step "Installing SignageOS files"

  # Copy rootfs overlay
  cp -r "$PROJECT_DIR/rootfs-overlay/." "$root/"

  # Install web UI npm deps
  info "Installing web UI dependencies..."
  mount_chroot "$root"
  chr "$root" "cd /usr/share/signaeos/webui && npm install --production --no-audit --no-fund"
  umount_chroot "$root"

  # Set permissions
  chmod +x "$root/usr/bin/signaeos-init"
  chmod +x "$root/usr/bin/signaeos-update"
  chmod +x "$root/usr/bin/signaeos-ctl"

  # Version stamp
  echo "$SIGNAEOS_VERSION" > "$root/etc/signaeos-version"

  # Udev rule for Stream Deck USB
  cat > "$root/etc/udev/rules.d/50-streamdeck.rules" <<'EOF'
# Elgato Stream Deck
SUBSYSTEM=="usb", ATTRS{idVendor}=="0fd9", MODE="0666", GROUP="plugdev"
EOF

  info "SignageOS files installed."
}

# ─── Configure the system ─────────────────────────────────────────────────────
configure_system() {
  local root="$1" arch="$2"

  step "Configuring system"

  mount_chroot "$root"

  # Hostname
  echo "signaeos" > "$root/etc/hostname"
  cat > "$root/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   signaeos signaeos.local
::1         localhost ip6-localhost ip6-loopback
EOF

  # Locale
  chr "$root" "echo 'en_GB.UTF-8 UTF-8' >> /etc/locale.gen && locale-gen"
  chr "$root" "echo 'LANG=en_GB.UTF-8' > /etc/default/locale"

  # Timezone (sensible default — overrideable in web UI later)
  chr "$root" "ln -sf /usr/share/zoneinfo/UTC /etc/localtime"

  # Root — no password, key auth only
  chr "$root" "passwd -d root"
  chr "$root" "passwd -l root"

  # SSH hardening
  mkdir -p "$root/root/.ssh"
  chmod 700 "$root/root/.ssh"

  # avahi-daemon mDNS — ensure it advertises signaeos.local
  cat > "$root/etc/avahi/avahi-daemon.conf" <<'EOF'
[server]
host-name=signaeos
domain-name=local
use-ipv4=yes
use-ipv6=yes
allow-interfaces=eth0,wlan0

[publish]
publish-addresses=yes
publish-hinfo=no
publish-workstation=no
publish-domain=yes
EOF

  # nsswitch: enable mDNS
  sed -i 's/^hosts:.*/hosts:          files mdns4_minimal [NOTFOUND=return] dns/' \
    "$root/etc/nsswitch.conf"

  # NetworkManager — manage everything
  cat > "$root/etc/NetworkManager/NetworkManager.conf" <<'EOF'
[main]
plugins=ifupdown,keyfile
dhcp=internal

[ifupdown]
managed=true

[device]
wifi.backend=wpa_supplicant
EOF

  # Weston kiosk compositor config
  mkdir -p "$root/etc/weston"
  cat > "$root/etc/weston/weston.ini" <<'EOF'
[core]
backend=drm-backend.so
shell=kiosk-shell.so
idle-time=0
repaint-window=8

[output]
name=HDMI-A-1
mode=1920x1080@60
transform=normal

[keyboard]
keymap_rules=evdev
keymap_layout=gb

[shell]
# Kiosk shell — no taskbar, no decorations
EOF

  # systemd — disable units we don't need
  for unit in apt-daily.timer apt-daily-upgrade.timer \
              man-db.timer e2scrub_reboot.timer; do
    chr "$root" "systemctl disable $unit 2>/dev/null || true"
  done

  # Enable our units
  chr "$root" "systemctl enable \
    signaeos-init.service \
    signaeos-webui.service \
    companion-satellite.service \
    signaeos-update.timer \
    NetworkManager.service \
    avahi-daemon.service \
    ssh.service \
    weston.service"

  # systemd target: boot to multi-user (no GUI login manager)
  chr "$root" "systemctl set-default multi-user.target"

  # Serial console for debugging
  chr "$root" "systemctl enable serial-getty@ttyS0.service 2>/dev/null || true"
  if [[ "$arch" == "arm64" ]]; then
    chr "$root" "systemctl enable serial-getty@ttyAMA0.service 2>/dev/null || true"
  fi

  umount_chroot "$root"

  info "System configured."
}

# ─── Pack rootfs into squashfs ────────────────────────────────────────────────
make_squashfs() {
  local root="$1" output="$2"

  step "Creating squashfs rootfs"

  # Things to exclude from the squashfs (will live in /data overlay or are runtime)
  mksquashfs "$root" "$output" \
    -comp zstd -Xcompression-level 15 \
    -noappend \
    -wildcards \
    -e \
      "proc/*" \
      "sys/*" \
      "dev/*" \
      "run/*" \
      "tmp/*" \
      "var/cache/apt/*" \
      "var/lib/apt/lists/*" \
      "usr/share/doc/*" \
      "usr/share/man/*" \
      "usr/share/locale/*" \
      "usr/lib/locale/*" \
    2>/dev/null

  local size
  size=$(du -sh "$output" | cut -f1)
  info "squashfs created: $output ($size)"
}

# ─── Assemble Raspberry Pi image ──────────────────────────────────────────────
assemble_rpi_image() {
  local squashfs="$1"
  local kernel_dir="$2"
  local output_img="$3"

  step "Assembling Raspberry Pi disk image"

  local total=$(( 2 + BOOT_SIZE + ROOTFS_SIZE + ROOTFS_SIZE + DATA_SIZE ))
  info "Image size: ${total}MiB"

  dd if=/dev/zero of="$output_img" bs=1M count="$total" status=progress

  parted -s "$output_img" \
    mklabel gpt \
    mkpart boot  fat32  2MiB                        $(( 2 + BOOT_SIZE ))MiB \
    mkpart rootfs-a     $(( 2 + BOOT_SIZE ))MiB     $(( 2 + BOOT_SIZE + ROOTFS_SIZE ))MiB \
    mkpart rootfs-b     $(( 2 + BOOT_SIZE + ROOTFS_SIZE ))MiB  $(( 2 + BOOT_SIZE + ROOTFS_SIZE*2 ))MiB \
    mkpart data  ext4   $(( 2 + BOOT_SIZE + ROOTFS_SIZE*2 ))MiB 100% \
    set 1 boot on

  LOOP_DEV=$(losetup -f --show -P "$output_img")
  info "Loop device: $LOOP_DEV"

  mkfs.vfat -F32 -n SGNOS-BOOT "${LOOP_DEV}p1"
  mkfs.ext4 -L data -q "${LOOP_DEV}p4"

  # Write squashfs to slot A
  info "Writing rootfs to slot A..."
  dd if="$squashfs" of="${LOOP_DEV}p2" bs=4M status=progress
  sync

  # Boot partition
  local boot_mnt; boot_mnt=$(mktemp -d)
  mount "${LOOP_DEV}p1" "$boot_mnt"

  # RPi firmware files come from the installed kernel_dir (chroot)
  info "Copying boot files..."
  cp -r "$kernel_dir/boot/firmware/." "$boot_mnt/" 2>/dev/null || \
  cp -r "$kernel_dir/boot/."          "$boot_mnt/" 2>/dev/null || true

  # Kernel image
  local kimg
  kimg=$(find "$kernel_dir/boot" -name "vmlinuz-*" | sort | tail -1)
  [[ -n "$kimg" ]] && cp "$kimg" "$boot_mnt/kernel8.img"

  # Initramfs
  local initrd
  initrd=$(find "$kernel_dir/boot" -name "initrd.img-*" | sort | tail -1)
  [[ -n "$initrd" ]] && cp "$initrd" "$boot_mnt/initramfs.img"

  # config.txt
  cat > "$boot_mnt/config.txt" <<'EOF'
arm_64bit=1
kernel=kernel8.img
initramfs initramfs.img followkernel

# HDMI
hdmi_force_hotplug=1
hdmi_drive=2
disable_overscan=1
hdmi_group=2
hdmi_mode=82

# GPU memory
gpu_mem=128

# Disable rainbow splash
disable_splash=1

[pi4]
dtoverlay=vc4-kms-v3d
max_framebuffers=2
arm_boost=1

[pi5]
dtoverlay=vc4-kms-v3d-pi5
EOF

  # cmdline.txt — boots slot A squashfs, mounts data overlay
  cat > "$boot_mnt/cmdline.txt" <<'EOF'
console=serial0,115200 console=tty1 root=PARTLABEL=rootfs-a rootfstype=squashfs ro quiet loglevel=3 signaeos.data=PARTLABEL=data
EOF

  # A/B boot flag
  cat > "$boot_mnt/signaeos.env" <<'EOF'
active_slot=a
boot_attempts=0
EOF

  sync
  umount "$boot_mnt"
  rmdir "$boot_mnt"

  losetup -d "$LOOP_DEV"
  LOOP_DEV=""

  info "RPi image assembled: $output_img"
}

# ─── Assemble x86 image ───────────────────────────────────────────────────────
assemble_x86_image() {
  local squashfs="$1"
  local kernel_dir="$2"
  local output_img="$3"

  step "Assembling x86_64 disk image"

  local total=$(( 2 + BOOT_SIZE + ROOTFS_SIZE + ROOTFS_SIZE + DATA_SIZE ))
  info "Image size: ${total}MiB"

  dd if=/dev/zero of="$output_img" bs=1M count="$total" status=progress

  parted -s "$output_img" \
    mklabel gpt \
    mkpart ESP  fat32  2MiB                         $(( 2 + BOOT_SIZE ))MiB \
    mkpart rootfs-a     $(( 2 + BOOT_SIZE ))MiB     $(( 2 + BOOT_SIZE + ROOTFS_SIZE ))MiB \
    mkpart rootfs-b     $(( 2 + BOOT_SIZE + ROOTFS_SIZE ))MiB  $(( 2 + BOOT_SIZE + ROOTFS_SIZE*2 ))MiB \
    mkpart data  ext4   $(( 2 + BOOT_SIZE + ROOTFS_SIZE*2 ))MiB 100% \
    set 1 boot on \
    set 1 esp  on

  LOOP_DEV=$(losetup -f --show -P "$output_img")
  info "Loop device: $LOOP_DEV"

  mkfs.vfat -F32 -n SGNOS-EFI "${LOOP_DEV}p1"
  mkfs.ext4 -L data -q "${LOOP_DEV}p4"

  # Write squashfs to slot A
  info "Writing rootfs to slot A..."
  dd if="$squashfs" of="${LOOP_DEV}p2" bs=4M status=progress
  sync

  # EFI partition
  local efi_mnt; efi_mnt=$(mktemp -d)
  mount "${LOOP_DEV}p1" "$efi_mnt"

  mkdir -p "$efi_mnt/EFI/BOOT" "$efi_mnt/grub"

  # Kernel + initrd
  local kimg initrd
  kimg=$(find "$kernel_dir/boot" -name "vmlinuz-*" | sort | tail -1)
  initrd=$(find "$kernel_dir/boot" -name "initrd.img-*" | sort | tail -1)
  [[ -n "$kimg"   ]] && cp "$kimg"   "$efi_mnt/vmlinuz"
  [[ -n "$initrd" ]] && cp "$initrd" "$efi_mnt/initrd.img"

  # GRUB EFI binary
  grub-mkimage \
    -O x86_64-efi \
    -o "$efi_mnt/EFI/BOOT/bootx64.efi" \
    -p /grub \
    boot linux ext2 fat squash4 part_gpt part_msdos \
    normal configfile echo search search_label \
    loadenv test

  # grub.cfg — reads A/B env file and boots correct slot
  cat > "$efi_mnt/grub/grub.cfg" <<'EOF'
set default=0
set timeout=0
set gfxpayload=keep

search --no-floppy --label --set=root SGNOS-EFI

# Load A/B flag
if [ -f /signaeos.env ]; then
  load_env -f /signaeos.env
fi

if [ "${active_slot}" = "b" ]; then
  set rootpart="rootfs-b"
else
  set rootpart="rootfs-a"
fi

menuentry "SignageOS" {
  linux  /vmlinuz  root=PARTLABEL=${rootpart} rootfstype=squashfs ro quiet loglevel=3 signaeos.data=PARTLABEL=data
  initrd /initrd.img
}

# Fallback — boot other slot if this one fails 3 times
if [ "${boot_attempts}" -ge 3 ]; then
  if [ "${active_slot}" = "b" ]; then
    set rootpart="rootfs-a"
    save_env -f /signaeos.env active_slot=a boot_attempts=0
  else
    set rootpart="rootfs-b"
    save_env -f /signaeos.env active_slot=b boot_attempts=0
  fi
fi
EOF

  # A/B boot flag
  cat > "$efi_mnt/signaeos.env" <<'EOF'
# GRUB environment block
active_slot=a
boot_attempts=0
EOF
  # Pad to 1024 bytes for grub-saveenv compatibility
  truncate -s 1024 "$efi_mnt/signaeos.env"

  sync
  umount "$efi_mnt"
  rmdir "$efi_mnt"

  losetup -d "$LOOP_DEV"
  LOOP_DEV=""

  info "x86 image assembled: $output_img"
}

# ─── Build for a target ───────────────────────────────────────────────────────
build() {
  local target="$1"   # rpi | x86
  local arch
  [[ "$target" == "rpi" ]] && arch="arm64" || arch="amd64"

  local work_dir="$OUTPUT_DIR/$target/work"
  local rootfs_dir="$work_dir/rootfs"
  local squashfs_path="$work_dir/rootfs.squashfs"

  step "Building SignageOS for $target ($arch)"
  mkdir -p "$work_dir" "$OUTPUT_DIR/$target/images"

  # 1. Bootstrap
  bootstrap_debian "$rootfs_dir" "$arch"

  # 2. Install packages
  install_packages "$rootfs_dir" "$arch"

  # 3. Companion Satellite
  install_companion_satellite "$rootfs_dir" "$arch"

  # 4. SignageOS files
  install_signaeos_files "$rootfs_dir"

  # 5. Configure
  configure_system "$rootfs_dir" "$arch"

  # 6. Pack squashfs
  make_squashfs "$rootfs_dir" "$squashfs_path"

  # 7. Assemble disk image
  local img="$OUTPUT_DIR/$target/images/signaeos-${target}.img"
  if [[ "$target" == "rpi" ]]; then
    assemble_rpi_image "$squashfs_path" "$rootfs_dir" "$img"
    info "Compressing..."
    xz -T0 -v "$img"
    info "${G}Done: ${img}.xz${N}"
  else
    assemble_x86_image "$squashfs_path" "$rootfs_dir" "$img"
    info "${G}Done: ${img}${N}"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  info "SignageOS Build System v$SIGNAEOS_VERSION"
  info "Target: $TARGET"
  info "Output: $OUTPUT_DIR"

  check_deps

  case "$TARGET" in
    rpi) build rpi ;;
    x86) build x86 ;;
    all) build rpi; build x86 ;;
    *)   error "Unknown target '$TARGET'. Use: rpi | x86 | all" ;;
  esac

  step "Build complete"
  echo
  echo -e "  ${G}Flash RPi:${N}  xzcat output/rpi/images/signaeos-rpi.img.xz | sudo dd of=/dev/sdX bs=4M status=progress"
  echo -e "  ${G}Flash x86:${N}  sudo dd if=output/x86/images/signaeos-x86.img of=/dev/sdX bs=4M status=progress"
  echo -e "  ${G}Setup UI:${N}   http://signaeos.local:3000"
  echo
}

main "$@"
