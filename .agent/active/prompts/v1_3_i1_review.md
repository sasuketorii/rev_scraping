# Review v1.3 I.1 — CLI public-API snapshot

## Files touched (additive only)
- `scripts/cli-public-api-snapshot.sh` (new, +180 LOC, executable)
- `.agent/v1.3/cli-public-api.snapshot.json` (new, 29 KB, machine-generated)

## Gates PASS
- `./scripts/cli-public-api-snapshot.sh --check` → exit 0 (no drift)
- `cargo test -p stealth-cli` → 258 passed / 0 failed
- snapshot stats: 11 top-level commands, 36 spider flags, 11 env vars, 16 MCP tools, 5 exit codes

## Verify (3)
1. Snapshot is machine-readable (`python3 -m json.tool` PASS) and byte-stable
   (`--check` mode diffs against committed file).
2. Public-surface coverage is exhaustive: every `rev-stealth <cmd> --help` and
   every `rev-stealth <cmd> <sub> --help` body is captured, including flag
   defaults, value enums, env-var bindings.
3. Drift detection actually fires: any byte change in the generated JSON
   produces exit-1 from `--check` with a unified diff in stderr.

## Out of scope
- The cargo-public-api Rust ABI diff (Lane I.2 — separate review).
- semver policy documentation (Lane I.3 — separate review).

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
