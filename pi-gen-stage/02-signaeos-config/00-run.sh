#!/bin/bash -e
# stage 02 — post-user-creation config
# Pi-gen has created FIRST_USER_NAME by this point

on_chroot << EOF

# ── Sudoers ───────────────────────────────────────────────────────────────────
# FIRST_USER_NAME is set in the pi-gen config (signaeos)
echo '${FIRST_USER_NAME} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/010_signaeos-nopasswd
chmod 440 /etc/sudoers.d/010_signaeos-nopasswd
echo "Added ${FIRST_USER_NAME} to sudoers."

# ── Verify services are enabled ───────────────────────────────────────────────
for svc in signaeos-webui signaeos-display1 signaeos-display2 \
           companion-satellite weston NetworkManager avahi-daemon ssh; do
    systemctl enable \$svc 2>/dev/null && echo "Enabled: \$svc" || echo "Warning: could not enable \$svc"
done
systemctl enable signaeos-update.timer 2>/dev/null || true

# ── Verify web UI files exist ─────────────────────────────────────────────────
if [ ! -f /usr/share/signaeos/webui/server.js ]; then
    echo "ERROR: Web UI server.js not found!"
    exit 1
fi
if [ ! -d /usr/share/signaeos/webui/node_modules ]; then
    echo "node_modules missing — installing now..."
    cd /usr/share/signaeos/webui && npm install --production --no-audit --no-fund
fi

# ── Verify binaries exist ─────────────────────────────────────────────────────
for bin in signaeos-display1 signaeos-display2 signaeos-ctl; do
    if [ ! -f /usr/bin/\$bin ]; then
        echo "ERROR: /usr/bin/\$bin not found!"
        exit 1
    fi
    chmod +x /usr/bin/\$bin
done

# ── SSH config ────────────────────────────────────────────────────────────────
# Allow password auth for initial setup, key-only enforced via web UI later
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

echo "Stage 02 complete."
EOF
