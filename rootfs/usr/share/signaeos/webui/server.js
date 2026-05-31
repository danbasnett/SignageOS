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

// ── NDI direct device query via TCP port 5960 ─────────────────────────────
// NDI devices respond with XML listing their streams.
// BirdDog format: <ndi><services><service name="X" port="N">...
function queryNdiDevice(ip) {
  return new Promise(resolve => {
    const sock = new net.Socket();
    let buf = '';
    let timer;

    const done = () => {
      clearTimeout(timer);
      sock.destroy();

      // Parse XML response
      const sources = [];
      // Match all service name attributes
      const re = /<service\s+name="([^"]+)"/g;
      let m;
      while ((m = re.exec(buf)) !== null) {
        const name = m[1].trim();
        if (name) sources.push({ label: name, name, ip, source: 'device' });
      }
      resolve(sources);
    };

    timer = setTimeout(done, 4000);

    sock.connect(5960, ip, () => {
      // Send NDI discovery request
      sock.write('<ndi_discovery_request />\n');
    });

    sock.on('data', chunk => {
      buf += chunk.toString();
      // Response ends with </ndi> — parse as soon as we have it
      if (buf.includes('</ndi>')) done();
    });

    sock.on('error', () => resolve([]));
    sock.on('close', () => done());
  });
}

