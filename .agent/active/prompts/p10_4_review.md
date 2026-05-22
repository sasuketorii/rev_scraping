# Review P10.4 vps.md + Xvfb VNC

You are the Codex reviewer for RevHarness Lane A P10.4. Verify the slice.

## Files in scope
- `docs/deploy/vps.md` (NEW; 8 sections)
- `dist/systemd/system/rev-stealth-xvfb-vnc.service` (NEW)
- `dist/systemd/install.sh` (UPDATED; adds `--with-vnc-fallback`)
- `dist/systemd/uninstall.sh` (UPDATED; cleans the optional unit)

## Pre-confirmed gates (coder side, already PASS)
- `cargo check --workspace` (no Rust touched; expected no-op)
- `cargo test --workspace --no-fail-fast` >= 619 maintained (no Rust touched)
- `bash -n dist/systemd/install.sh` PASS
- `bash -n dist/systemd/uninstall.sh` PASS
- `bash -n dist/systemd/setup-credentials.sh` PASS (untouched)
- SPDX-License-Identifier headers present in all new/updated files

## Verify
1. `docs/deploy/vps.md` covers all 8 sections:
   prereq / install / verify / auth-export / troubleshooting /
   recommended-host / security / uninstall.
2. `rev-stealth-xvfb-vnc.service` binds localhost only
   (`x11vnc ... -localhost`) and has no public exposure.
3. `install.sh --with-vnc-fallback` is opt-in:
   - default invocation must NOT link the VNC unit.
   - even when linked, the unit is NOT auto-enabled (no
     `systemctl enable --now rev-stealth-xvfb-vnc`).
4. Auth-export pattern uses local-login + `scp` of the `.enc` blob; the
   runbook explicitly forbids remote interactive login.
5. Troubleshooting table includes: "no $DISPLAY", "chromium missing",
   "gluetun stuck", "leak detected".
6. Hardening parity: VNC unit mirrors mcp.service hardening
   (NoNewPrivileges, ProtectSystem=strict, etc.).
7. No raw secrets / tokens / cookies in any new file.

## Output
Return one of:
- `verdict: LGTM` (with a 1-line justification)
- `verdict: BLOCK: <concrete reason and file:line>`
