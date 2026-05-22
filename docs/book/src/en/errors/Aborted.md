# `Aborted`

> **Wire `kind`** (snake_case): `aborted`
> **When emitted**: Operation cancelled by caller (e.g. shutdown signal).
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "aborted",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Resume the operation if still desired.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/Aborted.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
# happens if the caller cancels mid-call (e.g. Claude Code timeout)
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Resume the operation if still desired.

**Common root causes**:

- Caller closed the JSON-RPC connection.
- Claude Code / Hermes hit its own timeout.
- User cancelled.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
