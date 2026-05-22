# `recipe_import`

> Import recipes from a base64-encoded JSON array. Secret-rejected and path-traversal guarded.

**Canonical schema**: [`docs/json-schemas/recipe_import.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/recipe_import.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `payload` | string | yes | Base64-encoded JSON array of SiteRecipe entries. |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"recipe_import","arguments":{"payload":"W3sieyJkb21haW4iOiJleGFtcGxlLmNvbSJ9XQ=="}}}' \
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
        "text": "{\"imported\":0,\"rejected\":[],\"total\":0}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/recipe_import.output.json`.

## Failure example — `Validation` (wire `kind: "validation"`)

If a recipe in the payload fails schema validation, the response is an `ErrorEnvelope`. The MCP layer
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
      "text": "{\"kind\":\"validation\",\"message\":\"...\",\"retryable\":false,\"hint\":\"...\",\"doc_url\":\"https://sasuketorii.github.io/rev_scraping/en/errors/Validation.html\"}"
    }]
  }
}
```

Follow the [`Validation` troubleshooting page](../errors/Validation.md)
for the fix recipe.

## See also

- [Error reference](../errors/README.md) — all 26 `ErrorKind` variants
- [MCP transport contract](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md)
