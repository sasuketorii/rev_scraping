# Lane K.3 reviewer prompt (Codex) — round 2

You are the v1.3 Lane K.3 reviewer, round 2. Round 1 flagged:
1. `crates/stealth-mcp/src/bin/gen_reference.rs` missing `#![forbid(unsafe_code)]`.
2. CI grep only checked `crates/*/src/lib.rs`, not `src/main.rs` or `src/bin/*.rs`.
3. No SAFETY-doc check for unsafe blocks.

Round 2 fixes:
1. Added `#![forbid(unsafe_code)]` to gen_reference.rs (cargo check passes).
2. security.yml grep step now walks lib.rs + main.rs + bin/*.rs and reports
   missing entries individually. Local verification: `for f in crates/*/src/main.rs
   crates/*/src/bin/*.rs; do grep -q forbid... done` → all clean.
3. Added a second step "SAFETY-doc check for every unsafe block" that scans
   crates/**/*.rs (excluding tests/benches) with awk, flagging any
   `unsafe {` block whose preceding non-blank line is not `// SAFETY:`.
   v1.3 baseline has zero unsafe blocks so this is a tripwire for future
   regressions.

Constraints: prompt ≤ 2 KB / no Write/Edit / baseline 7c700a0b.

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 3 items>
