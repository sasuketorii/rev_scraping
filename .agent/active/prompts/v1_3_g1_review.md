# Review v1.3 G.1 — CLI public surface inventory

## Scope
Lane G sub-phase 1 of 8. Pure tooling + evidence; no production Rust code touched.
Goal: produce a machine-readable inventory of every `rev-stealth` sub-command,
flag, positional, and exit code, plus a naming-consistency review note
(`rev-stealth <noun> <verb>` shape).

## Files touched (new)
- `$REPO_ROOT/scripts/cli_surface_inventory.py` (executable, no deps beyond stdlib)
- `$REPO_ROOT/.agent/v1.3/cli-surface.json` (generated, 43 command nodes)
- `$REPO_ROOT/.agent/v1.3/cli-naming-lint.json` (5 informational lints, 0 violations)
- `$REPO_ROOT/.agent/v1.3/cli-surface-review.md` (decision log)

## Gates PASS
- `cargo test --workspace --no-fail-fast`: **776 PASS / 0 fail / 38 ignored** (baseline preserved; no Rust changed)
- `cargo clippy --workspace --all-targets -- -D warnings`: **clean**
- `python3 scripts/cli_surface_inventory.py --bin ./target/debug/rev-stealth`: **exit 0**, deterministic JSON output
- naming lint: 0 kebab violations on command names, 0 on long flags; 5 `info-flat-top-level` notes documented in review.md

## Verify (3)
1. The inventory script walks the whole tree (root → top-level → leaf) by
   invoking `rev-stealth [<path>] --help` and parses clap's stable Commands /
   Options / Arguments sections. Re-running it on the same binary produces a
   byte-identical `cli-surface.json` (deterministic, suitable for CI drift gate).
2. `cli-surface-review.md` documents why the 5 flat top-level commands
   (`doctor`, `spider`, `relocate`, `cf-evaluate`, `measure`) are intentionally
   kept without a `<verb>` layer, and confirms `config profile {list,create,
   switch,delete}` is the only legitimate 3-level path. No command-name or
   long-flag kebab-case violations exist.
3. Baseline preserved: no `Cargo.toml`, no `*.rs`, no `.github/workflows/*`
   changes; workspace test count stays at 776 PASS / 0 fail.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
