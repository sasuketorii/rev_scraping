# `recipe_remove`

> Remove a recipe file. Preview unless `confirm=true`.

**Canonical schema**: [`docs/json-schemas/recipe_remove.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/recipe_remove.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `domain` | string | yes | Recipe domain key to remove. |
| `confirm` | boolean | no | Must be `true` to actually delete; `false` (default) only previews. |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"recipe_remove","arguments":{"domain":"example.com","confirm":false}}}' \
  | rev-stealth mcp
```

**Response** (success envelope, abridged — see `outputSchema` link above
for the full field list):

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "isError": false,
    "content": [
      {
        "type": "text",
        "text": "{\"removed\":false,\"domain\":\"example.com\"}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/recipe_remove.output.json`.

## Failure example — `RecipeNotFound` (wire `kind: "recipe_not_found"`)

If the recipe to remove does not exist, the response is an `ErrorEnvelope`. The MCP layer
serialises `kind` as the snake_case `wire_name` (not the PascalCase Rust
variant), and `retryable: false` reflects whether retrying
without changing inputs is plausibly safe (see
`crates/stealth-agent-contracts/src/error.rs`, `all_error_kind_docs()`).

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "isError": true,
    "content": [{
      "type": "text",
      "text": "{\"kind\":\"recipe_not_found\",\"message\":\"...\",\"retryable\":false,\"hint\":\"...\",\"doc_url\":\"https://sasuketorii.github.io/rev_scraping/en/errors/RecipeNotFound.html\"}"
    }]
  }
}
```

Follow the [`RecipeNotFound` troubleshooting page](../errors/RecipeNotFound.md)
for the fix recipe.

## See also

- [Error reference](../errors/README.md) — all 26 `ErrorKind` variants
- [MCP transport contract](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md)
