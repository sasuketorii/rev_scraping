# Review P7.1 — Hermes adapter scaffold (round 4 / final)

## Round 3 verdict
BLOCK on a single narrow finding:
- `stop()` only closed `stdin` inside the `if self._proc.poll() is
  None` branch. If the child wrote a partial frame, flushed, and
  exited (`sys.exit(0)`) before the handshake deadline fired,
  `start()`'s failure path called `stop()` with `poll()` already
  returning 0, leaving parent-side `stdin` open. Reviewer confirmed
  with a real-subprocess probe and `python3 -Wd`.

## Round 4 fix
- `dist/hermes/rev-scraping-mcp/mcp_client.py`:
  * `stop()` now closes **all three** parent-side pipes
    (`stdin` / `stdout` / `stderr`) unconditionally after the
    live-child wait/escalate path, including the case where `poll()`
    is already non-None. The close loop uses `not getattr(s,
    "closed", True)` so closing an already-closed stream is a no-op.
- `dist/hermes/rev-scraping-mcp/tests/test_smoke.py`:
  * New regression test
    `RealSubprocessTimeoutTests::test_dead_child_no_fd_leak_after_start_failure`
    spawns a `python3 -c "...write b'{'; sys.exit(0)"` child, lets
    `start()` raise via the partial-frame timeout, then asserts that
    `proc.stdin`, `proc.stdout`, and `proc.stderr` are all `closed`.

## Files touched in this round
- `dist/hermes/rev-scraping-mcp/mcp_client.py`
- `dist/hermes/rev-scraping-mcp/tests/test_smoke.py`

## Gates PASS
- `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests`:
  20 PASS / 0 fail / 0.95s (was 19; +1 dead-child fd-leak regression).
- `python3 -W error::ResourceWarning -m unittest discover
  dist/hermes/rev-scraping-mcp/tests`: 20 PASS / 0 fail — no
  ResourceWarning surfaces from the close loop.
- `cargo test --workspace`: 673 PASS / 0 fail / 38 ignored.
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.

## Verify (3 claims)
1. `stop()` closes `stdin`, `stdout`, and `stderr` whether or not the
   child is still running. The dead-child branch (round 3 reviewer's
   reproducer: partial frame + `sys.exit(0)`) is covered by
   `RealSubprocessTimeoutTests::test_dead_child_no_fd_leak_after_start_failure`.
2. Closing an already-closed stream is a no-op via
   `not getattr(s, "closed", True)`, so the new unconditional close
   loop does not double-close on the live-child path.
3. The live-child wait/escalate sequence is unchanged: still closes
   stdin first to signal EOF, waits up to ``timeout``, then escalates
   to ``terminate()`` / ``kill()`` on `TimeoutExpired`.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
