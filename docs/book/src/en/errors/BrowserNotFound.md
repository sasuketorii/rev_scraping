# `BrowserNotFound`

> **Wire `kind`** (snake_case): `browser_not_found`
> **When emitted**: Headless browser binary could not be located on PATH.
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "browser_not_found",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Install Chrome/Chromium or set OBSCURA_BIN.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/BrowserNotFound.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth doctor  # on a host without Chromium installed
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Install Chrome/Chromium or set OBSCURA_BIN.

**Common root causes**:

- Chromium binary not on PATH and no sidecar image configured.
- `CHROMIUM_PATH` env var unset on a non-standard install.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
