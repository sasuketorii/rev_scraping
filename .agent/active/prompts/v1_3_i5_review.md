# Review v1.3 I.5 — MCP tool-schema breaking-change detector

## Files touched
- `scripts/mcp-schema-breaking.sh` (new, +90 LOC, executable)
- `.github/workflows/ci.yml` — added `mcp-schema-breaking-detector` job (depends on existing `gen_reference --check` for output-schema freshness, then runs the tool-list diff)

## Gates PASS
- `./scripts/mcp-schema-breaking.sh --check` → exit 0 (16 tools, no drift)
- The existing `mcp-schema-lint` (gen_reference --check) job is **complementary**, not replaced — it gates docs/MCP_REFERENCE.md freshness; I.5 gates the tool-name surface itself.

## Verify (3)
1. Source-of-truth comparison: live tool names extracted from `crates/stealth-mcp/src/tools.rs` (`grep -oE 'name: "..."'`) vs the snapshot's `mcp_tools.names` array. Both lists sorted before diff.
2. Removed / renamed tool ⇒ exit 1 from `--check` ⇒ CI fails ⇒ PR must add `mcp-schema-breaking` label (documented in docs/compat.md).
3. Added tool ⇒ exit 0 with informational stdout ⇒ contributor regenerates snapshot + applies `api-additive` (Lane I.2 contract).

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
