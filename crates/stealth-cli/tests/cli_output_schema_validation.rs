// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.3 Lane G.4 round 2 fix.
//! v1.3 Lane G.4 round-2 — JSON-Schema validation of every CLI subcommand's
//! `--output-format json` payload contract.
//!
//! Round-1 reviewer BLOCK: the schema inventory existed but did NOT describe
//! the actually-emitted envelopes. Round-2 fix rewrote the schemas to mirror
//! each emitter; this test pins that the schemas validate representative
//! payloads built directly from the `json!({...})` macros in the emitters.
//!
//! What this test does:
//!   * Loads each `docs/json-schemas/cli/<name>.output.json` and compiles it
//!     as Draft-07 (catches schema-syntax drift).
//!   * For each subcommand, constructs at least one OK-envelope sample and
//!     one ERR-envelope sample shaped like the matching `emit_ok` / `emit_err`
//!     in the source-of-truth emitter, and asserts validation passes.
//!   * For `config` (multi-action untagged shape) and `doctor` (no envelope,
//!     three top-level variants) we exercise one sample per documented
//!     branch of the `oneOf`.
//!
//! What this test does NOT do:
//!   * Spawn the CLI binary (kept hermetic; the live CLI is covered by the
//!     `e2e_*` suites and `output_format_coverage.rs`).
//!   * Assert that the live emitter sample is byte-identical to the sample
//!     here — additional non-required fields are tolerated via
//!     `additionalProperties: true` in each schema where applicable.
//!
//! Drift policy: when an emitter adds a *required* field, add it to both
//! the schema and the sample here. When it adds an optional field, only the
//! schema needs to grow.

use std::fs;
use std::path::PathBuf;

use jsonschema::JSONSchema;
use serde_json::{json, Value};

fn schemas_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("workspace root")
        .join("docs")
        .join("json-schemas")
        .join("cli")
}

fn load(name: &str) -> JSONSchema {
    let path = schemas_dir().join(name);
    let raw = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("schema {} must exist: {e}", path.display()));
    let parsed: Value = serde_json::from_str(&raw)
        .unwrap_or_else(|e| panic!("schema {} must be valid JSON: {e}", path.display()));
    JSONSchema::options()
        .with_draft(jsonschema::Draft::Draft7)
        .compile(&parsed)
        .unwrap_or_else(|e| panic!("schema {} must compile as Draft-07: {e}", path.display()))
}

fn validate_ok(schema: &JSONSchema, sample: &Value, label: &str) {
    if let Err(errors) = schema.validate(sample) {
        let collected: Vec<String> = errors.map(|e| format!("{e}")).collect();
        panic!(
            "{label} sample failed schema validation: {:#?}\nsample: {}",
            collected,
            serde_json::to_string_pretty(sample).unwrap_or_default()
        );
    }
}

// ---------- 1) every schema compiles ---------------------------------------

#[test]
fn all_cli_output_schemas_compile_as_draft7() {
    for name in [
        "captcha.output.json",
        "browser.output.json",
        "vpn.output.json",
        "spider.output.json",
        "relocate.output.json",
        "cf-evaluate.output.json",
        "auth.output.json",
        "measure.output.json",
        "hermes.output.json",
        "doctor.output.json",
        "config.output.json",
    ] {
        let _ = load(name);
    }
}

// ---------- 2) shared `{ok, operation, result|exit_code+error}` envelopes --

#[test]
fn measure_ok_and_err_envelopes_validate() {
    let s = load("measure.output.json");
    let ok = json!({
        "ok": true,
        "operation": "measure",
        "result": {
            "url": "https://example.test/",
            "user_agent": "rev-stealth/1.1.0 (+measurement)",
            "local": {
                "scheme": "https",
                "host": "example.test",
                "sec_ch_ua_valid": true,
                "ja4_placeholder": "ja4-stub-deadbeef",
                "bot_score": 0,
            },
            "external": { "enabled": false },
            "egress": null,
        },
    });
    validate_ok(&s, &ok, "measure OK");
    let err = json!({
        "ok": false,
        "operation": "measure",
        "exit_code": 3,
        "error": "invalid --url",
    });
    validate_ok(&s, &err, "measure ERR");
}

