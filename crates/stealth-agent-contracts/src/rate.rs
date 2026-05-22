// SPDX-License-Identifier: MIT
// Source: rev_scraping Lane C P1+P3.1+P3.2 (stealth-agent-contracts crate, original work)
//! Per-host rate limit configuration and runtime token bucket limiter shared
//! across stealth-* crates.
//!
//! P1 (preserved): [`RateLimitConfig`] is the wire-format contract describing
//! per-host steady-state QPS and burst capacity.
//!
//! P3.1 (added): [`PerHostRateLimiter`] is a `Send + Sync` runtime token
//! bucket limiter, keyed by host string, that honors HTTP `Retry-After`
//! semantics via [`PerHostRateLimiter::record_429`]. Token refill uses the
//! monotonic [`std::time::Instant`] clock (never wall-clock) so leap seconds
//! and NTP slews cannot unblock or stick a host.
//!
//! P3.2 (added): [`ToolRateLimiter`] layers Stripe-style idempotency-key
//! replay on top of [`PerHostRateLimiter`]. Tool invocations carry an
//! [`IdempotencyKey`]; the first completion is cached for a TTL so that an
//! agent retrying on transient failure receives the original
//! [`CompletionRecord`] instead of executing the side effect twice.

use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::{Duration, Instant};
use thiserror::Error;

use crate::error::ErrorEnvelope;

/// Per-host token-bucket rate limit configuration.
///
/// `per_host_qps` is the steady-state queries-per-second cap, and `burst` is
/// the maximum burst size (token bucket capacity).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct RateLimitConfig {
    /// Steady-state queries per second per host.
    pub per_host_qps: f64,
    /// Maximum burst size (token bucket capacity).
    pub burst: u32,
}

impl Default for RateLimitConfig {
    /// Conservative defaults: 1 qps per host, burst of 2.
    fn default() -> Self {
        Self {
            per_host_qps: 1.0,
            burst: 2,
        }
    }
}

/// Reason a [`PerHostRateLimiter::try_acquire`] call was denied.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RateLimitReason {
    /// Steady-state QPS exceeded; bucket is empty and refilling.
    QpsExceeded,
    /// Host is in HTTP 429 cooldown (server-signaled `Retry-After`).
    Retry429,
}

/// Returned when a host is currently rate-limited. `wait_for_ms` is the
/// minimum number of milliseconds the caller should sleep before retrying.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("rate-limited ({reason:?}); retry after {wait_for_ms} ms")]
pub struct RateLimitWait {
    /// Minimum sleep before retry, in milliseconds (rounded up).
    pub wait_for_ms: u64,
    /// Why the request was denied.
    pub reason: RateLimitReason,
}

/// Default exponential backoff floor (seconds) when a 429 omits `Retry-After`.
pub const DEFAULT_429_BACKOFF_SECS: u64 = 30;

/// Upper bound (seconds) for a single `Retry-After` cooldown (24 hours).
///
/// `Retry-After` is network-controlled input, so we clamp it to this
/// documented maximum before adding to a monotonic [`Instant`]. Without this
/// clamp a hostile or buggy server could send a value large enough to
/// overflow `Instant + Duration` and panic the limiter (runtime DoS).
pub const MAX_429_BACKOFF_SECS: u64 = 24 * 60 * 60;

#[derive(Debug)]
struct TokenBucket {
    tokens: f64,
    capacity: f64,
    refill_per_sec: f64,
    last_refill: Instant,
    last_429_until: Option<Instant>,
}

impl TokenBucket {
    fn new(cfg: &RateLimitConfig, now: Instant) -> Self {
        let capacity = f64::from(cfg.burst.max(1));
        Self {
            tokens: capacity,
            capacity,
            refill_per_sec: cfg.per_host_qps.max(0.0),
            last_refill: now,
            last_429_until: None,
        }
    }

    fn refill(&mut self, now: Instant) {
        let elapsed = now
            .saturating_duration_since(self.last_refill)
            .as_secs_f64();
        if elapsed > 0.0 && self.refill_per_sec > 0.0 {
            self.tokens = (self.tokens + elapsed * self.refill_per_sec).min(self.capacity);
        }
        self.last_refill = now;
    }
}

