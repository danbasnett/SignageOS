# SignageOS

Dual display digital signage OS. Display 1 shows web content (Chromium/Firefox kiosk), Display 2 shows NDI sources. Both controlled via Stream Deck through Bitfocus Companion Satellite.

## Installation

### Step 1 — Flash Raspberry Pi OS Lite

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Choose OS → **Raspberry Pi OS Lite (64-bit)**
3. Before writing, click the **settings cog** (or press `Ctrl+Shift+X`) and set:
   - Hostname: `signaeos`
   - Enable SSH: ✓
   - Username: `pi`  Password: `signaeos`
   - WiFi credentials (optional — ethernet recommended for first boot)
4. Write to SD card

### Step 2 — Install SignageOS

Download the latest release from the [Releases page](../../releases):

```bash
# Extract the provision bundle
tar -xzf signaeos-provision-v*.tar.gz

# Run the installer (SD card must be inserted in your Mac/PC)
./install.sh
```

Eject the SD card safely.

### Step 3 — First boot

1. Insert SD card into Pi, connect ethernet, power on
2. Wait **10–15 minutes** — provisioning installs everything automatically
3. Browse to **http://signaeos.local:3000**

To watch provisioning progress:
```bash
ssh pi@signaeos.local   # password: signaeos
sudo journalctl -u signaeos-firstboot -f
```

---

## Setup UI

Browse to `http://signaeos.local:3000` (or `http://<ip>:3000`).

| Section | What you configure |
|---|---|
| Display 1 — Web | URLs to show, browser choice, device name |
| Display 2 — NDI | NDI sources, switch between them |
| NDI Access Manager | AM server IP, source visibility, receiver registration |
| Network & VLANs | 802.1q trunk VLANs, WiFi, hostname |
| Stream Deck | Companion server IP, Satellite port |
| System | SSH keys, OTA updates, reboot |

---

## Stream Deck / Companion

Companion Satellite runs on port `16622`. In Bitfocus Companion:

**Option A — HTTP actions (simplest):**

| Button | POST to |
|---|---|
| Switch Display 1 to URL 0 | `http://signaeos.local:3000/api/display/1/switch/0` |
| Switch Display 1 to URL 1 | `http://signaeos.local:3000/api/display/1/switch/1` |
| NDI Source next | `http://signaeos.local:3000/api/display/2/next` |
| NDI Source previous | `http://signaeos.local:3000/api/display/2/prev` |

**Option B — Companion Satellite:**
Add a Satellite connection pointing at `signaeos.local`, port `16622`.

---

## SSH

```bash
ssh pi@signaeos.local
# password: signaeos
```

Useful commands once in:

```bash
sudo systemctl status signaeos-webui       # web UI status
sudo systemctl status signaeos-display1    # display 1 status
sudo journalctl -u signaeos-display1 -f   # live logs
signaeos-ctl d1 status                    # current URL on display 1
signaeos-ctl d2 status                    # current NDI source on display 2
signaeos-ctl d2 discover                  # scan for NDI sources on network
signaeos-update check                     # check for updates
signaeos-update apply                     # apply update (no reboot needed)
```

---

## Dual display wiring

- **Single device (Pi 5 / x86):** connect two HDMI cables, Weston manages both outputs automatically
- **Two devices:** flash both with the same image; set Role to `web` on one and `ndi` on the other in the web UI

---

## Config file

`/data/signaeos/config.json` — written by the web UI, can be edited manually:

```json
{
  "role": "both",
  "display_name": "Lobby Screen",
  "display1": {
    "browser": "chromium",
    "current_index": 0,
    "urls": [
      { "label": "Dashboard", "url": "https://grafana.local/d/abc" },
      { "label": "Alerts",    "url": "https://grafana.local/d/xyz" }
    ]
  },
  "display2": {
    "current_source": "ATEM MINI (192.168.1.50)",
    "sources": [
      { "label": "ATEM",    "name": "ATEM MINI (192.168.1.50)" },
      { "label": "Camera",  "name": "PTZ Camera 1 (192.168.1.51)" }
    ]
  },
  "ndi": {
    "access_manager_ip": "192.168.1.100",
    "access_manager_port": 80,
    "groups": ["public", "studio1"]
  },
  "network": {
    "hostname": "lobby-screen",
    "native_vlan": "1",
    "vlans": [
      { "id": 10, "ip": "10.10.10.5/24", "gateway": "10.10.10.1", "label": "AV VLAN" }
    ],
    "wifi_ssid": "",
    "wifi_password": ""
  }
}
```

---

## Building from source

The GitHub Actions workflow packages everything automatically on each tag push. No image build needed — the provision script installs onto standard Raspberry Pi OS Lite.

```bash
git tag v1.0.0
git push origin v1.0.0
# Release appears at github.com/your-org/signaeos/releases
```
