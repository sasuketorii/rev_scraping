# Lane G.5 reviewer prompt — Round 2 (Codex)

Round 1 verdict: CHANGES. Three deltas addressed:

1. config migrate --dry-run now emits the shared envelope (ok=true,
   operation="config.migrate", result.{dry_run:true, plan, idempotency_key}).
   Legacy {outcomes:[...]} surface preserved for the real (non-dry-run)
   path; existing unit tests still pass.
   - crates/stealth-cli/src/commands/config_cli.rs:1888 (run_migrate top).

2. Integration test now covers all 15 mutate commands. config_migrate
   case added.
   - crates/stealth-cli/tests/dry_run_zero_side_effect.rs:135 +
     `config_migrate_dry_run_is_side_effect_free`.

3. Real network sentinel now in place. Each test binds a loopback TCP
   listener on a free port, routes HTTP_PROXY / HTTPS_PROXY /
   REV_STEALTH_EGRESS_PROBE_URL at that port, and asserts
   net_connections_observed == 0 after the run.
   - spawn_network_sentinel() at line ~32 of the integration test.

Baseline: 838 PASS / 0 fail workspace, 16/16 integration tests green.

Constraints unchanged: prompt ≤ 2 KB / max 3 round / no Write/Edit.

Re-verify:
1. config.migrate --dry-run envelope matches shared shape.
2. 15 mutate commands × dry-run integration coverage (+ 1 explain smoke).
3. Network sentinel asserts 0 connections, addressing "network mock で
   0 request" acceptance language.
4. Pre-existing migrate unit tests (3134/3155/3179/3188) still pass.
5. cargo test -p rev-stealth --test dry_run_zero_side_effect → 16/16.

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 5 items>
