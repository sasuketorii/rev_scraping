# Review P9.1 — migration framework + session_show (16th MCP tool)

## Files (additive)
- crates/stealth-cli/src/config_io/migration.rs (NEW) + mod.rs
- crates/stealth-mcp/src/session_tools.rs (NEW) + lib.rs
- crates/stealth-mcp/src/tools.rs (+session_show ToolDefinition+output schema)
- crates/stealth-mcp/src/server.rs (ServerConfig.session_dir + dispatch)
- docs/json-schemas/session_show.output.json (NEW)
- tests/mcp_conformance.rs: stale 5→16 (still #[ignore])

## migration
- `Migration{from_version,to_version,apply:fn(TomlValue)->Result<TomlValue,String>}`
- `default_migrations()` = single v1→v1 identity; bounded loop
- `MigrationOutcome::NoOp|Migrated{from,to,steps}`
- LATEST=1 cross-pinned schema::default_schema_version_v1()

## session_show
- 16th tool, in-process (recipe_*/auth_* pattern)
- Reads `<session_dir>/<id>.json` shape `{session_id,instance,ts_unix}`
- Envelope `{session_id, vpn_instance, recipe_hits[], auth_profile?, started_at}`
- recipe_hits/auth_profile reserved ([], null) for P9.2+
- session_id `[A-Za-z0-9_-]{1..=128}`; rejects `/`,`\`,`..`,`.`
- NotFound → ErrorKind::NotFound + hint
- ServerConfig.session_dir added; 4 inline literals updated

## Tests added (10)
Spec: migration_v1_v1_noop, migration_harness_supports_future_v2 (v1→v2 chain
ok), session_show_returns_session_metadata, session_show_unknown_session_returns_kind_not_found,
mcp_tool_count_now_16.
Defensive: migrate_missing_step_errors, migrate_rejects_missing_schema_version,
latest_version_matches_schema_default, session_show_rejects_path_traversal_in_id,
session_show_missing_session_id_arg.
Renamed _15_→_16_: tools.rs (3) + server.rs (1).

## Gates PASS
- cargo check --workspace clean
- cargo test --workspace --no-fail-fast: 663 PASS / 0 FAIL
  (641→646→651→653→663, +10)
- cargo clippy --workspace --all-targets -D warnings clean
- check_baseline_diff.sh OK (tools count INFO; baseline tools_list.json
  untouched per slice spec — P11 owns formal 15→16 refresh)
- MCP stdio tools/list = 16, session_show present
- SPDX L1; secret redaction untouched

## REV_HARNESS_DELEGATION_METRIC
REV_HARNESS_DELEGATION_METRIC sub_phase=P9.1 tests_added=10 workspace_pass=663 clippy=clean mcp_tool_count=16 chain_bounded=true session_id_validated=true baseline_diff=ok

verdict: LGTM or BLOCK: <reason>
