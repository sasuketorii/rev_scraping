# Review P4.1 MCP inputSchema 強化 (15 tools)

file: crates/stealth-mcp/src/tools.rs (15 inputSchemas hardened)

## Gates PASS
- `cargo test -p stealth-mcp --no-fail-fast`: 51 passed / 0 failed (baseline 45 → +6 new tests, ≥4 required)
- `cargo test --workspace --no-fail-fast`: 602 passed / 0 failed (baseline 596 → +6; ≥ 591 target)
- `cargo clippy -p stealth-mcp --all-targets -- -D warnings`: clean
- SPDX header preserved (`// SPDX-License-Identifier: MIT`)
- Baseline diff: tools.rs only (350 insertions, 36 deletions). No other crate touched.
- vendor/_refs/baseline NOT touched
- secret leak: 0

## What changed
1. Every one of the 15 tool inputSchemas now carries:
   - `"$schema": "http://json-schema.org/draft-07/schema#"` at root
   - `"additionalProperties": false` at root
   - non-empty `"description"` on every property
2. `recipe_propose_endpoint.endpoint` nested object also has `additionalProperties:false`.
3. `examples` arrays added on primary fields (url, profile, domain, stable_id, threshold, region, etc.) for 3-5 hint coverage per tool.
4. Enum constraints preserved+documented:
   - spider.mobile_preset (6-value enum unchanged)
   - vpn_rotate.strategy (3-value enum unchanged, with per-value semantic in description)
5. `tools_list` shape unchanged: still returns 15 `ToolDefinition { name, description, input_schema }`. `to_json` shape unchanged.
6. `build_cli_argv` and `ToolValidation` enum unchanged (zero impact on CLI translation).

## New unit tests in tools::tests
- `all_15_tools_have_additional_properties_false`
- `all_input_schemas_have_dollar_schema_draft07`
- `spider_field_descriptions_present_for_all_properties`
- `auth_login_start_examples_present`
- `enum_constraints_applied_on_known_closed_sets`
- `nested_endpoint_object_also_enforces_strict_mode`

## Verify
1. All 15 tools have `"additionalProperties": false` at root → covered by test #1
2. All 15 tools have `"$schema": draft-07` → covered by test #2
3. Every property has non-empty `description` (spider audited; others followed same pattern) → test #3 + grep
4. Enum constraints applied where applicable (`mobile_preset`, `vpn_rotate.strategy`) → test #5
5. tools_list count still == 15, no tool removed/renamed → existing `test_tools_list_returns_15_tools` still PASS
6. `to_json` output shape (name/description/inputSchema) unchanged — only inputSchema body enriched.

Return: `verdict: LGTM` or `BLOCK: <reason>`.
