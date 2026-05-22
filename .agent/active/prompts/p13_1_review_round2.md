# Review P13.1 round 2 — sanitize_error_envelope fix

Round 1 verdict: BLOCK — `sanitize_error_envelope` was pure pass-through and
did not populate `_meta.sanitize` for error envelopes.

## Fix
`crates/stealth-sanitize/src/lib.rs::sanitize_error_envelope` now builds the
same `SanitizationReport` and attaches it at `data._meta.sanitize`:
- preserves existing `data` object fields (merge, no clobber)
- non-object `data` value moved under `value` key; `None` synthesizes obj
- `bytes_in` = `message.len()` + serialized `data` size
- `Off` → `layers_applied=[]`; Warn/Enforce → `["L7:meta"]`
- 16-char hex nonce

## Tests added (3, total stealth-sanitize 15 PASS)
- `error_envelope_balanced_attaches_meta_sanitize_into_data`
- `error_envelope_off_mode_has_empty_layers_but_meta_still_present`
- `error_envelope_preserves_existing_data_object_fields`

## Gates PASS
- `cargo test -p stealth-sanitize`: 15 / 0
- `cargo test --workspace --no-fail-fast`: 695 / 0 (baseline 680 → +15)
- `cargo clippy -p stealth-sanitize --all-targets -- -D warnings`: clean

## Verify (3)
1. `sanitize_error_envelope` now emits `_meta.sanitize` with same schema as
   `sanitize_for_agent`: `schema_version=1`, `policy_name`, `mode`,
   `bytes_in/out`, `layers_applied`, `canary_hits=[]`, 16-char hex
   `sanitize_id`, `aborted=false` — addressing round-1 finding.
2. Pre-existing `data` fields survive: test
   `error_envelope_preserves_existing_data_object_fields` asserts `detail`
   and `n` keys remain alongside injected `_meta.sanitize`.
3. P13.1 still layer-free: `layers_applied` empty in `Off`, single
   `"L7:meta"` entry in Warn/Enforce; no L2/L3/L4/L5 work runs. `aborted`
   always `false`. Layer wiring deferred to P13.2-P13.4 per synthesis.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
