# `AuthSessionPending`

> **Wire `kind`** (snake_case): `auth_session_pending`
> **When emitted**: `session_token` exists but the login helper has not yet finished.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "auth_session_pending",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Poll `auth_login_complete` again after a short delay.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/AuthSessionPending.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
# call auth_login_complete before the browser flow has finished
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Poll `auth_login_complete` again after a short delay.

**Common root causes**:

- Browser flow not yet finished — poll again after a brief delay.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
