# Review P10.1 systemd templates

files: dist/systemd/{system,user,tmpfiles.d,sysusers.d}/*, install.sh, uninstall.sh, README.md (10 total)

gates PASS (on darwin host):
- systemd-analyze: skipped (binary absent on darwin; documented in completion report)
- bash -n dist/systemd/install.sh: OK
- bash -n dist/systemd/uninstall.sh: OK
- cargo check --workspace: clean (no rust impact)
- scripts/check_baseline_diff.sh: OK (dist/ outside baseline)
- SPDX-License-Identifier present in install.sh, uninstall.sh, README.md

verify:
1. ExecStart on every .service uses an absolute path AND a ${REV_STEALTH_BIN:-...} fallback (via /bin/sh -c 'exec ...').
2. Restart=on-failure and RestartSec=5s on all 5 .service units (the .timer has neither).
3. PrivateTmp=yes, ProtectSystem=strict, NoNewPrivileges=yes on all 5 .service units.
4. tmpfiles.d/rev-stealth.conf: /var/log/rev-stealth = 0750, /var/lib/rev-stealth = 0700 (both owned by rev-stealth:rev-stealth).
5. sysusers.d/rev-stealth.conf: creates rev-stealth system user (type u, /usr/sbin/nologin) and matching group; not root.
6. install.sh: idempotent (uses `ln -sfn`, `systemctl ... || true`, `install -d`); re-running is safe. uninstall.sh: removes /etc symlinks, disables units, supports --purge for state dirs.
7. LoadCredentialEncrypted appears only as placeholder comments (P10.2 will wire), no raw secrets.
8. system mcp/doctor add hardening: ProtectKernelTunables=yes, ProtectKernelModules=yes, ProtectControlGroups=yes, RestrictSUIDSGID=yes, LockPersonality=yes.

scope guard: only dist/systemd/ touched; vendor/, _refs/, src/, crates/ untouched.

return: verdict: LGTM or BLOCK: <reason>
