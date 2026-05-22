# Review P4.2 outputSchema 15 tools

scope: ExecPlan §D Lane C P4.2. additive only. P4.1 inputSchemas untouched.
source-of-truth: docs/json-schemas/*.output.json (15 new), embedded via `include_str!`.

files:
- crates/stealth-mcp/src/tools.rs (output_schema field on ToolDefinition; 15 include_str! consts; 5 new tests)
- docs/json-schemas/{spider,relocate,cf_evaluate,doctor,vpn_rotate,recipe_list,recipe_show,recipe_remove,recipe_propose_endpoint,recipe_export,recipe_import,auth_login_start,auth_login_complete,auth_list,auth_status}.output.json

gates PASS:
- cargo test -p stealth-mcp: 57 (52 base + 5 new)
- cargo test --workspace: 618 passed >= 615 bar
- cargo clippy --workspace -- -D warnings: clean
- SPDX: only pre-existing failure on vpn-rotate/credentials.rs (untracked, unrelated)
- baseline tools_list.json unchanged (v1.1.0 snapshot pinned; outputSchema additive)

verify:
1. 15 *.output.json with $schema draft-07 + additionalProperties:false at root.
2. ToolDef.output_schema populated via include_str! + parse_output_schema (NO schemars derive).
3. tool_definitions() returns 15 tools all with non-null outputSchema in to_json().
4. spider.output describes {ok, operation, result} envelope AND result.{session_id,recipe,api_response,cf,vpn_monitor,relocate,leak,error}.
5. doctor.output describes raw DoctorReport (NOT wrapped) matching `doctor --format json`.
6. recipe_show enumerates 10 SiteRecipe top-level keys (schema_version, site, api, scraping_strategy, rate_limits, selectors, fingerprint, anti_bot, notes, auth) with root additionalProperties:false; inner blocks permissive.
7. auth_* outputs carry cookie_values_returned:false contract marker; cookie material never surfaces.
8. New tests: all_15_tools_have_output_schema / all_output_schemas_are_draft07 / all_output_schemas_have_additional_properties_false / spider_output_schema_documents_recipe_result_shape / output_schemas_examples_present.

return: `verdict: LGTM` or `BLOCK: <reason>`.