/// Runtime per-host token bucket rate limiter.
///
/// Cheap to clone via `Arc` from the caller side; internally uses [`DashMap`]
/// so distinct hosts never contend on a global lock. All time arithmetic uses
/// the monotonic [`Instant`] clock.
#[derive(Debug)]
pub struct PerHostRateLimiter {
    buckets: DashMap<String, TokenBucket>,
    default_config: RateLimitConfig,
}

impl PerHostRateLimiter {
    /// Construct a new limiter with `default` applied to every host on first
    /// observation.
    #[must_use]
    pub fn new(default: RateLimitConfig) -> Self {
        Self {
            buckets: DashMap::new(),
            default_config: default,
        }
    }

    /// Return the default config (read-only accessor; useful for diagnostics).
    #[must_use]
    pub fn default_config(&self) -> RateLimitConfig {
        self.default_config
    }

    /// Try to acquire a single token for `host`.
    ///
    /// Returns `Ok(())` on success (one token consumed) or
    /// `Err(RateLimitWait)` when the host is currently throttled (either
    /// because of QPS or an in-flight `Retry-After` cooldown).
    ///
    /// # Errors
    /// Returns [`RateLimitWait`] with the reason and the minimum wait
    /// duration in milliseconds.
    pub fn try_acquire(&self, host: &str) -> Result<(), RateLimitWait> {
        let now = Instant::now();
        let mut entry = self
            .buckets
            .entry(host.to_string())
            .or_insert_with(|| TokenBucket::new(&self.default_config, now));

        // 1) 429 cooldown takes priority.
        if let Some(until) = entry.last_429_until {
            if now < until {
                let wait = until.saturating_duration_since(now);
                return Err(RateLimitWait {
                    wait_for_ms: duration_to_ms_ceil(wait),
                    reason: RateLimitReason::Retry429,
                });
            }
            entry.last_429_until = None;
        }

        // 2) Steady-state token bucket.
        entry.refill(now);
        if entry.tokens >= 1.0 {
            entry.tokens -= 1.0;
            return Ok(());
        }

        let needed = 1.0 - entry.tokens;
        let wait_secs = if entry.refill_per_sec > 0.0 {
            needed / entry.refill_per_sec
        } else {
            // Zero refill rate -> effectively never; cap at a sane bound.
            f64::from(u32::MAX)
        };
        let wait_ms = (wait_secs * 1000.0).ceil().max(1.0);
        // Clamp to u64 range without panicking on extreme f64.
        let wait_for_ms = if wait_ms.is_finite() && wait_ms < u64_max_f64() {
            wait_ms as u64
        } else {
            u64::MAX
        };
        Err(RateLimitWait {
            wait_for_ms,
            reason: RateLimitReason::QpsExceeded,
        })
    }

    /// Record an HTTP 429 from `host`.
    ///
    /// If `retry_after_secs` is `Some`, the server's `Retry-After` is honored
    /// up to a documented hard cap of [`MAX_429_BACKOFF_SECS`] (24 hours).
    /// Values above the cap are clamped — this prevents a hostile or buggy
    /// server from feeding a value that overflows `Instant + Duration` and
    /// panicking the limiter. If `retry_after_secs` is `None`, the
    /// exponential backoff floor [`DEFAULT_429_BACKOFF_SECS`] (30 s) is
    /// applied instead.
    pub fn record_429(&self, host: &str, retry_after_secs: Option<u64>) {
        let now = Instant::now();
        let backoff = retry_after_secs
            .unwrap_or(DEFAULT_429_BACKOFF_SECS)
            .min(MAX_429_BACKOFF_SECS);
        // checked_add guards against Instant overflow on platforms with a
        // small monotonic clock domain; saturate to `now` (effectively a
        // no-op cooldown) rather than panic on network-controlled input.
        let until = now.checked_add(Duration::from_secs(backoff)).unwrap_or(now);
        let mut entry = self
            .buckets
            .entry(host.to_string())
            .or_insert_with(|| TokenBucket::new(&self.default_config, now));
        entry.last_429_until = Some(until);
        // Drain bucket so the cooldown is the binding constraint.
        entry.tokens = 0.0;
    }

