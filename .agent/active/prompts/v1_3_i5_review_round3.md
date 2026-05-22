# Review v1.3 I.5 (Round 3)

R2 BLOCK addressed:

The detector only compared tool names; docs/compat.md promised coverage of required-arg, enum, and output-field breaks too. Fixed:

1. **Extended `scripts/mcp-schema-breaking.sh`** to compare live snapshot's `mcp_tools.schemas.<tool>.required` vs base. Tightened required-args (optional→required) flagged BREAKING; relaxed (required→optional) noted, not blocking.

2. **Aligned `docs/compat.md`** to accurately split responsibility:
   - `scripts/mcp-schema-breaking.sh` → tool name removes/renames + required-arg tightening (snapshot-based diff).
   - `mcp-schema-lint` (`gen_reference --check`) → value-enum and output-field changes via the rendered docs/MCP_REFERENCE.md.
   Together they cover the at-a-glance promise. Enum/output coverage in the snapshot itself is tracked for v1.4.

## Files touched (delta)
- `scripts/mcp-schema-breaking.sh` — diff logic rewrite (4 buckets: added/removed/tightened/relaxed).
- `docs/compat.md` — MCP-tier cell rewritten to split responsibilities.

## Gates PASS
- `./scripts/mcp-schema-breaking.sh --check` → exit 0 (no base reachable, first PR introducing snapshot).
- Snapshot JSON parses; schema `required` arrays present per tool.

## Verify (3)
1. Removed/renamed tool ⇒ BREAKING (preserved).
2. NEW: arg moves optional→required ⇒ BREAKING ⇒ `mcp-schema-breaking` label.
3. docs/compat.md no longer promises enum/output coverage from this gate — assigned to `mcp-schema-lint`.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
