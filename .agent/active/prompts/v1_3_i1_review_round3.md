# Review v1.3 I.1 (Round 3)

R2 BLOCK addressed:

1. **MCP required arrays inaccurate** — `extract_required()` matched the FIRST `"required"` in a 4000-char window, leaking into the next tool. Rewrote with input_schema brace-depth tracking: bounds search to `input_schema: json!({…})` of *this* tool, walks JSON char-by-char, records `"required"` only at depth=1 (immediate root child). Verified corrections:
   - `auth_list` now `[]` (was `['profile']`)
   - `doctor` now `[]` (was `['domain']`)
   - `recipe_export` now `[]` (was `['payload']`)
   - `recipe_list` now `[]` (was `['domain']`)
   - `recipe_propose_endpoint` still `[domain, endpoint]` (sub-required `[purpose, path]` not leaked)
   - `vpn_rotate` correctly `[]`

2. **`--check` reliability** — switched comparison base from working-tree (`git diff --quiet`) to HEAD (`git diff HEAD --quiet`). Untracked-file case explicit: "not yet tracked" note, no spurious exit-1.

## Files touched (delta)
- `scripts/cli-public-api-snapshot.sh` — `extract_required` rewrite + `--check` hardening
- `.agent/v1.3/cli-public-api.snapshot.json` — regenerated (4 tools' required arrays corrected)

## Gates PASS
- `./scripts/cli-public-api-snapshot.sh --check` → exit 0 when snapshot committed
- All 16 tools cross-checked against `tool_definitions()` source
- `cargo test -p stealth-cli` → 258 passed / 0 failed

## Verify (3)
1. `recipe_propose_endpoint` requires `[domain, endpoint]`, not nested `[purpose, path]` — depth-1 filter works.
2. `vpn_rotate` correctly `required=[]`.
3. `--check` deterministic once snapshot is on HEAD.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
