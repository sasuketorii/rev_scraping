# `Captcha`

> **Wire `kind`** (snake_case): `captcha`
> **When emitted**: Captcha challenge encountered and not bypassable in current mode.
> **Retryable**: no — fix inputs first

## `ErrorEnvelope` shape

The MCP layer serialises this variant as a snake_case `kind`. The
`doc_url` field is injected by the MCP server (the in-tree
`ErrorEnvelope` struct itself does not carry it — it is added by the
JSON-RPC wrapper for agent consumption).

```json
{
  "kind": "captcha",
  "message": "<context-specific>",
  "retryable": false,
  "hint": "Switch to an authenticated flow or solve out-of-band.",
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/Captcha.html"
}
```

## Reproduction

The fastest way to see this error in your own shell:

```sh
rev-stealth cf-evaluate --url https://challenged.example.com --output-format json
```

The JSON-RPC `result.isError` will be `true` and the embedded text
content carries the envelope above.

## Fix path

Switch to an authenticated flow or solve out-of-band.

**Common root causes**:

- Site escalated to hCaptcha / reCAPTCHA / Turnstile.
- Current mode does not include a solver.
- Profile cookies expired and triggered re-challenge.

## Related

- [Error reference index](./README.md)
- [Tools cookbook](../tools/README.md)
- Source: [`crates/stealth-agent-contracts/src/error.rs`](https://github.com/sasuketorii/rev_scraping/blob/main/crates/stealth-agent-contracts/src/error.rs)
