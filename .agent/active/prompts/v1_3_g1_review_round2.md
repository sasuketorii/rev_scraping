# Review v1.3 G.1 round 2

## Round-1 BLOCK addressed
1. **Exit-code inventory now machine-readable.** Schema 1.0 → 1.1.
   Top-level JSON gains `exit_code_dictionary` (6 entries from
   `stealth_core::ExitCode`: 0/1/2/3/4/7) and `exit_code_coverage`
   (`{total_commands:43, mapped_commands:43, missing:[]}`).
   Every node now carries `exit_codes: list[int]`
   (e.g. `doctor:[0,1,7]`, `vpn:[0,1,2,3,7]`, `spider:[0,1,2,3,4,7]`).
   Script warns to stderr when `missing` is non-empty (drift gate hook).
2. **review.md counts corrected**: 11 top-level / 36 leaf / 43 nodes
   (was 12 / 19 / 43). Top-level table has 11 rows. Drift-gate section
   references `exit_code_coverage`.

## Files
- `scripts/cli_surface_inventory.py` (+EXIT_CODES table,
   +COMMAND_EXIT_CODES mapping, +coverage check)
- `.agent/v1.3/cli-surface.json` (regenerated)
- `.agent/v1.3/cli-naming-lint.json` (regenerated)
- `.agent/v1.3/cli-surface-review.md` (counts + drift text)

## Gates PASS
- `cargo test --workspace --no-fail-fast`: 781 PASS / 0 fail.
  Baseline grew 776 → 781 from parallel lanes H/I/K landing during
  G.1 review; G.1 itself adds no Rust.
- `cargo clippy --workspace -- -D warnings`: clean.
  (`--all-targets` exposes pre-existing Lane K regressions — out of
  Lane G scope.)
- Determinism: `diff -q` byte-identical across re-runs.
- Exit-code coverage: 43/43 mapped.

## Verify (3)
1. `.agent/v1.3/cli-surface.json` has top-level
   `exit_code_dictionary` (6 entries) and `exit_code_coverage`;
   every node under `root.subcommands.*` has a non-empty
   `exit_codes` array.
2. `.agent/v1.3/cli-surface-review.md` summary reads
   `11 top-level / 36 leaf / 43 nodes`; shape table has 11 rows.
3. Re-running the script produces byte-identical JSON. No `.rs` /
   `Cargo.toml` edits in G.1; 776 → 781 delta is from parallel lanes
   in `git diff --stat HEAD`.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
