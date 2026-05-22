# Lane K.5 reviewer prompt (Codex) — round 3

You are the v1.3 Lane K.5 reviewer, round 3. Round 2 flagged:
1. `to_vec(&env.report)` was ignored instead of asserted.
2. `Preset::Strict` could abort on L3 before L2 ran.
3. New target file `sanitize_envelope_parse.rs` not in tracked diff.

Round 3 fixes:
1. Replaced `let _ = serde_json::to_vec(&env.report);` with
   `serde_json::to_vec(&env.report).expect("report must serialize");`
   so any serialize failure crashes libfuzzer.
2. Switched the harness from `Preset::Strict` to `Preset::Balanced` so
   the L2 envelope normalize / forgery-neutralize path always executes
   on every parsed iteration (Strict could short-circuit on L3 critical).
3. `sanitize_envelope_parse.rs` is present in the working tree as a
   new untracked file (will be staged in the same commit as the
   removed `sanitize_full.rs`). Workflow + fuzz/Cargo.toml already
   reference the new name.

Constraints: prompt ≤ 2 KB / no Write/Edit / baseline 7c700a0b.

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 3 items>
