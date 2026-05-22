# Review P3.1 fix round 2.5 — doc/behavior alignment

prior verdict (r2): BLOCK — record_429 rustdoc said Retry-After is "honored
verbatim" but code clamps at 24h.

fix applied in crates/stealth-agent-contracts/src/rate.rs:
1. Rewrote record_429 rustdoc to state: Retry-After is honored up to
   MAX_429_BACKOFF_SECS (24h) and values above the cap are clamped, with
   the rationale (Instant overflow / runtime DoS) documented inline.
2. Promoted DEFAULT_429_BACKOFF_SECS and MAX_429_BACKOFF_SECS to `pub const`
   so the rustdoc intra-doc links resolve cleanly. No new variable surface
   beyond two constants; both are documented.
3. No behavior change since r2 — only documentation alignment.

gates (re-run locally):
- cargo test -p stealth-agent-contracts: 14 passed
- cargo clippy -p stealth-agent-contracts --all-targets -- -D warnings: clean
- cargo doc -p stealth-agent-contracts --no-deps: 0 warnings (previously had
  2 broken-private-link warnings; now resolved).

verify:
1. record_429 rustdoc and impl agree about the 24h clamp.
2. DEFAULT_429_BACKOFF_SECS / MAX_429_BACKOFF_SECS are pub with docs.
3. No other public API change.

return: verdict: LGTM or BLOCK: <reason>
