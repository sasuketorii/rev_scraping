# `Aup`

> **Wire `kind`** (snake_case): `aup`
> **When emitted**: Acceptable Use Policy violation (site / robots / contract).
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "aup",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Confirm target is on the AUP allowlist and robots.txt allows the path.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/Aup.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth spider --url http://localhost:8080 --output-format json
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Confirm target is on the AUP allowlist and robots.txt allows the path.

**Common root causes**:

- Target URL is not on the AUP allowlist.
- `robots.txt` disallows the path.
- Site is on the global deny-list.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
