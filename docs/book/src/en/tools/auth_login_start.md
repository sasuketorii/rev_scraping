# `auth_login_start`

> Phase 1 of 2-phase login: AUP-enforce + spawn rev-auth helper. Returns a `session_token`. Cookie values never returned.

**Canonical schema**: [`docs/json-schemas/auth_login_start.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/auth_login_start.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `profile` | string | yes | Auth profile name; reused on subsequent calls. |
| `url` | string | yes | Login start URL. Must be on the AUP allowlist. |
| `domain` | string | no | Cookie scope domain (defaults to URL host). |
| `completion_pattern` | string (regex) | no | Pattern matched against post-login URL/DOM to detect completion. |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"auth_login_start","arguments":{"profile":"example_main","url":"https://example.com/login"}}}' \
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
        "text": "{\"ok\":true,\"session_token\":\"sess_b2f9b1c0e2\",\"login_window_pid\":12345,\"profile\":\"example_main\",\"domain\":\"example.com\",\"cookie_values_returned\":false}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/auth_login_start.output.json`.

## Failure example — `Aup` (wire `kind: "aup"`)

If the URL is not on the auth-allowed AUP allowlist, the response is an `ErrorEnvelope`. The MCP layer
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
      "text": "{\"kind\":\"aup\",\"message\":\"...\",\"retryable\":false,\"hint\":\"...\",\"doc_url\":\"https://sasuketorii.github.io/rev_scraping/en/errors/Aup.html\"}"
    }]
  }
}
```

Follow the [`Aup` troubleshooting page](../errors/Aup.md)
for the fix recipe.

## See also

- [Error reference](../errors/README.md) — all 26 `ErrorKind` variants
- [MCP transport contract](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md)
