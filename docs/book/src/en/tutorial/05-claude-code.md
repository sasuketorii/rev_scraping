# Step 5 — Claude Code integration (5 minutes)

This is the single most important page in the book. If you only read one
chapter, read this one.

## Register rev-stealth as an MCP server

```sh
claude mcp add rev-stealth -- rev-stealth mcp
```

That's the whole installation. `rev-stealth mcp` speaks line-delimited
JSON-RPC 2.0 over stdin/stdout (see
[`docs/MCP_REFERENCE.md`](https://github.com/sasuketorii/rev_scraping/blob/main/docs/MCP_REFERENCE.md)
for the protocol).

## Verify Claude can see the 16 tools

In a fresh Claude Code session:

> List every rev-stealth MCP tool by name.

Claude should enumerate all 16 (`spider`, `relocate`, `cf_evaluate`,
`doctor`, …). If only a subset is visible, run `rev-stealth doctor` and
check `claude mcp list`.

## Drive a real scrape from Claude

Paste this into a Claude Code session:

> Use the rev_stealth MCP to spider https://example.com and tell me the
> page title.

Claude will call the `spider` tool, receive a structured JSON response
matching `docs/json-schemas/spider.output.json`, and answer in natural
language. Because every tool has an `outputSchema`, Claude does not need
to guess at the response shape.

## Error envelope contract

Every failure surfaces in this shape (matches
[`I.7` `ErrorEnvelope`](../compat.md)):

```json
{
  "kind": "RateLimit",
  "message": "Server returned 429",
  "hint": "Retry after the specified interval",
  "retry_after_ms": 30000,
  "doc_url": "https://sasuketorii.github.io/rev_scraping/en/errors/RateLimit.html"
}
```

Claude can read `kind` and `doc_url`, follow the URL, and pick a fix
strategy without further user input.

## Smoke test

```sh
claude mcp list | grep -q rev-stealth
# expected: exit 0
```

## What to do next

- [Step 6 — Hermes orchestrator](./06-hermes.md) to chain `rev-stealth` with
  other MCPs in a Hermes workflow.
- [MCP Tools Cookbook](../tools/README.md) for per-tool JSON-RPC examples.
