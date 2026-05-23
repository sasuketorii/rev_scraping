# Review v1.3 G.7 round 6 (narrow fix verify post round-5 BLOCK) — RE-REVIEW

## Round 5 BLOCK 内容
- `crates/stealth-cli/src/commands/config_cli.rs` `validate_cmd` failure path: `{ok:false, reports, read_errors}` を直接 emit、`error` field なしで central `emit()` auto-augment を bypass → G.7 envelope 欠落
- 同 file `migrate_cmd` failure path: `{outcomes}` のみ emit、同様 bypass

## Round 6 narrow fix (option 1: structurally honest)

### `run_validate` failure path (`crates/stealth-cli/src/commands/config_cli.rs` ~949)
- `any_err == true` 時、`{ok:false, operation:"config.validate", exit_code:1, error:<summary>, reports, read_errors}` を構築
- `augment_with_g7_fields(CliErrorKind::Validation, hint=...)` で明示 augment
- 既存 `reports` / `read_errors` payload retain
- 成功時 `{ok:true, reports, read_errors}` 不変

### `run_migrate` failure path (`crates/stealth-cli/src/commands/config_cli.rs` ~2213)
- `any_error == true` 時、`{ok:false, operation:"config.migrate", exit_code:1, error:<summary>, outcomes}` を構築
- `augment_with_g7_fields(CliErrorKind::Validation, hint=...)` で明示 augment (新規 `Migration` variant 追加は arity-26 invariant 違反のため `Validation` を流用)
- 既存 `outcomes` payload retain
- 成功時 `{outcomes}` 不変

### Tests (`crates/stealth-cli/tests/error_template_uniform.rs`)
- `config_validate_failure_emits_canonical_envelope`: tempdir に `__bogus_field__` 含む policy.toml seed → `deny_unknown_fields` で validate 失敗 → G.7 envelope + `reports` + `read_errors` retain 検証
- `config_migrate_failure_emits_canonical_envelope`: `schema_version = 999` seed → migrate 失敗 → G.7 envelope + `outcomes` retain 検証

## Gates (driver 計測 — 再現性確認済)
- `cargo test --workspace --no-fail-fast`: **886 PASS / 0 fail** (clean run、複数回再実行で再現)
- `cargo test -p rev-stealth --test error_template_uniform`: **14 PASS / 0 fail** (round 5 の 12 + new 2)
- `cargo clippy -p rev-stealth --tests`: round 6 touched files (`config_cli.rs` / `error_template_uniform.rs`) に新規 warning **無し**
  - 既知 pre-existing lints (`idempotency.rs:87` dead_code / `:144` io_other_error) は round 5 prompt で明示 out-of-scope 宣言済

## Round 6 round-1 reviewer flake 注記
Round 6 の最初のレビューで `auth_login_with_allow_no_vpn_skips_probe` が parallel env-var race で fail との報告あり (reviewer 自身も「same test passed in isolation」「existing parallel env-var race with `REV_SCRAPING_REQUIRE_VPN`」と分析)。本 driver の `config_cli.rs` 編集とは無関係 (auth.rs は本 round 完全に未編集)。再実行 (`cargo test --workspace --no-fail-fast`) で 886 PASS / 0 fail を確認済。

## Verify (3)
1. round 5 BLOCK 2 path (validate + migrate failure) で G.7 envelope 5 fields ({kind, message, hint, retry_after_ms, doc_url}) 揃う
2. 既存 diagnostic payload (`reports` / `read_errors` / `outcomes`) が retain (structurally honest)
3. workspace test PASS (再実行で flake 消失)、touched files に新規 clippy warning なし

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
