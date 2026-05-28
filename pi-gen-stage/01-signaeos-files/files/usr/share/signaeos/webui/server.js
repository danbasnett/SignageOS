'use strict';
const express = require('express');
const fs      = require('fs');
const path    = require('path');
const net     = require('net');
const http    = require('http');
const { exec, execSync } = require('child_process');

const PORT        = 3000;
const CONFIG_FILE = process.env.SIGNAEOS_CONFIG || '/data/signaeos/config.json';
const D1_SOCK     = '/run/signaeos/display1.sock';
const D2_SOCK     = '/run/signaeos/display2.sock';

const DEFAULT_CONFIG = {
  role: 'both',
  display_name: 'SignageOS',
  display1: { browser: 'chromium', current_index: 0,
    urls: [{ label: 'Setup', url: 'http://localhost:3000' }] },
  display2: { current_source: '', sources: [] },
  ndi: { access_manager_ip: '', access_manager_port: 80, groups: [] },
  companion: { server_ip: '', server_port: 16622 },
  network: { hostname: 'signaeos', native_vlan: '', vlans: [], wifi_ssid: '', wifi_password: '' },
  ssh: { authorized_keys: '' }
};

// ── Config ────────────────────────────────────────────────────────────────────
function readConfig() {
  try { return Object.assign({}, DEFAULT_CONFIG, JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'))); }
  catch { return Object.assign({}, DEFAULT_CONFIG); }
}
function writeConfig(cfg) {
  fs.mkdirSync(path.dirname(CONFIG_FILE), { recursive: true });
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2));
}

// ── Socket ────────────────────────────────────────────────────────────────────
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

// ── NDI Access Manager proxy ───────────────────────────────────────────────────
function amRequest(cfg, method, apiPath, body) {
  return new Promise(resolve => {
    if (!cfg.ndi?.access_manager_ip) return resolve({ error: 'no access manager configured' });
    const opts = {
      hostname: cfg.ndi.access_manager_ip,
      port: cfg.ndi.access_manager_port || 80,
      path: apiPath,
      method,
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' }
    };
    const req = http.request(opts, res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => { try { resolve(JSON.parse(data)); } catch { resolve({ raw: data }); } });
    });
    req.on('error', e => resolve({ error: e.message }));
    req.setTimeout(5000, () => { req.destroy(); resolve({ error: 'timeout' }); });
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

// ── Apply config side-effects ─────────────────────────────────────────────────
async function applyConfig(cfg) {
  writeConfig(cfg);

  // Hostname
  try { fs.writeFileSync('/etc/hostname', cfg.network.hostname + '\n');
        execSync(`hostname '${cfg.network.hostname}'`); } catch {}

  // SSH keys
  if (cfg.ssh?.authorized_keys) {
    try {
      fs.mkdirSync('/root/.ssh', { recursive: true });
      fs.writeFileSync('/root/.ssh/authorized_keys', cfg.ssh.authorized_keys);
      fs.chmodSync('/root/.ssh', 0o700);
      fs.chmodSync('/root/.ssh/authorized_keys', 0o600);
    } catch {}
  }

  // WiFi
  if (cfg.network?.wifi_ssid && cfg.network?.wifi_password &&
      !cfg.network.wifi_password.includes('•')) {
    exec(`nmcli device wifi connect '${cfg.network.wifi_ssid}' password '${cfg.network.wifi_password}'`,
      err => err && console.warn('WiFi:', err.message));
  }

  // Companion Satellite
  if (cfg.companion?.server_ip) {
    fs.mkdirSync('/data/signaeos', { recursive: true });
    fs.writeFileSync('/data/signaeos/satellite.json',
      JSON.stringify({ remoteIp: cfg.companion.server_ip, remotePort: cfg.companion.server_port || 16622 }, null, 2));
    exec('systemctl restart companion-satellite', () => {});
  }

  // Reload displays
  await d1({ cmd: 'reload' }).catch(() => {});
}

// ── Express ───────────────────────────────────────────────────────────────────
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
    await applyConfig(Object.assign({}, existing, incoming));
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});

// ── Display 1 — Web ───────────────────────────────────────────────────────────
app.get ('/api/display/1/status',         async (req, res) => res.json(await d1({ cmd: 'status' })));
app.post('/api/display/1/switch/:index',  async (req, res) => {
  const idx = parseInt(req.params.index, 10);
  const r = await d1({ cmd: 'switch', index: idx });
  if (r.ok) { const cfg = readConfig(); cfg.display1.current_index = idx; writeConfig(cfg); }
  res.json(r);
});
app.post('/api/display/1/next',   async (req, res) => res.json(await d1({ cmd: 'next' })));
app.post('/api/display/1/prev',   async (req, res) => res.json(await d1({ cmd: 'prev' })));
app.post('/api/display/1/reload', async (req, res) => res.json(await d1({ cmd: 'reload' })));

