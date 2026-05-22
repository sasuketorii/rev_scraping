<!-- SPDX-License-Identifier: MIT -->
# REV Stealth VPS Deploy Runbook

Operator-facing runbook for installing REV Stealth on a Linux VPS. Targets
Ubuntu 22.04+ / Debian 12+ on systemd 252+. macOS / WSL are dev-only.

This file is the canonical install path for production VPS rollouts. It pairs
with `dist/systemd/install.sh` (P10.1), `dist/systemd/setup-credentials.sh`
(P10.2), and `rev-stealth doctor --vps` (P10.3).

## 1. Prerequisites

| Component | Minimum | Notes |
|-----------|---------|-------|
| OS | Ubuntu 22.04 LTS / Debian 12 | systemd 252+ required for `LoadCredentialEncrypted=` |
| Kernel | 5.15+ | for nftables, eBPF features used by gluetun |
| Docker | 24.x | `docker compose v2` plugin must be installed |
| Chrome / Chromium | 120+ | matches the CDP version pinned by `stealth-cli` |
| xvfb-run | latest | needed for headful-equivalent runs on a headless host |
| x11vnc | latest | only required if you install the optional `--with-vnc-fallback` emergency unit (section 4 / 8) |
| sysstat | latest | `sar`, `iostat` for the `doctor --vps` perf probes |
| systemd-creds | bundled | used by `setup-credentials.sh` for encryption |

Install the OS-side tooling first:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 chromium-browser \
  xvfb x11vnc sysstat ufw fail2ban unattended-upgrades
```

`docker compose version` must report `v2.x`. The legacy `docker-compose`
(hyphen) binary is not supported by `scripts/vpn_up.sh`.

## 2. Install Steps

Run from the cloned repo on the VPS as a sudoer account.

```bash
# 2.1 bring up the VPN pool (uses src/infra/docker-compose.vpn.yml)
./scripts/vpn_up.sh

# 2.2 install systemd unit templates (idempotent, symlinks into /etc)
sudo ./dist/systemd/install.sh

# 2.3 provision VPN credentials into encrypted credstore (P10.2)
sudo ./dist/systemd/setup-credentials.sh
```

`install.sh` is idempotent (`ln -sfn` + `systemctl ... || true`); re-running it
after upgrades is safe. Pass `--no-enable` to link units without starting them.

For an emergency interactive desktop fallback, install the optional Xvfb + VNC
helper unit (see section 4):

```bash
sudo ./dist/systemd/install.sh --with-vnc-fallback
```

## 3. Post-install Verification

`rev-stealth doctor --vps` is the single source of truth for VPS health. It
exercises the systemd units, credstore, VPN leak detector, and the perf probes
that the timer-driven doctor.service will run on a schedule.

```bash
sudo -u rev-stealth rev-stealth doctor --vps --json \
  | tee /var/log/rev-stealth/doctor-firstboot.json
```

A passing run returns `"status":"PASS"` and exits 0. Any non-zero exit must be
treated as a blocker. The expected test coverage tied to this command is 610
deterministic assertions; see `docs/manual/verification-truth-matrix.md` for
the canonical evidence schema.

Spot-check the systemd units:

```bash
systemctl status rev-stealth-mcp.service
systemctl list-timers rev-stealth-doctor.timer
journalctl -u rev-stealth-mcp.service -n 100 --no-pager
```

## 4. Auth Export (Local -> VPS, no remote interactive login)

VPS hosts must not run interactive Claude / Codex login flows. Instead, perform
the OAuth / keychain login on a trusted local workstation, export the
already-encrypted credential blobs, and transfer them via `scp`.

```bash
# 4.1 (local workstation, after a successful local auth)
rev-stealth auth export --out ./rev-stealth-creds.enc
sha256sum ./rev-stealth-creds.enc > ./rev-stealth-creds.enc.sha256

# 4.2 ship to VPS over SSH (no plaintext passes over the wire)
scp ./rev-stealth-creds.enc ./rev-stealth-creds.enc.sha256 \
    operator@vps.example.net:/tmp/

# 4.3 (on the VPS) import under the rev-stealth system user
sudo -u rev-stealth rev-stealth auth import \
  --in /tmp/rev-stealth-creds.enc \
  --sha256 /tmp/rev-stealth-creds.enc.sha256
