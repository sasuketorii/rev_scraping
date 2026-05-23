# Review v1.3 Lane G fix-up R2 — round 4 (closure on the parse-failure detector)

Round 3 verdict: **Request Changes**. Sole remaining blocker:

> The detector only records local `--output-format` when the value is
> `json` or `yaml`; local `text` / `human` is discarded, so a structured
> global falls through incorrectly.

Reproducer:
```
./target/debug/rev-stealth --format json spider --output-format text 2>&1 | head -1
# (round 3) Actual: JSON envelope
# (expected) Actual: clap human text line
```

## Round 4 fix — three-state detector

- `crates/stealth-cli/src/lib.rs::requested_structured_format`
  refactored to a **three-state** classification:
  * `Some(Some("json"|"yaml"))` — structured (emit envelope).
  * `Some(None)`               — recognised human-aliased value
    (`human` / `text`). Records *presence* of the flag so a local
    human override can suppress a structured global; carries no wire
    format (caller falls through to clap's human print).
  * `None`                     — unrecognised value, ignored.
- Internal `global` and `local` records both carry `Option<Option<&str>>`;
  the final answer is `local.or(global).and_then(|c| c)`, which yields
  `None` when either:
  * no `--format`/`--output-format` was seen, OR
  * the effective override was a human alias (`human`/`text`).

Verify (Codex's R3 round-3 reproducer):
```
./target/debug/rev-stealth --format json spider --output-format text 2>&1 | head -1
# → error: the following required arguments were not provided:
```
(human text, not a JSON envelope — matches the successful-dispatch path).

## New regression tests (lib.rs `parse_failure_format_detector`)

5 new cases on top of the round-3 set of 7:
- `local_output_format_text_suppresses_global_format_json`
- `local_output_format_human_suppresses_global_format_yaml`
- `local_output_format_human_combined_suppresses_global_combined`
  (covers `--format=json … --output-format=human` syntax)
- `local_structured_wins_over_global_human` (symmetric:
  `--format human … --output-format json` → `Some("json")`)
- `unrecognised_format_value_is_ignored`

Plus renamed `unknown_format_value_falls_through_to_none` →
`global_text_falls_through_to_none` for clarity. Total detector unit
tests: **12** (all pass).

## Acceptance

| Gate | Result |
|------|--------|
| `cargo test -p rev-stealth --lib parse_failure_format_detector` | 12/12 |
| `cargo test --workspace --no-fail-fast` | 907 passed / 0 failed / 38 ignored |
| `cargo fmt --all -- --check` | clean |
| `cargo build --release --bin rev-stealth` | clean |
| `python3 scripts/cli_surface_inventory.py … --check` | `OK (no drift)` |

Workspace delta vs baseline: 886 → 907 (+21: 9 from R2 round-1 + 7
round-3 + 5 round-4 detector tests).

## All R2 fixup reproducers (one shot)

```
./target/debug/rev-stealth --format yaml spider 2>&1 | head -1
# → yaml envelope (doc_url …)

./target/debug/rev-stealth --format json spider --output-format yaml 2>&1 | head -1
# → yaml envelope (local yaml wins over global json)

./target/debug/rev-stealth --format yaml spider --output-format json 2>&1 | head -1
# → JSON envelope (local json wins over global yaml)

./target/debug/rev-stealth --format json spider --output-format text 2>&1 | head -1
# → "error: the following required arguments were not provided:" (clap human print)

./target/debug/rev-stealth --format yaml spider --output-format human 2>&1 | head -1
# → "error: the following required arguments were not provided:" (clap human print)

REV_SCRAPING_HOME=/tmp/xx ./target/debug/rev-stealth config --output-format yaml init --dry-run | head -3
# → yaml envelope (config dry-run yaml end-to-end)
```

## Verdict criteria

LGTM if all 6 reproducers above match the expected outputs and the
acceptance gates hold.

If Codex still finds an axis the detector cannot represent, please
identify it concretely (precise argv + observed-vs-expected) so the
fix is targeted.
