# MCP Tools Cookbook

Sixteen tools. One JSON-RPC envelope. Every page below shows:

1. A real `tools/call` request you can paste into `rev-stealth mcp`
2. A real success response (matching the published `outputSchema`)
3. At least one failure example with its `ErrorEnvelope`
4. Where to find the canonical schema in this repo

## Wire format reminder

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"<tool>","arguments":{}}}' \
  | rev-stealth mcp
```

For the full transport contract see
[`docs/MCP_REFERENCE.md`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md).

## Tool index

| Tool | Purpose | Mutates state? |
|---|---|---|
| [spider](./spider.md) | Stealth-scrape a URL with optional CF evaluation | no |
| [relocate](./relocate.md) | Adaptively re-locate a previously recorded element | no |
| [cf_evaluate](./cf_evaluate.md) | Probe Cloudflare Turnstile resilience | no |
| [doctor](./doctor.md) | Leak-guard / VPN / captcha sidecar self-test | no |
| [recipe_list](./recipe_list.md) | List recipes under `~/.rev_scraping/sites/` | no |
| [recipe_show](./recipe_show.md) | Full SiteRecipe JSON for a domain | no |
| [recipe_remove](./recipe_remove.md) | Delete a recipe (preview unless confirmed) | yes |
| [recipe_propose_endpoint](./recipe_propose_endpoint.md) | Append a new endpoint to a recipe | yes |
| [recipe_export](./recipe_export.md) | Export all recipes as base64 JSON | no |
| [recipe_import](./recipe_import.md) | Import recipes from base64 JSON | yes |
| [auth_login_start](./auth_login_start.md) | Phase 1 of 2-phase login | yes |
| [auth_login_complete](./auth_login_complete.md) | Phase 2 of 2-phase login | yes |
| [auth_list](./auth_list.md) | Enumerate stored auth profiles (meta only) | no |
| [auth_status](./auth_status.md) | Freshness classification for an auth profile | no |
| [session_show](./session_show.md) | Persisted metadata for a session id | no |
| [vpn_rotate](./vpn_rotate.md) | Rotate VPN exit | yes |
