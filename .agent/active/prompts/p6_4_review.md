# Review P6.4 — config history / rollback / gc

file: crates/stealth-cli/src/commands/config_cli.rs (additive)

## Slice
- ConfigAction::History | Rollback | Gc (new) with HistoryArgs / RollbackArgs / GcArgs
- run_history / run_rollback / run_gc dispatched from `run()`
- All three route through FsConfigWriter (ConfigWriter trait); rollback uses write_with_backup so the displaced current becomes a fresh .bak
- resolve_bak() rejects `/`, `\`, `..` segments and any name not starting with `<filename>.bak.` (path-traversal guard)
- WriteTarget reused (policy default; authorized supported); HistoryEntry / RollbackOutcome / GcOutcome Serialize for JSON
- No new deps; SPDX preserved L1

## Tests added (5)
1. history_lists_in_desc — 4 writes → 3 baks, newest first (.bak of v2), oldest last (v0)
2. rollback_restores — restore oldest .bak; current matches its content
3. rollback_makes_current_into_bak — displaced current is preserved as a new .bak (via ConfigWriter)
4. rollback_rejects_path_traversal — `../etc/passwd` returns exit 2, current untouched
5. gc_keeps_latest_n — 5 baks, keep=2 → 2 remain (newest), older deleted

## Gates PASS
- cargo check --workspace clean
- cargo test --workspace --no-fail-fast: 646 PASS / 0 FAIL (641 → 646)
- cargo clippy -p stealth-cli --all-targets -- -D warnings clean
- SPDX preserved; ConfigWriter trait used (no raw fs::rename for backups)
- Secret redaction surfaces untouched
- CLI smoke: `rev-stealth config --help` lists `history`, `rollback`, `gc`
- baseline diff: no template / package-count drift; tools_list.json untouched (P9.1 will bump)

## REV_HARNESS_DELEGATION_METRIC
REV_HARNESS_DELEGATION_METRIC sub_phase=P6.4 tests_added=5 workspace_pass=646 clippy=clean configwriter=enforced path_traversal_rejected=true

verdict: LGTM or BLOCK: <reason>
