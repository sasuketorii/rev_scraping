# Review P7.1 — Hermes adapter scaffold (round 2)

## Round 1 verdict
BLOCK with three findings:
1. **Redaction defined but not wired** — `tool_proxy` returned raw
   `supervised.call_tool(...)` result. ✅ Fixed.
2. **`readline()` blocks past the deadline on a live silent child**;
   `INITIALIZE_TIMEOUT` / call timeouts could not fire and the 32-attempt
   supervisor cap was unreachable. ✅ Fixed.
3. **Claim 3 over-stated** — `/dist/*` only ignores top-level; nested
   `dist/` trees other than `scripts/semantic-mcp-server/dist/` are not
   ignored. Narrowed below. (No file change; scope-honest restatement.)
4. **Residual**: `McpClient(env=...)` override bypassed `filter_env()`.
   ✅ Fixed.

## Files touched in this round
- `dist/hermes/rev-scraping-mcp/__init__.py` — `invoker` now wraps every
  `supervised.call_tool` response with `schema_bridge.redact_response`
  before returning to the Hermes ctx.
- `dist/hermes/rev-scraping-mcp/mcp_client.py`:
  * `McpClient.start()` re-filters caller-supplied `env=` through
    `filter_env(...)`, so a future caller cannot smuggle
    `ANTHROPIC_API_KEY` et al. into the child by passing `env=os.environ`.
  * New `_readline_with_deadline(stream, deadline)` uses `select.select`
    on the underlying fd (when available) so a silent live child trips
    the deadline. A pure-Python fallback handles in-memory test fakes.
  * `_recv()` now treats either deadline expiry **or** a dead child as
    `McpProtocolError`, which `SupervisedClient` can surface within its
    32-attempt cap.
- `dist/hermes/rev-scraping-mcp/tests/test_smoke.py` — three new tests:
  * `TimeoutTests::test_silent_child_times_out` — silent child raises
    `McpProtocolError` (uses monkey-patched 0.1s `INITIALIZE_TIMEOUT`).
  * `EnvOverrideFilteringTests::test_explicit_env_override_is_filtered`
    — `env=os.environ`-shaped override has secrets stripped.
  * `RegisterRedactionTests::test_register_invoker_redacts_cookie_values`
    — full `register(ctx)` path: registered tool function does not echo
    the raw cookie value.

## Gates PASS
- `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests`:
  18 PASS / 0 fail (was 15; +3 round-2 tests).
- `cargo test --workspace`: 673 PASS / 0 fail (unchanged from round 1).
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.

## Verify (3 claims)
1. `register(ctx)`'s invoker calls `redact_response` on every
   `tools/call` result before returning to Hermes
   (`dist/hermes/rev-scraping-mcp/__init__.py` invoker closure). The new
   `RegisterRedactionTests` test exercises the full register path
   (FakePopen returns `Set-Cookie: session_id=abc123secret`) and asserts
   `abc123secret` is absent from the proxied result.
2. A silent live child surfaces `McpProtocolError` within
   `INITIALIZE_TIMEOUT` / `DEFAULT_CALL_TIMEOUT` because
   `_readline_with_deadline` uses `select.select` on the stdout fd and
   `_recv` raises on deadline expiry; covered by
   `TimeoutTests::test_silent_child_times_out`.
3. Any `env=` override passed to `McpClient` is re-filtered through
   `filter_env(...)` in `start()`, so secret-shaped env (`ANTHROPIC_API_KEY`,
   `OPENAI_API_KEY`, ...) cannot reach the spawned child even if a
   future caller forgets to scrub upstream; covered by
   `EnvOverrideFilteringTests::test_explicit_env_override_is_filtered`.

## Scope-honest restatement of round-1 claim 3
The `.gitignore` change preserves the existing `/dist/*` exclusion and
adds **only** `!/dist/hermes`, parallel to `!/dist/systemd`. Broader
nested-package `dist/` coverage was pre-existing (only
`scripts/semantic-mcp-server/dist/` is explicitly re-ignored) and is
**out of scope** for Lane D / P7.1 — it predates this change and
belongs in a separate gitignore-hygiene task.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
