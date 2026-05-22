# `Validation`

> **Wire `kind`** (snake_case): `validation`
> **When emitted**: Input validation failure.
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "validation",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Inspect `message` and fix the offending field.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/Validation.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth recipe propose-endpoint --url 'not a url' --output-format json
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Inspect `message` and fix the offending field.

**Common root causes**:

- Input field violates the published schema.
- String exceeds max length.
- Required field absent.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
