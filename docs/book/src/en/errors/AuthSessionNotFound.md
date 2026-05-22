# `AuthSessionNotFound`

> **Wire `kind`** (snake_case): `auth_session_not_found`
> **When emitted**: `session_token` is unknown to the registry (never issued, GC'd, or already consumed).
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "auth_session_not_found",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Start a new login flow with `auth_login_start`.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/AuthSessionNotFound.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth auth login complete --session-token bogus --output-format json
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Start a new login flow with `auth_login_start`.

**Common root causes**:

- Token typo or single-use token re-used.
- Token belongs to a previous `rev-stealth` process.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