// ── NDI multicast discovery via ndi-find tool (SDK, if installed) ──────────
function discoverNdiLocal() {
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
            .map(name => ({ label: name, name, source: 'local' }));
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

  // Query all configured device IPs directly via TCP 5960
  const deviceIps = (ndi.devices || []).map(d => d.ip).filter(Boolean);
  const deviceResults = await Promise.all(deviceIps.map(ip => queryNdiDevice(ip)));
  const fromDevices = deviceResults.flat();

  // Try local multicast discovery too (works if NDI SDK is installed)
  const fromLocal = await discoverNdiLocal();

  // Manual sources always included
  const manual = (ndi.manual_sources || []).map(s => ({
    label: s.label || s.name,
    name:  s.name,
    ip:    s.ip || '',
    source: 'manual'
  }));

  // Merge and deduplicate by name
  const seen = new Set();
  return [...fromDevices, ...fromLocal, ...manual].filter(s => {
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

  // Companion Satellite — call the real Satellite API
  if (cfg.companion?.server_ip) {
    const host = cfg.companion.server_ip;
    const port = cfg.companion.server_port || 16622;
    // Write legacy config file as fallback
    fs.mkdirSync('/data/signaeos', { recursive: true });
    fs.writeFileSync('/data/signaeos/satellite.json',
      JSON.stringify({ remoteIp: host, remotePort: port }, null, 2));
    // Call the Satellite REST API to update the host live
    const satHost = new Promise(resolve => {
      const body = JSON.stringify({ host });
      const opts = { hostname: '127.0.0.1', port: 9999, path: '/api/host',
        method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } };
      const req = http.request(opts, res => { res.resume(); resolve(res.statusCode); });
      req.on('error', () => resolve(null));
      req.setTimeout(3000, () => { req.destroy(); resolve(null); });
      req.write(body); req.end();
    });
    await satHost;
    // Also write to /boot/satellite-config which the Satellite service reads on restart
    try {
      fs.writeFileSync('/boot/satellite-config', `COMPANION_HOST=${host}\nCOMPANION_PORT=${port}\n`);
    } catch {}
  }

  await d1({ cmd: 'reload' }).catch(() => {});
}

// ── Express ────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ── Kiosk controller page ────────────────────────────────────────────────────
// Loaded once by Chromium. Uses window.location.replace to navigate.
// After navigating away, Chromium's back/forward is locked in kiosk mode
// so we use CDP (remote debugging) to navigate back when URL changes.
app.get('/kiosk/display1', (req, res) => {
  const cfg = readConfig();
  const idx = cfg.display1?.current_index || 0;
  const url = cfg.display1?.urls?.[idx]?.url || 'http://localhost:3000';
  res.setHeader('Content-Type', 'text/html');
  res.send(`<!DOCTYPE html><html><head><meta charset="UTF-8">
<style>*{margin:0;padding:0}body{background:#000}</style></head>
<body><script>window.location.replace(${JSON.stringify(url)});</script></body></html>`);
});

// ── CDP navigation helper ─────────────────────────────────────────────────
function cdpNavigate(url) {
  return new Promise(resolve => {
    const req = http.get('http://127.0.0.1:9222/json', res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        try {
          const targets = JSON.parse(data);
          const page = targets.find(t => t.type === 'page');
          if (!page) return resolve(false);
          const wsUrl = page.webSocketDebuggerUrl;
          const urlObj = new URL(wsUrl);
          const sock = net.createConnection(parseInt(urlObj.port) || 9222, '127.0.0.1', () => {
            const key = Buffer.from(`${Math.random()}`).toString('base64');
            sock.write(
              `GET ${urlObj.pathname}${urlObj.search} HTTP/1.1\r\n` +
              `Host: 127.0.0.1:${urlObj.port}\r\n` +
              `Upgrade: websocket\r\nConnection: Upgrade\r\n` +
              `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`
            );
          });
          let done = false;
          sock.on('data', chunk => {
            if (done) return;
            // After HTTP upgrade response, send CDP command
            if (chunk.toString().includes('101')) {
              done = true;
              const msg = JSON.stringify({ id: 1, method: 'Page.navigate', params: { url } });
              const buf = Buffer.from(msg);
              const frame = Buffer.alloc(2 + buf.length);
              frame[0] = 0x81; frame[1] = buf.length;
              buf.copy(frame, 2);
              sock.write(frame);
              setTimeout(() => { sock.destroy(); resolve(true); }, 300);
            }
          });
          sock.on('error', () => resolve(false));
          setTimeout(() => { sock.destroy(); resolve(false); }, 3000);
        } catch { resolve(false); }
      });
    });
    req.on('error', () => resolve(false));
    req.setTimeout(2000, () => { req.destroy(); resolve(false); });
  });
}

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
app.get ('/api/display/1/status', async (req, res) => {
  const cfg = readConfig();
  const idx = cfg.display1?.current_index || 0;
  const url = cfg.display1?.urls?.[idx]?.url || '';
  const label = cfg.display1?.urls?.[idx]?.label || '';
  const total = (cfg.display1?.urls || []).length;
  res.json({ ok: true, display: 1, index: idx, url, label, total });
});

