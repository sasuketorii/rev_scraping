# `Auth`

> **Wire `kind`** (snake_case): `auth`
> **When emitted**: Authentication / authorization failure.
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "auth",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Re-run `auth_login_start` / refresh the profile.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/Auth.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth spider --url https://members.example.com --profile nonexistent
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Re-run `auth_login_start` / refresh the profile.

**Common root causes**:

- Profile cookies are stale.
- Site rotated its CSRF token format.
- 2FA-protected endpoint.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
