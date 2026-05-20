#!/usr/bin/env python3
"""Quick launch command guard for `codex app-server`.

Usage:
  python codex-app-server-launch-guard.py 'codex app-server --listen stdio://'
"""
from __future__ import annotations
import argparse
import re
import sys


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('command', nargs='+', help='Launch command string or tokens')
    args = p.parse_args()
    cmd = ' '.join(args.command)
    findings: list[tuple[str, str]] = []

    if 'codex' not in cmd or 'app-server' not in cmd:
        findings.append(('HIGH', 'Command does not clearly start `codex app-server`.'))
    if re.search(r'--listen\s+ws://(0\.0\.0\.0|\[::\]|(?!127\.0\.0\.1|localhost)[^\s]+)', cmd):
        findings.append(('CRITICAL', 'Non-loopback WebSocket listener detected.'))
    if 'ws://' in cmd and '--ws-auth' not in cmd and not re.search(r'ws://(127\.0\.0\.1|localhost)', cmd):
        findings.append(('CRITICAL', 'Remote WebSocket appears to lack --ws-auth.'))
    if re.search(r'--ws-token(?:-file|-sha256)?\s+[^\s]+', cmd) and '--ws-token-file' not in cmd and '--ws-token-sha256' not in cmd:
        findings.append(('HIGH', 'Raw WebSocket token may be in argv/shell history. Prefer --ws-token-file.'))
    if '--yolo' in cmd or 'danger' in cmd:
        findings.append(('CRITICAL', 'Danger/yolo mode detected.'))
    if '--listen off' in cmd or '--listen=off' in cmd:
        findings.append(('INFO', 'Listen off detected. Verify intended control path.'))
    if '--listen stdio://' in cmd or 'app-server' in cmd and '--listen' not in cmd:
        findings.append(('INFO', 'stdio/default transport appears to be used. Still verify cwd/env/auth isolation.'))

    print('# Codex app-server launch guard')
    print()
    print(f'Command: `{cmd}`')
    print()
    for sev, msg in findings:
        print(f'- {sev}: {msg}')
    if any(sev == 'CRITICAL' for sev, _ in findings):
        return 2
    if any(sev == 'HIGH' for sev, _ in findings):
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
