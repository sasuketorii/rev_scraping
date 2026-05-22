# P4.2 outputSchema review - ROUND 2 (post-fix)

Round-1 BLOCK findings addressed:
1. vpn_rotate.output.json: operation -> `vpn.rotate` (dot). result -> `{rotated, container, previous_ip, new_ip, elapsed_ms, reason}` per vpn_cmd.rs emit_ok.
2. spider/relocate/cf_evaluate.output.json: root requires only `{ok, operation}`; `oneOf` enforces success `{result}` vs failure `{exit_code, error}` matching emit_err.
3. auth_status: handler in crates/stealth-mcp/src/auth_tools.rs always emits `cookie_values_returned:false` (Missing branch included). Schema now requires it.

gates PASS:
- cargo test -p stealth-mcp: 57 / 0 fail
- cargo test --workspace: 625 / 0 fail (round-1 had 1 flaky auth probe test, passes in isolation, unrelated)
- cargo clippy --workspace -- -D warnings: clean
- baseline tools_list.json untouched (v1.1.0 pinned, 15 entries)
- spider_output_schema_documents_recipe_result_shape updated to verify oneOf

files touched (round 2):
- docs/json-schemas/{spider,relocate,cf_evaluate}.output.json (oneOf success|failure)
- docs/json-schemas/vpn_rotate.output.json (operation `vpn.rotate`, RotationReport shape)
- docs/json-schemas/auth_status.output.json (require cookie_values_returned)
- crates/stealth-mcp/src/auth_tools.rs (Missing branch emits cookie_values_returned:false)
- crates/stealth-mcp/src/tools.rs (spider test updated for oneOf)

verify:
1. vpn_rotate operation == `vpn.rotate` and result keys match vpn_cmd.rs emit_ok.
2. spider/relocate/cf_evaluate schemas use oneOf for success vs failure per emit_err.
3. auth_status handler emits `cookie_values_returned:false` on ALL branches; schema requires it.
4. Round-1 invariants still hold: draft-07, additionalProperties:false root x15, include_str! source-of-truth, 5 new tests.

return: `verdict: LGTM` or `BLOCK: <reason>`.
