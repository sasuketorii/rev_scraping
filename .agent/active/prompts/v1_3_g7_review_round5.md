# Review v1.3 G.7 round 5 (narrow LGTM verify post round-4 fix)

## Round 4 で対応済の指摘 (前 driver report 由来)
- config-profile / config-validate / migrate / rollback / gc paths の cascading が config_cli.rs 中央 emit() 経由で auto-augment
- argv-peek で `--format=json` 結合形対応
- 明示的 local `--output-format text` が global を上書き
- clap parse error → G.7 envelope at operation="cli.parse"

## 現状 deliverable (uncommitted)
- crates/stealth-cli/src/commands/error_envelope.rs (CliErrorKind 26 + helpers)
- crates/stealth-cli/tests/error_template_uniform.rs (integration 12 + 26 doc_url resolve test + base URL pin)
- 10 modified Rust files (delegate to emit_err_envelope / augment in place)

## Gates PASS
- cargo test --workspace --no-fail-fast: 877 PASS / 0 fail
- cargo clippy -D warnings (lane G.7 touched): clean
  - pre-existing lints in crates/stealth-cli/src/commands/idempotency.rs:87,144 (root/gc_expired dead_code, io::Error::other suggestion) are unchanged on main, out of scope for G.7
- 26 ErrorKind 全部 docs/book/src/en/errors/<Pascal>.md に解決可能

## Verify (3)
1. 全 sub-command の error path JSON 出力に {kind, message, hint?, retry_after_ms?, doc_url} 5 fields 揃う
2. doc_url は https://github.com/sasuketorii/rev_scraping/blob/main/docs/book/src/en/errors/<Pascal>.md 形式で resolve
3. 26 ErrorKind の pascal_name と wire_name (snake_case) が exhaustive match で対応

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
