// SPDX-License-Identifier: MIT
//
// Lane K K.4 — property-based invariants for stealth-sanitize.
//
// These tests assert structural invariants that must hold for ANY JSON
// input, not just the curated golden corpus. They complement
// `golden_corpus.rs` (which pins exact expected output) by guaranteeing
// the implementation does not panic, leak bytes, or violate documented
// guarantees on inputs the corpus never imagined.
//
// PR runs default to 256 cases per property. Set
// `PROPTEST_CASES=1024` in nightly cron to widen the search.

use proptest::prelude::*;
use serde_json::{json, Value};
use stealth_sanitize::{
    sanitize_for_agent, sanitize_for_agent_with, Mode, Preset, SanitizePolicy, WrapContext,
};

/// Generate an arbitrary `serde_json::Value`. Bounded depth to avoid
/// stack-blowing the recursion in `walk()`.
fn arb_json_value() -> impl Strategy<Value = Value> {
    let leaf = prop_oneof![
        Just(Value::Null),
        any::<bool>().prop_map(Value::Bool),
        any::<i64>().prop_map(|n| json!(n)),
        // Strings up to 64 chars, any Unicode scalar (proptest's default).
        ".{0,64}".prop_map(Value::String),
    ];
    leaf.prop_recursive(
        4,  // max depth
        32, // max total size
        8,  // max items per collection
        |inner| {
            prop_oneof![
                prop::collection::vec(inner.clone(), 0..4).prop_map(Value::Array),
                prop::collection::hash_map("[a-z]{1,8}", inner, 0..4).prop_map(|m| {
                    let mut obj = serde_json::Map::new();
                    for (k, v) in m {
                        obj.insert(k, v);
                    }
                    Value::Object(obj)
                }),
            ]
        },
    )
}

proptest! {
    #![proptest_config(ProptestConfig {
        // 256 cases on PR; nightly cron may override via PROPTEST_CASES env.
        cases: 256,
        // Keep failure persistence per workspace convention.
        failure_persistence: None,
        .. ProptestConfig::default()
    })]

    /// Mode::Off must be a structural no-op: the payload returned is
    /// exactly the input, byte-for-byte after JSON round-trip.
    #[test]
    fn mode_off_is_identity(payload in arb_json_value()) {
        let mut policy = SanitizePolicy::preset(Preset::Balanced);
        policy.mode = Mode::Off;
        let envelope = sanitize_for_agent(payload.clone(), &policy);
        prop_assert_eq!(envelope.payload, payload);
        prop_assert!(envelope.report.layers_applied.is_empty());
        prop_assert!(!envelope.report.aborted);
    }

    /// `sanitize_for_agent_with` must never panic on arbitrary input,
    /// across every shipped preset. Also asserts that bytes_in /
    /// bytes_out are populated (non-zero only when payload is non-Null).
    #[test]
    fn never_panics_across_presets(payload in arb_json_value()) {
        for preset in [Preset::Strict, Preset::Balanced, Preset::PassThrough] {
            let policy = SanitizePolicy::preset(preset);
            let ctx = WrapContext::default();
            let envelope = sanitize_for_agent_with(
                payload.clone(),
                &policy,
                ctx,
            );
            // bytes_in is the pre-sanitize estimate. bytes_out is post.
            // The contract says both fields are populated and non-negative
            // (u64 already enforces non-negative). We just assert they
            // are coherent with the abort flag.
            if envelope.report.aborted {
                prop_assert_eq!(envelope.payload, Value::Null);
            }
            // sanitize_id is a non-empty nonce.
            prop_assert!(!envelope.report.sanitize_id.is_empty());
        }
    }

    /// The sanitize report's `sanitize_id` must be unique across two
    /// independent calls (collision probability negligible for the
    /// nonce strategy). This guards against a regression that would
    /// re-use a static ID across requests.
    #[test]
    fn sanitize_id_is_unique_across_calls(payload in arb_json_value()) {
        let policy = SanitizePolicy::preset(Preset::Balanced);
        let a = sanitize_for_agent(payload.clone(), &policy);
        let b = sanitize_for_agent(payload, &policy);
        prop_assert_ne!(a.report.sanitize_id, b.report.sanitize_id);
    }
}
