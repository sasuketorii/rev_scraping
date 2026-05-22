# `RecipeNotFound`

> **Wire `kind`** (snake_case): `recipe_not_found`
> **When emitted**: Recipe lookup failed: the requested `domain` has no recipe on disk.
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "recipe_not_found",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Run `recipe_list` to see available domains.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/RecipeNotFound.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth recipe show --domain unseen.example --output-format json
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Run `recipe_list` to see available domains.

**Common root causes**:

- No recipe file at `~/.rev_scraping/sites/<domain>.toml`.
- Domain spelling mismatch (e.g. trailing slash).

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