    /// Record a successful response from `host`. Clears any sticky 429
    /// cooldown so a recovered host is not banned forever.
    pub fn record_success(&self, host: &str) {
        if let Some(mut entry) = self.buckets.get_mut(host) {
            entry.last_429_until = None;
        }
    }
}

fn duration_to_ms_ceil(d: Duration) -> u64 {
    let nanos = u128::from(d.subsec_nanos());
    let secs_ms = d.as_secs().saturating_mul(1000);
    let extra = if nanos == 0 {
        0
    } else {
        nanos.div_ceil(1_000_000)
    };
    secs_ms.saturating_add(u64::try_from(extra).unwrap_or(u64::MAX))
}

fn u64_max_f64() -> f64 {
    // u64::MAX is not exactly representable in f64; this is an upper guard.
    18_446_744_073_709_551_000.0
}

// Asserted at compile time: limiter is safe to share across threads.
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<PerHostRateLimiter>();
    assert_send_sync::<ToolRateLimiter>();
};

// ---------------------------------------------------------------------------
// P3.2: tool-level idempotency-key replay layered on top of per-host limiter.
// ---------------------------------------------------------------------------

/// Default TTL for cached idempotency-key completions (1 hour), matching
/// Stripe's idempotency window for tool replay semantics.
pub const DEFAULT_IDEMPOTENCY_TTL_SECS: u64 = 60 * 60;

/// Opaque idempotency key carried by a tool invocation.
///
/// Wraps a `String` so callers can supply either a UUID v4 (preferred when no
/// natural key exists) or a caller-defined deterministic key. Equality and
/// hashing are case-sensitive byte comparisons — callers MUST normalize their
/// keys before constructing this type if they want case-insensitive matching.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct IdempotencyKey(String);

impl IdempotencyKey {
    /// Construct an [`IdempotencyKey`] from any string-like value.
    #[must_use]
    pub fn new<S: Into<String>>(s: S) -> Self {
        Self(s.into())
    }

    /// Generate a fresh random key (UUID v4) when the caller has no natural
    /// idempotency identity to reuse.
    #[must_use]
    pub fn random() -> Self {
        Self(uuid::Uuid::new_v4().to_string())
    }

    /// Borrow the underlying key as a `&str`.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for IdempotencyKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Cached completion outcome for a previously executed tool invocation.
///
/// `completed_at` is captured from the monotonic [`Instant`] clock so TTL
/// arithmetic cannot be skewed by wall-clock adjustments.
#[derive(Debug, Clone)]
pub struct CompletionRecord {
    /// Result payload: either the tool's JSON output or a structured error
    /// envelope. Replay returns this verbatim.
    pub result: Result<serde_json::Value, ErrorEnvelope>,
    /// Monotonic completion timestamp used for TTL eviction.
    pub completed_at: Instant,
}

impl CompletionRecord {
    fn is_expired(&self, now: Instant, ttl: Duration) -> bool {
        now.saturating_duration_since(self.completed_at) >= ttl
    }
}

/// Tool-level rate limiter combining per-host token-bucket admission control
/// with Stripe-style idempotency-key replay.
///
/// The first completion observed for a given [`IdempotencyKey`] is cached for
/// `ttl`; subsequent [`ToolRateLimiter::check_or_replay`] calls within the
/// window return the cached [`CompletionRecord`] without consuming a host
/// token. After TTL expiry the slot is reclaimable (call
/// [`ToolRateLimiter::gc_expired`] periodically) and the key may be reused.
#[derive(Debug)]
pub struct ToolRateLimiter {
    per_host: Arc<PerHostRateLimiter>,
    completed: DashMap<IdempotencyKey, CompletionRecord>,
    ttl: Duration,
}

impl ToolRateLimiter {
    /// Build a new [`ToolRateLimiter`] wrapping the given per-host limiter.
    #[must_use]
    pub fn new(per_host: Arc<PerHostRateLimiter>, ttl: Duration) -> Self {
        Self {
            per_host,
            completed: DashMap::new(),
            ttl,
        }
    }

