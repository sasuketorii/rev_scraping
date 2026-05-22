# rev-scraping-mcp (Hermes plugin)

Hermes adapter that wraps the [`stealth-mcp`](../../../crates/stealth-mcp)
Rust binary and re-exposes its 16 MCP tools as Hermes ctx callables.

## Install

The supported path is `rev-stealth hermes install` (see P7.3). The
subcommand copies this scaffold into `~/.hermes/plugins/rev-scraping-mcp/`
(override with `--prefix <dir>`).

Manual install (for development):

```bash
mkdir -p ~/.hermes/plugins/rev-scraping-mcp
cp -R dist/hermes/rev-scraping-mcp/* ~/.hermes/plugins/rev-scraping-mcp/
```

You must also have the `stealth-mcp` binary on `PATH` (build with
`cargo build --release -p stealth-mcp`). Override the binary location
with the `REV_SCRAPING_MCP_BIN` env var.

## What Hermes sees

The plugin's `register(ctx)` entrypoint:

1. Spawns `stealth-mcp` as a subprocess with a **whitelisted** env
   (see `plugin.yaml::env_allowlist` and `mcp_client.ENV_ALLOWLIST`).
2. Negotiates the MCP `2024-11-05` protocol via `initialize`.
3. Lists tools via `tools/list` and registers each as a Hermes
   ctx callable via `ctx.register_tool(...)`.
4. Forwards each invocation as a `tools/call` to the child.
5. Restarts the child on crash with exponential backoff
   (`1s, 2s, 4s, 8s, 16s`, capped at `16s`).

## Secret boundary

The adapter passes **only** an explicit allow-list of env vars to the
child. Host secrets like `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`GITHUB_TOKEN`, and AWS credentials are stripped before spawn.

Response payloads are passed through `schema_bridge.redact_response`,
which scrubs `Cookie` / `Set-Cookie` headers and common secret-shaped
fields before they reach the host model. This is defense in depth on
top of stealth-mcp's own redaction.

## Tests

```bash
cd dist/hermes/rev-scraping-mcp
python3 -m unittest discover tests -v
```

The smoke tests are pure stdlib (`unittest`) and mock the subprocess so
they do not require a built `stealth-mcp` binary.

## Files

| File | Purpose |
| --- | --- |
| `plugin.yaml` | Hermes plugin manifest. |
| `__init__.py` | `register(ctx)` entrypoint. |
| `mcp_client.py` | JSON-RPC 2.0 stdio client + env scrubbing. |
| `lifecycle.py` | Restart-with-backoff supervisor. |
| `tool_proxy.py` | Per-tool callable bridge. |
| `schema_bridge.py` | MCP -> Hermes schema translation + response redaction. |
| `tests/` | Stdlib-only smoke tests. |
