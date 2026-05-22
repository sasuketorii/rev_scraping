# Review Lane C P1 stealth-agent-contracts crate (round 3 — final)

Round 2 BLOCK addressed:
- token.rs: introduced `is_strict_v4(&Uuid) -> bool` requiring BOTH `Version::Random` AND `Variant::RFC4122`. Applied uniformly in `from_uuid` and `ensure_v4` (deserialize). Rejects malformed v4-version-but-NCS-variant UUIDs like `00000000-0000-4000-0000-000000000000`.
- Added test `token_rejects_v4_version_with_wrong_variant` asserting:
  * `Uuid::parse_str("00000000-0000-4000-0000-000000000000").get_version_num() == 4` AND `get_variant() != RFC4122` (sanity)
  * `ProgressToken::from_uuid(malformed)` → None
  * `SessionId::from_uuid(malformed)` → None
  * `serde_json::from_str::<ProgressToken>(json)` → Err
  * `serde_json::from_str::<SessionId>(json)` → Err

files unchanged from round 2 except token.rs hardening.

gates PASS (re-run):
- cargo test -p stealth-agent-contracts: 6/6 PASS (added strict-variant test)
- cargo test --workspace --no-fail-fast: 557 PASS / 0 FAIL / 38 ignored
- cargo clippy --workspace --all-targets -- -D warnings: clean
- check_source_and_spdx.sh: PASS
- check_baseline_diff.sh: PASS

verify (focused diff):
1. `is_strict_v4` uses `matches!(u.get_version(), Some(Version::Random))` + `u.get_variant() == Variant::RFC4122`.
2. Both `ProgressToken::from_uuid` and `SessionId::from_uuid` call `is_strict_v4`.
3. `ensure_v4` calls `is_strict_v4`; deserialize error message includes both version and variant.
4. Test coverage: v1 UUID rejected, malformed v4-variant-NCS UUID rejected, valid `Uuid::new_v4()` accepted, 128-sample uniqueness.

return: verdict: LGTM or BLOCK: <reason>
