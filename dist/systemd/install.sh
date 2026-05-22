#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# dist/systemd/install.sh
# Idempotent installer for REV Stealth systemd unit templates.
# Re-running this script is safe: it uses `ln -sfn` and `systemctl ... || true`
# guards so existing symlinks/users are not duplicated.
#
# Usage:
#   sudo ./install.sh                       # link everything, reload daemon
#   sudo ./install.sh --no-enable           # link only, do not enable/start units
#   sudo ./install.sh --with-vnc-fallback   # also link the optional Xvfb+VNC
#                                           # emergency unit (NOT enabled by
#                                           # default; localhost-bound only).
#                                           # See docs/deploy/vps.md sec 4 + 7.
#
# Layout produced:
#   /etc/systemd/system/rev-stealth-*.service        (symlinks to this repo)
#   /etc/systemd/system/rev-stealth-*.timer
#   /etc/tmpfiles.d/rev-stealth.conf                 (symlink)
#   /etc/sysusers.d/rev-stealth.conf                 (symlink)
# User-scope units are NOT linked system-wide; copy them with
# `systemctl --user link` from each operator account that needs them.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENABLE=1
WITH_VNC_FALLBACK=0
for arg in "$@"; do
  case "$arg" in
    --no-enable) ENABLE=0 ;;
    --with-vnc-fallback) WITH_VNC_FALLBACK=1 ;;
    -h|--help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "install.sh: must be run as root (try: sudo $0)" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "install.sh: systemctl not found - this host does not appear to use systemd" >&2
  exit 1
fi

link_unit() {
  local src="$1" dst="$2"
  if [ ! -e "$src" ]; then
    echo "missing source: $src" >&2
    return 1
  fi
  ln -sfn "$src" "$dst"
  echo "  linked $dst -> $src"
}

echo "[1/5] Linking system units"
install -d -m 0755 /etc/systemd/system
for unit in rev-stealth-mcp.service rev-stealth-vpn@.service \
            rev-stealth-doctor.service rev-stealth-doctor.timer; do
  link_unit "$HERE/system/$unit" "/etc/systemd/system/$unit"
done

if [ "$WITH_VNC_FALLBACK" -eq 1 ]; then
  echo "  [opt] linking rev-stealth-xvfb-vnc.service (DISABLED by default, localhost-only)"
  link_unit "$HERE/system/rev-stealth-xvfb-vnc.service" \
            "/etc/systemd/system/rev-stealth-xvfb-vnc.service"
fi

echo "[2/5] Linking sysusers.d"
install -d -m 0755 /etc/sysusers.d
link_unit "$HERE/sysusers.d/rev-stealth.conf" "/etc/sysusers.d/rev-stealth.conf"

echo "[3/5] Linking tmpfiles.d"
install -d -m 0755 /etc/tmpfiles.d
link_unit "$HERE/tmpfiles.d/rev-stealth.conf" "/etc/tmpfiles.d/rev-stealth.conf"

echo "[4/5] Provisioning user/group + runtime dirs"
systemd-sysusers /etc/sysusers.d/rev-stealth.conf || true
systemd-tmpfiles --create /etc/tmpfiles.d/rev-stealth.conf || true

echo "[5/5] Reloading systemd"
systemctl daemon-reload

if [ "$ENABLE" -eq 1 ]; then
  echo "Enabling units (use --no-enable to skip)"
  systemctl enable --now rev-stealth-mcp.service     || true
  systemctl enable --now rev-stealth-doctor.timer    || true
  # VPN templated instances are opt-in: operator runs
  #   systemctl enable --now rev-stealth-vpn@1.service
  # Xvfb+VNC fallback is ALSO opt-in even when linked via --with-vnc-fallback;
  # it is intentionally NOT enabled here. Start it manually only when needed:
  #   systemctl start rev-stealth-xvfb-vnc.service
fi

echo "OK: install complete"
