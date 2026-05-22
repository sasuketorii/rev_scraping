# Review P10.1 systemd templates — round 2 (fix applied)

Round 1 BLOCK was: rev-stealth-doctor.service ExecStart missed `exec`.

Fix (single line, dist/systemd/system/rev-stealth-doctor.service):
  before: ExecStart=/bin/sh -c '"${REV_STEALTH_BIN:-/usr/local/bin/stealth-cli}" doctor --vps --format json >> /var/log/rev-stealth/doctor.jsonl'
  after:  ExecStart=/bin/sh -c 'exec "${REV_STEALTH_BIN:-/usr/local/bin/stealth-cli}" doctor --vps --format json >> /var/log/rev-stealth/doctor.jsonl'

All other content unchanged from round 1.

Re-verify only:
1. All 5 .service ExecStart= lines use /bin/sh -c 'exec "${REV_STEALTH_BIN:-<abs>}" ...'.
2. Restart=on-failure + RestartSec=5s still present on the 5 services.
3. PrivateTmp/ProtectSystem=strict/NoNewPrivileges=yes still present on the 5 services.
4. Doctor file otherwise unchanged (hardening directives intact).

Gates re-checked locally:
- bash -n install.sh / uninstall.sh: OK
- cargo check --workspace: clean
- check_baseline_diff.sh: OK
- systemd-analyze: skipped (darwin)
- SPDX: install.sh / uninstall.sh / README.md all present

return: verdict: LGTM or BLOCK: <reason>
