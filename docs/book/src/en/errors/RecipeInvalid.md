# `RecipeInvalid`

> **Wire `kind`** (snake_case): `recipe_invalid`
> **When emitted**: Recipe payload (TOML/JSON) failed schema or semantic validation.
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "recipe_invalid",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Fix the recipe and re-import.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/RecipeInvalid.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth recipe import --file corrupt.json --output-format json
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Fix the recipe and re-import.

**Common root causes**:

- Recipe file fails schema validation.
- Recipe contains a secret-leak heuristic match.
- Recipe references a path with `..` (path traversal guard).

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
