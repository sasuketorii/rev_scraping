# Review P13.3 — L2 envelope + L3 canary

## Files
- crates/stealth-sanitize/src/layer2_envelope.rs (new, 6 tests)
- crates/stealth-sanitize/src/layer3_canary.rs (new, 25 tests, 20 rules)
- crates/stealth-sanitize/src/lib.rs (WrapContext + sanitize_for_agent_with; pipeline L4→L5→L3→L2→L7)

## Ref `.agent/active/v1_2_injection_synthesis.md` L37-L80

## Gates PASS
- `cargo test -p stealth-sanitize`: 72 / 0
- `cargo test --workspace --no-fail-fast`: 752 / 0 (baseline 696)
- `cargo clippy -p stealth-sanitize --all-targets -- -D warnings`: clean

## L2
- Wraps every string leaf with `<<<UNTRUSTED_CONTENT origin=X tool=Y sanitize_id=NONCE>>>...<<<END_UNTRUSTED_CONTENT sanitize_id=NONCE>>>`
- `neutralize_forgery()`: END replaced first then START → `<<<U_NOSTRTAG>>>`
- Keys not wrapped; non-string leaves untouched

## L3
- 13 literal patterns (aho-corasick): #9, #10, #12 variants
- 17 regex (RegexSet): #1-8, #11, #13-20
- Severity: Critical #6,9,10,11,12,19 / High #1-5,16,17,18 / Suspicious #7,8,13,14,15,20
- Warn: Critical reports only, High → `[REDACTED:injection]`, Suspicious report-only
- Enforce: Critical removes region; lib.rs sets `aborted=true` + payload=Null when `canary.critical_fail_closed`
- Overlap dedup: sort by start asc / len desc, skip any starting before prev end
- OnceLock-cached engines

## lib.rs
- Order L4 → L5 → L3 → L2 → L7; L2 skipped when aborted
- L4 bidi-override canaries enter canary_hits as Suspicious when enable_suspicious
- New `sanitize_for_agent_with(...)`; old `sanitize_for_agent()` calls it with Default ctx

## Verify (3)
1. Matched bytes never in report: test `matched_bytes_never_in_report` serializes hits, asserts literal absent.
2. Forgery: L2 test `neutralizes_forged_start_marker_inside_body` + L3 `c19_envelope_forgery_detected`.
3. Idempotence under Enforce: `idempotent_after_redaction` runs twice, asserts equality.

## Residual risk
- L3 offset is in post-L4/L5 buffer. P13.5 golden corpus uses base64.
- Enforce critical → payload=Null. P13.4 must map Null → empty per-tool shape.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
