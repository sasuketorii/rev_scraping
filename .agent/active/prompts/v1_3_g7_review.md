# Review v1.3 Lane G.7 — unified error template

Every `rev-stealth` failure path now emits `{kind, message, hint?, retry_after_ms?, doc_url}` alongside the legacy `error:<string>` (kept for v1.2.x consumers). Closed 26-variant taxonomy (Lane I mirror). `doc_url` → Lane J `docs/book/src/en/errors/<PascalCase>.md`. Success envelopes unchanged.

## Wire (JSON)
```
{"ok":false,"operation":<op>,"exit_code":<n>,
 "error":"<msg>",
 "kind":"<snake>","message":"<msg>","hint":<str|null>,
 "retry_after_ms":<u64|null>,
 "doc_url":"https://.../docs/book/src/en/errors/<Pascal>.md"}
```

## Files
NEW:
- `crates/stealth-cli/src/commands/error_envelope.rs` — `CliErrorKind` (26 variants, exhaustive `#[forbid(unreachable_patterns)]` matches), `emit_err_envelope`, `augment_with_g7_fields`, `classify_legacy_message`. 7 unit tests.
- `crates/stealth-cli/tests/error_template_uniform.rs` — 6 tests: cf-evaluate/measure/spider/relocate invalid-url spawns carry the 5 G.7 fields; every variant doc page exists; `DOC_URL_BASE` pinned.

MODIFIED:
- `{captcha,browser,vpn}_cmd.rs::emit_error`, `commands/{auth,cf_evaluate,measure,relocate,spider}.rs::emit_err` — delegate to `emit_err_envelope`.
- `spider.rs::emit_leak_exit` — `augment_with_g7_fields` in place (preserves `vpn_monitor`).
- `hermes.rs::emit_err` — keeps category `kind:"hermes"`; G.7 wire kind exposed as `error_kind` (test special-cases hermes).
- `commands/mod.rs`, `lib.rs` (`#[doc(hidden)] pub mod __error_envelope_for_test`).

## Constraints
- No `Cargo.toml` / workspace-dep edits (Lane H Slice B-3 collision).
- Schemas unchanged (additive fields, existing fixtures pass 20/20). Schema declaration deferred.
- `unsafe_code = forbid` preserved.

## Gates
- `cargo test --workspace --no-fail-fast` → **871 passed / 0 failed / 38 ignored** (858 + 6 integration + 7 unit).
- `error_template_uniform` 6/6, `cli_output_schema_validation` 20/20, `idempotency_replay` regression-free.

## Verify
1. `cargo test --workspace --no-fail-fast 2>&1 | grep -E '^test result:' | awk '{p+=$4;f+=$6} END{print p" "f}'` → `871 0`
2. `cargo test -p rev-stealth --test error_template_uniform 2>&1 | tail -3` → 6/6 ok
3. `ls docs/book/src/en/errors/*.md | wc -l` → 27
4. `git diff --name-only` — no Cargo.* / lockfile

## Out of scope (G.8+)
- Schema additions for the 5 G.7 fields (Lane H window).
- `stealth-mcp` JSON-RPC parity.
- Per-callsite explicit-kind plumbing (heuristic covers today).
- `clap-mangen` man-pages (G.8).

LGTM or list blocking findings.