sudo shred -u /tmp/rev-stealth-creds.enc /tmp/rev-stealth-creds.enc.sha256
```

The exported `.enc` blob is sealed by `systemd-creds` (same key custody as the
VPN credstore from P10.2). It is safe at rest but must still be removed from
`/tmp` after import.

## 5. Troubleshooting

| Symptom | Likely cause | First action |
|---------|--------------|--------------|
| `Failed: no $DISPLAY` from stealth-mcp | Chromium launched without Xvfb | enable the Xvfb VNC fallback unit, or set `DISPLAY=:99` via drop-in override |
| `chromium: command not found` in journalctl | Chrome / Chromium package missing | re-run the apt install in section 1; rerun `doctor --vps` |
| `rev-stealth-vpn@1` stuck in `activating` | gluetun cannot finish handshake (auth or region) | `docker compose -f src/infra/docker-compose.vpn.yml logs vpn-1`; verify credstore via `setup-credentials.sh --dry-run` |
| `doctor --vps` reports `leak detected` | gluetun policy misrouting or NAT escape | stop the affected pool member, inspect `ip route` / `iptables -L`, never run scrapes until the leak gate clears |
| Doctor timer not firing | timer not enabled | `systemctl enable --now rev-stealth-doctor.timer` |
| `LoadCredentialEncrypted` fails on boot | systemd < 252 or missing credstore file | check `systemctl --version` and `ls /etc/credstore.encrypted/` |

For everything else, capture `journalctl -u rev-stealth-* --since "1 hour ago"`
and attach it to the incident report.

## 6. Recommended Host

| Provider | Plan | Reason |
|----------|------|--------|
| Hetzner Cloud | CPX21 (3 vCPU AMD, 4 GB RAM, 80 GB NVMe, EUR 5.83 / mo) | comfortably fits a 3-instance gluetun pool + headful-equivalent Chromium |
| Hetzner Cloud | CPX31 | recommended once a 4th VPN instance or parallel scraping job is enabled |
| Alternatives | OVH VPS Value 2, Vultr High-Performance 4GB | acceptable if Hetzner egress policy is a problem |

Avoid shared-CPU "burst" tiers under EUR 4 / mo: Chromium + gluetun
saturate the steal-credits budget within minutes and `doctor --vps` will
start flapping on perf probes.

## 7. Security Checklist

Run this checklist on every fresh VPS before opening it to operator traffic.

- [ ] `ufw default deny incoming` and only allow `22/tcp` (SSH) and any
      explicitly required scraping egress.
- [ ] `fail2ban` enabled with the `sshd` jail (`/etc/fail2ban/jail.d/sshd.conf`).
- [ ] `/etc/ssh/sshd_config`: `PermitRootLogin no`, `PasswordAuthentication no`,
      `KbdInteractiveAuthentication no`. Reload with `systemctl reload ssh`.
- [ ] Unattended security upgrades enabled
      (`dpkg-reconfigure -plow unattended-upgrades`).
- [ ] `/etc/credstore.encrypted/` mode `0700`, owned by `root:root`.
- [ ] `rev-stealth` system user has `NoNewPrivileges=yes` (already set in
      `dist/systemd/system/rev-stealth-mcp.service`).
- [ ] The optional VNC fallback (section 8) is **disabled by default** and only
      bound to `127.0.0.1`. Reach it via SSH local forwarding, never expose to
      the public interface.
- [ ] `setup-credentials.sh` was run as root and its plaintext stdin source
      (env or prompt) was discarded.
- [ ] Doctor timer wired (`systemctl is-enabled rev-stealth-doctor.timer`).

## 8. Uninstall

```bash
sudo ./dist/systemd/uninstall.sh            # keep data
sudo ./dist/systemd/uninstall.sh --purge    # also rm /var/lib/rev-stealth + /var/log/rev-stealth
```

The uninstaller leaves the `rev-stealth` system user in place because user
deletion is distro-specific and recoverable; remove it manually with
`deluser rev-stealth` only after confirming no residual state remains.

For the optional VNC fallback added by `--with-vnc-fallback`, also disable it:

```bash
sudo systemctl disable --now rev-stealth-xvfb-vnc.service
sudo rm -f /etc/systemd/system/rev-stealth-xvfb-vnc.service
sudo systemctl daemon-reload
```
