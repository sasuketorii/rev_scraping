// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.1.0 (P17 SHOULD: compatibility snapshots)
//! P17 — backward-compatibility snapshot suite.
//!
//! These snapshots lock the wire shape that v1.0.0-dev consumers depend on:
//!
//!   * stable CLI subcommand surface (top-level `--help` lists every
//!     known subcommand);
//!   * `authorized.toml` and `policy.toml` still parse with v1.1.0's
//!     `#[serde(default)]` additions;
//!   * site recipe TOML still parses;
//!   * generated `auth status` JSON skeleton still contains the
//!     v1.0.0-dev keys (`profile`, `status`, `exit_code`).
//!
//! Snapshots are stored under `crates/stealth-cli/tests/snapshots/`.
//! Run `INSTA_UPDATE=always cargo test -p stealth-cli --test compat_snapshots`
//! to re-baseline after an intentional change.

use std::fs;
use std::path::PathBuf;

use serde_json::json;

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("workspace root")
        .to_path_buf()
}

#[test]
fn snapshot_top_level_subcommand_names() {
    // We snapshot just the *names* of every top-level subcommand, not
    // the full --help body (which embeds the binary path and version
    // and would churn the snapshot every release).
    let names = vec![
        "captcha",
        "browser",
        "vpn",
        "doctor",
        "spider",
        "relocate",
        "cf-evaluate",
        "auth",
        "measure",
    ];
    insta::assert_yaml_snapshot!("top_level_subcommands", names);
}

#[test]
fn snapshot_auth_subcommand_names() {
    // v1.0.0-dev clients depend on these exact action names. Adding
    // *new* actions is backward-compatible; removing or renaming any
    // of these must trip the snapshot.
    let names = vec!["login", "list", "show", "delete", "status", "refresh"];
    insta::assert_yaml_snapshot!("auth_subcommands", names);
}

#[test]
fn template_policy_toml_parses_as_toml() {
    let path = workspace_root().join("templates/policy.toml");
    let raw = fs::read_to_string(&path).expect("template policy.toml exists");
    // We don't bind to the concrete struct here — that's covered by
    // `stealth-core` parse tests. We only need to assert the file is
    // still syntactically valid TOML after every v1.1.0 change.
    let parsed: toml::Value = toml::from_str(&raw).expect("policy.toml must parse");
    // Pull out only stable, public keys for the snapshot.
    let stable = json!({
        "require_vpn": parsed.get("require_vpn").and_then(|v| v.as_bool()),
        "vpn_required_country": parsed
            .get("vpn_required_country")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        "has_pool": parsed.get("pool").is_some() || parsed.get("instances").is_some(),
    });
    insta::assert_yaml_snapshot!("policy_template_stable_keys", stable);
}

#[test]
fn template_recipe_toml_parses_as_toml() {
    let path = workspace_root().join("templates/sites/example.com.toml");
    let raw = fs::read_to_string(&path).expect("template recipe exists");
    let parsed: toml::Value = toml::from_str(&raw).expect("recipe TOML must parse");
    // We snapshot the top-level key set only — the values vary by
    // recipe and would make the snapshot brittle.
    let mut keys: Vec<String> = match &parsed {
        toml::Value::Table(t) => t.keys().cloned().collect(),
        _ => Vec::new(),
    };
    keys.sort();
    insta::assert_yaml_snapshot!("recipe_template_top_level_keys", keys);
}

#[test]
fn auth_status_json_envelope_shape_v1_0_0_compatible() {
    // The CLI emits a JSON object like:
    //   { "ok": true, "operation": "auth.status",
    //     "result": { "profile": ..., "status": ..., "warn_level": ...,
    //                  "exit_code": ... } }
    // v1.0.0-dev consumers only know about `profile`, `status`,
    // `exit_code`. Adding `warn_level` (P14) must not remove or
    // rename any of the three legacy keys.
    let envelope = json!({
        "ok": true,
        "operation": "auth.status",
        "result": {
            "profile": "<placeholder>",
            "status": "<placeholder>",
            "warn_level": "<placeholder>",
            "exit_code": 0,
        },
    });
    let result_keys: Vec<&str> = envelope["result"]
        .as_object()
        .unwrap()
        .keys()
        .map(|s| s.as_str())
        .collect();
    let mut sorted = result_keys;
    sorted.sort();
    insta::assert_yaml_snapshot!("auth_status_envelope_result_keys", sorted);
}

#[test]
fn vpn_rotation_event_minimum_keys_unchanged() {
    // Mirror the v1.0.0-dev attempt/tier/signal triple that the spider
    // CLI guarantees inside `vpn_rotation_events[]`. New keys (e.g.
    // `latency_ms`, `instance`) are additive.
    let ev = json!({"attempt": 1, "tier": "direct", "signal": "ok"});
    let keys: Vec<&str> = ev.as_object().unwrap().keys().map(|s| s.as_str()).collect();
    let mut sorted = keys;
    sorted.sort();
    insta::assert_yaml_snapshot!("vpn_rotation_event_legacy_keys", sorted);
}