#[test]
fn captcha_solve_and_verify_validate() {
    let s = load("captcha.output.json");
    let solve = json!({
        "ok": true,
        "operation": "captcha.solve",
        "result": {
            "type": "recaptcha-v2",
            "site_url": "https://example.test/",
            "site_key": null,
            "solver": "stub",
            "elapsed_ms": 0,
            "token_len": 0,
            "token_preview": "",
            "dry_run": true,
        },
    });
    validate_ok(&s, &solve, "captcha.solve OK");
    let verify = json!({
        "ok": true,
        "operation": "captcha.verify",
        "result": {
            "type": "hcaptcha",
            "valid": false,
            "score": null,
            "action": null,
            "errors": ["mismatched-secret"],
        },
    });
    validate_ok(&s, &verify, "captcha.verify OK");
    let err = json!({
        "ok": false,
        "operation": "captcha.solve",
        "exit_code": 1,
        "error": "unknown captcha type",
    });
    validate_ok(&s, &err, "captcha ERR");
}

#[test]
fn browser_launch_envelope_validates() {
    let s = load("browser.output.json");
    let ok = json!({
        "ok": true,
        "operation": "browser.launch",
        "result": {
            "profile_id": "p-001",
            "browser_profile": "chrome-desktop",
            "stealth_level": "obscura",
            "url_requested": "https://example.test/",
            "url_final": "https://example.test/",
            "title": "Example",
            "user_agent": "Mozilla/5.0",
            "fingerprint": {
                "preset_id": "ua-1",
                "viewport": [1920, 1080],
                "device_scale_factor": 1.0,
                "device_memory": 8,
                "hardware_concurrency": 8,
                "max_touch_points": 0,
                "webgl_vendor": "Google Inc.",
                "webgl_renderer": "ANGLE",
            },
        },
    });
    validate_ok(&s, &ok, "browser.launch OK");
    let err = json!({
        "ok": false,
        "operation": "browser.launch",
        "exit_code": 2,
        "error": "launch failed",
    });
    validate_ok(&s, &err, "browser.launch ERR");
}

#[test]
fn vpn_rotate_and_status_validate() {
    let s = load("vpn.output.json");
    let rotate = json!({
        "ok": true,
        "operation": "vpn.rotate",
        "result": {
            "rotated": true,
            "container": "vpn-1",
            "previous_ip": "1.2.3.4",
            "new_ip": "5.6.7.8",
            "elapsed_ms": 500,
            "reason": "test",
        },
    });
    validate_ok(&s, &rotate, "vpn.rotate OK");
    let status = json!({
        "ok": true,
        "operation": "vpn.status",
        "result": {
            "provider": "obscura",
            "container": null,
            "running": false,
            "current_ip": null,
        },
    });
    validate_ok(&s, &status, "vpn.status OK");
    let err = json!({
        "ok": false,
        "operation": "vpn.rotate",
        "exit_code": 1,
        "error": "no instance",
    });
    validate_ok(&s, &err, "vpn ERR");
}

#[test]
fn spider_envelope_validates() {
    let s = load("spider.output.json");
    let ok = json!({
        "ok": true,
        "operation": "spider",
        "result": {
            "session_id": "00000000-0000-0000-0000-000000000000",
            "url": "https://example.test/",
            "url_requested": "https://example.test/",
            "url_final": null,
            "fetcher": "reqwest",
            "used_fallback": false,
            "exit_code": 0,
        },
    });
    validate_ok(&s, &ok, "spider OK");
    let err = json!({
        "ok": false,
        "operation": "spider",
        "exit_code": 7,
        "error": "vpn leak detected",
        "vpn_monitor": { "enabled": true, "leak_detected": true },
    });
    validate_ok(&s, &err, "spider ERR (leak)");
}

#[test]
fn relocate_envelope_validates() {
    let s = load("relocate.output.json");
    let exact = json!({
        "ok": true,
        "operation": "relocate",
        "result": { "kind": "exact", "node": "<button/>" },
    });
    validate_ok(&s, &exact, "relocate exact");
    let fuzzy = json!({
        "ok": true,
        "operation": "relocate",
        "result": { "kind": "fuzzy", "score": 0.87, "node": "<button/>" },
    });
    validate_ok(&s, &fuzzy, "relocate fuzzy");
    let ambig = json!({
        "ok": true,
        "operation": "relocate",
        "result": { "kind": "ambiguous", "candidates": 3 },
    });
    validate_ok(&s, &ambig, "relocate ambiguous");
    let nomatch = json!({
        "ok": false,
        "operation": "relocate",
        "exit_code": 9,
        "error": "no match",
    });
    validate_ok(&s, &nomatch, "relocate no-match ERR");
}

