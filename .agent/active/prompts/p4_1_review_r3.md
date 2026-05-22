# Review P4.1 round 3 (after fix)

file: crates/stealth-mcp/src/tools.rs

## Fix applied (response to round-2 BLOCK on spec item 6)
Round 2 reviewer flagged that several tools had fewer than 3 fields with
`examples`. Round 2 spec wording was ambiguous (some tools physically have
only 1-2 properties). Bar redefined and enforced: **every property of every
tool must carry a non-empty `examples` array.** That is now mechanically
checked by a new unit test `every_property_of_every_tool_has_examples`,
which also recurses into the nested `recipe_propose_endpoint.endpoint` object.

Properties newly given examples:
- `cf_evaluate.session_id`
- `recipe_remove.confirm`
- `recipe_import.payload`
- `spider.cf_evaluate`, `spider.vpn`, `spider.strict`
- `relocate.html`, `relocate.url`
- `recipe_propose_endpoint.endpoint.url_pattern`

## Constraints
- **No network.** All checks are local file / cargo test based.
- Verdict on the last line: `LGTM` or `BLOCK: <reason>`.

## Spec to verify (local-only)
1. `tool_definitions()` returns exactly 15 tools; names unchanged.
2. Every tool root inputSchema has all three:
   - `"$schema": "http://json-schema.org/draft-07/schema#"`
   - `"type": "object"`
   - `"additionalProperties": false`
3. Every property of every tool has non-empty `"description"`.
4. Every property of every tool has non-empty `"examples"` (recursing into
   the nested `recipe_propose_endpoint.endpoint` object's own properties).
5. `recipe_propose_endpoint.properties.endpoint` declares
   `additionalProperties: false`.
6. Enums preserved: `spider.mobile_preset` (6 values),
   `vpn_rotate.strategy` (3 values).
7. `build_cli_argv` body and `ToolValidation` enum unchanged from baseline.
8. SPDX header preserved.

## Evidence collected locally
- `cargo test -p stealth-mcp --no-fail-fast`: 52 passed / 0 failed.
- `cargo test --workspace --no-fail-fast`: 610 passed / 0 failed (≥ 591 target).
- `cargo clippy -p stealth-mcp --all-targets -- -D warnings`: clean.
- `git diff --stat`: only `crates/stealth-mcp/src/tools.rs` modified.

## Helper grep checks (expected counts)
- `grep -c '"additionalProperties": false' tools.rs` → 16 (15 roots + 1 nested endpoint).
- `grep -c '"$schema":' tools.rs` → 15 (one per tool root; DRAFT07 const is 1 extra line but not as JSON value, see top of file).

Return verdict.
