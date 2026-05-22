# `BrowserCrashed`

> **Wire `kind`** (snake_case): `browser_crashed`
> **When emitted**: Headless browser process crashed mid-operation.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "browser_crashed",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Retry; if reproducible, capture core dump and file a bug.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/BrowserCrashed.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
# kill -9 the chromium PID during a spider call
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Retry; if reproducible, capture core dump and file a bug.

**Common root causes**:

- OOM kill.
- Chromium SIGSEGV.
- Sandbox policy denied a required syscall.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
