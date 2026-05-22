# `VpnNotConfigured`

> **Wire `kind`** (snake_case): `vpn_not_configured`
> **When emitted**: VPN rotation requested but no VPN backend is configured.
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "vpn_not_configured",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Configure Surfshark/Gluetun in policy.toml before requesting rotation.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/VpnNotConfigured.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth vpn rotate --country JP --output-format json  # on a host without VPN creds
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Configure Surfshark/Gluetun in policy.toml before requesting rotation.

**Common root causes**:

- No `VPN_*` environment variables set.
- No Gluetun sidecar reachable.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
