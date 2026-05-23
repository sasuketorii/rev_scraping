# Review v1.3 Lane G fix-up R2 — round 2 (Codex R1 deltas closure)

Round 1 verdict: **FAIL** with 3 axis-specific findings:

1. **Delta 3** — `auth_login_with_same_idem_key_audits_only_once` silently
   skipped under sandboxed CI because AUP allowlist scaffolding was missing.
2. **Delta 1** — `commands/config_cli.rs::dry_run_format_bridge` collapsed
   `ConfigFormat::Yaml` → `OutputFormat::Json`, so
   `rev-stealth config --output-format yaml init --dry-run` emitted JSON.
3. **Delta 1** — `lib.rs::run_async` clap-parse-failure heuristic only
   detected `--format json`, so `rev-stealth --format yaml spider` emitted
   clap human text instead of a yaml error envelope.

All three are now fixed.

---

## Round 2 fixes

### Finding #1 — Delta 3: AUP scaffolding seeded + silent-skip removed

- `crates/stealth-cli/tests/auth_login_idempotency_audit.rs::seed_authorized_toml`
  **(new helper)** — writes `$HOME/.rev_scraping/authorized.toml` with a
  schema-valid permissive entry for `example.test` + `auth_allowed = true`
  + a far-future `expires_at`. Both tests now call it from
  `run_auth_login` so every spawn clears the AUP gate deterministically.
- Both `if exit1 != 0 { eprintln!("skipping…"); return; }` early-return
  branches replaced with `assert_eq!(exit1, 0, …)` so a future regression
  (or sandbox stripping) FAILs the test instead of silently greening.
- `auth_login_with_different_idem_key_audits_twice` got the same
  treatment for symmetry.

Verify:
```
cargo test -p rev-stealth --test auth_login_idempotency_audit -- --nocapture 2>&1 | tail -5
# → 2 passed; 0 failed
```

(No "skipping" lines surface on stderr.)

### Finding #2 — Delta 1: config-mutate dry-run honours yaml

- `crates/stealth-cli/src/commands/config_cli.rs::dry_run_format_bridge`
  no longer collapses `ConfigFormat::Yaml` to `OutputFormat::Json`. The
  bridge now returns `OutputFormat::Yaml`, which the
  `commands/dry_run.rs::emit_dry_run` yaml branch (added in round 1)
  picks up end-to-end.

Verify (reviewer's own reproducer):
```
REV_SCRAPING_HOME=/private/tmp/rev-review-config-yaml-dryrun \
  ./target/debug/rev-stealth config --output-format yaml init --dry-run
```
emits (excerpt):
```yaml
ok: true
operation: config.init
result:
  dry_run: true
  idempotency_key: null
  plan:
  - resolve REV_SCRAPING_HOME base directory
  - …
```

### Finding #3 — Delta 1: clap-parse-failure yaml envelope

- `crates/stealth-cli/src/lib.rs::run_async` parse-failure heuristic
  refactored. New nested fn `requested_structured_format` walks argv for
  `(--format|--output-format) (json|yaml)` (split + combined `=` forms)
  and returns `Some("json")` / `Some("yaml")` / `None`. The match arm
  routes to `OutputFormat::Json`, `OutputFormat::Yaml`, or clap's human
  print respectively.

Verify:
```
./target/debug/rev-stealth --format yaml spider 2>&1 | head -3
# → yaml envelope: doc_url / error / exit_code / kind / message / ok / operation / …

./target/debug/rev-stealth --format json spider 2>&1 | head -1
# → single-line JSON envelope (unchanged)
```

---

## Files touched (round 2)

| File | Change |
|------|--------|
| `crates/stealth-cli/src/commands/config_cli.rs` | bridge no longer collapses Yaml |
| `crates/stealth-cli/src/lib.rs` | parse-failure heuristic gains yaml branch |
| `crates/stealth-cli/tests/auth_login_idempotency_audit.rs` | seed allowlist + fail-loud asserts |

## Acceptance

| Gate | Result |
|------|--------|
| `cargo test --workspace --no-fail-fast` | 895 passed / 0 failed / 38 ignored |
| `cargo test -p rev-stealth --test auth_login_idempotency_audit` | 2/2 |
| `cargo test -p rev-stealth --test output_format_coverage` | 6/6 |
| `cargo test -p rev-stealth --test idempotency_invariants` | 3/3 |
| `cargo fmt --all -- --check` | clean |
| `cargo build --release --bin rev-stealth` | clean |
| `python3 scripts/cli_surface_inventory.py … --check` | `OK (no drift)` |

## Out of scope (unchanged from round 1)

- Lane H Slice B-3 workspace edits.
- Per-yaml JSON-schema docs (yaml is a re-encoding of the same field set).
- `cargo clippy -D warnings` on the local Rust 1.95 toolchain hits
  pre-existing lints in `man_page_quality` + `deprecated_completeness`
  that CI (pinned to 1.83) does not trigger; baseline-stable, no R2
  regression.
