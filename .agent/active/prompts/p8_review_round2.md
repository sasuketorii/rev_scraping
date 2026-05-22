# Review P8 — MCP_REFERENCE.md auto-generation (round 2)

## Fix from round 1 BLOCK
Round 1 verdict: BLOCK — generated doc claimed CI job `mcp-schema-lint` runs freshness; that job is a P11 deliverable and does not exist yet.

Fix: replaced the header line in `crates/stealth-mcp/src/reference.rs::write_header` to describe today's actual gate (the `mcp_reference_freshness` regression test that runs under `cargo test --workspace`). Re-ran the generator; the doc + freshness test agree.

## Files touched (same as round 1)
- crates/stealth-agent-contracts/src/error.rs
- crates/stealth-agent-contracts/src/lib.rs
- crates/stealth-mcp/src/lib.rs
- crates/stealth-mcp/src/reference.rs  (header text updated this round)
- crates/stealth-mcp/src/bin/gen_reference.rs
- crates/stealth-mcp/Cargo.toml
- crates/stealth-mcp/tests/mcp_reference_freshness.rs
- docs/MCP_REFERENCE.md  (regenerated)

## Gates PASS
- `cargo test --workspace`: 680 PASS / 0 fail / 38 ign
- `cargo clippy --workspace --all-targets -- -D warnings`: clean
- `cargo run -p stealth-mcp --bin gen_reference -- --check`: exit 0
- `cargo test -p stealth-mcp --test mcp_reference_freshness`: 2 PASS

## Verify (3)
1. The new header text in MCP_REFERENCE.md describes only mechanisms that exist today (the freshness regression test) and no longer references the unimplemented `mcp-schema-lint` CI job.
2. `cargo run -p stealth-mcp --bin gen_reference -- --check` still exits 0 against the committed file (byte-stable).
3. The 26 ErrorKind variants and 16 tools still appear in the generated table; determinism is preserved (BTreeMap for property ordering, fixed canonical order array for ErrorKind, no HashMap in the rendering path).

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
