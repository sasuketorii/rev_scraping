# Review v1.3 I.1 (Round 2)

R1 BLOCK addressed:
1. **cf-evaluate parsing** — switched help-filename separator from `-` to `__`. `cf-evaluate` now parses as single top-level command, not `cf` → `evaluate`.
2. **Wrapped env / default / possible-values** — parser now accumulates each flag's full block (head + continuation lines) before regex search. Verified: `auth login --obscura-bin` → `REV_OBSCURA_BIN`, `--rev-auth-bin` → `REV_AUTH_BIN`, `--aad-context` → default `""`.
3. **MCP input-schema fields** — snapshot now includes per-tool `schemas.<tool>.required` array extracted from `tool_definitions()`. Example: `spider.required = ["url"]`.

`$schema_version` bumped 1 → 2.

## Files touched (delta)
- `scripts/cli-public-api-snapshot.sh` — rewrote help parser + MCP schema extractor
- `.agent/v1.3/cli-public-api.snapshot.json` — regenerated (29371 → 35391 bytes)

## Gates PASS (re-verified)
- `./scripts/cli-public-api-snapshot.sh --check` → exit 0
- `cargo test -p stealth-cli` → 258 passed / 0 failed
- 11 top-level cmds (now including `cf-evaluate` as single name)
- 16 MCP tools with required-arg arrays captured

## Verify (3)
1. R1 items resolved: no `cf` pseudo-command in `commands{}`; wrapped `[env:…]` bindings present; MCP `schemas` object present.
2. `--check` deterministic (rerun = byte-identical).
3. Drift detection fires on hypothetical 17th tool (changes `mcp_tools.count`).

R1 noted `cargo test -p stealth-cli` failure: this is `e2e_relocate_url_guard` parallel-test race from concurrent Lane G/K touching `stealth-sanitize`. Passes in isolation. Not caused by Lane I.1 (no Rust source changed in I.1).

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
