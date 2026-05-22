# Review P3.2 round 2 — per-tool rate-limit + idempotency-key

scope: `crates/stealth-agent-contracts/src/rate.rs`, `lib.rs` re-exports,
`Cargo.toml` (serde_json promoted).

round-1 BLOCK (your verdict): expired-eviction race in `check_or_replay`
between dropping the read guard and unconditional `remove()` could clobber a
concurrent `record_completion` insert.

round-2 FIX (rate.rs `check_or_replay`, ~lines 360-385): capture the observed
`completed_at: Instant` while the read guard is held, drop the guard, then
call `self.completed.remove_if(key, |_, rec| rec.completed_at == observed_at)`
so the eviction is atomic w.r.t. any racing writer. A fresh record inserted
between the guard drop and the remove will have a strictly later
`completed_at` Instant, so the predicate returns `false` and the new record
survives. Documented inline.

gates re-run PASS:
- `cargo test -p stealth-agent-contracts` = 19/19
- `cargo test --workspace --no-fail-fast` = 584 passed / 0 failed
- `cargo clippy -p stealth-agent-contracts --all-targets -- -D warnings` clean
- SPDX preserved on all 4 src files; no vendor/_refs/baseline edits

verify the fix:
1. Race fix uses `remove_if` with `completed_at` equality (atomic via shard
   lock); no unconditional `remove()` after guard drop.
2. `Instant` is monotonic so a later `record_completion` is guaranteed
   `>= observed_at` — equality predicate cannot false-positive across writers.
3. All 14 P1+P3.1 tests preserved; 5 P3.2 tests still pass.
4. `Send+Sync` compile-time assertion for `ToolRateLimiter` still present.
5. No secret material added in tests/docs.

return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
