# Lane G fix-up R2 — Codex re-score request

R1 record: Opus 4.7-xhigh PASS 9.23 / Codex gpt-5.5-xhigh FAIL 8.78
(gap 0.45). The 5 deltas from the convergence record landed in commit
`cf086e6a` on `main`. Re-score Lane G as a whole (G.1 → G.8) plus the
fix-up R2 deltas with the same rubric used at R1.

Rubric: axis-weighted 1–10 scoring. For each axis report the score and
1–2 sentences of evidence. Final `Overall` = arithmetic mean (R1 used
the same convention; preserve it).

## Deltas landed in R2

1. `--output-format {human, text, json, yaml}` across all 11 top-level
   subcommands. `OutputFormat::Yaml` variant + `text` alias. Centralised
   `output_render::emit_ok` so the yaml branch lives in one place.
   `DoctorFormat`/`ConfigFormat` extended; config `dry_run_format_bridge`
   honours yaml. Clap-parse-failure detector mirrors runtime dispatch
   precedence (local-over-global, config/doctor reject local `human`).
2. `crates/stealth-cli/tests/idempotency_invariants.rs` — proptest
   50-iter × 3 properties (replay-invariance, payload-variance non-
   collision, key-variance non-collision).
3. `crates/stealth-cli/tests/auth_login_idempotency_audit.rs` — direct
   audit-line invariance: 2 invocations with same `--idempotency-key` →
   exactly 1 line in `audit.jsonl`. POSIX-sh fake rev-auth via
   `REV_AUTH_BIN`; AUP allowlist seeded so the test is fail-loud on
   regression (not silently skip).
4. `cli-surface-drift` CI gate. `scripts/cli_surface_inventory.py
   --check` re-walks the binary and diffs against the committed
   inventory, exits 1 on drift. New job in `.github/workflows/ci.yml`.
5. `.gitignore` honest-disclosure of `target/completions/` +
   `target/man/` as committed-derived-state with drift-gate justification.

## Acceptance (verifiable)

```bash
git fetch origin main
git checkout cf086e6a

cargo test --workspace --no-fail-fast 2>&1 | grep -E '^test result:' \
  | awk '{p+=$4; f+=$6; i+=$8} END {print p" "f" "i}'
# → 911 0 38

cargo test -p rev-stealth --lib parse_failure_format_detector
# → 16 passed

cargo test -p rev-stealth --test output_format_coverage
# → 6 passed (includes multi-format matrix + sub-sub-command coverage)

cargo test -p rev-stealth --test idempotency_invariants
# → 3 passed (50 cases each)

cargo test -p rev-stealth --test auth_login_idempotency_audit
# → 2 passed (no "skipping:" lines on stderr)

cargo build --release --bin rev-stealth
python3 scripts/cli_surface_inventory.py \
  --bin ./target/release/rev-stealth --check
# → cli-surface-drift: OK (no drift)
```

All four Codex-review reproducers from the 4 review rounds emit the
expected output:

```bash
./target/debug/rev-stealth --format yaml spider | head -1
# → yaml envelope (parse-failure)

./target/debug/rev-stealth --format json spider --output-format yaml | head -1
# → yaml envelope (local wins)

./target/debug/rev-stealth --format json spider --output-format text | head -1
# → "error: the following required arguments…" (clap human print)

REV_SCRAPING_HOME=/tmp/x \
  ./target/debug/rev-stealth --format yaml config init --dry-run | head -3
# → yaml envelope (config dry-run end-to-end)

./target/debug/rev-stealth --format json config --output-format human init --dry-run | head -1
# → JSON envelope (local `human` rejected on config; structured global wins)
```

## Axes (mirror R1 rubric)

Please score and justify each:

* Vision / scope
* Architecture coherence
* Code quality
* Reviewer-bait surface (anti-gameability)
* Operator UX
* Failure-mode coverage
* Test/proof discipline
* Build/CI rigor
* Docs / acceptance traceability
* Slice closure / honest disclosure

Then state Overall + Verdict (PASS ≥ 9.0 / FAIL otherwise).

Report ONLY the rubric. No re-review of the deltas (already reviewed
through 4 rounds; transcripts in `.agent/active/prompts/v1_3_g_fixup_r2_review*.md`).
