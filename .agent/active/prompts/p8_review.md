# Review P8 — MCP_REFERENCE.md auto-generation

## Files touched
- crates/stealth-agent-contracts/src/error.rs (added `ErrorKindDoc` struct + `all_error_kind_docs()` returning the 26 variants in canonical order, exhaustive no-wildcard match)
- crates/stealth-agent-contracts/src/lib.rs (re-export `all_error_kind_docs`, `ErrorKindDoc`)
- crates/stealth-mcp/src/lib.rs (declare `pub mod reference;`)
- crates/stealth-mcp/src/reference.rs (new — `render_reference()` deterministic markdown renderer; uses `BTreeMap` for property ordering, `Vec` declared order for tools, canonical order for ErrorKind; 4 unit tests)
- crates/stealth-mcp/src/bin/gen_reference.rs (new binary; default = write, `--check` = compare-only-exit-1-on-drift, `--output PATH` override)
- crates/stealth-mcp/Cargo.toml (declared `[[bin]] gen_reference`)
- crates/stealth-mcp/tests/mcp_reference_freshness.rs (new — freshness regression test + determinism cross-check)
- docs/MCP_REFERENCE.md (new — generated, 835 lines)

## Gates PASS
- `cargo test --workspace`: 680 PASS / 0 fail / 38 ign (baseline was 674; +6 = 4 reference unit tests + 2 freshness integration tests)
- `cargo clippy --workspace --all-targets -- -D warnings`: clean
- `cargo fmt -p stealth-agent-contracts -p stealth-mcp --check`: clean (pre-existing fmt drift in unrelated crates left untouched)
- `cargo run -p stealth-mcp --bin gen_reference` → writes 835-line MCP_REFERENCE.md
- Re-running with `--check` → exit 0 (byte-stable)
- Freshness test alone: `cargo test -p stealth-mcp --test mcp_reference_freshness` → 2 PASS

## Verify (3)
1. The renderer is deterministic across runs: `cargo run -p stealth-mcp --bin gen_reference -- --check` returns exit 0 against the file just written by the regular run. `render_reference()` uses `BTreeMap` for per-tool input/output properties, `Vec` declared order for `tool_definitions()`, and the fixed canonical order array inside `all_error_kind_docs()` (no `HashMap` anywhere in the rendering path).
2. The doc is rebuildable from the in-tree sources only — no external network or local cache. The generator binary calls `stealth_mcp::reference::render_reference()`, which depends only on `tool_definitions()` (already include_str!'d output schemas) and `all_error_kind_docs()`. The freshness test asserts byte-equality with the committed file.
3. The 26 ErrorKind variants are surfaced by the `all_error_kind_docs()` exhaustive match (no wildcard, `#[forbid(unreachable_patterns)]`), so adding a 27th variant to `ErrorKind` is a compile error until a matching `ErrorKindDoc` row is added — preventing silent doc drift on the closed-enum boundary.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
