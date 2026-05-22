# Lane G.5 reviewer prompt (Codex)

You are the v1.3 Lane G.5 reviewer. Verify acceptance from
.agent/active/v1_3_uplift_execplan_rev1.md (Lane G.5):

> `--dry-run` + `--explain` を全 mutate コマンドに完備.
> Acceptance: integration test (`crates/stealth-cli/tests/
> dry_run_zero_side_effect.rs`): 各 mutate コマンドを `--dry-run` で実行、
> tmpdir mtime/inode unchanged + network mock で 0 request.

Baseline: commit 0a790a5f on main, 820 PASS.
After G.5: 837 PASS / 0 fail.

Artifacts:
- crates/stealth-cli/src/commands/dry_run.rs (new shim)
- crates/stealth-cli/src/commands/mod.rs (mod registration)
- crates/stealth-cli/src/commands/auth.rs (login/delete/refresh)
- crates/stealth-cli/src/commands/hermes.rs (install/uninstall)
- crates/stealth-cli/src/commands/config_cli.rs (init/set/edit/migrate/
  rollback/gc/profile.{create,switch,delete})
- crates/stealth-cli/src/vpn_cmd.rs (rotate)
- crates/stealth-cli/tests/dry_run_zero_side_effect.rs (15 tests)

Constraints:
- prompt ≤ 2 KB / max 3 round / no Write/Edit
- recipe import/remove/propose_endpoint は本 build に存在しない (skip).

Verify:
1. DryRunArgs flattened into every mutate Args variant (15 commands).
2. Each mutate run_* short-circuits BEFORE file/network/keyring side
   effect when args.dry_run_args.is_dry_run().
3. emit_dry_run envelope: ok=true, operation, result.{dry_run:true,
   plan:[..], idempotency_key:<str|null>}.
4. Integration test snapshots tmpdir before/after, asserts exit 0 +
   envelope shape — covers all 15 mutate commands.
5. --idempotency-key round-trips into envelope (G.6 prep).
6. migrate --dry-run semantics preserved via MigrateArgs::dry_run() shim.

Return:
verdict: LGTM | CHANGES
deltas: <none | bullet list, ≤ 5 items>
