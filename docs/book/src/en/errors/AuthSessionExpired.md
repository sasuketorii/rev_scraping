# `AuthSessionExpired`

> **Wire `kind`** (snake_case): `auth_session_expired`
> **When emitted**: `auth_login_complete` polled past `login_timeout` budget.
> **Retryable**: yes — safe to retry with backoff

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "auth_session_expired",
  "message": "<context-specific>",
  "retryable": true,
  "hint": "Re-run `auth_login_start` to obtain a fresh session_token.",
  "retry_after_ms": <number-or-null>,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/AuthSessionExpired.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
# wait > session TTL after auth_login_start, then call auth_login_complete
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Re-run `auth_login_start` to obtain a fresh session_token.

**Common root causes**:

- More than `session_ttl_secs` elapsed between `auth_login_start` and `auth_login_complete`.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
