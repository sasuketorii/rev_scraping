# Review P7.1 — Hermes adapter scaffold (rev-scraping-mcp)

## Scope
Lane D / P7.1. Create a Hermes plugin scaffold under
`dist/hermes/rev-scraping-mcp/` that wraps the existing `stealth-mcp`
Rust binary as a Hermes ctx plugin.

## Files touched
- `dist/hermes/rev-scraping-mcp/plugin.yaml` (new)
- `dist/hermes/rev-scraping-mcp/__init__.py` (new — `register(ctx)` entrypoint)
- `dist/hermes/rev-scraping-mcp/mcp_client.py` (new — JSON-RPC 2.0 stdio client + env scrubbing)
- `dist/hermes/rev-scraping-mcp/lifecycle.py` (new — restart-with-backoff supervisor)
- `dist/hermes/rev-scraping-mcp/tool_proxy.py` (new — per-tool callable bridge)
- `dist/hermes/rev-scraping-mcp/schema_bridge.py` (new — MCP→Hermes schema + redaction; used by P7.2 too)
- `dist/hermes/rev-scraping-mcp/README.md` (new — install + secret-boundary docs)
- `.gitignore` (added `!/dist/hermes` exception, parallel to the existing `!/dist/systemd`)

## Gates PASS
- `cargo build -p stealth-cli`: clean (no Rust changes in P7.1)
- `cargo clippy --workspace --all-targets -- -D warnings`: clean
- `cargo test --workspace`: 673 PASS / 0 fail / 38 ignored (baseline 663 + 10 P7.3 tests; P7.1 itself adds no Rust tests)
- `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests`: 15 PASS / 0 fail (P7.2 tests cover the P7.1 modules)

## Verify (3 claims)
1. The MCP child is spawned with only the documented env allowlist
   (`REV_SCRAPING_*`, `VPN_*_FILE`, `PATH`, `HOME`, `LANG`, `LC_ALL`). Host
   secrets such as `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GITHUB_TOKEN`, and
   AWS creds are dropped before `subprocess.Popen` runs
   (`mcp_client.filter_env`, plus an explicit `ENV_DENYLIST` defensive guard).
2. Restart-with-backoff follows exponential 1/2/4/8/16s capped at 16s
   (`lifecycle.BACKOFF_SCHEDULE_S` + `SupervisedClient.backoff_seconds`),
   and a `MAX_RESTART_ATTEMPTS=32` hard cap surfaces persistent failure
   instead of looping forever.
3. The `.gitignore` change preserves the existing `/dist/*` global exclusion
   and only un-ignores `/dist/hermes` (mirroring the `!/dist/systemd` policy
   from P10.5). No nested package dist trees are accidentally exposed.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
