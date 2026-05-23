# Review v1.3 Lane G.7 — round 2 (round-1 findings addressed)

## Round-1 blocking findings → fixed

1. **`config get` missed G.7** ([config_cli.rs:1008]($REPO_ROOT/crates/stealth-cli/src/commands/config_cli.rs))
   Augmented the JSON not-found payload (and `emit_set_error` / `emit_edit_error`) with `augment_with_g7_fields(NotFound, ...)`.
   Verify: `rev-stealth config --output-format json get __missing__` → carries `kind`, `message`, `hint`, `doc_url`.

2. **clap parse failures bypassed G.7** ([lib.rs:406]($REPO_ROOT/crates/stealth-cli/src/lib.rs))
   Replaced `Cli::parse()` with `try_parse()`. On `--help` / `--version` exits 0 with clap's stdout. On real parse error and `--format json` requested (argv-peek), emit the canonical envelope at `operation: "cli.parse"` exit 2. Otherwise fall back to clap's human render.
   Verify: `rev-stealth --format json measure` → JSON envelope with `kind`, `message`, `doc_url`.

3. **`doctor` non-zero exit lacked G.7** ([doctor.rs:592]($REPO_ROOT/crates/stealth-cli/src/doctor.rs))
   `emit_report` now serialises to `Value`, calls `augment_with_g7_fields(VpnLeak, ...)` when `!report.all_pass()`, then prints. Pass-path unchanged.
   Verify: `rev-stealth doctor --skip-exit-ip` (when failing) → carries `kind:"vpn_leak"`, `doc_url`, `hint`.

4. **`private_interfaces` warning on hidden re-export** ([lib.rs]($REPO_ROOT/crates/stealth-cli/src/lib.rs))
   Restricted `__error_envelope_for_test` to only `CliErrorKind` + `DOC_URL_BASE` (the public-safe surface). The `emit_err_envelope` / `augment_with_g7_fields` helpers stay reachable only internally via `crate::commands::error_envelope`.

## New integration tests
Added two tests covering the round-1 surfaces:
- `config_get_missing_key_emits_canonical_envelope` — accepts kind `not_found` or `internal` (heuristic-tolerant).
- `clap_parse_failure_emits_canonical_envelope` — pins `operation:"cli.parse"`, `exit_code:2`.

Updated stdout parser to handle multi-line pretty JSON (config emits pretty).

## Gates
- `cargo test --workspace --no-fail-fast` → **873 passed / 0 failed / 38 ignored** (858 baseline + 8 integration + 7 unit).
- `cargo test -p rev-stealth --test error_template_uniform` → **8/8 PASS**.
- `cargo test -p rev-stealth --test cli_output_schema_validation` → **20/20 PASS** (no regression).

## Residual scope
- Other config emit paths (e.g. line 908 `read_errors` items list) are nested step results inside an outer `{ok:false, ...}` envelope at the operation level — the outer envelope still goes through `emit_set_error` / similar, which now carry G.7 fields. Per-row `error` strings inside list payloads are deliberately left as-is (they would garble the row schema).
- `spider.rs::1089` and `spider.rs::1524` are nested step results inside the spider output `result.steps[]`, not top-level envelopes; out of G.7 scope.
- Schema declarations for the 5 G.7 fields deferred (Lane H Slice B-3 window).
- `stealth-mcp` JSON-RPC parity deferred.

## Constraints honored
- No `Cargo.toml` / lockfile changes.
- `unsafe_code = forbid` preserved.
- No `private_interfaces` warning.
- Heuristic kind classification is reversible: any future callsite can pass an explicit `CliErrorKind` via `emit_err_envelope`.

LGTM or list residual blocking findings.
