# Review P3.1 fix round 2 — Instant overflow guard

prior verdict: BLOCK on rate.rs record_429 Instant + Duration overflow with
network-controlled Retry-After.

fix applied in crates/stealth-agent-contracts/src/rate.rs:
1. Added MAX_429_BACKOFF_SECS = 86_400 (24h) documented upper bound.
2. record_429 now clamps retry_after_secs via `.min(MAX_429_BACKOFF_SECS)`
   before constructing the Duration.
3. Instant arithmetic uses `now.checked_add(...).unwrap_or(now)` as a second
   layer of defense — saturates to `now` (no-op cooldown) on platform
   overflow rather than panicking.
4. New test `record_429_clamps_hostile_retry_after_no_panic` feeds
   `Some(u64::MAX)` and asserts:
   - no panic
   - reason == Retry429
   - wait_for_ms <= MAX_429_BACKOFF_SECS * 1000
   - wait_for_ms > (MAX_429_BACKOFF_SECS - 1) * 1000  (clamp actually fires)

gates (re-run locally):
- cargo test -p stealth-agent-contracts: 14 passed (was 13, +1 overflow test)
- cargo clippy -p stealth-agent-contracts --all-targets -- -D warnings: clean
- baseline P1 tests still pass (rate_limit_config_default_values, error x2,
  token x2).

verify:
1. record_429 cannot panic regardless of retry_after_secs value (clamp +
   checked_add).
2. MAX_429_BACKOFF_SECS = 24h is documented in rustdoc on the constant.
3. No regressions in the other 7 P3.1 tests.
4. Public API surface unchanged (record_429 signature stable).

return: verdict: LGTM or BLOCK: <reason>
