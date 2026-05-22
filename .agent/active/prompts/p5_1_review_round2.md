# P5.1 Review Request — Round 2 (post-fix)

target files:
- crates/stealth-cli/src/config_io/mod.rs
- crates/stealth-cli/src/config_io/schema.rs
- crates/stealth-cli/src/config_io/validate.rs
- crates/stealth-cli/src/config_io/lev.rs
- crates/stealth-cli/src/policy.rs

## Round 1 verdict
BLOCK on: lenient unknown-field handling could suppress non-lenient regex
errors in validate_authorized_toml.

## Round 1 fix applied
File: crates/stealth-cli/src/config_io/validate.rs

`validate_authorized_toml()` no longer gates pattern-regex validation on the
overall structural report's `is_ok()`. Pattern extraction now goes through a
new helper `extract_target_patterns()` that walks `toml::Value` and pulls every
`targets[].url_pattern` string regardless of unknown sibling fields. Each
pattern is regex-compiled. Failures are pushed as `Custom("InvalidRegex")` —
which is NOT in the lenient-downgrade set in `ValidationReport::push()`, so
they remain hard errors even under `REV_SCRAPING_CONFIG_LENIENT=1`.

Added regression test:
- `validate_authorized_lenient_mode_still_flags_invalid_regex`

Toml fixture used:

```toml
bogus_root = true

[[targets]]
url_pattern = "["
```

Under `REV_SCRAPING_CONFIG_LENIENT=1`, asserts that an `InvalidRegex` error
appears in `report.errors` (not just warnings).

## Residual risk noted in round 1
`Policy::load_from()` does not enforce `KnownConfig::supported_versions()` at
load time. Intentionally left out of this slice — P5.1 scope is the validation
engine, not loader integration. Loader hookup is P5.2 (config validate CLI
subcommand + load-time strict path).

## Gates re-run
- cargo check --workspace                                   : PASS
- cargo test --workspace --no-fail-fast                     : 543 PASS / 0 FAIL
- cargo clippy --workspace --all-targets -- -D warnings     : PASS
- bash scripts/check_source_and_spdx.sh                     : PASS
- bash scripts/check_baseline_diff.sh                       : PASS

## Spec-required unit tests (lib, all PASS):
1. validate_policy_accepts_existing_templates_policy_toml
2. validate_policy_rejects_unknown_field
3. validate_policy_levenshtein_suggests_correction
4. validate_authorized_accepts_existing_templates
5. validate_authorized_rejects_invalid_url_pattern
6. policy_schema_version_default_is_1

Plus round-2 regression: validate_authorized_lenient_mode_still_flags_invalid_regex

## Constraints honored
- no vendor/, _refs/, baseline/ edits
- existing policy.rs public API unchanged (schema_version additive only)
- aup::AuthorizedFile public API unchanged (AuthorizedSchema is a separate strict mirror)
- no secret leak path introduced

verdict: LGTM / BLOCK
