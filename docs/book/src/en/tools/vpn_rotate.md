# `vpn_rotate`

> Rotate VPN exit (Surfshark via Gluetun).

**Canonical schema**: [`docs/json-schemas/vpn_rotate.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/vpn_rotate.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `provider` | string | no | VPN provider key (default `surfshark`). |
| `strategy` | enum | no | One of `lazy-on-fail` (default), `every-n`, `interval`. |
| `region` | string | no | Target region / country hint (e.g. `JP`, `US`). |
| `reason` | string | no | Free-form reason recorded with the rotation event. |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"vpn_rotate","arguments":{"region":"JP","reason":"manual"}}}' \
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
        "text": "{\"result\":{\"rotated\":true,\"container\":\"gluetun\",\"reason\":\"cf-challenge\"},\"operation\":\"vpn.rotate\",\"ok\":true}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/vpn_rotate.output.json`.

## Failure example — `VpnNotConfigured` (wire `kind: "vpn_not_configured"`)

If VPN credentials are not configured on this host, the response is an `ErrorEnvelope`. The MCP layer
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
      "text": "{\"kind\":\"vpn_not_configured\",\"message\":\"...\",\"retryable\":false,\"hint\":\"...\",\"doc_url\":\"https://sasuketorii.github.io/rev_scraping/en/errors/VpnNotConfigured.html\"}"
    }]
  }
}
```

Follow the [`VpnNotConfigured` troubleshooting page](../errors/VpnNotConfigured.md)
for the fix recipe.

## See also

- [Error reference](../errors/README.md) — all 26 `ErrorKind` variants
- [MCP transport contract](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md)
