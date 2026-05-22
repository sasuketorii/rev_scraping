# `NotFound`

> **Wire `kind`** (snake_case): `not_found`
> **When emitted**: Target resource not found.
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "not_found",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Verify the URL / recipe / profile name.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/NotFound.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth recipe show --domain does.not.exist --output-format json
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Verify the URL / recipe / profile name.

**Common root causes**:

- URL 404s.
- Recipe name typo.
- Profile / session id was garbage-collected.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
