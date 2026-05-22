# P4.2 outputSchema review - ROUND 3 (final)

Round-2 BLOCK addressed:
- spider.output.json now declares root `vpn_monitor` (object, optional) so the leak-shutdown failure envelope emitted by `emit_leak_exit` at crates/stealth-cli/src/commands/spider.rs:1607 validates. Documented as "Failure-only (exit_code=7); attached at root, not inside `result`".
- relocate/cf_evaluate: confirmed via grep that those crates use plain emit_err for leak paths (no extra root keys); their schemas unchanged.

gates PASS:
- cargo test -p stealth-mcp: 57 / 0 fail (52 baseline + 5 new P4.2 tests)
- cargo clippy --workspace -- -D warnings: clean
- baseline tools_list.json untouched (15 entries, v1.1.0 pinned)

files changed in this round:
- docs/json-schemas/spider.output.json (added root vpn_monitor object property)

verify:
1. spider schema root now permits vpn_monitor on the failure branch (emit_leak_exit shape).
2. relocate/cf_evaluate intentionally unchanged: their leak paths use emit_err with no extra root keys.
3. All round-1/2 fixes still hold: vpn_rotate operation=`vpn.rotate`, auth_status emits cookie_values_returned on all branches, oneOf success|failure on spider/relocate/cf_evaluate.

return: `verdict: LGTM` or `BLOCK: <reason>`.
