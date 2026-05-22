#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# dist/systemd/uninstall.sh
# Full removal counterpart to install.sh.
# Stops + disables units, then removes the /etc symlinks. Does NOT delete
# /var/lib/rev-stealth or /var/log/rev-stealth (operator data); pass
# --purge to wipe those as well.
#
# Usage:
#   sudo ./uninstall.sh
#   sudo ./uninstall.sh --purge   # also rm -rf state + logs

set -euo pipefail

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "uninstall.sh: must be run as root (try: sudo $0)" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "uninstall.sh: systemctl not found" >&2
  exit 1
fi

echo "[1/4] Stopping + disabling units"
# Stop templated vpn instances best-effort.
for u in $(systemctl list-units --no-legend 'rev-stealth-vpn@*.service' 2>/dev/null | awk '{print $1}'); do
  systemctl disable --now "$u" || true
done
for unit in rev-stealth-doctor.timer rev-stealth-doctor.service \
            rev-stealth-mcp.service rev-stealth-xvfb-vnc.service; do
  systemctl disable --now "$unit" || true
done

echo "[2/4] Removing /etc/systemd/system symlinks"
for unit in rev-stealth-mcp.service rev-stealth-vpn@.service \
            rev-stealth-doctor.service rev-stealth-doctor.timer \
            rev-stealth-xvfb-vnc.service; do
  rm -f "/etc/systemd/system/$unit"
done

echo "[3/4] Removing sysusers.d / tmpfiles.d entries"
rm -f /etc/sysusers.d/rev-stealth.conf
rm -f /etc/tmpfiles.d/rev-stealth.conf

echo "[4/4] Reloading systemd"
systemctl daemon-reload

if [ "$PURGE" -eq 1 ]; then
  echo "--purge: removing /var/lib/rev-stealth and /var/log/rev-stealth"
  rm -rf /var/lib/rev-stealth /var/log/rev-stealth
  # Leave user/group in place; deluser is distro-specific and recoverable.
fi

echo "OK: uninstall complete"
