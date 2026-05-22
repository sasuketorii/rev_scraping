# REV Stealth — systemd unit templates

<!-- SPDX-License-Identifier: MIT -->

This directory contains the canonical systemd unit templates for running
`rev_scraping` (a.k.a. REV Stealth) as a long-lived service on a Linux VPS.
Templates are split into **system** and **user** scope; pick whichever
matches your deployment model.

P10.1 ships *templates and installer plumbing only*. Credential wiring
(Surfshark VPN secrets via `LoadCredentialEncrypted=`) lands in P10.2 —
the corresponding placeholder comments are already present in the unit
files.

## File map

| Path                                          | Role                                                                 |
| --------------------------------------------- | -------------------------------------------------------------------- |
| `system/rev-stealth-mcp.service`              | `stealth-mcp` daemon, runs as the `rev-stealth` system user.         |
| `system/rev-stealth-vpn@.service`             | Templated docker-compose instance for VPN egress (`@1`, `@2`, ...).  |
| `system/rev-stealth-doctor.service`           | One-shot health probe; emits JSONL.                                  |
| `system/rev-stealth-doctor.timer`             | Fires the probe at boot + every 30 min.                              |
| `user/rev-stealth-mcp.service`                | User-scope variant of the MCP daemon (no root).                      |
| `user/rev-stealth-soak.service`               | Runs `scripts/run_soak.sh` under the operator account.               |
| `tmpfiles.d/rev-stealth.conf`                 | Boot-time creation of runtime + log dirs with correct perms.         |
| `sysusers.d/rev-stealth.conf`                 | Provisions the `rev-stealth` system user/group.                      |
| `install.sh`                                  | Idempotent installer (`sudo ./install.sh`).                          |
| `uninstall.sh`                                | Full reversal (`sudo ./uninstall.sh [--purge]`).                     |

## Install (system scope)

```sh
sudo ./install.sh                 # link + enable + start
sudo ./install.sh --no-enable     # link only
```

The installer:

1. symlinks system units into `/etc/systemd/system/`,
2. links `sysusers.d` + `tmpfiles.d` drop-ins under `/etc/`,
3. runs `systemd-sysusers` + `systemd-tmpfiles --create` to provision
   the `rev-stealth` user/group and runtime dirs,
4. `systemctl daemon-reload`,
5. (default) enables and starts `rev-stealth-mcp.service` and
   `rev-stealth-doctor.timer`.

VPN instances are opt-in:

```sh
sudo systemctl enable --now rev-stealth-vpn@1.service
```

## Install (user scope)

```sh
mkdir -p ~/.config/systemd/user
systemctl --user link  $(pwd)/user/rev-stealth-mcp.service
systemctl --user link  $(pwd)/user/rev-stealth-soak.service
systemctl --user daemon-reload
systemctl --user enable --now rev-stealth-mcp.service
```

User units expect `~/.local/bin/stealth-mcp` and `~/.config/rev-stealth/mcp.toml`
unless overridden via a drop-in:

```sh
systemctl --user edit rev-stealth-mcp.service
# [Service]
# Environment=REV_STEALTH_BIN=/opt/rev-stealth/bin/stealth-mcp
```

## Uninstall

```sh
sudo ./uninstall.sh           # stop, disable, unlink
sudo ./uninstall.sh --purge   # also rm -rf /var/lib/rev-stealth /var/log/rev-stealth
```

User-scope units are removed with `systemctl --user disable --now <unit>`
followed by deleting the `~/.config/systemd/user/<unit>` symlink.

## Override knobs

Every `ExecStart=` resolves to an absolute path and accepts a
`REV_STEALTH_BIN` env override, so operators can swap binaries without
editing the unit file:

```ini
# /etc/systemd/system/rev-stealth-mcp.service.d/override.conf
[Service]
Environment=REV_STEALTH_BIN=/opt/rev-stealth/bin/stealth-mcp
Environment=RUST_LOG=debug
```

Apply with `systemctl daemon-reload && systemctl restart <unit>`.

## Hardening defaults

All long-running services inherit the same hardening floor:

| Directive              | Value          |
| ---------------------- | -------------- |
| `Restart=`             | `on-failure`   |
| `RestartSec=`          | `5s`           |
| `LimitNOFILE=`         | `65536`        |
| `PrivateTmp=`          | `yes`          |
| `ProtectSystem=`       | `strict`       |
| `NoNewPrivileges=`     | `yes`          |
| `ProtectKernelTunables=` | `yes` (system MCP + doctor) |
| `RestrictSUIDSGID=`    | `yes` (system MCP + doctor) |

## Log + data locations

| Path                              | Mode  | Owner         | Notes                                      |
| --------------------------------- | ----- | ------------- | ------------------------------------------ |
| `/var/lib/rev-stealth/`           | 0700  | `rev-stealth` | service state, compose project dirs        |
| `/var/lib/rev-stealth/vpn/vpn-N/` | 0700  | `rev-stealth` | per-instance VPN compose project           |
| `/var/log/rev-stealth/`           | 0750  | `rev-stealth` | doctor JSONL + service logs                |
| `/var/log/rev-stealth/doctor.jsonl` | 0640 | `rev-stealth` | append-only health probe stream            |

Inspect runtime status:

```sh
systemctl status rev-stealth-mcp.service
journalctl -u rev-stealth-mcp.service -f
journalctl -u rev-stealth-doctor.service --since today
tail -f /var/log/rev-stealth/doctor.jsonl
```

## Credential handling (P10.2 preview)

VPN and origin credentials will be delivered via
`LoadCredentialEncrypted=` referencing `/etc/credstore.encrypted/`.
Placeholder comments mark the eventual insertion point in
`rev-stealth-mcp.service` and `rev-stealth-vpn@.service`; do not put raw
secrets into these unit files or into env drop-ins committed to source
control.
