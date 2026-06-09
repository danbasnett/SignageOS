#!/usr/bin/env bash
# Validate a SignageOS install on Raspberry Pi / Debian.
set -u

failures=0

ok() {
  printf 'OK   %s\n' "$*"
}

warn() {
  printf 'WARN %s\n' "$*"
}

fail() {
  printf 'FAIL %s\n' "$*"
  failures=$((failures + 1))
}

check_service() {
  local service="$1"
  if systemctl is-active --quiet "$service"; then
    ok "$service is active"
  else
    fail "$service is not active"
    systemctl --no-pager --lines=5 status "$service" 2>/dev/null || true
  fi
}

check_socket() {
  local path="$1"
  if [[ -S "$path" ]]; then
    ok "$path exists"
  else
    fail "$path is missing"
  fi
}

check_http() {
  local path="$1"
  if curl -fsS "http://127.0.0.1:3000${path}" >/tmp/signaeos-validate-http.json 2>/dev/null; then
    ok "GET ${path}"
  else
    fail "GET ${path} failed"
  fi
}

echo "SignageOS validation"
echo "===================="

check_service seatd.service
check_service sway.service
check_service signaeos-webui.service
check_service signaeos-display1.service
check_service signaeos-display2.service

check_socket /run/signaeos/display1.sock
check_socket /run/signaeos/display2.sock

check_http /api/config
check_http /api/monitors
check_http /api/status

if [[ -x /usr/bin/signaeos-ndi-player ]]; then
  ok "native NDI player installed"
else
  warn "native NDI player not installed; Display 2 will need VLC/ndiplay fallback"
fi

if command -v signaeos-ctl >/dev/null 2>&1; then
  echo
  echo "Display control status"
  signaeos-ctl d1 status || fail "signaeos-ctl d1 status failed"
  signaeos-ctl d2 status || fail "signaeos-ctl d2 status failed"
else
  fail "signaeos-ctl not found"
fi

if command -v swaymsg >/dev/null 2>&1; then
  runtime_dir="${XDG_RUNTIME_DIR:-/run/signaeos-runtime}"
  sway_sock="$(find "$runtime_dir" -maxdepth 1 -type s -name 'sway-ipc.*.sock' 2>/dev/null | sort | head -1 || true)"
  if [[ -n "$sway_sock" ]]; then
    echo
    echo "Sway outputs"
    SWAYSOCK="$sway_sock" XDG_RUNTIME_DIR="$runtime_dir" swaymsg -t get_outputs || warn "could not read Sway outputs"
  else
    fail "Sway IPC socket not found in $runtime_dir"
  fi
fi

echo
if (( failures == 0 )); then
  ok "validation completed without failures"
else
  fail "$failures validation check(s) failed"
fi

exit "$failures"
