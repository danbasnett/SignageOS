'use strict';
const express = require('express');
const fs      = require('fs');
const path    = require('path');
const net     = require('net');
const http    = require('http');
const { exec, execSync } = require('child_process');

const PORT        = 3000;
const CONFIG_FILE = process.env.SIGNAEOS_CONFIG || '/data/signaeos/config.json';
const NDI_CONFIG  = '/etc/ndi/ndi-config.v1.json';
const D1_SOCK     = '/run/signaeos/display1.sock';
const D2_SOCK     = '/run/signaeos/display2.sock';

const DEFAULT_CONFIG = {
  role: 'both',
  display_name: 'SignageOS',
  display1: { browser: 'chromium', current_index: 0,
    urls: [{ label: 'Setup', url: 'http://localhost:3000' }] },
  display2: { current_source: '', sources: [] },
  ndi: {
    // NDI devices to query directly (extra_ips) - [{ip, label}]
    devices: [],
    // NDI Discovery Server IP (optional)
    discovery_server: '',
    // Manual sources - [{label, name, ip}]
    manual_sources: []
  },
  companion: { server_ip: '', server_port: 16622 },
  network: { hostname: 'signaeos', native_vlan: '', vlans: [], wifi_ssid: '', wifi_password: '' },
  ssh: { authorized_keys: '' }
};

// ── Config ─────────────────────────────────────────────────────────────────
function readConfig() {
  try {
    const raw = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
    return Object.assign({}, DEFAULT_CONFIG, raw,
      { ndi: Object.assign({}, DEFAULT_CONFIG.ndi, raw.ndi || {}) });
  } catch { return Object.assign({}, DEFAULT_CONFIG); }
}
function writeConfig(cfg) {
  fs.mkdirSync(path.dirname(CONFIG_FILE), { recursive: true });
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2));
}

// ── Write NDI SDK config file ──────────────────────────────────────────────
// This tells the NDI SDK which IPs to query directly (extra_ips) and
// optionally which discovery server to use. Takes effect immediately for
// any NDI tool or ndiplay that reads this file.
function writeNdiConfig(cfg) {
  const ndi = cfg.ndi || {};
  const deviceIps = (ndi.devices || []).map(d => d.ip).filter(Boolean).join(',');
  const ndiCfg = { ndi: { networks: {} } };
  if (deviceIps)               ndiCfg.ndi.networks.extra_ips  = deviceIps;
  if (ndi.discovery_server)    ndiCfg.ndi.networks.discovery  = ndi.discovery_server;
  fs.mkdirSync('/etc/ndi', { recursive: true });
  fs.writeFileSync(NDI_CONFIG, JSON.stringify(ndiCfg, null, 2));
  console.log('NDI config written:', JSON.stringify(ndiCfg.ndi.networks));
}

// ── Socket ─────────────────────────────────────────────────────────────────
function sendSocket(sockPath, cmd) {
  return new Promise(resolve => {
    const c = net.createConnection({ path: sockPath }, () => c.write(JSON.stringify(cmd) + '\n'));
    let buf = '';
    c.on('data', d => buf += d);
    c.on('end', () => { try { resolve(JSON.parse(buf)); } catch { resolve({ ok: true }); } });
    c.on('error', e => resolve({ ok: false, error: e.message }));
    setTimeout(() => { c.destroy(); resolve({ ok: false, error: 'timeout' }); }, 5000);
  });
}
const d1 = cmd => sendSocket(D1_SOCK, cmd);
const d2 = cmd => sendSocket(D2_SOCK, cmd);

