# Review P7.1 — Hermes adapter scaffold (round 3)

## Round 2 verdict
BLOCK on a single finding:
- `_readline_with_deadline` used `select.select` to wait for readability
  but then called `stream.readline()`, which still blocks until `\n` or
  EOF — so a wedged child writing a partial frame (e.g. `{` then sleep)
  bypassed the deadline. Reviewer confirmed with a real-subprocess
  probe; the new in-memory test did not exercise that path.

## Round 3 fix
- `dist/hermes/rev-scraping-mcp/mcp_client.py`:
  * `_readline_with_deadline` no longer calls `stream.readline()` on
    the fd path. Instead it reads raw bytes with `os.read(fd, 4096)`
    inside the `select` loop and assembles lines manually, carrying
    over any partial bytes across `_recv` calls via the new
    `self._byte_carry` buffer. The deadline is checked before every
    `select` slice and on every loop iteration, so a child that writes
    a partial line and sleeps now times out reliably.
  * Production stdio is now opened with `text=False, bufsize=0` so the
    `os.read` path is not racing Python's text-mode buffer. A new
    `binary_io: Optional[bool]` constructor kwarg lets tests force the
    binary path through a wrapped factory (default infers from
    `popen_factory is subprocess.Popen`).
  * `_send` probes text vs bytes via try/except and encodes UTF-8 on
    the binary path. Test fakes continue to use text-mode pipes
    unchanged.
  * `start()` now calls `self.stop(timeout=0.5)` if `_initialize`
    raises, so a wedged peer cannot leak file descriptors when the
    handshake deadline fires.
  * `stop()` closes stdout/stderr in addition to stdin to silence
    `ResourceWarning` from unittest's filter.
- `dist/hermes/rev-scraping-mcp/tests/test_smoke.py`:
  * New `RealSubprocessTimeoutTests::test_partial_frame_does_not_wedge_past_deadline`
    spawns a real `python3 -c '...'` child that writes `{` (no newline)
    then sleeps 30s. With `INITIALIZE_TIMEOUT=0.3s` the client raises
    `McpProtocolError` well under the 10s bound (~0.5s observed on
    macOS Python 3.14). Exercises the production `binary_io=True` path.

## Files touched in this round
- `dist/hermes/rev-scraping-mcp/mcp_client.py`
- `dist/hermes/rev-scraping-mcp/tests/test_smoke.py`

## Gates PASS
- `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests`:
  19 PASS / 0 fail / total runtime ~0.9s (was 18; +1 real-subprocess
  partial-frame test).
- `cargo test --workspace`: 673 PASS / 0 fail / 38 ignored.
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.

## Verify (3 claims)
1. A live child that writes a partial JSON-RPC frame (no `\n`) and
   sleeps past the deadline now raises `McpProtocolError` within the
   configured timeout. Covered by the new real-subprocess test
   (`RealSubprocessTimeoutTests`) which forces `binary_io=True` and
   uses `python3 -c "...write b'{'; sleep 30"`; the client raises in
   ~0.5s, asserted under a 10s bound.
2. The production stdio path uses raw bytes (`text=False, bufsize=0`)
   and `os.read(fd, 4096)` so Python's text-mode buffer cannot swallow
   data that bypassed the deadline. Partial bytes carry across `_recv`
   calls via `self._byte_carry` (reset on `start()` / `stop()`).
3. Half-spawned child fd leaks are no longer possible on handshake
   failure: `start()` calls `self.stop(timeout=0.5)` in the
   `_initialize` exception path, and `stop()` closes stdin **and**
   stdout/stderr.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
