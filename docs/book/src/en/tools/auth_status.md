# `auth_status`

> Return freshness classification for an auth profile (`Valid` | `PartiallyExpired` | `AllExpired` | `Missing`).

**Canonical schema**: [`docs/json-schemas/auth_status.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/auth_status.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `profile` | string | yes | Auth profile name to check. |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"auth_status","arguments":{"profile":"example_main"}}}' \
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
        "text": "{\"profile\":\"example_main\",\"status\":\"Valid\",\"cookie_values_returned\":false}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/auth_status.output.json`.

## Failure example — `NotFound` (wire `kind: "not_found"`)

If no profile has ever been stored under that name, the response is an `ErrorEnvelope`. The MCP layer
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