// ── Display 2 — NDI ───────────────────────────────────────────────────────────
app.get ('/api/display/2/status',          async (req, res) => res.json(await d2({ cmd: 'status' })));
app.post('/api/display/2/source/:name',    async (req, res) => {
  const name = decodeURIComponent(req.params.name);
  const r = await d2({ cmd: 'source', source: name });
  if (r.ok) { const cfg = readConfig(); cfg.display2.current_source = name; writeConfig(cfg); }
  res.json(r);
});
app.post('/api/display/2/next',     async (req, res) => res.json(await d2({ cmd: 'next' })));
app.post('/api/display/2/prev',     async (req, res) => res.json(await d2({ cmd: 'prev' })));
app.post('/api/display/2/discover', async (req, res) => res.json(await d2({ cmd: 'discover' })));

// ── NDI Access Manager ────────────────────────────────────────────────────────
app.get('/api/ndi/am/sources',   async (req, res) => res.json(await amRequest(readConfig(), 'GET', '/v1/sources')));
app.get('/api/ndi/am/groups',    async (req, res) => res.json(await amRequest(readConfig(), 'GET', '/v1/groups')));
app.get('/api/ndi/am/receivers', async (req, res) => res.json(await amRequest(readConfig(), 'GET', '/v1/receivers')));

app.post('/api/ndi/am/register', async (req, res) => {
  const cfg = readConfig();
  const ip = execSync('hostname -I 2>/dev/null || echo ""').toString().trim().split(' ')[0];
  const body = { name: cfg.display_name || 'SignageOS', ip, groups: cfg.ndi?.groups || [] };
  res.json(await amRequest(cfg, 'POST', '/v1/receivers', body));
});

app.put('/api/ndi/am/sources/:id', async (req, res) => {
  res.json(await amRequest(readConfig(), 'PUT', `/v1/sources/${req.params.id}`, req.body));
});

app.put('/api/ndi/am/groups/:id', async (req, res) => {
  res.json(await amRequest(readConfig(), 'PUT', `/v1/groups/${req.params.id}`, req.body));
});

// ── Network / VLAN ────────────────────────────────────────────────────────────
app.get('/api/network/interfaces', (req, res) => {
  exec('ip -j addr', (err, stdout) => {
    if (err) return res.json({ ok: false, error: err.message });
    try { res.json({ ok: true, interfaces: JSON.parse(stdout) }); }
    catch { res.json({ ok: false, error: 'parse error' }); }
  });
});

app.get('/api/network/wifi/scan', (req, res) => {
  exec('nmcli -t -f SSID,SIGNAL,SECURITY device wifi list --rescan yes', (err, stdout) => {
    if (err) return res.json({ ok: false, networks: [] });
    const networks = stdout.split('\n').filter(Boolean)
      .map(l => { const p = l.split(':'); return { ssid: p[0], signal: parseInt(p[1]||'0',10), security: p[2]||'' }; })
      .filter(n => n.ssid).sort((a,b) => b.signal - a.signal);
    res.json({ ok: true, networks });
  });
});

// Apply VLAN config — creates/updates NM connections
app.post('/api/network/vlans', async (req, res) => {
  const cfg = readConfig();
  cfg.network.vlans = req.body.vlans || [];
  cfg.network.native_vlan = req.body.native_vlan || '';
  writeConfig(cfg);

  // Apply via nmcli — find primary ethernet interface
  exec("ip -o link show | awk -F': ' '$2 ~ /^eth|^en/ {print $2; exit}'", (err, iface) => {
    iface = (iface || 'eth0').trim();
    const cmds = (cfg.network.vlans || []).map(v => {
      const vif = `${iface}.${v.id}`;
      const ipArg = v.ip ? `ipv4.method manual ipv4.addresses '${v.ip}'` : 'ipv4.method auto';
      const gwArg = v.gateway ? `ipv4.gateway '${v.gateway}'` : '';
      return `nmcli con delete '${vif}' 2>/dev/null; nmcli con add type vlan con-name '${vif}' dev '${iface}' id ${v.id} ${ipArg} ${gwArg} ipv6.method ignore && nmcli con up '${vif}'`;
    });
    if (cmds.length === 0) return res.json({ ok: true });
    exec(cmds.join(' && '), err2 => {
      if (err2) { console.warn('VLAN apply:', err2.message); return res.json({ ok: false, error: err2.message }); }
      res.json({ ok: true });
    });
  });
});

// ── System ────────────────────────────────────────────────────────────────────
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

app.post('/api/reboot',         (req, res) => { res.json({ ok: true }); setTimeout(() => exec('systemctl reboot'), 500); });
app.post('/api/update/check',   (req, res) => exec('signaeos-update check',  (e,o) => res.json({ ok: !e, output: o })));
app.post('/api/update/apply',   (req, res) => exec('signaeos-update apply',  (e,o) => res.json({ ok: !e, output: o })));

app.get('/api/status', async (req, res) => {
  const [s1, s2] = await Promise.all([
    d1({ cmd: 'status' }).catch(() => ({ ok: false })),
    d2({ cmd: 'status' }).catch(() => ({ ok: false }))
  ]);
  res.json({ ok: true, display1: s1, display2: s2 });
});

app.listen(PORT, '0.0.0.0', () => console.log(`SignageOS WebUI :${PORT}`));
