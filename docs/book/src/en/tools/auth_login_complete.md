# `auth_login_complete`

> Phase 2 of 2-phase login: poll until rev-auth finishes, then return ProfileMeta. Single-use `session_token`. Cookie values never returned.

**Canonical schema**: [`docs/json-schemas/auth_login_complete.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/auth_login_complete.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `session_token` | string | yes | Single-use token from `auth_login_start`. |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"auth_login_complete","arguments":{"session_token":"sess_b2f9b1c0e2"}}}' \
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
        "text": "{\"ok\":true,\"profile\":\"example_main\",\"domain\":\"example.com\",\"cookie_count\":0,\"saved_to\":\"/home/user/.rev_scraping/auth/example_main.enc\",\"cookie_values_returned\":false}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/auth_login_complete.output.json`.

## Failure example — `AuthSessionExpired` (wire `kind: "auth_session_expired"`)

If the session token aged out before the browser flow completed, the response is an `ErrorEnvelope`. The MCP layer
serialises `kind` as the snake_case `wire_name` (not the PascalCase Rust
variant), and `retryable: true` reflects whether retrying
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
      "text": "{\"kind\":\"auth_session_expired\",\"message\":\"...\",\"retryable\":true,\"hint\":\"...\",\"doc_url\":\"https://sasuketorii.github.io/rev_scraping/en/errors/AuthSessionExpired.html\"}"
    }]
  }
}
```

Follow the [`AuthSessionExpired` troubleshooting page](../errors/AuthSessionExpired.md)
for the fix recipe.

## See also

- [Error reference](../errors/README.md) — all 26 `ErrorKind` variants
- [MCP transport contract](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md)
