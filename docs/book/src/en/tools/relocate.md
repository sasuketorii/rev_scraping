# `relocate`

> Adaptive relocate a previously recorded element via stealth-parse.

**Canonical schema**: [`docs/json-schemas/relocate.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/relocate.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `session_id` | string (UUIDv4) | yes | Session that originally emitted the `stable_id`. |
| `stable_id` | string | yes | Stable element ID to re-locate. |
| `html` | string | no | Raw HTML to search in. Mutually exclusive with `url`. |
| `url` | string | no | URL to fetch and search in. Mutually exclusive with `html`. |
| `threshold` | number | no | Similarity threshold in [0,1] (default `0.85`). |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"relocate","arguments":{"session_id":"7c3e3b8a-3b2e-4e57-9a8a-1e1c1f6d7a01","stable_id":"sid_8d3a","url":"https://example.com/products/42"}}}' \
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
        "text": "{\"result\":{},\"operation\":\"relocate\",\"ok\":true}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/relocate.output.json`.

## Failure example — `NotFound` (wire `kind: "not_found"`)

If the `stable_id` is no longer present in the page DOM, the response is an `ErrorEnvelope`. The MCP layer
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
      "text": "{\"kind\":\"not_found\",\"message\":\"...\",\"retryable\":false,\"hint\":\"...\",\"doc_url\":\"https://sasuketorii.github.io/rev_scraping/en/errors/NotFound.html\"}"
    }]
  }
}
```

Follow the [`NotFound` troubleshooting page](../errors/NotFound.md)
for the fix recipe.

## See also

- [Error reference](../errors/README.md) — all 26 `ErrorKind` variants
- [MCP transport contract](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md)
