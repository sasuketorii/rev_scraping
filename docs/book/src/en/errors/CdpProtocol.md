# `CdpProtocol`

> **Wire `kind`** (snake_case): `cdp_protocol`
> **When emitted**: Chrome DevTools Protocol returned an unexpected error code.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "cdp_protocol",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Retry; if persistent, check Chrome version compatibility.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/CdpProtocol.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
# happens when Chromium reports an unexpected CDP envelope; see logs
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Retry; if persistent, check Chrome version compatibility.

**Common root causes**:

- Chromium / Chrome version mismatch.
- Unexpected CDP message during inspection.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
