# Review v1.3 I.3 (Round 2)

R1 BLOCK addressed:

1. **Internal-types tier had no labels.** Added language to the table cell: if a refactor surfaces in the snapshot OR cargo-public-api diff, `api-additive` (new pub item) / `api-breaking` (removed or renamed pub item) labels apply at reviewer discretion. Same vocabulary as the CLI tier — internal types just don't trigger an automatic version bump on their own.

2. **MCP lifecycle inconsistency.** R1 text said "callable through v3.x" but "remove in v3.0" — contradictory. Fixed to:
   - v1.x ship
   - v2.0 mark `#[deprecated]` (warning visible through v2.x and v3.x)
   - v4.0 remove
   This honors the documented 2-major guarantee (callable through v3.x = removable in v4.0). CLI lifecycle (1-major) similarly clarified: ship in v1.x → deprecate v2.0 → remove v3.0.

## Files touched (delta)
- `docs/compat.md` — internal-types row updated, MCP lifecycle corrected (v3.0 → v4.0), CLI lifecycle wording tightened ("v1.3 → v1.x" → "v1.x").

## Gates PASS
- markdown still renders
- README TOC link target unchanged

## Verify (3)
1. Internal-types tier now names the same label vocabulary (`api-additive` / `api-breaking`) as the CLI tier.
2. MCP lifecycle is internally consistent: 2-major guarantee = removal in v4.0 when deprecation lands in v2.0.
3. CLI lifecycle stays 1-major: ship v1.x → deprecate v2.0 → remove v3.0.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
