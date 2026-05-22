# `VpnCountryMismatch`

> **Wire `kind`** (snake_case): `vpn_country_mismatch`
> **When emitted**: VPN egress is up but the resolved country does not match the requested `country` constraint.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "vpn_country_mismatch",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Retry rotation with a different region hint.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/VpnCountryMismatch.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth vpn rotate --country JP  # but VPN returns US exit
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Retry rotation with a different region hint.

**Common root causes**:

- VPN provider gave a different exit country than requested.
- Geo-IP database disagrees with provider claim.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
