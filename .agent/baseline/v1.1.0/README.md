# v1.1.0 baseline snapshot

## Anchor

- Git SHA: 67665dbc01ecfda84fbd2a7d068548653d7d3607
- Captured: 2026-05-20T10:58:06Z
- Host: Darwin localhost 25.5.0 Darwin Kernel Version 25.5.0: Mon Apr 27 20:39:09 PDT 2026; root:xnu-12377.121.6~2/RELEASE_ARM64_T6020 arm64
- rustc: rustc 1.95.0 (59807616e 2026-04-14)
- cargo: cargo 1.95.0 (f2d3ce0bd 2026-03-21)

## Files

- test_count.txt: Per-suite workspace test result counts parsed from `cargo test --workspace --no-fail-fast`.
- tools_list.json: Raw MCP `tools/list` result object captured from `stealth-mcp`.
- policy_schema.toml: Copy of the v1.1.0 `templates/policy.toml` schema baseline, with sha256 sidecar.
- authorized_schema.toml: Sentinel baseline for the absent v1.1.0 authorized targets template, with sha256 sidecar.
- cli_help_snapshots/: Help output snapshots for workspace binaries and visible subcommands.
- cargo_metadata.json: `cargo metadata --no-deps --format-version 1` workspace package snapshot.

## Rule

> **All v1.2.0 sub-phases MUST guarantee diff-zero against this snapshot for the listed artifacts** unless the sub-phase is explicitly authorised in `.agent/active/v1.2.0_execplan_rev1.md` section A to modify a given file. Any unauthorised drift is a P0-regression and blocks GA.

## Verification

Run:

```bash
bash scripts/check_baseline_diff.sh
```

Exit code 0 means the currently implemented minimal baseline checks passed. Exit code 1 means at least one checked artifact drifted from the v1.1.0 baseline. Exit code 2 means the baseline directory is missing.

## Known gaps

- `authorized_schema.toml` is a sentinel because v1.1.0 shipped no `templates/authorized_targets.toml` and no other non-baseline `authorized*.toml` candidate was found.
- MCP tool count matched expectation: 15.
- Cargo metadata package count matched expectation: 11.
- Workspace test count matched expectation: 519 passed, 0 failed, 37 ignored.
