# Review v1.3 I.3 (Round 3)

R2 BLOCK addressed:

The "any tier" major-bump rule still contradicted the internal-types tier's no-guarantee rule. Rewrote `docs/compat.md` line 51-58 to scope the major-bump rule explicitly to the **MCP** and **CLI** tiers; the internal-types tier is excluded from the project-major bump rule (matching the tier's own "no guarantee" wording). Internal-types changes can still receive `api-additive` / `api-breaking` labels for reviewer visibility, but they do not force a version bump.

## Files touched (delta)
- `docs/compat.md` — line 51-58 rewrite of the Major bump-rule bullet.

## Gates PASS
- markdown still renders
- README TOC link unchanged

## Verify (3)
1. Bumping-rules section now explicitly limits the major-bump rule to MCP + CLI tiers. Internal types tier explicitly carved out.
2. The three tiers in the at-a-glance table remain internally consistent: MCP=2-major / CLI=1-major / internal=no guarantee, with the major-bump rule honoring all three.
3. MCP lifecycle (R2 fix) still consistent: ship v1.x → deprecate v2.0 → remove v4.0.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
