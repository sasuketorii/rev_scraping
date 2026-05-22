# Review P13.1 — stealth-sanitize skeleton

Lane F sub-phase P13.1: new `stealth-sanitize` crate, public API only. Layers land in P13.2-P13.5.
Design: `.agent/active/v1_2_injection_synthesis.md`.
Permission: user authorized work on `main`. No worktree.

## Files
- `Cargo.toml` — add member + path dep
- `crates/stealth-sanitize/Cargo.toml` — new (serde, serde_json, regex, rand, unicode-normalization, aho-corasick)
- `crates/stealth-sanitize/src/lib.rs` — `sanitize_for_agent` / `sanitize_error_envelope` (no-op layers, populates `_meta.sanitize` shape)
- `crates/stealth-sanitize/src/policy.rs` — `Mode{Off,Warn,Enforce}`, `Preset{Strict,Balanced,PassThrough}`, `SanitizePolicy/LimitPolicy/CanaryPolicy/UnicodePolicy`
- `crates/stealth-sanitize/src/report.rs` — `SanitizationReport/SanitizedEnvelope/CanaryHit/CanarySeverity/ErrorEnvelope`
- `crates/stealth-sanitize/src/nonce.rs` — 16-char hex nonce via `OsRng`

## Gates PASS
- `cargo test -p stealth-sanitize`: 12 / 0
- `cargo test --workspace --no-fail-fast`: 692 / 0 (baseline 680 → +12)
- `cargo clippy -p stealth-sanitize --all-targets -- -D warnings`: clean

## Verify (3)
1. Public API matches synthesis §"公開 API" — `Mode/SanitizePolicy/SanitizedEnvelope/SanitizationReport/CanaryHit/sanitize_for_agent/sanitize_error_envelope` all present, no drift.
2. `CanaryHit` serialization omits any `matched_bytes` field (test `canary_hit_does_not_carry_matched_bytes_field`) so raw injection strings cannot leak back via `_meta.sanitize`.
3. P13.1 is layers-free: `layers_applied = ["L7:meta"]` in Warn/Enforce, empty in Off. `aborted` always false. L2/L3/L4/L5 work lands in later slices.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
