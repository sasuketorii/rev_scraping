# P5.1 Review Request

target files:
- crates/stealth-cli/src/config_io/mod.rs
- crates/stealth-cli/src/config_io/schema.rs
- crates/stealth-cli/src/config_io/validate.rs
- crates/stealth-cli/src/config_io/lev.rs
- crates/stealth-cli/src/policy.rs (schema_version field + deny_unknown_fields + KnownConfig impl)

spec: ExecPlan §B.5 (Config UX) — schema + validate engine

gates passed:
- cargo check --workspace                                   : PASS
- cargo test --workspace --no-fail-fast                     : 542 PASS / 0 FAIL (baseline 519 + 6 spec tests + 17 other previously-unaccounted)
- cargo clippy --workspace --all-targets -- -D warnings     : PASS (no warnings)
- bash scripts/check_source_and_spdx.sh                     : PASS
- bash scripts/check_baseline_diff.sh                       : PASS (policy.toml sha unchanged, templates/authorized*.toml absent — sentinel OK)

review focus:
1. deny_unknown_fields applied on Policy, VpnInstance, AuthorizedSchema, AuthorizedTargetSchema.
2. schema_version default = 1 via default_schema_version_v1() helper, accepted on empty TOML, rejected on 999.
3. Levenshtein-based "Did you mean ..." suggestion for unknown-field typos (distance <= 2).
4. New validate_authorized_toml() layers regex-compile checks on each url_pattern after structural validation.
5. AuthorizedSchema is a strict mirror; aup::AuthorizedFile public API is untouched (non-destructive).
6. ValidateOptions + REV_SCRAPING_CONFIG_LENIENT env: strict by default, downgrade unknown-field / unsupported-version to warnings when lenient.

6 spec-required unit tests (all PASS under cargo test -p stealth-cli --lib):
- validate_policy_accepts_existing_templates_policy_toml
- validate_policy_rejects_unknown_field
- validate_policy_levenshtein_suggests_correction
- validate_authorized_accepts_existing_templates
- validate_authorized_rejects_invalid_url_pattern
- policy_schema_version_default_is_1

constraints honored:
- no vendor/, _refs/, baseline/ edits
- existing policy.rs public API unchanged (schema_version is additive with serde default; Policy::default() still returns the same effective runtime values; KnownConfig trait impl added but does not affect existing call sites)
- no secret leak path introduced (validator operates on plain TOML text, no network, no env capture beyond REV_SCRAPING_CONFIG_LENIENT)

verdict: LGTM / BLOCK
