# Step 7 — VPS deployment

For long-running scraping the recommended deployment is a small Linux VPS
with `rev-stealth` running as a systemd service and Chromium in a
sandboxed sidecar.

## Install on the VPS

```sh
curl -fsSL https://github.com/sasuketorii/rev_scraping/releases/download/v1.3.0/rev-stealth_1.3.0_amd64.deb -o rev-stealth.deb
sudo dpkg -i rev-stealth.deb
sudo systemctl enable --now rev-stealth-doctor.timer
```

`rev-stealth-doctor.timer` runs `doctor --output-format json` every 15
minutes and surfaces failures via journald. CI gates require a clean 24-72
hour run before tagging `v1.3.0`.

## systemd unit (excerpt)

```ini
[Service]
Type=simple
ExecStart=/usr/local/bin/rev-stealth mcp
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/rev-stealth
SystemCallArchitectures=native
```

`systemd-analyze security rev-stealth.service` should report **OK** with
no `UNSAFE` findings.

## Docker compose (alternative)

```yaml
services:
  rev-stealth:
    image: ghcr.io/sasuketorii/rev-stealth:v1.3.0
    restart: unless-stopped
    volumes:
      - rev-data:/var/lib/rev-stealth
  chromium:
    image: ghcr.io/sasuketorii/rev-stealth-chromium:v1.3.0
    restart: unless-stopped

volumes:
  rev-data:
```

## Smoke test

```sh
systemctl is-active rev-stealth-doctor.timer
# expected: "active"
```

That's the full tour. Next: pick a tool from the
[MCP Tools Cookbook](../tools/README.md) and copy the JSON-RPC example
into your agent.
