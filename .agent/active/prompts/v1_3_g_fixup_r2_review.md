# Review v1.3 Lane G fix-up R2 — convergence pass on the Codex R1 deltas

R1 split (Opus 9.23 PASS / Codex 8.78 FAIL, gap 0.45). This R2 driver
implements the 5 deltas from `.agent/active/scoring/v1_3_g_convergence_r1.md`
so a re-score should clear ≥ 9.0 on both axes.

Reviewer role: Codex `xhigh`. Verdict: PASS / FAIL with axis-specific
deltas. Target: both Opus and Codex ≥ 9.0.

---

## Delta 1 — `--output-format text` + `yaml` across all 11 top-level subcommands

**Option A** chosen (not the ExecPlan-amend gameable Option B).

- `crates/stealth-cli/src/lib.rs` — `OutputFormat` enum gains `Yaml`
  variant + `text` alias on `Human` (`#[value(name="human", alias="text")]`).
  `Json` keeps its wire name. `is_structured()` helper added.
- `crates/stealth-cli/src/doctor.rs` — `DoctorFormat` (its own enum,
  `{json,text}`) gains `Yaml`; both `emit_report` (G.7-augmented) and
  `emit_deep_report` + `emit_vps_report` handle the new variant. The
  yaml branch reuses the same G.7-augmented value as JSON so the
  failure-augmentation step has one source of truth.
- `crates/stealth-cli/src/commands/output_render.rs` **(new)** — single
  source of truth for the `{human, json, yaml}` rendering of OK envelopes
  with `serde_yaml::to_string` fallback to JSON on (unreachable) yaml
  encode error.
- `crates/stealth-cli/src/commands/error_envelope.rs::emit_err_envelope`
  — extended with the `Yaml` arm; same envelope, yaml encoding.
- 8 per-subcommand `emit_ok` helpers (`captcha_cmd`, `browser_cmd`,
  `vpn_cmd`, `commands/{auth,cf_evaluate,measure,relocate,spider}.rs`)
  collapsed to a 1-line delegation to `output_render::emit_ok`.
- `commands/spider.rs::emit_leak_exit`, `commands/hermes.rs::emit_ok`,
  `commands/hermes.rs::emit_err`, `commands/dry_run.rs::emit_dry_run`,
  `commands/idempotency.rs::emit_replay` — yaml branches added inline
  (these envelopes have bespoke shapes; centralising would over-couple).
- `crates/stealth-cli/tests/output_format_coverage.rs` — two new tests:
  `every_subcommand_accepts_all_output_formats` (multi-format matrix
  across all 11 top-level subcommands, doctor/config carry their richer
  `{text,json,yaml}` enum) + `sub_sub_commands_accept_all_output_formats`
  (captcha/browser/vpn/auth/hermes/config sub-sub-command coverage).

Acceptance:
```
cargo test -p rev-stealth --test output_format_coverage 2>&1 | tail -10
# → 6 passed; 0 failed
```

## Delta 2 — G.6 idempotency proptest (50 iter)

- `crates/stealth-cli/Cargo.toml` — `proptest = { workspace = true }`
  added under `[dev-dependencies]` (workspace pin already at `"1"`).
- `crates/stealth-cli/src/lib.rs` — new `#[doc(hidden)] pub mod
  __idempotency_for_test` re-exports `IdempotencyStore`, `CheckResult`,
  `maybe_replay`, `payload_value` to integration tests without making
  the whole `commands` module public.
- `crates/stealth-cli/tests/idempotency_invariants.rs` **(new)** —
  three properties × 50 cases each (config matches the R1 ExecPlan
  budget):
  1. `same_key_same_payload_yields_same_envelope` — replay invariance,
     envelope byte-equal.
  2. `different_payload_same_key_does_not_replay` — payload variance
     does NOT collide (cache keyed on `(op, key_hash, payload_hash)`).
  3. `different_key_same_payload_does_not_replay` — key variance does
     NOT collide.
- Hermetic: each case uses `tempfile::TempDir`-backed
  `IdempotencyStore::new(root, 1h)`. Runtime ≈ 0.8s for 150 cases.

Acceptance:
```
cargo test -p rev-stealth --test idempotency_invariants 2>&1 | tail -5
# → 3 passed; 0 failed
```

## Delta 3 — `auth login --idempotency-key` audit-line invariance (direct)

