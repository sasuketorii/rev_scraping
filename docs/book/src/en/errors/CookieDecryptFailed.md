# `CookieDecryptFailed`

> **Wire `kind`** (snake_case): `cookie_decrypt_failed`
> **When emitted**: On-disk cookie store could not be decrypted (bad passphrase / corruption).
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "cookie_decrypt_failed",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Re-create the auth profile.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/CookieDecryptFailed.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
# happens if ~/.local/share/rev-stealth/profiles/* is tampered with
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Re-create the auth profile.

**Common root causes**:

- Profile encryption key changed (machine migration).
- File on disk was tampered with.
- Profile created on a different `rev-stealth` major version.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