app.post('/api/display/1/switch/:index', async (req, res) => {
  const idx = parseInt(req.params.index, 10);
  const cfg = readConfig();
  const total = (cfg.display1?.urls || []).length;
  if (idx < 0 || idx >= total) return res.json({ ok: false, error: 'index out of range' });
  cfg.display1.current_index = idx;
  writeConfig(cfg);
  const url = cfg.display1.urls[idx]?.url || '';
  // Navigate via CDP (no Chromium restart)
  const navigated = url ? await cdpNavigate(url) : false;
  // Fallback: tell display1 daemon to switch (will restart browser if CDP failed)
  if (!navigated && url) await d1({ cmd: 'switch', index: idx }).catch(() => {});
  res.json({ ok: true, url, navigated });
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

// ── Test card ──────────────────────────────────────────────────────────────
app.post('/api/test/:display', (req, res) => {
  const display  = req.params.display;
  const socket   = 'wayland-1'; // sway socket
  const workspace = display === '2' ? '2' : '1';
  const colors   = ['red','orange','yellow','lime','cyan','blue','violet','white'];
  const htmlPath = `/tmp/signaeos-test-d${display}.html`;

  const html = `<!DOCTYPE html><html><body style="margin:0;overflow:hidden;background:#000;font-family:sans-serif">
<div style="display:grid;grid-template-columns:repeat(8,1fr);width:100vw;height:55vh">
${colors.map(c => `<div style="background:${c}"></div>`).join('')}
</div>
<div style="text-align:center;color:white;padding:40px;text-shadow:2px 2px 6px #000">
  <h1 style="font-size:5vw;margin:0 0 16px">SignageOS</h1>
  <h2 style="font-size:3vw;margin:0 0 12px;color:#aef">Display ${display} — ${display === '1' ? 'HDMI-A-1' : 'HDMI-A-2'}</h2>
  <p style="font-size:2vw;margin:0;color:#8f8">Weston + Wayland OK</p>
  <p style="font-size:1.5vw;margin:8px 0 0;color:#888">${new Date().toLocaleTimeString()}</p>
</div></body></html>`;

  fs.writeFileSync(htmlPath, html);

  exec(`pkill -f "chromium-test-d${display}" 2>/dev/null; true`, () => {
    // Find sway socket dynamically and switch workspace
    exec('ls /run/user/1000/sway-ipc.*.sock 2>/dev/null | head -1', (e, sock) => {
      sock = (sock || '').trim();
      const switchCmd = sock
        ? `SWAYSOCK=${sock} WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 swaymsg workspace ${workspace} 2>/dev/null || true`
        : 'true';
      exec(switchCmd, () => {
        setTimeout(() => {
          // Must run as admin since wayland socket is in admin's session
          const cmd = [
            'sudo -u admin',
            `WAYLAND_DISPLAY=wayland-1`,
            `XDG_RUNTIME_DIR=/run/user/1000`,
            'chromium',
            '--kiosk',
            '--start-fullscreen',
            '--no-sandbox',
            '--ozone-platform=wayland',
            `--user-data-dir=/data/chromium-test-d${display}`,
            '--disable-infobars',
            '--noerrdialogs',
            '--disable-session-crashed-bubble',
            `--app=file://${htmlPath}`
          ].join(' ');
          exec(cmd + ' &', err => {
            if (err) return res.json({ ok: false, error: err.message });
            // Force fullscreen after launch
            setTimeout(() => {
              exec('ls /run/user/1000/sway-ipc.*.sock 2>/dev/null | head -1', (e, sock) => {
                sock = (sock || '').trim();
                if (sock) exec(`SWAYSOCK=${sock} WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 swaymsg '[app_id="chromium"] fullscreen enable' 2>/dev/null`);
              });
            }, 3000);
            res.json({ ok: true });
          });
        }, 500);
      });
    });
  });
});

app.post('/api/test/stop', (req, res) => {
  exec('pkill -9 -f "user-data-dir=/data/chromium-test" 2>/dev/null; true', () => {
    exec('systemctl restart signaeos-display1 && sleep 10 && systemctl restart signaeos-display2', () => {
      res.json({ ok: true });
    });
  });
});

// ── Monitor configuration ──────────────────────────────────────────────────
app.get('/api/monitors', (req, res) => {
  const cfg = readConfig();
  res.json({ ok: true, monitors: cfg.monitors || {
    display1: { output: 'HDMI-A-1', resolution: '1920x1080@60', rotation: 'normal' },
    display2: { output: 'HDMI-A-2', resolution: '1920x1080@60', rotation: 'normal' }
  }});
});

app.post('/api/monitors', (req, res) => {
  const { display1, display2, swap } = req.body;
  const cfg = readConfig();
  const saved = cfg.monitors || {};

  // For swap, flip the saved output assignments
  let d1out, d2out, d1res, d2res, d1rot, d2rot;
  if (swap) {
    d1out = saved.display2?.output    || 'HDMI-A-2';
    d2out = saved.display1?.output    || 'HDMI-A-1';
    d1res = saved.display1?.resolution || '1920x1080@60';
    d2res = saved.display2?.resolution || '1920x1080@60';
    d1rot = saved.display1?.rotation   || 'normal';
    d2rot = saved.display2?.rotation   || 'normal';
  } else {
    d1out = display1?.output     || saved.display1?.output    || 'HDMI-A-1';
    d2out = display2?.output     || saved.display2?.output    || 'HDMI-A-2';
    d1res = display1?.resolution || saved.display1?.resolution || '1920x1080@60';
    d2res = display2?.resolution || saved.display2?.resolution || '1920x1080@60';
    d1rot = display1?.rotation   || saved.display1?.rotation   || 'normal';
    d2rot = display2?.rotation   || saved.display2?.rotation   || 'normal';
  }

  cfg.monitors = { display1: { output: d1out, resolution: d1res, rotation: d1rot },
                   display2: { output: d2out, resolution: d2res, rotation: d2rot } };
  writeConfig(cfg);

  // Convert resolution to sway mode format: 1920x1080@60 → 1920x1080@60Hz
  const toMode = r => r.includes('Hz') ? r : r.replace(/@(\d+(\.\d+)?)$/, '@$1Hz');
  const d1mode = toMode(d1res);
  const d2mode = toMode(d2res);

  const swayConf = `# SignageOS Sway config — auto-generated
# Note: no explicit modes — let sway negotiate with the monitors
output ${d1out} enable position 0 0 transform ${d1rot}
output ${d2out} enable position 1920 0 transform ${d2rot}

workspace 1 output ${d1out}
workspace 2 output ${d2out}

for_window [app_id="chromium"] fullscreen enable
for_window [app_id="vlc"]      fullscreen enable

assign [app_id="signaeos-test-d1"] workspace 1
assign [app_id="signaeos-test-d2"] workspace 2
for_window [app_id="signaeos-test-d1"] fullscreen enable
for_window [app_id="signaeos-test-d2"] fullscreen enable

default_border none
default_floating_border none
hide_edge_borders --i3 both
gaps inner 0
gaps outer 0
seat * hide_cursor 3000
focus_follows_mouse no
`;

  try {
    fs.mkdirSync('/etc/sway', { recursive: true });
    fs.writeFileSync('/etc/sway/config', swayConf);
    // Use swaymsg reload — reconfigures outputs without restarting sway
    const sock = execSync('ls /run/user/1000/sway-ipc.*.sock 2>/dev/null | head -1', { encoding: 'utf8' }).trim();
    if (sock) {
      exec(`SWAYSOCK=${sock} WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 swaymsg reload`, () => {
        exec('systemctl restart signaeos-display1 && sleep 10 && systemctl restart signaeos-display2', () => {
          res.json({ ok: true, monitors: cfg.monitors });
        });
      });
    } else {
      exec('systemctl restart sway && sleep 5 && systemctl restart signaeos-display1 signaeos-display2', err => {
        res.json({ ok: !err, monitors: cfg.monitors });
      });
    }
  } catch (e) {
    res.json({ ok: false, error: e.message });
  }
});
// Proxy to local Satellite API to avoid CORS issues from the browser
function satelliteRequest(path) {
  return new Promise(resolve => {
    const opts = { hostname: '127.0.0.1', port: 9999, path, method: 'GET',
      headers: { Accept: 'application/json' } };
    const req = http.request(opts, res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => { try { resolve({ ok: true, data: JSON.parse(data), status: res.statusCode }); }
                            catch { resolve({ ok: true, data: { raw: data }, status: res.statusCode }); } });
    });
    req.on('error', e => resolve({ ok: false, error: e.message }));
    req.setTimeout(3000, () => { req.destroy(); resolve({ ok: false, error: 'timeout' }); });
    req.end();
  });
}

app.get('/api/satellite/status',   async (req, res) => res.json(await satelliteRequest('/api/status')));
app.get('/api/satellite/surfaces', async (req, res) => res.json(await satelliteRequest('/api/surfaces')));

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
