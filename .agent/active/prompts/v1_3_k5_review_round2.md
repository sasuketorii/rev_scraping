# Lane K.5 reviewer prompt (Codex) — round 2

You are the v1.3 Lane K.5 reviewer, round 2. Round 1 flagged:
- `sanitize_full` is not a distinct `sanitize::layer2_envelope::parse` target.

Round 2 fix:
1. Renamed the L2 target from `sanitize_full` to `sanitize_envelope_parse`.
2. New `fuzz_targets/sanitize_envelope_parse.rs` is L2-focused: feeds bytes
   through `serde_json::from_slice` (the envelope parse entry) and then
   `sanitize_for_agent(Preset::Strict, ...)` so `apply_l2` and
   `neutralize_forgery` are exercised on every iteration. The property
   asserts: parse + L2 normalize never panic and the resulting report
   serializes back to JSON.
3. Updated `fuzz/Cargo.toml` and `.github/workflows/fuzz-nightly.yml` to
   reference the renamed target. Deleted the obsolete `sanitize_full.rs`.

Three targets now align 1:1 with the K.5 spec:
- sanitize_envelope_parse  → sanitize::layer2_envelope::parse
- sanitize_l4_unicode      → sanitize::layer4_unicode::normalize
- mcp_jsonrpc_frame        → MCP JSON-RPC frame parser

Constraints: prompt ≤ 2 KB / no Write/Edit / baseline 7c700a0b.

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 3 items>
