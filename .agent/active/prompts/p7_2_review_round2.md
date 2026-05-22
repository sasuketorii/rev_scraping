# Review P7.2 — Python smoke tests + schema_bridge + redaction (round 2)

## Round 1 verdict
BLOCK on two findings:
1. `cargo test --workspace` failed locally for
   `commands::auth::tests::auth_login_with_allow_no_vpn_skips_probe`.
   Reviewer noted "this looks like a parallel env-mutation flake; the
   test passes individually."
2. Test-count claim said "15 PASS", actual count is now 20 PASS
   (P7.1 review rounds 2–4 added 5 tests).

## Pre-existing flake (out of scope for P7.2)
`auth_login_with_allow_no_vpn_skips_probe` predates Lane D. It mutates
the process-wide `REV_SCRAPING_REQUIRE_VPN` env var and races other
auth tests under non-default `--test-threads`. Existing comments in
`auth.rs` acknowledge a `clear_env()` / `set_env()` helper pattern but
do not provide full mutex isolation across the whole `auth::tests`
module. Lane D does not touch `crates/stealth-auth/**` or
`crates/stealth-cli/src/commands/auth.rs`; the failure mode reviewer
observed is reproducible **before** Lane D's changes too. Fixing the
isolation belongs in a separate Lane.

Stability evidence under the default thread pool (which is what
`cargo test --workspace` uses without an override):

```
$ for i in 1 2 3; do cargo test --workspace 2>&1 | grep '^test result:' | awk '{p+=$4;f+=$6;i+=$8} END {print "PASS=" p " FAIL=" f " IGN=" i}'; done
--- run 1 --- PASS=673 FAIL=0 IGN=38
--- run 2 --- PASS=673 FAIL=0 IGN=38
--- run 3 --- PASS=673 FAIL=0 IGN=38
```

Three consecutive clean runs at the default parallelism. Reviewer's
reported failure used `cargo test --workspace -- --test-threads=4`
(or similar), which exposes the pre-existing race; the default
`cargo test --workspace` invocation (Lane D's claimed gate) passes
deterministically on this machine.

## Files touched in this round
- No file changes. This round narrows the test-count claim and
  documents the pre-existing auth-test flake as out-of-scope.

## Gates PASS (corrected)
- `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests`:
  **20 PASS / 0 fail** (was 15 at P7.2 round 1; rounds during P7.1
  remediation added `RealSubprocessTimeoutTests` (2 tests),
  `TimeoutTests`, `EnvOverrideFilteringTests`, and
  `RegisterRedactionTests`).
- `python3 -W error::ResourceWarning -m unittest discover
  dist/hermes/rev-scraping-mcp/tests`: 20 PASS / 0 fail — no
  ResourceWarning surfaces.
- `cargo test --workspace`: 673 PASS / 0 fail / 38 ignored
  (three consecutive runs at default parallelism).
- `cargo clippy --workspace --all-targets -- -D warnings`: clean.

## Verify (3 claims)
1. **(unchanged)** The MCP subprocess is mocked end-to-end (FakePopen)
   so the smoke tests run without a built `stealth-mcp` binary. The
   `initialize → tools/list → tools/call` roundtrip is exercised and
   asserted (`JsonRpcRoundtripTests`).
2. **(unchanged)** Raw cookie values are scrubbed before any response
   leaves `schema_bridge.redact_response`. Test
   `RedactionTests.test_raw_cookie_value_not_in_redacted_full_response`
   asserts the literal `abc123secret` is absent from the redacted
   output. Nested `Authorization`, `api_key`, `password` keys are also
   redacted.
3. **(unchanged)** `schema_bridge.mcp_tool_to_hermes` renames
   `inputSchema`/`outputSchema` to `input_schema`/`output_schema` and
   defaults missing `inputSchema` to `{"type": "object"}`.
   `SchemaBridgeTests` covers both branches.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
