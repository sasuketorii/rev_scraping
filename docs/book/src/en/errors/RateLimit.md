# `RateLimit`

> **Wire `kind`** (snake_case): `rate_limit`
> **When emitted**: Per-host or global rate limit exceeded.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "rate_limit",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Honor `retry_after_ms`; reduce per-host QPS.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/RateLimit.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
for i in $(seq 1 100); do rev-stealth spider --url https://example.com; done
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Honor `retry_after_ms`; reduce per-host QPS.

**Common root causes**:

- Per-host QPS exceeded.
- Global concurrency exceeded.
- Origin returned 429 with `Retry-After`.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