#[test]
fn cf_evaluate_envelope_validates() {
    let s = load("cf-evaluate.output.json");
    let ok = json!({
        "ok": true,
        "operation": "cf-evaluate",
        "result": {
            "url": "https://example.test/",
            "outcome": "Cleared",
            "exit_code": 0,
        },
    });
    validate_ok(&s, &ok, "cf-evaluate OK");
    let err = json!({
        "ok": false,
        "operation": "cf-evaluate",
        "exit_code": 7,
        "error": "vpn pool exhausted",
    });
    validate_ok(&s, &err, "cf-evaluate ERR");
}

#[test]
fn auth_envelopes_validate() {
    let s = load("auth.output.json");
    let list = json!({
        "ok": true,
        "operation": "auth.list",
        "result": {
            "profiles": [
                {
                    "profile": "p1",
                    "domains": ["example.test"],
                    "created_at": "2026-05-22T00:00:00+00:00",
                    "last_used": "2026-05-22T00:00:00+00:00",
                    "cookie_count": 2,
                    "status": "valid",
                    "cookie_values_returned": false,
                }
            ]
        },
    });
    validate_ok(&s, &list, "auth.list");
    let show = json!({
        "ok": true,
        "operation": "auth.show",
        "result": {
            "profile": "p1",
            "domains": ["example.test"],
            "created_at": "2026-05-22T00:00:00+00:00",
            "last_used": "2026-05-22T00:00:00+00:00",
            "cookie_name_sha256_prefixes": ["abcd"],
            "status": "valid",
            "cookie_values_returned": false,
        },
    });
    validate_ok(&s, &show, "auth.show");
    let delete = json!({
        "ok": true,
        "operation": "auth.delete",
        "result": { "profile": "p1", "deleted": true },
    });
    validate_ok(&s, &delete, "auth.delete");
    let status = json!({
        "ok": true,
        "operation": "auth.status",
        "result": {
            "profile": "p1",
            "status": "valid",
            "warn_level": null,
            "exit_code": 0,
        },
    });
    validate_ok(&s, &status, "auth.status");
    let err = json!({
        "ok": false,
        "operation": "auth.refresh",
        "exit_code": 4,
        "error": "auth expired",
    });
    validate_ok(&s, &err, "auth.refresh ERR");
    // Round-3 fix: cover the ERR envelope for login as well — the CLI itself
    // emits this on policy / AUP / VPN-guard / spawn failures BEFORE handing
    // off to rev-auth, so it must validate against the schema.
    let login_err = json!({
        "ok": false,
        "operation": "auth.login",
        "exit_code": 1,
        "error": "AUP: domain not authorized",
    });
    validate_ok(&s, &login_err, "auth.login ERR");
}

#[test]
fn auth_login_refresh_flat_success_validates() {
    // Round-3 fix for reviewer round-2 BLOCK: `rev-stealth auth login` and
    // `auth refresh` SUCCESS paths inherit stdout from the external rev-auth
    // helper, which prints a flat `SuccessJson` (no envelope). The schema
    // must accept this as a distinct top-level branch — see
    // `crates/stealth-auth/src/bin/rev_auth.rs::SuccessJson` (line 212) and
    // the println at line 382, plus `auth.rs::spawn_rev_auth_login` line 406
    // which inherits the child's stdout.
    let s = load("auth.output.json");
    let login_success = json!({
        "ok": true,
        "profile": "p1",
        "domain": "example.test",
        "cookie_count": 4,
        "expires_at": "2026-06-22T00:00:00+00:00",
        "saved_to": "/home/u/.rev_scraping/auth/p1.enc",
    });
    validate_ok(&s, &login_success, "auth.login flat SuccessJson");
    // expires_at can be null when no cookie carries an expiry.
    let login_success_no_expiry = json!({
        "ok": true,
        "profile": "p1",
        "domain": "example.test",
        "cookie_count": 0,
        "expires_at": null,
        "saved_to": "/home/u/.rev_scraping/auth/p1.enc",
    });
    validate_ok(
        &s,
        &login_success_no_expiry,
        "auth.login flat SuccessJson (no expiry)",
    );
}

