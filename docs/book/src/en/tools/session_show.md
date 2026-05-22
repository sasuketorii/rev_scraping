# `session_show`

> Return persisted metadata for a session id (VPN binding, started_at, recipe hits, auth profile). Cookie values never disclosed.

**Canonical schema**: [`docs/json-schemas/session_show.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/session_show.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `session_id` | string | yes | Session id matching `[A-Za-z0-9_-]{1,128}`. |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"session_show","arguments":{"session_id":"7e23b58c-9c2c-44bd-9a4d-7b6b32f04d1e"}}}' \
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
        "text": "{\"session_id\":\"7e23b58c-9c2c-44bd-9a4d-7b6b32f04d1e\",\"vpn_instance\":\"vpn-2\",\"recipe_hits\":[],\"started_at\":1700000000}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/session_show.output.json`.

## Failure example — `NotFound` (wire `kind: "not_found"`)

If the session id is unknown or was garbage-collected, the response is an `ErrorEnvelope`. The MCP layer
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