// ── NDI local discovery via ndi-find ───────────────────────────────────────
// With extra_ips set in /etc/ndi/ndi-config.v1.json, this also queries
// those IPs directly — crossing subnets without multicast.
function discoverNdi() {
  return new Promise(resolve => {
    const tools = [
      '/usr/local/bin/ndi-discover',
      '/usr/local/bin/NDI_Find',
      'ndi-discover',
      'NDI_Find'
    ];
    let tried = 0;
    const tryTool = () => {
      if (tried >= tools.length) return resolve([]);
      const tool = tools[tried++];
      exec(`timeout 5 ${tool} 2>/dev/null`, (err, stdout) => {
        if (!err && stdout.trim()) {
          const sources = stdout.split('\n')
            .map(l => l.trim())
            .filter(l => l.length > 0 && !l.startsWith('#'))
            .map(name => ({ label: name, name, source: 'discovered' }));
          return resolve(sources);
        }
        tryTool();
      });
    };
    tryTool();
  });
}

// ── Get all NDI sources ────────────────────────────────────────────────────
async function getAllNdiSources() {
  const cfg = readConfig();
  const ndi = cfg.ndi || {};

  // Run local discovery (picks up extra_ips from NDI config automatically)
  const discovered = await discoverNdi();

  // Manual sources always included
  const manual = (ndi.manual_sources || []).map(s => ({
    label: s.label || s.name,
    name:  s.name,
    ip:    s.ip || '',
    source: 'manual'
  }));

  // Deduplicate by name
  const seen = new Set();
  return [...discovered, ...manual].filter(s => {
    if (!s.name || seen.has(s.name)) return false;
    seen.add(s.name); return true;
  });
}

// ── Apply config ───────────────────────────────────────────────────────────
async function applyConfig(cfg) {
  writeConfig(cfg);
  writeNdiConfig(cfg);

  try { fs.writeFileSync('/etc/hostname', cfg.network.hostname + '\n');
        execSync(`hostname '${cfg.network.hostname}'`); } catch {}

  if (cfg.ssh?.authorized_keys) {
    try {
      fs.mkdirSync('/root/.ssh', { recursive: true });
      fs.writeFileSync('/root/.ssh/authorized_keys', cfg.ssh.authorized_keys);
      fs.chmodSync('/root/.ssh', 0o700);
      fs.chmodSync('/root/.ssh/authorized_keys', 0o600);
    } catch {}
  }

  if (cfg.network?.wifi_ssid && cfg.network?.wifi_password &&
      !cfg.network.wifi_password.includes('•')) {
    exec(`nmcli device wifi connect '${cfg.network.wifi_ssid}' password '${cfg.network.wifi_password}'`,
      err => err && console.warn('WiFi:', err.message));
  }

  if (cfg.companion?.server_ip) {
    fs.mkdirSync('/data/signaeos', { recursive: true });
    fs.writeFileSync('/data/signaeos/satellite.json',
      JSON.stringify({ remoteIp: cfg.companion.server_ip,
                       remotePort: cfg.companion.server_port || 16622 }, null, 2));
    exec('systemctl restart companion-satellite 2>/dev/null || true', () => {});
  }

  await d1({ cmd: 'reload' }).catch(() => {});
}

