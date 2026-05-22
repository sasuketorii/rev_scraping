# `Ssrf`

> **Wire `kind`** (snake_case): `ssrf`
> **When emitted**: Server-Side Request Forgery guard tripped (private/internal target).
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "ssrf",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Do not request loopback / RFC1918 / link-local targets.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/Ssrf.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth spider --url http://127.0.0.1/ --output-format json
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Do not request loopback / RFC1918 / link-local targets.

**Common root causes**:

- Loopback (`127.0.0.1`, `::1`).
- RFC1918 private ranges.
- Link-local / metadata IPs (`169.254.0.0/16`).

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