// ---------- 3) hermes (its own envelope) ----------------------------------

#[test]
fn hermes_envelopes_validate() {
    let s = load("hermes.output.json");
    let ok = json!({
        "kind": "hermes",
        "action": "install",
        "status": "ok",
        "report": {
            "prefix": "/home/u/.local",
            "source": null,
            "files_copied": 3,
            "python_check_ok": null,
        },
    });
    validate_ok(&s, &ok, "hermes install OK");
    let verify_ok = json!({
        "kind": "hermes",
        "action": "verify",
        "status": "ok",
        "report": {
            "prefix": "/home/u/.local",
            "source": "/repo/scaffold",
            "files_copied": 0,
            "python_check_ok": true,
        },
    });
    validate_ok(&s, &verify_ok, "hermes verify OK");
    let err = json!({
        "kind": "hermes",
        "action": "verify",
        "status": "error",
        "error": "python3 not available",
    });
    validate_ok(&s, &err, "hermes ERR");
}

// ---------- 4) doctor (no envelope; three top-level variants) -------------

#[test]
fn doctor_report_validates() {
    let s = load("doctor.output.json");
    let base = json!({
        "kill_switch": true,
        "dns_lock": true,
        "ipv6_disabled": true,
        "webrtc_guard_present": true,
        "exit_ip_ok": true,
        "exit_ip": { "ip": "5.6.7.8", "country": "JP", "asn": "AS123" },
    });
    validate_ok(&s, &base, "doctor base");
}

#[test]
fn doctor_deep_validates() {
    let s = load("doctor.output.json");
    let deep = json!({
        "obscura_binary": { "name": "obscura_binary", "status": "pass", "detail": "ok" },
        "vpn_pool_instances": { "name": "vpn_pool_instances", "status": "warn", "detail": "0 of 3 healthy" },
        "sites_recipes": { "name": "sites_recipes", "status": "pass", "detail": "12 recipes" },
        "auth_profiles": { "name": "auth_profiles", "status": "pass", "detail": "1 profile" },
        "auth_key_source": { "name": "auth_key_source", "status": "pass", "detail": "keyring" },
    });
    validate_ok(&s, &deep, "doctor deep");
}

#[test]
fn doctor_vps_array_validates() {
    let s = load("doctor.output.json");
    let vps = json!([
        { "name": "vps_egress", "status": "pass", "detail": "exit ok" },
        { "name": "tls_handshake", "status": "warn", "detail": "JA4 unknown" }
    ]);
    validate_ok(&s, &vps, "doctor --vps array");
}

// ---------- 5) config (no envelope; per-action untagged) ------------------

#[test]
fn config_paths_array_validates() {
    let s = load("config.output.json");
    let paths = json!([
        { "label": "policy", "path": "/p/policy.toml", "exists": true, "is_dir": false, "mode_octal": "0644" },
        { "label": "sites_dir", "path": "/p/sites", "exists": true, "is_dir": true, "mode_octal": "0755" }
    ]);
    validate_ok(&s, &paths, "config paths");
}

#[test]
fn config_validate_validates() {
    let s = load("config.output.json");
    let v = json!({
        "ok": true,
        "reports": [
            { "path": "/p/policy.toml", "ok": true, "errors": [] }
        ],
        "read_errors": [],
    });
    validate_ok(&s, &v, "config validate");
}

#[test]
fn config_diff_validates() {
    let s = load("config.output.json");
    let d = json!({ "diff": "--- a/x\n+++ b/x\n@@ -1,1 +1,1 @@\n-a\n+b\n" });
    validate_ok(&s, &d, "config diff");
}

#[test]
fn config_get_validates() {
    let s = load("config.output.json");
    let g = json!({ "key": "policy.network.tor", "value": false });
    validate_ok(&s, &g, "config get");
}

#[test]
fn config_show_validates() {
    let s = load("config.output.json");
    let show = json!({
        "policy": { "network": { "tor": false } },
        "authorized": { "domains": [] },
        "sites": {},
        "env": { "REV_SCRAPING_HOME": "/home/u/.rev_scraping" },
    });
    validate_ok(&s, &show, "config show");
}

#[test]
fn config_outcomes_validates() {
    let s = load("config.output.json");
    let init = json!({ "outcomes": [{ "kind": "created", "path": "/p/policy.toml" }] });
    validate_ok(&s, &init, "config init/migrate");
}