// ── Express ────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Config
app.get('/api/config', (req, res) => {
  const cfg = readConfig();
  const safe = JSON.parse(JSON.stringify(cfg));
  if (safe.network?.wifi_password) safe.network.wifi_password = '••••••••';
  res.json(safe);
});
app.post('/api/config', async (req, res) => {
  try {
    const existing = readConfig(); const incoming = req.body;
    if (incoming.network?.wifi_password === '••••••••')
      incoming.network.wifi_password = existing.network?.wifi_password || '';
    const merged = Object.assign({}, existing, incoming,
      { ndi: Object.assign({}, existing.ndi || {}, incoming.ndi || {}) });
    await applyConfig(merged);
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});

// Display 1
app.get ('/api/display/1/status',        async (req, res) => res.json(await d1({ cmd: 'status' })));
app.post('/api/display/1/switch/:index', async (req, res) => {
  const idx = parseInt(req.params.index, 10);
  const r = await d1({ cmd: 'switch', index: idx });
  if (r.ok) { const cfg = readConfig(); cfg.display1.current_index = idx; writeConfig(cfg); }
  res.json(r);
});
app.post('/api/display/1/next',   async (req, res) => res.json(await d1({ cmd: 'next' })));
app.post('/api/display/1/prev',   async (req, res) => res.json(await d1({ cmd: 'prev' })));
app.post('/api/display/1/reload', async (req, res) => res.json(await d1({ cmd: 'reload' })));

// Display 2
app.get ('/api/display/2/status', async (req, res) => res.json(await d2({ cmd: 'status' })));
app.post('/api/display/2/source/:name', async (req, res) => {
  const name = decodeURIComponent(req.params.name);
  const r = await d2({ cmd: 'source', source: name });
  if (r.ok) { const cfg = readConfig(); cfg.display2.current_source = name; writeConfig(cfg); }
  res.json(r);
});
app.post('/api/display/2/source', async (req, res) => {
  const name = req.body.name || '';
  const r = await d2({ cmd: 'source', source: name });
  if (r.ok) { const cfg = readConfig(); cfg.display2.current_source = name; writeConfig(cfg); }
  res.json(r);
});
app.post('/api/display/2/next', async (req, res) => res.json(await d2({ cmd: 'next' })));
app.post('/api/display/2/prev', async (req, res) => res.json(await d2({ cmd: 'prev' })));

// ── NDI ────────────────────────────────────────────────────────────────────

// GET /api/ndi/sources — discover all sources
app.get('/api/ndi/sources', async (req, res) => {
  const sources = await getAllNdiSources();
  res.json({ ok: true, sources });
});

// GET /api/ndi/config — current NDI SDK config
app.get('/api/ndi/config', (req, res) => {
  const cfg = readConfig();
  res.json({ ok: true, ndi: cfg.ndi });
});

// POST /api/ndi/devices — add or update a device IP
app.post('/api/ndi/devices', (req, res) => {
  const { ip, label } = req.body;
  if (!ip) return res.status(400).json({ ok: false, error: 'ip required' });
  const cfg = readConfig();
  cfg.ndi.devices = cfg.ndi.devices || [];
  const idx = cfg.ndi.devices.findIndex(d => d.ip === ip);
  const entry = { ip, label: label || ip };
  if (idx >= 0) cfg.ndi.devices[idx] = entry;
  else cfg.ndi.devices.push(entry);
  writeConfig(cfg);
  writeNdiConfig(cfg);
  res.json({ ok: true });
});

// DELETE /api/ndi/devices/:ip — remove a device IP
app.delete('/api/ndi/devices/:ip', (req, res) => {
  const ip = decodeURIComponent(req.params.ip);
  const cfg = readConfig();
  cfg.ndi.devices = (cfg.ndi.devices || []).filter(d => d.ip !== ip);
  writeConfig(cfg);
  writeNdiConfig(cfg);
  res.json({ ok: true });
});

// POST /api/ndi/discovery-server — set discovery server IP
app.post('/api/ndi/discovery-server', (req, res) => {
  const { ip } = req.body;
  const cfg = readConfig();
  cfg.ndi.discovery_server = ip || '';
  writeConfig(cfg);
  writeNdiConfig(cfg);
  res.json({ ok: true });
});

// POST /api/ndi/manual — add manual source
app.post('/api/ndi/manual', (req, res) => {
  const { label, name, ip } = req.body;
  if (!name) return res.status(400).json({ ok: false, error: 'name required' });
  const cfg = readConfig();
  cfg.ndi.manual_sources = cfg.ndi.manual_sources || [];
  const idx = cfg.ndi.manual_sources.findIndex(s => s.name === name);
  const entry = { label: label || name, name, ip: ip || '' };
  if (idx >= 0) cfg.ndi.manual_sources[idx] = entry;
  else cfg.ndi.manual_sources.push(entry);
  writeConfig(cfg);
  res.json({ ok: true });
});

// DELETE /api/ndi/manual/:name — remove manual source
app.delete('/api/ndi/manual/:name', (req, res) => {
  const name = decodeURIComponent(req.params.name);
  const cfg = readConfig();
  cfg.ndi.manual_sources = (cfg.ndi.manual_sources || []).filter(s => s.name !== name);
  writeConfig(cfg);
  res.json({ ok: true });
});

// ── Network ────────────────────────────────────────────────────────────────
app.get('/api/network/wifi/scan', (req, res) => {
  exec('nmcli -t -f SSID,SIGNAL,SECURITY device wifi list --rescan yes', (err, stdout) => {
    if (err) return res.json({ ok: false, networks: [] });
    const networks = stdout.split('\n').filter(Boolean)
      .map(l => { const p = l.split(':'); return { ssid: p[0], signal: parseInt(p[1]||'0',10), security: p[2]||'' }; })
      .filter(n => n.ssid).sort((a,b) => b.signal - a.signal);
    res.json({ ok: true, networks });
  });
});

app.post('/api/network/vlans', (req, res) => {
  const cfg = readConfig();
  cfg.network.vlans = req.body.vlans || [];
  cfg.network.native_vlan = req.body.native_vlan || '';
  writeConfig(cfg);
  exec("ip -o link show | awk -F': ' '$2 ~ /^eth|^en/ {print $2; exit}'", (err, iface) => {
    iface = (iface || 'eth0').trim();
    const cmds = (cfg.network.vlans || []).map(v => {
      const vif = `${iface}.${v.id}`;
      const ipArg = v.ip ? `ipv4.method manual ipv4.addresses '${v.ip}'` : 'ipv4.method auto';
      const gwArg = v.gateway ? `ipv4.gateway '${v.gateway}'` : '';
      return `nmcli con delete '${vif}' 2>/dev/null; nmcli con add type vlan con-name '${vif}' dev '${iface}' id ${v.id} ${ipArg} ${gwArg} ipv6.method ignore && nmcli con up '${vif}'`;
    });
    if (!cmds.length) return res.json({ ok: true });
    exec(cmds.join(' && '), err2 => {
      if (err2) return res.json({ ok: false, error: err2.message });
      res.json({ ok: true });
    });
  });
});

// ── System ─────────────────────────────────────────────────────────────────
app.get('/api/system', (req, res) => {
  try {
    const hostname = fs.readFileSync('/etc/hostname', 'utf8').trim();
    const uptime   = parseFloat(fs.readFileSync('/proc/uptime', 'utf8').split(' ')[0]);
    const ip       = execSync('hostname -I 2>/dev/null || echo ""').toString().trim().split(' ')[0] || '—';
    const arch     = execSync('uname -m').toString().trim();
    let version = 'unknown';
    try { version = fs.readFileSync('/etc/signaeos-version', 'utf8').trim(); } catch {}
    res.json({ ok: true, hostname, uptime, ip, arch, version });
  } catch (e) { res.json({ ok: false, error: e.message }); }
});

app.post('/api/reboot',       (req, res) => { res.json({ ok: true }); setTimeout(() => exec('systemctl reboot'), 500); });
app.post('/api/update/check', (req, res) => exec('signaeos-update check', (e,o) => res.json({ ok: !e, output: o })));
app.post('/api/update/apply', (req, res) => exec('signaeos-update apply', (e,o) => res.json({ ok: !e, output: o })));

app.get('/api/status', async (req, res) => {
  const [s1, s2] = await Promise.all([
    d1({ cmd: 'status' }).catch(() => ({ ok: false })),
    d2({ cmd: 'status' }).catch(() => ({ ok: false }))
  ]);
  res.json({ ok: true, display1: s1, display2: s2 });
});

// Write NDI config on startup with whatever is already configured
try { writeNdiConfig(readConfig()); } catch {}

app.listen(PORT, '0.0.0.0', () => console.log(`SignageOS WebUI :${PORT}`));
