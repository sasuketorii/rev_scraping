# Review P13.2 — stealth-sanitize L4 unicode + L5 length clamp

## Files touched
- crates/stealth-sanitize/src/layer4_unicode.rs (new, ~230 lines, 10 tests)
- crates/stealth-sanitize/src/layer5_clamp.rs (new, ~220 lines, 10 tests)
- crates/stealth-sanitize/src/lib.rs (wire L4 then L5 into `sanitize_for_agent`; bytes_out recomputed)

## Design ref
`.agent/active/v1_2_injection_synthesis.md` L11-L18, L4/L5 rows.

## Gates PASS
- `cargo test -p stealth-sanitize`: 37 passed / 0 failed
- `cargo test --workspace --no-fail-fast`: 717 passed / 0 failed (was 696 baseline)
- `cargo clippy -p stealth-sanitize --all-targets -- -D warnings`: clean

## What L4 does
- NFKC via `unicode-normalization`
- Strips zero-width: U+200B, U+200C, U+200D, U+2060, U+FEFF
- Strips tag chars: U+E0000..=U+E007F
- Strips bidi overrides: U+202D, U+202E, U+2066-U+2069 → each emits `bidi_override` Suspicious canary with RFC-6901 JSON pointer
- Legitimate Arabic/Hebrew preserved (not in override range)

## What L5 does
- per_field_max_bytes: head-80% + `[...TRUNCATED...]` + tail-20%, slicing on UTF-8 char boundaries (`char_boundary_floor/ceil`)
- total_max_bytes: cumulative; once over, subsequent strings replaced with marker or empty
- Idempotent (test `idempotent_after_clamp`)

## Verify (3)
1. False-positive zero on benign: tests `preserves_legitimate_arabic`, `no_modifications_when_text_is_pure_ascii`, `short_strings_untouched` pass.
2. NFKC idempotent: test `nfkc_is_idempotent` runs L4 twice and compares.
3. UTF-8 safety in clamp: `utf8_char_boundary_respected` test uses 3-byte Japanese chars; clamp never panics on slice.

## Residual risk
- L4 bidi canary length=0 (char stripped). L5 total budget ordering = serde_json Map BTree iteration (deterministic).

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
