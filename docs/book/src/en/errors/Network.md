# `Network`

> **Wire `kind`** (snake_case): `network`
> **When emitted**: Lower-level network / transport failure.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "network",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Retry with backoff; check egress connectivity.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/Network.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth spider --url https://dns-fail.invalid --output-format json
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Retry with backoff; check egress connectivity.

**Common root causes**:

- DNS lookup failure.
- TCP connection refused.
- TLS handshake failure.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
