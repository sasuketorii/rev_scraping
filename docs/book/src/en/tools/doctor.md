# `doctor`

> Run leak-guard / VPN / captcha sidecar health diagnostics.

**Canonical schema**: [`docs/json-schemas/doctor.output.json`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/json-schemas/doctor.output.json)
**Source**: [`crates/stealth-mcp/src/tools.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-mcp/src/tools.rs)

## Input arguments

| Field | Type | Required | Description |
|---|---|---|---|
| `container` | string | no | VPN container name to probe (default `gluetun`). |
| `expected_country` | string | no | ISO-3166 alpha-2 the VPN egress should report (e.g. `JP`). |

`inputSchema` has `additionalProperties: false` — unknown keys are rejected.

## Happy path

**Request**:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"doctor","arguments":{}}}' \
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
        "text": "{\"kill_switch\":true,\"dns_lock\":true,\"ipv6_disabled\":true,\"webrtc_guard_present\":true,\"exit_ip_ok\":true}"
      }
    ]
  }
}
```

The `text` field is a stringified JSON object that conforms to
`docs/json-schemas/doctor.output.json`.

## Failure example — `VpnLeak` (wire `kind: "vpn_leak"`)

If the diagnostic detects a DNS or IPv6 leak, the response is an `ErrorEnvelope`. The MCP layer
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
      "text": "{\"kind\":\"vpn_leak\",\"message\":\"...\",\"retryable\":true,\"hint\":\"...\",\"doc_url\":\"https://sasuketorii.github.io/rev_scraping/en/errors/VpnLeak.html\"}"
    }]
  }
}
```

Follow the [`VpnLeak` troubleshooting page](../errors/VpnLeak.md)
for the fix recipe.

## See also

- [Error reference](../errors/README.md) — all 26 `ErrorKind` variants
- [MCP transport contract](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md)
