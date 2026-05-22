# Review P7.2 — Python smoke tests + schema_bridge + cookie redaction

## Scope
Lane D / P7.2. Add pure-stdlib `unittest` smoke tests under
`dist/hermes/rev-scraping-mcp/tests/`, plus the MCP→Hermes schema bridge
and response redaction helpers in `schema_bridge.py`.

## Files touched
- `dist/hermes/rev-scraping-mcp/tests/__init__.py` (new — package marker)
- `dist/hermes/rev-scraping-mcp/tests/test_smoke.py` (new — 15 tests covering env scrubbing, initialize/tools/list/tools/call roundtrip, cookie & secret-field redaction, schema_bridge passthrough, backoff schedule, tool proxy dispatch, register-with-fake-ctx end-to-end)
- `dist/hermes/rev-scraping-mcp/schema_bridge.py` (already created in P7.1 commit; exercised here)
- `dist/hermes/rev-scraping-mcp/__init__.py` + `lifecycle.py` (relative-import dual-path fallback so tests can load modules without parent-package context; no behaviour change when Hermes loads the package normally)

## Gates PASS
- `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests`:
  15 PASS / 0 fail (Python 3.14.5)
- `cargo test --workspace`: 673 PASS / 0 fail (unchanged from P7.1 review)
- `cargo clippy --workspace --all-targets -- -D warnings`: clean

## Verify (3 claims)
1. The MCP subprocess is mocked end-to-end (`FakePopen` in `test_smoke.py`)
   so the smoke tests run without a built `stealth-mcp` binary. The
   `initialize → tools/list → tools/call` roundtrip is exercised and
   asserted (`JsonRpcRoundtripTests`).
2. Raw cookie values are scrubbed before any response leaves
   `schema_bridge.redact_response`. The test
   `RedactionTests.test_raw_cookie_value_not_in_redacted_full_response`
   takes the FakePopen response (which embeds the literal
   `abc123secret`) and asserts the JSON-serialized redacted output does
   not contain that substring. Nested `Authorization`, `api_key`,
   `password` keys are also redacted.
3. `schema_bridge.mcp_tool_to_hermes` is a passthrough that renames
   `inputSchema`/`outputSchema` → `input_schema`/`output_schema` and
   defaults missing `inputSchema` to `{"type": "object"}`. Test:
   `SchemaBridgeTests`.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
