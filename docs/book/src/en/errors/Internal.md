# `Internal`

> **Wire `kind`** (snake_case): `internal`
> **When emitted**: Unclassified internal error (last resort).
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "internal",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Capture logs and file a bug; do not silently retry.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/Internal.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
(this should never appear in normal operation; file a bug)
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Capture logs and file a bug; do not silently retry.

**Common root causes**:

- A bug. Capture `RUST_LOG=debug` output and file an issue.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
