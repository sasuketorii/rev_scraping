// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.1.0 (P10 security hardening)
//! P10 supply-chain / secret-scanning configuration tests.
//!
//! These tests do **not** invoke `cargo-deny` or `gitleaks` (those binaries
//! may not be on every developer's machine, and CI handles the real run in
//! `security.yml`). Instead we assert that the on-disk configuration files
//! parse as valid TOML and that the workspace `Cargo.toml` does not declare
//! supply-chain-risky deps (e.g. unused RC pins) that would silently bleed
//! into transitive resolution for every crate.

use std::fs;
use std::path::PathBuf;

fn workspace_root() -> PathBuf {
    // `CARGO_MANIFEST_DIR` for stealth-cli is .../crates/stealth-cli.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("workspace root resolvable from CARGO_MANIFEST_DIR")
        .to_path_buf()
}

/// Test 1: `deny.toml` exists, is valid TOML, and contains the sections that
/// our `security.yml` CI workflow expects to drive `cargo deny check`.
#[test]
fn deny_toml_parses_and_validates() {
    let path = workspace_root().join("deny.toml");
    let raw = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("deny.toml not readable at {}: {e}", path.display()));
    let doc: toml::Value = toml::from_str(&raw).expect("deny.toml must be valid TOML");

    let table = doc.as_table().expect("deny.toml top-level is a table");
    for required in ["licenses", "advisories", "bans", "sources"] {
        assert!(
            table.contains_key(required),
            "deny.toml is missing required section [{required}]"
        );
    }

    // The license allow-list must include MIT + Apache-2.0 (the two licenses
    // every workspace crate ships under) or `cargo deny check licenses` will
    // immediately fail on our own code.
    let allow = table["licenses"]["allow"]
        .as_array()
        .expect("licenses.allow is an array");
    let allow_strs: Vec<&str> = allow.iter().filter_map(|v| v.as_str()).collect();
    assert!(
        allow_strs.contains(&"MIT"),
        "licenses.allow must include MIT"
    );
    assert!(
        allow_strs.contains(&"Apache-2.0"),
        "licenses.allow must include Apache-2.0"
    );

    // Unknown registries / git sources must stay denied — this is the single
    // biggest supply-chain control in this config.
    assert_eq!(
        table["sources"]["unknown-registry"].as_str(),
        Some("deny"),
        "deny.toml: sources.unknown-registry must remain `deny`"
    );
    assert_eq!(
        table["sources"]["unknown-git"].as_str(),
        Some("deny"),
        "deny.toml: sources.unknown-git must remain `deny`"
    );
}

/// Test 2: `.gitleaks.toml` exists, is valid TOML, and declares at least the
/// VPN / cookie rules that are specific to rev_scraping. The upstream default
/// ruleset is extended via `[extend] useDefault = true`.
#[test]
fn gitleaks_config_parses() {
    let path = workspace_root().join(".gitleaks.toml");
    let raw = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!(".gitleaks.toml not readable at {}: {e}", path.display()));
    let doc: toml::Value = toml::from_str(&raw).expect(".gitleaks.toml must be valid TOML");

    let extend = doc
        .get("extend")
        .and_then(|v| v.get("useDefault"))
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    assert!(
        extend,
        ".gitleaks.toml must extend the default ruleset (useDefault = true)"
    );

    let rules = doc
        .get("rules")
        .and_then(|v| v.as_array())
        .expect(".gitleaks.toml must declare at least one [[rules]] entry");
    let rule_ids: Vec<&str> = rules
        .iter()
        .filter_map(|r| r.get("id").and_then(|v| v.as_str()))
        .collect();
    for required in [
        "revscraping-vpn-credentials",
        "revscraping-cookie-value",
        "revscraping-openvpn-inline-cert",
    ] {
        assert!(
            rule_ids.contains(&required),
            ".gitleaks.toml must declare rule id `{required}` (project-specific secret pattern)"
        );
    }
}

/// Test 3: workspace `Cargo.toml` does not re-introduce supply-chain-risky
/// dependencies that P10 explicitly removed. `wreq` is an RC pin and `rmcp`
/// 0.1 was never used by any crate — re-adding them at workspace scope would
/// silently broaden the dependency surface for every crate without
/// cargo-deny review.
#[test]
fn workspace_does_not_declare_pruned_deps() {
    let path = workspace_root().join("Cargo.toml");
    let raw = fs::read_to_string(&path).expect("workspace Cargo.toml readable");
    let doc: toml::Value = toml::from_str(&raw).expect("workspace Cargo.toml is valid TOML");

    let ws_deps = doc
        .get("workspace")
        .and_then(|w| w.get("dependencies"))
        .and_then(|v| v.as_table())
        .expect("[workspace.dependencies] table must exist");

    for pruned in ["wreq", "rmcp"] {
        assert!(
            !ws_deps.contains_key(pruned),
            "workspace.dependencies must not declare `{pruned}` (removed in P10 — \
             feature-gate it per-crate if a future stealth experiment needs it)"
        );
    }

    // Sanity: the deps we *do* want are still there. Catches accidental
    // wholesale deletion of [workspace.dependencies].
    for required in ["tokio", "serde", "reqwest", "anyhow"] {
        assert!(
            ws_deps.contains_key(required),
            "workspace.dependencies lost required dep `{required}`"
        );
    }
}
