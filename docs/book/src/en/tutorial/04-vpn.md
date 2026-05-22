# Step 4 — VPN rotation (optional)

If your scraping workload needs egress diversity, `rev-stealth` integrates
with WireGuard-compatible VPN providers (Surfshark via Gluetun is the
v1.3 default).

> If you do not have a VPN configured, you can skip this step; the
> example commands below will return `vpn_not_configured`
> ([fix](../errors/VpnNotConfigured.md)) which is itself a useful smoke
> test of the error surface.

## Rotate to a specific region

```sh
rev-stealth vpn rotate \
  --region JP \
  --reason tutorial-step4 \
  --output-format json
```

`--reason` is recorded with the rotation event for audit / observability.
The MCP `vpn_rotate` tool accepts the same arguments as `region` /
`reason` JSON fields (see the
[cookbook page](../tools/vpn_rotate.md)).

## Stub path (no VPN configured)

```sh
rev-stealth vpn rotate --region JP --output-format json
# expected: ErrorEnvelope with kind "vpn_not_configured" + doc_url
```

That error envelope is the contract every `rev-stealth` failure path
follows. Open `doc_url` to see the troubleshooting page.

## Smoke test

```sh
rev-stealth vpn rotate --region JP --output-format json \
  | jq -r '.region // .kind'
# expected: "JP" if VPN configured, "vpn_not_configured" otherwise — both
# are acceptable for this tutorial
```