    /// Configured replay TTL.
    #[must_use]
    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    /// Decide whether to replay a cached completion, proceed with a fresh
    /// execution, or back off.
    ///
    /// - `Ok(Some(record))`: cache hit within TTL — caller MUST return the
    ///   cached [`CompletionRecord`] without re-running the tool. No host
    ///   token is consumed.
    /// - `Ok(None)`: no cached completion (or it expired); a host token was
    ///   successfully acquired. Caller proceeds with the tool invocation and
    ///   then calls [`ToolRateLimiter::record_completion`].
    /// - `Err(RateLimitWait)`: per-host limiter denied admission. Caller
    ///   should sleep `wait_for_ms` and retry.
    ///
    /// # Errors
    /// Returns [`RateLimitWait`] when the underlying [`PerHostRateLimiter`]
    /// denies the request.
    pub fn check_or_replay(
        &self,
        key: &IdempotencyKey,
        host: &str,
    ) -> Result<Option<CompletionRecord>, RateLimitWait> {
        // 1) Cache lookup: fresh hit short-circuits before touching host tokens.
        let observed_completed_at = {
            if let Some(entry) = self.completed.get(key) {
                let now = Instant::now();
                if !entry.is_expired(now, self.ttl) {
                    return Ok(Some(entry.clone()));
                }
                // Expired: capture the observed completion timestamp so the
                // subsequent removal can be made conditional. We MUST NOT
                // unconditionally `remove()` after dropping the read guard:
                // a concurrent `record_completion` could insert a fresh
                // record in that window and we would silently delete it,
                // violating replay semantics. Using DashMap's `remove_if`
                // with an equality check on `completed_at` makes the eviction
                // atomic with respect to other writers.
                Some(entry.completed_at)
                // entry guard dropped at end of this block.
            } else {
                None
            }
        };
        if let Some(observed_at) = observed_completed_at {
            self.completed
                .remove_if(key, |_, rec| rec.completed_at == observed_at);
        }

        // 2) No live cache entry — admission control via per-host limiter.
        self.per_host.try_acquire(host)?;
        Ok(None)
    }

    /// Record a completed tool invocation under `key`.
    ///
    /// If a record already exists for `key` it is overwritten — callers that
    /// require strict first-writer-wins semantics MUST gate this via their
    /// own check_or_replay round trip.
    pub fn record_completion(
        &self,
        key: IdempotencyKey,
        result: Result<serde_json::Value, ErrorEnvelope>,
    ) {
        self.completed.insert(
            key,
            CompletionRecord {
                result,
                completed_at: Instant::now(),
            },
        );
    }

    /// Evict all completion records older than `ttl`.
    ///
    /// Safe to call on an empty map and safe to call concurrently with
    /// [`ToolRateLimiter::check_or_replay`] (DashMap shard locks serialize
    /// writers).
    pub fn gc_expired(&self) {
        let now = Instant::now();
        let ttl = self.ttl;
        self.completed.retain(|_, rec| !rec.is_expired(now, ttl));
    }

