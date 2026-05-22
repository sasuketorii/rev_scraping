# Migrating from Playwright MCP

[`@playwright/mcp`](https://github.com/microsoft/playwright-mcp) exposes
Playwright as a set of MCP tools (snapshot, click, fill, screenshot). It
gives an agent a generic browser. `rev-stealth` gives an agent a
**stealth-grade scraping pipeline** — narrower surface, but every tool is
guarded and every output is schema'd.

## Conceptual mapping

| Playwright MCP tool | rev_scraping equivalent |
|---|---|
| `browser_snapshot` | `spider` (returns sanitized markdown + structured JSON) |
| `browser_navigate` | `spider` arguments (`url`) |
| `browser_click` / `browser_fill` | recipe-driven (declarative selectors) |
| `browser_screenshot` | (not a primary tool — use `spider` + your own renderer) |
| `browser_console_messages` | session metadata via `session_show` |
| `browser_new_context` | `relocate` (new IP / profile binding) |

## Side-by-side: "scrape this page and give me the visible text"

**Playwright MCP** (multi-step):

```json
{"method":"tools/call","params":{"name":"browser_navigate","arguments":{"url":"https://example.com"}}}
{"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}
```

**rev_scraping** (one step):

```json
{"method":"tools/call","params":{"name":"spider","arguments":{"url":"https://example.com"}}}
```

## Side-by-side: rotate egress IP

**Playwright MCP**: no built-in concept; you proxy at the network layer
yourself.

**rev_scraping**:

```json
{"method":"tools/call","params":{"name":"vpn_rotate","arguments":{"region":"JP","reason":"manual"}}}
```

(See [`vpn_rotate` cookbook page](../tools/vpn_rotate.md) for the full input
schema; `additionalProperties:false` means stray keys like `country` or
`idempotency_key` are rejected.)

## What you gain

- Stealth-grade defaults (sanitize layer, leak guard, VPN rotation).
- Idempotent mutating tools (`recipe_propose_endpoint`, `recipe_import`,
  `auth_login_start`).
- Every tool has a published `outputSchema`; no agent-side guessing.
- Single binary; no Node, no `npx`, no Playwright bundle.

## What you lose

- No generic "click any button" surface. If your agent needs to interact
  with arbitrary widgets, keep Playwright MCP and use rev_stealth
  alongside it (they co-exist in `claude mcp` happily).
- No video / trace recording (those land in v1.4 if there is demand).

## See also

- [Quickstart](../tutorial/README.md)
- [Claude Code integration](../tutorial/05-claude-code.md)
