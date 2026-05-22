// SPDX-License-Identifier: MIT
// Source: new integration test for rev_scraping v1.2.0 (P5.1)

use stealth_cli::config_io::{validate_toml_against, ValidateOptions};
use stealth_cli::policy::Policy;

#[test]
fn v1_1_0_policy_fixture_loads_and_validates() {
    let path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/v1_1_0/policy.toml");
    let policy = Policy::load_from(&path).expect("v1.1.0 policy fixture loads");
    assert_eq!(policy.schema_version, 1);

    let raw = std::fs::read_to_string(&path).expect("fixture is readable");
    let report = validate_toml_against::<Policy>(&raw, &ValidateOptions::strict());
    assert!(report.errors.is_empty(), "errors: {:?}", report.errors);
    assert!(
        report.warnings.is_empty(),
        "warnings: {:?}",
        report.warnings
    );
}
