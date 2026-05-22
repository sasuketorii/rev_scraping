# Review P13.1 round 3 — non-object `_meta` fix

Round 2 verdict: BLOCK — when `data._meta` existed but was non-object,
`or_insert_with` returned the existing non-object value and the
`if let Value::Object` branch skipped insertion, dropping the report.

## Fix
`crates/stealth-sanitize/src/lib.rs::sanitize_error_envelope` now explicitly
removes any pre-existing `_meta` and reconstructs a fresh object:
- `Some(Object(m))` → reuse `m`
- `Some(other)` (string/null/array/number/bool) → fresh object with prior
  value preserved under `_meta._prev` for forensics
- `None` → fresh empty object
Then `_meta.sanitize` is inserted unconditionally and `_meta` is reinserted
into `data` as an `Object`. The pathological round-2 case is now covered.

## Test added (1, total 16 PASS for stealth-sanitize)
`error_envelope_replaces_non_object_meta_and_preserves_prev`:
- input `data: {"_meta": "stringy", "keep": 1}`
- asserts post-fix `_meta` is an object, contains `sanitize`, contains
  `_prev = "stringy"`, and sibling key `keep` survives.

## Gates PASS
- `cargo test -p stealth-sanitize`: 16 / 0
- `cargo test --workspace --no-fail-fast`: 696 / 0 (baseline 680 → +16)
- `cargo clippy -p stealth-sanitize --all-targets -- -D warnings`: clean

## Verify (3)
1. `_meta.sanitize` is unconditionally attached for every code path of
   `sanitize_error_envelope` regardless of incoming `data` shape
   (`None`, non-object, object-without-`_meta`, object-with-non-object-`_meta`,
   object-with-object-`_meta`). Round-2 finding addressed.
2. No prior data is silently dropped: existing sibling keys preserved
   (`error_envelope_preserves_existing_data_object_fields`); pathological
   non-object `_meta` value relocated to `_meta._prev` rather than discarded.
3. P13.1 invariants still hold: layers_applied empty in `Off`, single
   `"L7:meta"` entry in Warn/Enforce; `aborted=false`; `CanaryHit` has no
   `matched_bytes` field; layer wiring deferred to P13.2-P13.4.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
