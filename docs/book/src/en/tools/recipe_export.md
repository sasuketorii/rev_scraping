# `recipe_export`

> Export all recipes as a base64-encoded JSON array.

**Canonical schema**: [`docs/json-schemas/recipe_export.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/recipe_export.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| (none) | - | - | No arguments accepted. |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"recipe_export","arguments":{}}}' \
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
        "text": "{\"payload\":\"W3sieyJzaXRlIjp7ImRvbWFpbiI6ImV4YW1wbGUuY29tIn19XQ==\",\"count\":0,\"encoding\":\"base64-json\"}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/recipe_export.output.json`.

## Failure example — `Internal` (wire `kind: "internal"`)

If a recipe on disk fails to parse during export, the response is an `ErrorEnvelope`. The MCP layer
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
      "text": "{\"kind\":\"internal\",\"message\":\"...\",\"retryable\":false,\"hint\":\"...\",\"doc_url\":\"https://sasuketorii.github.io/rev_scraping/en/errors/Internal.html\"}"
    }]
  }
}
```

Follow the [`Internal` troubleshooting page](../errors/Internal.md)
for the fix recipe.

## See also

- [Error reference](../errors/README.md) — all 26 `ErrorKind` variants
- [MCP transport contract](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md)
