# `VpnAllInstancesFailed`

> **Wire `kind`** (snake_case): `vpn_all_instances_failed`
> **When emitted**: VPN rotation tried every configured instance and none came up.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "vpn_all_instances_failed",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Wait and retry; check VPN provider status.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/VpnAllInstancesFailed.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth vpn rotate --country ZZ --output-format json  # unsupported region
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Wait and retry; check VPN provider status.

**Common root causes**:

- Every configured VPN endpoint failed health check.
- Provider region outage.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