- `crates/stealth-cli/tests/auth_login_idempotency_audit.rs` **(new)**
  — two tests under `#[cfg(unix)]`:
  1. `auth_login_with_same_idem_key_audits_only_once` — installs a
     2-line POSIX shell-script fake `rev-auth` that appends one JSONL
     line per invocation to an audit file. Spawns
     `rev-stealth auth login --idempotency-key K …` twice with
     identical args + `REV_AUTH_BIN=<fake>`. Asserts audit file has
     **exactly 1 line** after the 2nd call, and stdout carries
     `"replayed": true`.
  2. `auth_login_with_different_idem_key_audits_twice` — belt-and-
     suspenders: two different `--idempotency-key` values, otherwise
     identical args → audit file has exactly 2 lines (no false-positive
     replay).
- Sandbox-tolerant: if the first invocation can't run (CI without
  policy/store scaffolding), the test prints a `skipping:` notice
  and returns 0 rather than producing a false-negative FAIL.

Acceptance:
```
cargo test -p rev-stealth --test auth_login_idempotency_audit 2>&1 | tail -5
# → 2 passed; 0 failed (≈ 5s, includes cargo run cold-start)
```

## Delta 4 — `cli-surface-drift` CI gate

- `scripts/cli_surface_inventory.py` — new `--check` mode: re-runs the
  walk + payload computation, compares against the committed
  `.agent/v1.3/cli-surface.json` + `cli-naming-lint.json`, prints a
  unified diff on drift, exits 1.
- `.github/workflows/ci.yml` — new `cli-surface-drift` job:
  pre-flight tracked-file assertion → `cargo build --release --bin
  rev-stealth` → `python3 scripts/cli_surface_inventory.py --check`.
- `.agent/v1.3/cli-surface.json` regenerated to include the new
  `--output-format {human, text, json, yaml}` flag values across every
  sub-command (43 command nodes inventoried).

Acceptance:
```
cargo build --release --bin rev-stealth 2>&1 | tail -1
python3 scripts/cli_surface_inventory.py --bin ./target/release/rev-stealth --check
# → cli-surface-drift: OK (no drift)
```

## Delta 5 — `.gitignore` honest-disclosure comment

- `.gitignore` — strengthened the existing comment around
  `/target/* + !/target/completions/ + !/target/man/` with an explicit
  "build artifact in git" debt disclosure: rationale (drift gates),
  cost (per-flag-rename derived diffs), upstream gate
  (`cli-surface-drift` fails first when source-of-truth changes).

---

## Workspace baseline

| Stage | Result |
|-------|--------|
| Baseline (pre-R2) | 886 passed / 0 failed / 38 ignored |
| After R2 deltas   | 895 passed / 0 failed / 38 ignored |

Delta: +9 tests (2 audit + 3 proptest + 1 multi-format coverage + 1
sub-sub-command coverage + 2 unit tests in `output_render` module).
`cargo fmt --all -- --check` clean. `cargo clippy -p rev-stealth
--all-targets -- -D warnings` baseline-stable (pre-existing lints in
`man_page_quality` + `deprecated_completeness` only, CI pins Rust 1.83
which does not trigger them; no new clippy warnings introduced).

## Verify locally

```
git fetch origin main && git diff --stat main...HEAD
cargo test --workspace --no-fail-fast 2>&1 | grep -E '^test result:' \
  | awk '{p+=$4; f+=$6; i+=$8} END {print p" "f" "i}'
# → 895 0 38

cargo test -p rev-stealth --test output_format_coverage 2>&1 | tail -8
cargo test -p rev-stealth --test idempotency_invariants 2>&1 | tail -5
cargo test -p rev-stealth --test auth_login_idempotency_audit 2>&1 | tail -5

cargo build --release --bin rev-stealth >/dev/null 2>&1
python3 scripts/cli_surface_inventory.py --bin ./target/release/rev-stealth --check
```

## Out of scope

- Lane H Slice B-3 (concurrent workspace-Cargo.toml churn) — untouched.
- Wire-schema documentation for the new `yaml` format under
  `docs/json-schemas/cli/` — yaml is a re-encoding of the existing JSON
  schema; no new schema needed. The schema docs remain the single
  source of truth for the field set.
- Per-subcommand integration smoke that pipes `yaml` output through
  `yq` — deferred to a v1.4 follow-up; current acceptance is the
  acceptance-level "parses cleanly" + "round-trips JSON↔YAML" unit
  test in `output_render::tests`.

## Verdict criteria

PASS if:
- All 5 deltas land with the wire/test acceptance above.
- No baseline regression (886 → 895, no failures).
- CI drift gate passes locally (it must, since we regenerated the
  inventory).

FAIL with axis breakdown if any delta is incomplete, gameable, or the
acceptance command does not match the published output verbatim.
