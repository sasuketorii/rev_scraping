# `CdpDisconnected`

> **Wire `kind`** (snake_case): `cdp_disconnected`
> **When emitted**: CDP WebSocket disconnected before the operation completed.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "cdp_disconnected",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Retry; relaunch the browser if disconnects persist.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/CdpDisconnected.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
# kill the Chromium sidecar mid-scrape, then call `spider`
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Retry; relaunch the browser if disconnects persist.

**Common root causes**:

- Chromium crashed or was killed.
- Sidecar container restarted.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
