# Review P13.3 round 3 — fixes pointer-leak BLOCK

## Round 2 BLOCK
> Key hit pointer is built from the original key — raw key bytes (and stripped bidi/zero-width chars) appear in `_meta.sanitize.canary_hits[].pointer`, violating "report must never re-introduce matched source bytes".

## Fix (both L3 and L4)
Key pointer is now positional, not name-derived:
- `layer3_canary.rs`: `format!("{pointer}/_k{idx}#key")` where `idx` is iteration order of the parent map. No raw key bytes ever touch the report.
- `layer4_unicode.rs`: same `_k<idx>#key` form for bidi-override key hits.

The new child pointer used to descend into the *value* still uses the scrubbed/redacted key (safe — it has already been stripped of canary content), so value-leaf pointers remain human-readable.

## Files
- crates/stealth-sanitize/src/layer3_canary.rs (positional `_k<idx>#key` pointer; +1 leak test)
- crates/stealth-sanitize/src/layer4_unicode.rs (same; +1 leak test)

## Gates PASS
- `cargo test -p stealth-sanitize`: 79 / 0 (was 77; +2 leak tests)
- `cargo test --workspace --no-fail-fast`: 759 / 0
- `cargo clippy -p stealth-sanitize --all-targets -- -D warnings`: clean

## Verify (3)
1. **No raw-key leak in L3 report**: test `key_canary_pointer_does_not_leak_raw_key_bytes` serializes `r.hits` and asserts the unique token `XYZTOKEN` placed inside the canary key does NOT appear anywhere in the report JSON.
2. **No raw-key leak in L4 report**: test `key_pointer_does_not_leak_raw_key_chars` does the same with marker `UNIQUEMARK` for a bidi-stripped key.
3. **Pointer still useful for forensics**: both leak tests also assert that some `#key` pointer was emitted (positional, but still distinguishable from value pointers).

## Residual
- Positional id is map-iteration-order-dependent. `serde_json::Map` defaults to preserving insertion order (the default `serde_json` feature `preserve_order` is OFF; without it Map is a BTreeMap by key). Either way `into_iter().enumerate()` is deterministic for a given input; reviewers replaying a payload will get the same `_k<i>` numbering.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
