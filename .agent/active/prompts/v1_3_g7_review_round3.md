# Review v1.3 Lane G.7 — round 3 (round-2 findings addressed)

## Round-2 blocking findings → fixed

1. **`--format=json` (combined) bypassed the G.7 clap-parse heuristic** ([lib.rs]($REPO_ROOT/crates/stealth-cli/src/lib.rs))
   Extended the argv-peek to match both forms:
   - split: `--format json` / `--output-format json`
   - combined: `--format=json` / `--output-format=json`
   New test `clap_parse_failure_combined_arg_form_emits_canonical_envelope` pins the combined form.

2. **Global `--format json` didn't propagate into `config` subtree** ([config_cli.rs::run]($REPO_ROOT/crates/stealth-cli/src/commands/config_cli.rs:618))
   Added JSON-promotion at the dispatch entry: when global is `Json` and local `ConfigFormat` is at its default `Text`, promote to `Json`. Asymmetric on purpose — caller can still pass `--output-format text` explicitly for forced human output under a JSON-global session.
   New test `config_get_missing_key_promotes_global_json` pins the behavior.

## Gates
- `cargo test --workspace --no-fail-fast` → **875 passed / 0 failed / 38 ignored** (858 baseline + 10 integration + 7 unit).
- `cargo test -p rev-stealth --test error_template_uniform` → **10/10 PASS**.
- `cargo test -p rev-stealth --test cli_output_schema_validation` → **20/20 PASS** (no regression).

## Spot-check (manual)
```
$ rev-stealth --format=json measure
{"doc_url":".../Internal.md","error":"...","exit_code":2,"kind":"internal","message":"...","operation":"cli.parse",...}

$ rev-stealth --format json config get __missing__
{"doc_url":".../NotFound.md","error":"not_found","hint":"...","key":"__missing__","kind":"not_found","message":"key not found: __missing__",...}
```

## Surfaces covered by G.7 now
| surface | path | trigger | test |
|---|---|---|---|
| cf-evaluate | `emit_err` | invalid URL | integration |
| measure | `emit_err` | invalid URL | integration |
| spider | `emit_err`, `emit_leak_exit` | invalid URL, leak | integration + augment |
| relocate | `emit_err` | invalid URL | integration |
| auth | `emit_err` | every error path | delegated |
| captcha | `emit_error` | every error path | delegated |
| browser | `emit_error` | every error path | delegated |
| vpn | `emit_error` | every error path | delegated |
| hermes | `emit_err` | every error path (`error_kind` field) | delegated |
| config | `run_get`, `emit_set_error`, `emit_edit_error` | not-found / write fail | integration |
| doctor | `emit_report` | `!report.all_pass()` | augment in place |
| **clap parse** | `Cli::try_parse` wrapper in `run_async` | any parse error w/ `--format json` | integration (split + combined) |

## Residual non-blocking
- `spider.rs::1089`, `spider.rs::1524`, `config_cli.rs::908` — nested
  step-result `error` fields inside list payloads (not top-level
  envelopes). Out of G.7 surface contract.
- Schema declarations for the 5 G.7 fields — additive, deferred to
  post-Lane-H window so we don't have to relax `additionalProperties:
  false` during the parallel mass-rename slice.
- `stealth-mcp` JSON-RPC parity — deferred.
- `clap-mangen` man-page auto-gen — G.8.

## Constraints honored
- No `Cargo.toml` / lockfile churn (verified `git diff --name-only` is
  clean of `Cargo.*`).
- `unsafe_code = forbid` preserved.
- No new clippy / rustc warnings beyond the pre-existing G.6 dead-code
  warnings.
- `private_interfaces` clean.

LGTM or list residual blocking findings.
