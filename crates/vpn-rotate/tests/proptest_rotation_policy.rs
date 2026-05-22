// SPDX-License-Identifier: MIT
//
// Lane K K.4 — property-based invariants for vpn-rotate strategy parsing
// and rotation-request shape.
//
// Two invariants:
//   1. `RotationStrategy::from_slug` is a total function from a known set
//      of accepted slugs and rejects every other input (no panic, no
//      partial parsing). Round-trips via serde with the kebab-case repr.
//   2. `RotationRequest` round-trips through serde JSON without loss for
//      every (provider, strategy, region, reason) shape that callers can
//      construct.
//
// PR runs default to 256 cases per property.

use proptest::prelude::*;
use vpn_rotate::{RotationRequest, RotationStrategy};

/// Known accepted slugs and the strategy they map to. Anything not in
/// this set MUST be rejected by `from_slug`.
fn accepted_slugs() -> Vec<(&'static str, RotationStrategy)> {
    vec![
        ("lazy-on-fail", RotationStrategy::LazyOnFail),
        ("lazy", RotationStrategy::LazyOnFail),
        ("every-n", RotationStrategy::EveryN),
        ("every", RotationStrategy::EveryN),
        ("interval", RotationStrategy::Interval),
    ]
}

fn arb_slug() -> impl Strategy<Value = String> {
    // Mix accepted slugs (must parse) with arbitrary noise (must reject).
    prop_oneof![
        Just("lazy-on-fail".to_string()),
        Just("lazy".to_string()),
        Just("every-n".to_string()),
        Just("every".to_string()),
        Just("interval".to_string()),
        "[a-z0-9_-]{0,16}".prop_map(|s| s),
    ]
}

fn arb_strategy() -> impl Strategy<Value = RotationStrategy> {
    prop_oneof![
        Just(RotationStrategy::LazyOnFail),
        Just(RotationStrategy::EveryN),
        Just(RotationStrategy::Interval),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 256,
        failure_persistence: None,
        .. ProptestConfig::default()
    })]

    /// `from_slug` MUST be total: accept exactly the documented set,
    /// reject everything else, never panic.
    #[test]
    fn rotation_strategy_from_slug_total(slug in arb_slug()) {
        let parsed = RotationStrategy::from_slug(&slug);
        let expected = accepted_slugs()
            .into_iter()
            .find(|(k, _)| *k == slug)
            .map(|(_, v)| v);
        prop_assert_eq!(parsed, expected);
    }

    /// `RotationRequest` MUST round-trip through serde JSON with no loss
    /// regardless of which strategy is chosen. This guards the wire
    /// contract used by the rev-stealth CLI and the MCP rotate tool.
    #[test]
    fn rotation_request_json_roundtrip(
        provider in "[a-z0-9-]{1,16}",
        strategy in arb_strategy(),
        region in prop::option::of("[a-z0-9-]{1,16}"),
        reason in ".{0,64}",
    ) {
        let req = RotationRequest {
            provider: provider.clone(),
            strategy,
            region: region.clone(),
            reason: reason.clone(),
        };
        let j = serde_json::to_string(&req).expect("serialize must succeed");
        let back: RotationRequest =
            serde_json::from_str(&j).expect("deserialize must succeed");
        prop_assert_eq!(back.provider, provider);
        prop_assert_eq!(back.strategy, strategy);
        prop_assert_eq!(back.region, region);
        prop_assert_eq!(back.reason, reason);
    }
}
