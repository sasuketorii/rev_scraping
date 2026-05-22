# Review P3.3 progress + cancel
files:
- crates/stealth-agent-contracts/src/progress.rs (NEW)
- crates/stealth-agent-contracts/src/lib.rs (+pub mod, re-export Tracker/State)
- crates/stealth-agent-contracts/Cargo.toml (+tokio sync dep; dev: rt,macros,time)

gates PASS:
- cargo test -p stealth-agent-contracts -> 24 passed (19 baseline + 5 new)
- cargo test --workspace --no-fail-fast --exclude stealth-cli -> 394 pass, 0 FAIL
  (stealth-cli has pre-existing compile errors in src/doctor.rs, NOT caused by P3.3;
   verified via git stash: errors persist without our changes — out of slice scope)
- cargo clippy -p stealth-agent-contracts --all-targets -- -D warnings -> clean
- baseline diff: only contracts crate (vendor/_refs untouched)

verify:
1. snapshot() returns owned ProgressState (Clone), not &ref — tracker_snapshot_is_consistent
   proves post-snapshot mutation does not affect captured copy.
2. cancel() idempotent: AtomicBool::store inherently idempotent; multi-call no panic
   (cancel_flag_propagates).
3. AtomicBool ordering: cancel uses Release, is_cancelled uses Acquire (NOT Relaxed) ->
   happens-before between issuer and checkpoint reader.
4. notify_waiters (broadcast) used in BOTH report() and cancel() — wakes all parked
   watchers, not single.
5. wait_for_update -> impl Future<Output=()> + '_; composes with tokio::time::timeout
   (demonstrated in wait_for_update_resolves_after_report).
6. 19 existing tests (token + rate + error) untouched.
7. Send+Sync compile-time assert on ProgressTracker AND ProgressState (const _ block).

notes:
- Mutex.lock().expect(...) panics on poison: acceptable; poison implies prior panic
  while holding lock — state already untrustworthy.
- wait_for_update has no stored permit (Notify::notified): documented; callers
  snapshot() first if they need initial state.

return: verdict: LGTM or BLOCK: <reason>
