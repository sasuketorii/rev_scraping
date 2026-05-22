# `VpnLeak`

> **Wire `kind`** (snake_case): `vpn_leak`
> **When emitted**: VPN / egress IP leak detected — real IP would have been exposed.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "vpn_leak",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Bring VPN up and re-run `doctor`; rotate via `vpn_rotate`.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/VpnLeak.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth doctor --output-format json | jq '.checks[] | select(.kind=="vpn_leak")'
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Bring VPN up and re-run `doctor`; rotate via `vpn_rotate`.

**Common root causes**:

- VPN tunnel is down but kill-switch failed.
- DNS leak (DNS resolved outside the tunnel).
- IPv6 leak.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
