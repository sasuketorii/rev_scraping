# Review v1.3 Lane G fix-up R2 — round 3 (Codex deltas closure)

Round 2 verdict: **Request Changes** with 1 blocking finding plus 1 nit:

1. **Blocking** — `requested_structured_format` did not honour the
   local-over-global `--output-format` precedence that runtime dispatch
   applies. Concretely:
   `rev-stealth --format json spider --output-format yaml` emitted a
   JSON parse-error envelope, contradicting the
   `OutputFormatOverride::resolve` contract.
2. **Nit (non-blocking)** — stale doc comment on
   `config_cli.rs::dry_run_format_bridge` still said yaml collapses to
   JSON.

Both addressed in round 3.

---

## Round 3 fixes

### Blocking: parse-failure detector mirrors local-over-global precedence

- `crates/stealth-cli/src/lib.rs` — extracted
  `requested_structured_format` to a module-level fn (was inner-fn,
  untestable) and rewrote the body to walk argv in source order while
  recording **separate** `global` (`--format`) and `local`
  (`--output-format`) candidates. Returns `local.or(global)`, so any
  per-subcommand `--output-format` wins over the global `--format`,
  matching `commands/output_format.rs::OutputFormatOverride::resolve`.
- `cli_tests::parse_failure_format_detector` **(new sub-module)** —
  7 unit tests covering: none, global-json-split, global-yaml-combined,
  local-yaml-split, **local-wins-over-global** (Codex regression case),
  **inverse local-wins (yaml→json)**, and `text` falls through to
  human print (since `text` aliases `human`, not a structured format).

Verify (Codex's R2 round-2 reproducer):
```
./target/debug/rev-stealth --format json spider --output-format yaml 2>&1 | head -3
# → yaml envelope (doc_url / error / exit_code …)

./target/debug/rev-stealth --format yaml spider --output-format json 2>&1 | head -1
# → single-line JSON envelope (local --output-format json wins)
```

### Nit: refreshed `dry_run_format_bridge` doc comment

- `crates/stealth-cli/src/commands/config_cli.rs` — doc comment now
  records both the pre-R2 collapse and the R2 fix, so a future reader
  doesn't have to git-blame to understand the change.

---

## Files touched (round 3)

| File | Change |
|------|--------|
| `crates/stealth-cli/src/lib.rs` | extract+rewrite detector + 7 unit tests |
| `crates/stealth-cli/src/commands/config_cli.rs` | doc-comment refresh |

## Acceptance

| Gate | Result |
|------|--------|
| `cargo test --workspace --no-fail-fast` | 902 passed / 0 failed / 38 ignored |
| `cargo test -p rev-stealth --lib parse_failure_format_detector` | 7/7 |
| `cargo test -p rev-stealth --test auth_login_idempotency_audit` | 2/2 |
| `cargo test -p rev-stealth --test output_format_coverage` | 6/6 |
| `cargo test -p rev-stealth --test idempotency_invariants` | 3/3 |
| `cargo fmt --all -- --check` | clean |
| `cargo build --release --bin rev-stealth` | clean |
| `python3 scripts/cli_surface_inventory.py … --check` | `OK (no drift)` |

Workspace delta: 886 (R1 baseline) → 902 (+16: 9 R2 round-1 + 7 R2
round-3 detector unit tests). 0 failures across rounds.

## Verdict criteria

PASS if the new detector behaviour matches runtime dispatch precedence
on every reviewer reproducer + all gates above hold.

FAIL with axis breakdown otherwise.
