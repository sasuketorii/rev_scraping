# Review P4.1 MCP inputSchema 強化 (round 2 — no network)

file: crates/stealth-mcp/src/tools.rs

## Constraints
- Local-only review. **Do not perform web search.** OpenAI strict-mode rules
  for this slice are already encoded in the spec below.
- Verdict must be `LGTM` or `BLOCK: <reason>` on the last line.

## Spec to verify (locally)
1. `tool_definitions()` returns exactly 15 tools (names unchanged from baseline).
2. Each tool's `input_schema` JSON has at its root:
   - `"$schema": "http://json-schema.org/draft-07/schema#"`
   - `"type": "object"`
   - `"additionalProperties": false`
3. Every property of every tool has a non-empty `"description"` string.
4. `recipe_propose_endpoint.properties.endpoint` (nested object) also has
   `additionalProperties: false`.
5. Enum constraints preserved:
   - `spider.properties.mobile_preset.enum` has 6 entries.
   - `vpn_rotate.properties.strategy.enum` has 3 entries.
6. `examples` arrays present on primary fields (≥ 3 fields per non-empty tool).
7. `build_cli_argv` body and `ToolValidation` enum are unchanged from baseline
   (only inputSchema bodies were enriched).
8. SPDX header `// SPDX-License-Identifier: MIT` preserved.

## Evidence already collected
- `cargo test -p stealth-mcp --no-fail-fast`: 51 passed / 0 failed (baseline 45, +6 new).
- `cargo test --workspace --no-fail-fast`: 602 passed / 0 failed (≥ 591 target).
- `cargo clippy -p stealth-mcp --all-targets -- -D warnings`: clean.
- `git diff --stat`: only `crates/stealth-mcp/src/tools.rs` modified.

## New tests
- `all_15_tools_have_additional_properties_false`
- `all_input_schemas_have_dollar_schema_draft07`
- `spider_field_descriptions_present_for_all_properties`
- `auth_login_start_examples_present`
- `enum_constraints_applied_on_known_closed_sets`
- `nested_endpoint_object_also_enforces_strict_mode`

Read the file, run `grep -c '"additionalProperties": false'` if you want a
quick sanity check (expected ≥ 16: 15 roots + 1 nested endpoint object), then
return verdict.
