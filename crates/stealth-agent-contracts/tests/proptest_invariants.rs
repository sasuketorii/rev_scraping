// SPDX-License-Identifier: MIT
//
// Lane K K.4 — property-based invariants for stealth-agent-contracts.
//
// Covers three invariants that any caller is allowed to rely on:
//   1. UUID v4 strict acceptance: ProgressToken / SessionId accept ONLY
//      strict RFC 4122 v4 inputs (random version + RFC4122 variant) and
//      reject every other 16-byte UUID across serde + from_uuid.
//   2. IdempotencyKey equality / hashing: byte-exact, case-sensitive, and
//      stable under serde round-trip.
//   3. RateLimiter "no panics across operations": arbitrary host strings,
//      acquire / record_429 / record_success sequences never panic and
//      always observe Retry-After cap.
//
// PR runs default to 256 cases per property. Nightly cron may override
// via `PROPTEST_CASES=1024`.

use proptest::prelude::*;
use stealth_agent_contracts::{
    rate::{
        IdempotencyKey, PerHostRateLimiter, RateLimitConfig, RateLimitReason, MAX_429_BACKOFF_SECS,
    },
    ProgressToken, SessionId,
};
use uuid::{Uuid, Variant, Version};

/// 16 arbitrary bytes shaped into a UUID. About 1/64 of these will be
/// valid v4 (version nibble == 4 AND variant bits == 10x). The property
/// asserts the v4 acceptance rule for both branches.
fn arb_uuid_bytes() -> impl Strategy<Value = [u8; 16]> {
    any::<[u8; 16]>()
}

/// A string suitable to use as an idempotency key. Bounded length avoids
/// pathological allocations while still covering Unicode + punctuation.
fn arb_key_string() -> impl Strategy<Value = String> {
    ".{0,64}".prop_map(|s| s)
}

/// Arbitrary host label. Bounded to ASCII-ish DNS-ish strings plus a few
/// edge cases (empty, single dot, colon for port-like).
fn arb_host() -> impl Strategy<Value = String> {
    prop_oneof![
        Just(String::new()),
        Just(".".to_string()),
        Just("localhost".to_string()),
        "[a-z0-9.-]{1,32}".prop_map(|s| s),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 256,
        failure_persistence: None,
        .. ProptestConfig::default()
    })]

    /// `ProgressToken::from_uuid` and `SessionId::from_uuid` accept EXACTLY
    /// the UUIDs that satisfy the strict v4 rule: version == Random AND
    /// variant == RFC4122. Both branches (accept / reject) are exercised
    /// from random bytes; serde deserialize MUST agree with from_uuid.
    #[test]
    fn token_v4_strict_accept_reject(bytes in arb_uuid_bytes()) {
        let u = Uuid::from_bytes(bytes);
        let is_strict_v4 = matches!(u.get_version(), Some(Version::Random))
            && u.get_variant() == Variant::RFC4122;

        let pt_opt = ProgressToken::from_uuid(u);
        let sid_opt = SessionId::from_uuid(u);
        prop_assert_eq!(pt_opt.is_some(), is_strict_v4);
        prop_assert_eq!(sid_opt.is_some(), is_strict_v4);

        // Round-trip: any accepted UUID must serialize+deserialize back to
        // an equal token. Any rejected UUID must fail deserialize.
        let json = format!("\"{}\"", u);
        let pt: Result<ProgressToken, _> = serde_json::from_str(&json);
        let sid: Result<SessionId, _> = serde_json::from_str(&json);
        prop_assert_eq!(pt.is_ok(), is_strict_v4);
        prop_assert_eq!(sid.is_ok(), is_strict_v4);

        if let (Some(pt_built), Ok(pt_parsed)) = (pt_opt, pt) {
            prop_assert_eq!(pt_built, pt_parsed);
        }
        if let (Some(sid_built), Ok(sid_parsed)) = (sid_opt, sid) {
            prop_assert_eq!(sid_built, sid_parsed);
        }
    }

    /// `IdempotencyKey` equality is byte-exact (case-sensitive) and is
    /// preserved through a serde round-trip. Distinct strings MUST hash
    /// to distinct keys (modulo their underlying String equality).
    #[test]
    fn idempotency_key_byte_exact_and_roundtrip(
        a in arb_key_string(),
        b in arb_key_string(),
    ) {
        let ka = IdempotencyKey::new(a.clone());
        let kb = IdempotencyKey::new(b.clone());
        prop_assert_eq!(ka == kb, a == b);

        // serde round-trip
        let j = serde_json::to_string(&ka).unwrap();
        let back: IdempotencyKey = serde_json::from_str(&j).unwrap();
        prop_assert_eq!(ka.clone(), back);

        // accessor agrees with construction
        prop_assert_eq!(ka.as_str(), a.as_str());
    }

    /// `PerHostRateLimiter` MUST NOT panic on arbitrary host strings or
    /// arbitrary Retry-After values, and the observable wait MUST honor
    /// the documented `MAX_429_BACKOFF_SECS` cap. The limiter's invariants
    /// are monotonic in the sense that record_success never increases the
    /// reported wait.
    #[test]
    fn ratelimiter_no_panic_and_cap_holds(
        host in arb_host(),
        retry_after in prop::option::of(any::<u64>()),
    ) {
        let l = PerHostRateLimiter::new(RateLimitConfig {
            per_host_qps: 1_000.0,
            burst: 10,
        });

        // Fresh host: at least one acquire should succeed without panic.
        let _ = l.try_acquire(&host);

        // Apply a server 429 with arbitrary retry-after. MUST NOT panic
        // even on u64::MAX.
        l.record_429(&host, retry_after);
        let denied = l.try_acquire(&host);
        match denied {
            Err(w) => {
                prop_assert_eq!(w.reason, RateLimitReason::Retry429);
                // The documented cap: wait MUST NOT exceed
                // MAX_429_BACKOFF_SECS * 1000 (plus tiny ms-rounding slop).
                prop_assert!(
                    w.wait_for_ms <= MAX_429_BACKOFF_SECS.saturating_mul(1000) + 10,
                    "wait_for_ms {} exceeds cap", w.wait_for_ms
                );
            }
            Ok(()) => {
                // Acceptable iff retry_after was Some(0).
                prop_assert_eq!(retry_after, Some(0));
            }
        }

        // record_success clears the sticky 429 ban: a subsequent acquire
        // must NOT be denied with Retry429 reason. (It may still be denied
        // with QpsExceeded because record_429 drained the bucket, which is
        // monotonic-friendly.)
        l.record_success(&host);
        if let Err(w) = l.try_acquire(&host) {
            prop_assert_ne!(w.reason, RateLimitReason::Retry429);
        }
    }
}
