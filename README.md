# SignageOS

A minimal Debian-based digital signage OS. Boots to a fullscreen kiosk browser, controlled via Stream Deck through Bitfocus Companion Satellite. Configured via a web UI — no keyboard or monitor required.

## Features

- **Debian Bookworm base** — real apt packages, proper GPU drivers, maintained browser security updates
- **Chromium or Firefox** — user-selectable in the web UI, fullscreen kiosk mode
- **Multi-URL switching** — define any number of URLs, switch between them instantly from a Stream Deck button
- **Bitfocus Companion Satellite** — Stream Deck plugs into this box *or* into any PC running Companion
- **First-boot web UI** — browse to `http://signaeos.local:3000` to configure everything
- **Read-only rootfs** — squashfs root, writable `ext4` data partition with overlayfs; survives power cuts
- **A/B OTA updates** — download to inactive slot, boot, auto-rollback on failure
- **SSH access** — key-based only; add keys in the web UI
- **WiFi + Ethernet** — NetworkManager, configurable from web UI with network scan
- **Multi-arch** — same codebase builds for Raspberry Pi 4/5 (arm64) and x86_64

---

## Build

### Host requirements (Ubuntu 22.04 / 24.04 recommended)

```bash
sudo apt-get install -y \
  debootstrap qemu-user-static binfmt-support \
  parted squashfs-tools dosfstools \
  grub-efi-amd64-bin mtools \
  curl wget git xz-utils
```

### Build

```bash
# Clone
git clone https://github.com/your-org/signaeos
cd signaeos

# Raspberry Pi 4/5 image  (~20–30 min first time, cached debootstrap after)
sudo ./scripts/build-image.sh rpi

# x86_64 image
sudo ./scripts/build-image.sh x86

# Both
sudo ./scripts/build-image.sh all
```

Outputs:
- `output/rpi/images/signaeos-rpi.img.xz` — compressed RPi image
- `output/x86/images/signaeos-x86.img` — x86 disk image

The first build downloads and caches a Debian debootstrap tarball in `.cache/`. Subsequent builds reuse it, taking ~10 minutes instead of ~30.

---

## Flash

### Raspberry Pi

```bash
xzcat output/rpi/images/signaeos-rpi.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
sync
```

Replace `/dev/sdX` with your SD card or USB drive.

### x86 (USB stick or SSD)

```bash
sudo dd if=output/x86/images/signaeos-x86.img of=/dev/sdX bs=4M status=progress
sync
```

Boot from the USB/SSD. Ensure UEFI boot is enabled in BIOS.

---

## First Boot

1. Connect the device to your network via ethernet
2. Browse to **`http://signaeos.local:3000`** from any device on the same network
   - If mDNS doesn't resolve, check your router's DHCP leases for the IP
3. Configure:
   - **Display**: name, browser choice
   - **URLs**: add all the pages you want to display (label + URL)
   - **Network**: WiFi credentials if needed, hostname
   - **Stream Deck**: Companion server IP
   - **System**: paste your SSH public key
4. Click **Save** — the kiosk reloads immediately

---

## Stream Deck Setup

### Option A — HTTP actions (simplest)

In Bitfocus Companion, add a **Generic HTTP** connection. For each URL:

| Button | Action | URL |
|--------|--------|-----|
| Dashboard | POST | `http://signaeos.local:3000/api/switch/0` |
| Alerts | POST | `http://signaeos.local:3000/api/switch/1` |
| Welcome | POST | `http://signaeos.local:3000/api/switch/2` |

### Option B — Companion Satellite

1. In Companion → Connections → Add → search **Satellite**
2. Enter this device's IP, port `16622`
3. Plug Stream Deck into this device or into any PC running Companion

### Direct API endpoints

```
POST /api/switch/:index   switch to URL by index (0-based)
POST /api/next            next URL
POST /api/prev            previous URL
POST /api/reload          reload current URL
GET  /api/status          current URL info
```

---

## SSH

```bash
ssh root@signaeos.local
```

Password auth is disabled. Add your public key in the web UI or drop a file at `/data/signaeos/authorized_keys`.

---

## Config file

`/data/signaeos/config.json` — written by the web UI, can be edited manually:

```json
{
  "display_name": "Lobby Screen",
  "browser": "chromium",
  "current_url_index": 0,
  "urls": [
    { "label": "Dashboard", "url": "https://grafana.local/d/abc" },
    { "label": "Alerts",    "url": "https://grafana.local/d/xyz" }
  ],
  "companion": {
    "server_ip": "192.168.1.100",
    "server_port": 16622
  },
  "network": {
    "hostname": "lobby-screen",
    "wifi_ssid": "MyWiFi",
    "wifi_password": "secret"
  },
  "ssh": {
    "authorized_keys": "ssh-ed25519 AAAA..."
  }
}
```

---

## Partition layout

```
┌────────────────┬─────────────┬─────────────┬────────────────┐
│  boot/EFI      │  rootfs-a   │  rootfs-b   │  data          │
│  256 MiB FAT   │  768 MiB    │  768 MiB    │  rest of disk  │
│  (kernel/grub) │  squashfs   │  squashfs   │  ext4 (grown   │
│                │  (active)   │  (update)   │  on first boot)│
└────────────────┴─────────────┴─────────────┴────────────────┘
```

- Root is always squashfs (read-only)
- `/data` is ext4, writable, holds config + overlayfs layers
- A/B: updates write to inactive slot, next boot switches to it

---

## OTA Updates

```bash
# Check for an update
signaeos-update check

# Apply (downloads to inactive slot)
signaeos-update apply

# Rollback to previous slot
signaeos-update rollback
```

Set `SIGNAEOS_UPDATE_SERVER=https://your-server` in `/etc/environment` to enable auto-checks. See `docs/update-server.md` for running your own update server.

---

## Logs

```bash
journalctl -u signaeos-init      -f   # kiosk / browser
journalctl -u signaeos-webui     -f   # web UI
journalctl -u companion-satellite -f  # Stream Deck satellite
journalctl -u weston              -f  # compositor

# Or from the build host after SSH:
ssh root@signaeos.local journalctl -u signaeos-init -n 50
```

---

## Useful commands (on device)

```bash
signaeos-ctl status          # what's currently showing
signaeos-ctl switch 2        # switch to URL index 2
signaeos-ctl next            # next URL
signaeos-ctl prev            # previous URL
signaeos-ctl reload          # reload current URL
signaeos-update status       # A/B slot info
```