    /// Current number of cached completion records (diagnostic / metrics use).
    #[must_use]
    pub fn cached_len(&self) -> usize {
        self.completed.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn rate_limit_config_default_values() {
        let d = RateLimitConfig::default();
        assert!((d.per_host_qps - 1.0).abs() < f64::EPSILON);
        assert_eq!(d.burst, 2);

        // serde round-trip (P1 contract preserved)
        let j = serde_json::to_string(&d).unwrap();
        let back: RateLimitConfig = serde_json::from_str(&j).unwrap();
        assert_eq!(d, back);
    }

    #[test]
    fn bucket_acquires_under_qps() {
        let l = PerHostRateLimiter::new(RateLimitConfig {
            per_host_qps: 100.0,
            burst: 5,
        });
        // First 5 (capacity) must succeed immediately.
        for _ in 0..5 {
            l.try_acquire("a.example").unwrap();
        }
    }

    #[test]
    fn bucket_blocks_over_burst() {
        let l = PerHostRateLimiter::new(RateLimitConfig {
            per_host_qps: 1.0,
            burst: 2,
        });
        l.try_acquire("b.example").unwrap();
        l.try_acquire("b.example").unwrap();
        let err = l.try_acquire("b.example").unwrap_err();
        assert_eq!(err.reason, RateLimitReason::QpsExceeded);
        assert!(err.wait_for_ms > 0);
    }

    #[test]
    fn bucket_refills_over_time() {
        let l = PerHostRateLimiter::new(RateLimitConfig {
            per_host_qps: 50.0, // 1 token per 20ms
            burst: 1,
        });
        l.try_acquire("c.example").unwrap();
        assert!(l.try_acquire("c.example").is_err());
        // After ~40ms a token should have refilled.
        thread::sleep(Duration::from_millis(40));
        l.try_acquire("c.example")
            .expect("token should have refilled after >20ms");
    }

    #[test]
    fn record_429_sets_retry_after() {
        let l = PerHostRateLimiter::new(RateLimitConfig {
            per_host_qps: 100.0,
            burst: 10,
        });
        l.record_429("d.example", Some(2));
        let err = l.try_acquire("d.example").unwrap_err();
        assert_eq!(err.reason, RateLimitReason::Retry429);
        // Server said 2s; allow slop but must be > 1s.
        assert!(
            err.wait_for_ms > 1_000 && err.wait_for_ms <= 2_000,
            "wait_for_ms = {}",
            err.wait_for_ms
        );
    }

    #[test]
    fn record_429_without_retry_after_uses_backoff_floor() {
        let l = PerHostRateLimiter::new(RateLimitConfig::default());
        l.record_429("e.example", None);
        let err = l.try_acquire("e.example").unwrap_err();
        assert_eq!(err.reason, RateLimitReason::Retry429);
        // Floor is 30s; must be >= ~29s remaining.
        assert!(
            err.wait_for_ms >= 29_000,
            "wait_for_ms = {}",
            err.wait_for_ms
        );
    }

    #[test]
    fn record_429_clamps_hostile_retry_after_no_panic() {
        // u64::MAX seconds would overflow `Instant + Duration` and panic if
        // unclamped. Verify the limiter survives and applies the documented
        // 24h cap.
        let l = PerHostRateLimiter::new(RateLimitConfig::default());
        l.record_429("hostile.example", Some(u64::MAX));
        let err = l.try_acquire("hostile.example").unwrap_err();
        assert_eq!(err.reason, RateLimitReason::Retry429);
        // 24h = 86_400_000 ms; allow generous slop.
        assert!(
            err.wait_for_ms <= MAX_429_BACKOFF_SECS * 1000,
            "wait_for_ms = {} exceeded MAX_429_BACKOFF_SECS cap",
            err.wait_for_ms
        );
        assert!(err.wait_for_ms > (MAX_429_BACKOFF_SECS - 1) * 1000);
    }

    #[test]
    fn record_success_resets_429_state() {
        let l = PerHostRateLimiter::new(RateLimitConfig {
            per_host_qps: 100.0,
            burst: 5,
        });
        l.record_429("f.example", Some(60));
        assert_eq!(
            l.try_acquire("f.example").unwrap_err().reason,
            RateLimitReason::Retry429
        );
        l.record_success("f.example");
        // Cooldown cleared; QPS bucket should allow acquire (capacity > 0
        // because record_429 zeroed tokens, but refill at 100/s gives 1 token
        // in <=10ms; sleep briefly to make the test deterministic).
        thread::sleep(Duration::from_millis(20));
        l.try_acquire("f.example")
            .expect("success should have cleared 429 ban");
    }

    #[test]
    fn per_host_isolation() {
        let l = PerHostRateLimiter::new(RateLimitConfig {
            per_host_qps: 1.0,
            burst: 1,
        });
        l.try_acquire("host-a").unwrap();
        // host-a is now empty, but host-b must be unaffected.
        l.try_acquire("host-b").unwrap();
        // And a 429 on host-a must not bleed into host-b.
        l.record_429("host-a", Some(60));
        let err_a = l.try_acquire("host-a").unwrap_err();
        assert_eq!(err_a.reason, RateLimitReason::Retry429);
        // host-b: bucket already drained by the prior acquire, so this is a
        // QPS denial, NOT a 429. The point is: no Retry429 contagion.
        if let Err(e) = l.try_acquire("host-b") {
            assert_eq!(e.reason, RateLimitReason::QpsExceeded);
        }
    }

    // -----------------------------------------------------------------------
    // P3.2: ToolRateLimiter idempotency-key replay
    // -----------------------------------------------------------------------

    fn fast_tool_limiter(ttl: Duration) -> ToolRateLimiter {
        // Generous host budget so admission control never confounds idempotency
        // assertions in these tests.
        let per_host = Arc::new(PerHostRateLimiter::new(RateLimitConfig {
            per_host_qps: 1_000.0,
            burst: 100,
        }));
        ToolRateLimiter::new(per_host, ttl)
    }

    #[test]
    fn idempotency_key_caches_first_completion() {
        let trl = fast_tool_limiter(Duration::from_secs(60));
        let key = IdempotencyKey::new("tool-call-1");
        // First call: cache miss, host token acquired.
        let miss = trl.check_or_replay(&key, "api.example").unwrap();
        assert!(miss.is_none(), "first call must be a cache miss");
        // Record completion.
        trl.record_completion(key.clone(), Ok(serde_json::json!({"ok": true})));
        assert_eq!(trl.cached_len(), 1);
    }

    #[test]
    fn idempotency_key_replay_returns_cached_within_ttl() {
        let trl = fast_tool_limiter(Duration::from_secs(60));
        let key = IdempotencyKey::new("tool-call-2");
        assert!(trl.check_or_replay(&key, "api.example").unwrap().is_none());
        trl.record_completion(key.clone(), Ok(serde_json::json!({"n": 42})));
        // Second call within TTL: must return cached record verbatim.
        let hit = trl
            .check_or_replay(&key, "api.example")
            .unwrap()
            .expect("expected cache hit within TTL");
        match hit.result {
            Ok(v) => assert_eq!(v, serde_json::json!({"n": 42})),
            Err(e) => panic!("expected Ok cached value, got Err: {e:?}"),
        }
    }

    #[test]
    fn idempotency_key_expires_after_ttl_gc() {
        // Tight TTL so we can observe expiry without long sleeps.
        let trl = fast_tool_limiter(Duration::from_millis(30));
        let key = IdempotencyKey::new("tool-call-3");
        assert!(trl.check_or_replay(&key, "api.example").unwrap().is_none());
        trl.record_completion(key.clone(), Ok(serde_json::Value::Null));
        assert_eq!(trl.cached_len(), 1);
        thread::sleep(Duration::from_millis(60));
        // gc must reclaim the expired slot without panicking.
        trl.gc_expired();
        assert_eq!(trl.cached_len(), 0, "expired record should be evicted");
        // gc on an empty map is also a no-op.
        trl.gc_expired();
        // After expiry, the next check_or_replay is a miss (proceed path).
        let miss_again = trl.check_or_replay(&key, "api.example").unwrap();
        assert!(
            miss_again.is_none(),
            "post-expiry call must be a cache miss"
        );
    }

    #[test]
    fn idempotency_key_unknown_returns_none() {
        let trl = fast_tool_limiter(Duration::from_secs(60));
        let key = IdempotencyKey::random();
        let res = trl.check_or_replay(&key, "api.example").unwrap();
        assert!(res.is_none(), "unknown key must be a cache miss");
        // Distinct random key on each call.
        assert_ne!(IdempotencyKey::random(), IdempotencyKey::random());
    }

    #[test]
    fn idempotency_key_distinct_keys_isolated() {
        let trl = fast_tool_limiter(Duration::from_secs(60));
        let k1 = IdempotencyKey::new("alpha");
        let k2 = IdempotencyKey::new("beta");
        assert!(trl.check_or_replay(&k1, "api.example").unwrap().is_none());
        trl.record_completion(k1.clone(), Ok(serde_json::json!("v1")));
        // k2 must NOT replay k1's result.
        let res_k2 = trl.check_or_replay(&k2, "api.example").unwrap();
        assert!(res_k2.is_none(), "distinct key must not collide with k1");
        trl.record_completion(k2.clone(), Ok(serde_json::json!("v2")));
        // Each key replays its own value.
        let hit_k1 = trl.check_or_replay(&k1, "api.example").unwrap().unwrap();
        let hit_k2 = trl.check_or_replay(&k2, "api.example").unwrap().unwrap();
        assert_eq!(hit_k1.result.unwrap(), serde_json::json!("v1"));
        assert_eq!(hit_k2.result.unwrap(), serde_json::json!("v2"));
    }
}
