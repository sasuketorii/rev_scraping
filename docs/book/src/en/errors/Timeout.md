# `Timeout`

> **Wire `kind`** (snake_case): `timeout`
> **When emitted**: Operation exceeded its timeout budget.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "timeout",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Retry with a larger budget or after backoff.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/Timeout.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth spider --url https://slow.example.com --timeout 1 --output-format json
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Retry with a larger budget or after backoff.

**Common root causes**:

- Network round-trip exceeded the budget.
- Origin server is genuinely slow.
- VPN added unexpected latency.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
