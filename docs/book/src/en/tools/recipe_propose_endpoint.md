# `recipe_propose_endpoint`

> Append a new endpoint to an existing site recipe. Secret-leak rejected.

**Canonical schema**: [`docs/json-schemas/recipe_propose_endpoint.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/recipe_propose_endpoint.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `domain` | string | yes | Recipe to append to. |
| `endpoint` | object | yes | Endpoint definition. Required sub-fields: `purpose`, `path`. Optional: `http_method`, `url_pattern`. |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"recipe_propose_endpoint","arguments":{"domain":"example.com","endpoint":{"purpose":"search","path":"/api/v1/search","http_method":"GET"}}}}' \
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
        "text": "{\"added\":true,\"domain\":\"example.com\",\"endpoint_count_after\":1}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/recipe_propose_endpoint.output.json`.

## Failure example — `RecipeInvalid` (wire `kind: "recipe_invalid"`)

If the proposed endpoint contains a secret-leak heuristic match, the response is an `ErrorEnvelope`. The MCP layer
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
      "text": "{\"kind\":\"recipe_invalid\",\"message\":\"...\",\"retryable\":false,\"hint\":\"...\",\"doc_url\":\"https://sasuketorii.github.io/rev_scraping/en/errors/RecipeInvalid.html\"}"
    }]
  }
}
```

Follow the [`RecipeInvalid` troubleshooting page](../errors/RecipeInvalid.md)
for the fix recipe.

## See also

- [Error reference](../errors/README.md) — all 26 `ErrorKind` variants
- [MCP transport contract](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md)
