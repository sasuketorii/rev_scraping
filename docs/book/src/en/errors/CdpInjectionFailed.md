# `CdpInjectionFailed`

> **Wire `kind`** (snake_case): `cdp_injection_failed`
> **When emitted**: Stealth JS injection into the target page failed.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "cdp_injection_failed",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Re-run; verify obscura binary version.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/CdpInjectionFailed.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
# happens when a recipe's JS payload is rejected by CSP
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Re-run; verify obscura binary version.

**Common root causes**:

- Page CSP rejects injected script.
- Recipe-provided JS contains a syntax error.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
