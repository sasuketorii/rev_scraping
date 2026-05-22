# Review P4.1 round 4 (narrow round-3 finding fix)

## Round 3 BLOCK
`recipe_propose_endpoint.endpoint` wrapper object lacked `examples`. Test was also too lax (skipped object wrappers).

## Fix applied
File: `crates/stealth-mcp/src/tools.rs`
- Added representative example object to `recipe_propose_endpoint.endpoint` wrapper
- Rewrote `every_property_of_every_tool_has_examples` test to:
  - Require examples on object-valued wrappers
  - Recurse into nested object properties

## Gates PASS
- `cargo test -p stealth-mcp`: 52/52 PASS (45 baseline + 7 new P4.1)
- `cargo test --workspace`: **610 PASS / 0 fail**
- clippy clean / SPDX
- 15 tools all conform: $schema + additionalProperties:false + per-field descriptions + examples + enums

## Verify (3)
1. `recipe_propose_endpoint.endpoint` wrapper object has `examples` key
2. `every_property_of_every_tool_has_examples` test recurses into nested objects
3. tools_list() shape compatible (15 tools, no field renamed)

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
