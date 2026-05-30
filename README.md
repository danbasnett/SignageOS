# SignageOS

Dual display digital signage for Raspberry Pi. Display 1 shows web content, Display 2 shows NDI. Both controlled via Stream Deck through Bitfocus Companion Satellite.

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
- HDMI display connected

## Features

- **Display 1** — Chromium or Firefox, fullscreen kiosk, switch URLs via Stream Deck
- **Display 2** — Native NDI viewer, switch sources via Stream Deck  
- **NDI Access Manager** — control source visibility from the web UI
- **802.1q VLANs** — trunk port support, configure tagged VLANs from web UI
- **Bitfocus Companion Satellite** — Stream Deck connects on port 16622
- **OTA updates** — `sudo signaeos-update apply`

## After install

```bash
# Check everything is running
sudo systemctl status signaeos-webui
sudo systemctl status signaeos-display1

# Live logs
sudo journalctl -u signaeos-display1 -f

# Control from command line
signaeos-ctl d1 status
signaeos-ctl d1 switch 1
signaeos-ctl d2 source "ATEM MINI (192.168.1.50)"
signaeos-ctl d2 discover

# Update
sudo signaeos-update check
sudo signaeos-update apply
```

## Companion / Stream Deck API

```
POST http://signaeos.local:3000/api/display/1/switch/0   switch display 1 to URL 0
POST http://signaeos.local:3000/api/display/1/next        next URL
POST http://signaeos.local:3000/api/display/2/next        next NDI source
POST http://signaeos.local:3000/api/display/2/prev        prev NDI source
```

Or use Companion Satellite on port `16622`.
