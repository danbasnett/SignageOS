'use strict';
/**
 * SignageOS Web UI — configuration server
 * Port 3000  |  REST API + static frontend
 */

const express = require('express');
const fs      = require('fs');
const path    = require('path');
const net     = require('net');
const { exec, execSync } = require('child_process');

const PORT        = 3000;
const CONFIG_FILE = process.env.SIGNAEOS_CONFIG || '/data/signaeos/config.json';
const SOCKET_PATH = '/run/signaeos/control.sock';

const DEFAULT_CONFIG = {
  display_name: 'SignageOS Display',
  browser: 'chromium',
  current_url_index: 0,
  urls: [{ label: 'Setup', url: 'http://localhost:3000' }],
  companion: { server_ip: '', server_port: 16622 },
  network: { wifi_ssid: '', wifi_password: '', hostname: 'signaeos' },
  ssh: { authorized_keys: '' }
};

// ─── Config ───────────────────────────────────────────────────────────────────
function readConfig() {
  try {
    return Object.assign({}, DEFAULT_CONFIG, JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')));
  } catch { return Object.assign({}, DEFAULT_CONFIG); }
}

function writeConfig(cfg) {
  fs.mkdirSync(path.dirname(CONFIG_FILE), { recursive: true });
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2));
}

// ─── Control socket ───────────────────────────────────────────────────────────
function sendControl(cmd) {
  return new Promise((resolve) => {
    const client = net.createConnection({ path: SOCKET_PATH }, () => {
      client.write(JSON.stringify(cmd) + '\n');
    });
    let buf = '';
    client.on('data', d => { buf += d; });
    client.on('end', () => {
      try { resolve(JSON.parse(buf)); } catch { resolve({ ok: true }); }
    });
    client.on('error', err => resolve({ ok: false, error: err.message }));
    setTimeout(() => { client.destroy(); resolve({ ok: false, error: 'timeout' }); }, 4000);
  });
}

// ─── Apply config side-effects ────────────────────────────────────────────────
async function applyConfig(cfg) {
  writeConfig(cfg);

  // Hostname
  try {
    fs.writeFileSync('/etc/hostname', cfg.network.hostname + '\n');
    execSync(`hostname '${cfg.network.hostname}'`);
  } catch {}

  // SSH keys
  if (cfg.ssh.authorized_keys) {
    try {
      fs.mkdirSync('/root/.ssh', { recursive: true });
      fs.writeFileSync('/root/.ssh/authorized_keys', cfg.ssh.authorized_keys);
      fs.chmodSync('/root/.ssh', 0o700);
      fs.chmodSync('/root/.ssh/authorized_keys', 0o600);
    } catch {}
  }

  // WiFi
  if (cfg.network.wifi_ssid && cfg.network.wifi_password &&
      !cfg.network.wifi_password.includes('•')) {
    exec(`nmcli device wifi connect '${cfg.network.wifi_ssid}' password '${cfg.network.wifi_password}'`,
      err => { if (err) console.warn('WiFi:', err.message); });
  }

  // Companion Satellite config
  if (cfg.companion.server_ip) {
    const satCfg = {
      remoteIp: cfg.companion.server_ip,
      remotePort: cfg.companion.server_port || 16622
    };
    fs.mkdirSync('/data/signaeos', { recursive: true });
    fs.writeFileSync('/data/signaeos/satellite.json', JSON.stringify(satCfg, null, 2));
    exec('systemctl restart companion-satellite', () => {});
  }

  // Reload kiosk
  await sendControl({ cmd: 'reload' });
}

// ─── Express ─────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// GET /api/config
app.get('/api/config', (req, res) => {
  const cfg = readConfig();
  const safe = JSON.parse(JSON.stringify(cfg));
  if (safe.network?.wifi_password) safe.network.wifi_password = '••••••••';
  res.json(safe);
});

// POST /api/config
app.post('/api/config', async (req, res) => {
  try {
    const existing = readConfig();
    const incoming = req.body;
    if (incoming.network?.wifi_password === '••••••••')
      incoming.network.wifi_password = existing.network?.wifi_password || '';
    const merged = Object.assign({}, existing, incoming);
    await applyConfig(merged);
    res.json({ ok: true });
  } catch (err) { res.status(500).json({ ok: false, error: err.message }); }
});

// POST /api/switch/:index  — called by Companion HTTP action
app.post('/api/switch/:index', async (req, res) => {
  const idx = parseInt(req.params.index, 10);
  const result = await sendControl({ cmd: 'switch', index: idx });
  if (result.ok) {
    const cfg = readConfig();
    cfg.current_url_index = idx;
    writeConfig(cfg);
  }
  res.json(result);
});

app.post('/api/next', async (req, res) => res.json(await sendControl({ cmd: 'next' })));
app.post('/api/prev', async (req, res) => res.json(await sendControl({ cmd: 'prev' })));
app.post('/api/reload', async (req, res) => res.json(await sendControl({ cmd: 'reload' })));

// GET /api/status
app.get('/api/status', async (req, res) => res.json(await sendControl({ cmd: 'status' })));

// GET /api/wifi/scan
app.get('/api/wifi/scan', (req, res) => {
  exec('nmcli -t -f SSID,SIGNAL,SECURITY device wifi list --rescan yes', (err, stdout) => {
    if (err) return res.json({ ok: false, networks: [] });
    const networks = stdout.split('\n').filter(Boolean).map(l => {
      const p = l.split(':');
      return { ssid: p[0], signal: parseInt(p[1] || '0', 10), security: p[2] || '' };
    }).filter(n => n.ssid).sort((a, b) => b.signal - a.signal);
    res.json({ ok: true, networks });
  });
});

// GET /api/system
app.get('/api/system', (req, res) => {
  try {
    const hostname = fs.readFileSync('/etc/hostname', 'utf8').trim();
    const uptime   = parseFloat(fs.readFileSync('/proc/uptime', 'utf8').split(' ')[0]);
    const ip       = execSync('hostname -I 2>/dev/null || echo ""').toString().trim().split(' ')[0] || '—';
    const arch     = execSync('uname -m').toString().trim();
    let version = 'unknown';
    try { version = fs.readFileSync('/etc/signaeos-version', 'utf8').trim(); } catch {}
    res.json({ ok: true, hostname, uptime, ip, arch, version });
  } catch (err) { res.json({ ok: false, error: err.message }); }
});

// POST /api/reboot
app.post('/api/reboot', (req, res) => {
  res.json({ ok: true });
  setTimeout(() => exec('systemctl reboot'), 500);
});

// POST /api/update/check
app.post('/api/update/check', (req, res) => {
  exec('signaeos-update check', (err, stdout) => res.json({ ok: !err, output: stdout }));
});

// POST /api/update/apply
app.post('/api/update/apply', (req, res) => {
  exec('signaeos-update apply', (err, stdout) => res.json({ ok: !err, output: stdout }));
});

// ─── Start ────────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log(`SignageOS WebUI :${PORT}  config: ${CONFIG_FILE}`);
});
