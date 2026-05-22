# Review P3.1 per-host token bucket rate limit

scope: Lane C P3.1 (≤1.5d slice). Adds runtime per-host token bucket limiter
to stealth-agent-contracts, preserving P1 RateLimitConfig wire contract.

files:
- crates/stealth-agent-contracts/src/rate.rs (expanded; P1 config preserved)
- crates/stealth-agent-contracts/src/lib.rs  (+3 re-exports)
- crates/stealth-agent-contracts/Cargo.toml  (+dashmap workspace dep)
- Cargo.toml                                 (+dashmap = "6" workspace)

gates PASS (locally):
- cargo test -p stealth-agent-contracts: 13 passed (was 4, +7 from rate)
- cargo test --workspace --no-fail-fast: 566 passed (baseline 559, +7)
- cargo clippy --workspace --all-targets -- -D warnings: clean
- SPDX header preserved on rate.rs
- baseline diff: vendor/_refs untouched
- existing 4 P1 tests preserved (error_envelope_serde_round_trip,
  error_kind_closed_enum_no_invalid_variant, progress_token_uuid_v4_unique,
  token_rejects_non_v4_uuid_on_deserialize, rate_limit_config_default_values)

verify:
1. PerHostRateLimiter is Send+Sync (compile-time assertion at end of rate.rs).
2. Token refill uses monotonic std::time::Instant only — no SystemTime / wall
   clock. Grep `SystemTime` in rate.rs to confirm absent.
3. record_429 honors Retry-After: Some(n) -> n secs; None -> 30s exponential
   backoff floor (DEFAULT_429_BACKOFF_SECS).
4. record_success clears last_429_until so a recovered host is not stuck
   banned. Covered by test record_success_resets_429_state.
5. per_host_isolation: DashMap-keyed; no global lock. Test
   per_host_isolation asserts host A's 429 cooldown does not cause Retry429
   on host B.
6. RateLimitConfig serde wire-format unchanged (test
   rate_limit_config_default_values still passes; round-trips JSON).
7. No unsafe; #![forbid(unsafe_code)] preserved on lib.rs.
8. RateLimitWait derives Error via thiserror; wait_for_ms uses ceiling
   conversion so callers never sleep 0 ms on sub-ms residual waits.

return: verdict: LGTM or BLOCK: <reason>
