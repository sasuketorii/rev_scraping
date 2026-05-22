# Review v1.3 I.2 — cargo-public-api PR gate

## Files touched
- `.github/workflows/ci.yml` — added `cargo-public-api-diff` job (advisory, nightly toolchain, pinned `cargo-public-api 0.39.0`, runs against `origin/$BASE_REF` for 6 workspace member crates)

## Gates PASS
- yamllint clean (workflow parses).
- `cargo build -p stealth-cli` → clean (no Rust source touched in I.2).
- Job is marked `continue-on-error: true` for v1.3 (advisory only); hardens to blocking in v1.4 per docs/compat.md.

## Verify (3)
1. Job triggers on `pull_request` (inherited from workflow root).
2. Covers all public-surface crates: stealth-core, stealth-auth, stealth-sanitize, stealth-agent-contracts, stealth-parse, stealth-mcp. (stealth-cli is gated by the snapshot job in I.1; internal-only crates excluded by design.)
3. Diff output is grouped per-crate (`::group::`) so reviewers can scan one fold per crate in the PR's Actions log.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
