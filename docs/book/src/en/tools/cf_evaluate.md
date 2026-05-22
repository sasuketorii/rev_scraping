# `cf_evaluate`

> Evaluate Cloudflare Turnstile resilience on an authorized target.

**Canonical schema**: [`docs/json-schemas/cf_evaluate.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/cf_evaluate.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `url` | string | yes | Target URL with active Turnstile challenge. AUP allowlist required. |
| `session_id` | string (UUIDv4) | no | Correlate with an existing spider session. |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"cf_evaluate","arguments":{"url":"https://challenged.example.com"}}}' \
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
        "text": "{\"result\":{},\"operation\":\"cf-evaluate\",\"ok\":true}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/cf_evaluate.output.json`.

## Failure example — `Captcha` (wire `kind: "captcha"`)

If the challenge could not be bypassed in the current mode, the response is an `ErrorEnvelope`. The MCP layer
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
      "text": "{\"kind\":\"captcha\",\"message\":\"...\",\"retryable\":false,\"hint\":\"...\",\"doc_url\":\"https://sasuketorii.github.io/rev_scraping/en/errors/Captcha.html\"}"
    }]
  }
}
```

Follow the [`Captcha` troubleshooting page](../errors/Captcha.md)
for the fix recipe.

## See also

- [Error reference](../errors/README.md) — all 26 `ErrorKind` variants
- [MCP transport contract](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md)
