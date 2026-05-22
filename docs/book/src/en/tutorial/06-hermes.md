# Step 6 — Hermes orchestrator (stub OK)

[Hermes](https://github.com/sasuketorii/hermes) is the upstream agent
orchestrator that `rev_scraping` integrates with most tightly. This
chapter shows the wire format even if you do not have a Hermes instance
running.

## Register rev-stealth as a Hermes MCP

In your Hermes project config (`hermes.toml`):

```toml
[mcp.rev-stealth]
command = "rev-stealth"
args = ["mcp"]
env = { RUST_LOG = "info" }
```

## Sample workflow

```toml
[[workflow.steps]]
mcp = "rev-stealth"
tool = "spider"
input = { url = "https://example.com" }
# `idempotency_key` is a Hermes-level field (folded into retry bookkeeping
# by Hermes itself). It is not part of the spider tool's inputSchema.
idempotency_key = "{{ workflow.id }}-step-1"

[[workflow.steps]]
mcp = "rev-stealth"
tool = "vpn_rotate"
# vpn_rotate input schema = { provider?, strategy?, region?, reason? } with
# additionalProperties:false. Pass region / reason, not country.
input = { region = "JP", reason = "hermes-step" }
on_error = "retry"
```

## Stub path (no Hermes installed)

You can simulate the same dispatch with the `rev-stealth mcp call` helper:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"spider","arguments":{"url":"https://example.com"}}}' \
  | rev-stealth mcp
```

That's the exact byte sequence Hermes would send.

## Smoke test

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | rev-stealth mcp \
  | jq '.result.tools | length'
# expected: 16
```
