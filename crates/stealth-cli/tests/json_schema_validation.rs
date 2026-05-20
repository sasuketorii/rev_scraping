// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.1.0 (P13 SHOULD: vpn_rotation_event schema)
//! P13 — JSON Schema validation tests for the `vpn_rotation_events` array
//! emitted by `rev-stealth spider`, `cf-evaluate`, and `relocate`.
//!
//! These tests do **not** run the CLI end-to-end. Instead we (a) load the
//! schema from `docs/json-schemas/vpn_rotation_event.schema.json`, (b)
//! construct realistic event payloads that mirror what `spider.rs` and
//! `vpn_selector.rs` actually emit, and (c) assert that each payload
//! validates. The CLI emission sites have unit tests covering shape;
//! this test guarantees the shape stays in sync with the schema.

use std::fs;
use std::path::PathBuf;

use jsonschema::JSONSchema;
use serde_json::{json, Value};

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("workspace root")
        .to_path_buf()
}

fn load_schema() -> JSONSchema {
    let path = workspace_root().join("docs/json-schemas/vpn_rotation_event.schema.json");
    let raw = fs::read_to_string(&path).expect("schema file must exist");
    let parsed: Value = serde_json::from_str(&raw).expect("schema must be valid JSON");
    JSONSchema::options()
        .with_draft(jsonschema::Draft::Draft7)
        .compile(&parsed)
        .expect("schema must compile as draft-07")
}

#[test]
fn schema_compiles_as_draft7() {
    let _ = load_schema();
}

#[test]
fn schema_accepts_minimal_event_with_only_attempt() {
    let schema = load_schema();
    let ev = json!({ "attempt": 1 });
    let result = schema.validate(&ev);
    assert!(
        result.is_ok(),
        "minimal {{attempt:1}} must validate; errors: {:?}",
        result
            .err()
            .map(|errs| errs.map(|e| e.to_string()).collect::<Vec<_>>())
    );
}

#[test]
fn schema_accepts_spider_style_failure_event() {
    // Mirrors crates/stealth-cli/src/commands/spider.rs ~L1082.
    let schema = load_schema();
    let ev = json!({
        "attempt": 2,
        "instance": "gluetun-1",
        "error": "tls handshake timeout",
        "signal": "tls_error",
        "tier": "gluetun",
        "latency_ms": 4200_u64,
    });
    assert!(schema.is_valid(&ev), "spider failure event must validate");
}

#[test]
fn schema_accepts_vpn_selector_style_event() {
    // Mirrors crates/stealth-cli/src/vpn_selector.rs (test_fallback_records_rotation_events).
    let schema = load_schema();
    let evs = vec![
        json!({"tier": "direct", "signal": "http_403", "attempt": 1}),
        json!({"tier": "surfshark", "signal": "ok", "attempt": 2}),
    ];
    for ev in &evs {
        assert!(
            schema.is_valid(ev),
            "vpn_selector event must validate: {ev}"
        );
    }
}

#[test]
fn schema_rejects_unknown_signal_enum_value() {
    let schema = load_schema();
    let ev = json!({"attempt": 1, "signal": "not_a_real_signal"});
    assert!(
        !schema.is_valid(&ev),
        "unknown enum value for signal must fail validation"
    );
}

#[test]
fn schema_rejects_missing_attempt_field() {
    let schema = load_schema();
    let ev = json!({"tier": "direct", "signal": "ok"});
    assert!(
        !schema.is_valid(&ev),
        "event missing required `attempt` must fail validation"
    );
}
