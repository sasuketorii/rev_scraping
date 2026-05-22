# Review v1.3 I.2 (Round 2)

R1 BLOCK addressed:

1. **`cargo public-api diff` syntax was invalid for pinned 0.39.0.** 0.39+ rejects a bare ref ("Error: Invalid published crate version syntax: origin/main") — it requires a commit RANGE `<base>..<head>`. Switched to:
   ```
   BASE_SHA=$(git rev-parse "origin/$BASE_REF")
   HEAD_SHA=$(git rev-parse HEAD)
   cargo public-api --package "$crate" diff "$BASE_SHA..$HEAD_SHA"
   ```
   Added explicit `git fetch --no-tags --depth=200 origin "$BASE_REF"` step so the base SHA is reachable in shallow CI checkouts.

2. **`|| true` masking removed.** Install step now hard-fails on cargo-install error (no fallback). Diff step no longer wraps the per-crate invocation in `|| echo`. Job-level `continue-on-error: true` remains as the documented advisory mechanism for v1.3; that flag will be flipped to `false` in v1.4 per docs/compat.md.

3. Job is gated by `if: github.event_name == 'pull_request'` for the diff (push-to-main doesn't have a meaningful base).

## Files touched (delta)
- `.github/workflows/ci.yml` — `cargo-public-api-diff` job step rewrite (lines ~497-530)

## Gates PASS
- yamllint: workflow valid
- `cargo public-api --help` (0.39.0): `diff <COMMITS>` confirmed as the correct syntax
- All 6 covered crates have library targets (stealth-core, -auth, -sanitize, -agent-contracts, -parse, -mcp)

## Verify (3)
1. `git rev-parse "origin/$BASE_REF"` is invoked AFTER `git fetch`, so shallow-clone CI runners get a reachable SHA.
2. No `|| true` / `set +e` / error-masking remains in either the install or diff step. Job-level `continue-on-error: true` is the SINGLE advisory toggle.
3. Push-to-main runs skip the diff step (no base ref) — they don't false-positive without a comparison target.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
