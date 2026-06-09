# SignageOS

Dual display digital signage for Raspberry Pi. Display 1 shows web content, Display 2 shows NDI. Both can be controlled from the web UI, command line, or Stream Deck through Bitfocus Companion Satellite.

## Install

On a Raspberry Pi running **Raspberry Pi OS Lite (Bookworm)**:

```bash
curl -fsSL https://raw.githubusercontent.com/danbasnett/SignageOS/main/install.sh | sudo bash
```

Takes about 10–15 minutes. Then browse to **http://signaeos.local:3000**.

## Requirements

- Raspberry Pi 4 or 5 (or x86_64)
- Raspberry Pi OS Lite 64-bit (Bookworm)
- Internet connection during install
- One or two HDMI displays connected
- An NDI source on the same network, via an NDI Discovery Server, or configured by source name/IP

## Features

- **Display 1** — Chromium fullscreen kiosk, switch URLs from the web UI or Stream Deck
- **Display 2** — Native NDI viewer, switch sources from the web UI or Stream Deck
- **Display assignment** — configure which HDMI output is web vs NDI from the web UI
- **NDI Access Manager** — control source visibility from the web UI
- **802.1q VLANs** — trunk port support, configure tagged VLANs from web UI
- **Bitfocus Companion Satellite** — Stream Deck connects on port 16622
- **OTA updates** — `sudo signaeos-update apply`

## First setup

1. Flash **Raspberry Pi OS Lite 64-bit Bookworm** to a Raspberry Pi 4 or 5.
2. Connect the displays before booting. On Pi 4/5, `HDMI-A-1` is the port closest to USB-C power and defaults to Display 1/Web. `HDMI-A-2` defaults to Display 2/NDI.
3. Install SignageOS:

```bash
curl -fsSL https://raw.githubusercontent.com/danbasnett/SignageOS/main/install.sh | sudo bash
```

4. Open **http://signaeos.local:3000**.
5. In **Display 1 — Web**, add the URL you want to show and save.
6. In **Display 2 — NDI**, add or discover the NDI source and select it.
7. If the displays are the wrong way round, open **Monitors** and click **Swap Displays**.

## After Install

```bash
# Check everything is running
sudo systemctl status sway
sudo systemctl status signaeos-webui
sudo systemctl status signaeos-display1
sudo systemctl status signaeos-display2

# Run the built-in validation checks
sudo /usr/share/signaeos/scripts/validate-pi.sh

# Live logs
sudo journalctl -u signaeos-display1 -f
sudo journalctl -u signaeos-display2 -f

# Control from command line
signaeos-ctl d1 status
signaeos-ctl d1 switch 1
signaeos-ctl d2 source "ATEM MINI (192.168.1.50)"
signaeos-ctl d2 discover

# Update
sudo signaeos-update check
sudo signaeos-update apply
```

## Display Routing

SignageOS uses Sway/Wayland to keep the two outputs separate:

- Workspace 1 is assigned to Display 1/Web.
- Workspace 2 is assigned to Display 2/NDI.
- `/etc/sway/config` is regenerated when you change monitor settings in the web UI.

The display services run as the `signaeos` user. Runtime sockets live under `/run/signaeos-runtime`, while control sockets live under `/run/signaeos`.

## NDI Notes

The installer downloads the NDI SDK and builds `/usr/bin/signaeos-ndi-player`. If the SDK download fails, Display 2 will fall back to VLC/`ndiplay` if either is available, then finally to a placeholder page showing the selected source name.

If discovery does not find your source:

- Add the NDI device IP in **NDI Sources > NDI Devices**.
- Add an NDI Discovery Server IP if your network uses one.
- Add a manual source using the exact NDI source name, for example `ATEM MINI (10.32.40.2)`.

## Companion / Stream Deck API

```
POST http://signaeos.local:3000/api/display/1/switch/0   switch display 1 to URL 0
POST http://signaeos.local:3000/api/display/1/next        next URL
POST http://signaeos.local:3000/api/display/2/next        next NDI source
POST http://signaeos.local:3000/api/display/2/prev        prev NDI source
```

Or use Companion Satellite on port `16622`.
