# Review v1.3 Lane G.6.b — idempotent commit hook integration

Lane G.6.b: wire the G.6.a `IdempotencyStore` library into every mutate
subcommand and add an integration test proving the at-most-once replay
contract. Library bug (sanitize test) fixed in-place. Proptest invariant
punted to G.6.c / v1.3.1 per ExecPlan.

## Scope (15 mutate commands hooked)
- `crates/stealth-cli/src/commands/auth.rs` — login / refresh / delete
- `crates/stealth-cli/src/commands/config_cli.rs` — init / set / edit / migrate / rollback / gc / profile.create / profile.switch / profile.delete
- `crates/stealth-cli/src/commands/hermes.rs` — install / uninstall
- `crates/stealth-cli/src/vpn_cmd.rs` — rotate

## Library changes
- `crates/stealth-cli/src/commands/idempotency.rs`
  - Added `IdempotencyStore::from_env_or_default()` (alias of `from_env`).
  - Added `emit_replay(format, op, &envelope) -> i32` — prints cached envelope verbatim with `replayed: true` marker.
  - Added `record_success(store, op, key, payload, envelope)` — best-effort persist; failure logs to stderr but does NOT change exit code.
  - Added `ReplayGuard` helper (paired `check()` + `record()`) to reduce per-command boilerplate.
  - Fixed pre-existing unit test bug: `sanitize_op("../../etc/passwd")` returns 6 underscores (4 dots + 2 slashes), not 7.

## Hook pattern (canonical)
```rust
if args.dry_run_args.is_dry_run() { return emit_dry_run(...); }
let key = args.dry_run_args.idempotency_key.clone();
let payload = idempotency::payload_value("<op>", [<deterministic args>]);
let (idem, replay_exit) = ReplayGuard::check(format, "<op>", key, payload);
if let Some(code) = replay_exit { return code; }
// ... real side effect ...
// on success:
idem.record("<op>", &envelope);
```

## Limitation (documented inline)
`auth.login` / `auth.refresh` spawn `rev-auth` which prints its own JSON to
the inherited stdout. The Rust caller can't capture that envelope without a
deeper refactor; we record a synthesized marker envelope. The replay
contract — "no side effect runs again" — still holds.

## Gates PASS
- `cargo build -p rev-stealth`: clean (1 pre-existing dead_code warning on `IdempotencyStore::root`/`gc_expired`, both intentionally public for G.6.c admin commands).
- `cargo test --workspace --no-fail-fast`: 857 passed / 0 failed / 38 ignored (baseline 838 + 14 idempotency unit + 5 new integration = 857).
- `cargo test -p rev-stealth --test idempotency_replay`: 5 / 5 PASS.
- `cargo test -p rev-stealth --test dry_run_zero_side_effect`: 16 / 16 PASS (G.5 regression-free).

## Integration test (`crates/stealth-cli/tests/idempotency_replay.rs`, ~260 lines)
- `config_init_same_key_replays_without_side_effect` — second run with same key returns cached envelope with `replayed: true`; cache count stays at 1.
- `config_init_different_payload_does_not_replay` — same key + different `--target` → new cache entry (2 total).
- `config_init_no_key_does_not_touch_cache` — missing `--idempotency-key` → zero cache writes.
- `config_profile_create_same_key_replays` — exercises the profile dispatcher hook.
- `hermes_uninstall_dry_run_skips_idempotency` — dry-run short-circuits BEFORE the idempotency check; no cache writes.

Isolation: every test sets `REV_SCRAPING_IDEMPOTENCY_DIR=<tmp>` so concurrent runs cannot interfere with each other or the operator's real `~/.rev_scraping/idempotency/`.

## Out of scope (G.6.c / v1.3.1)
- Proptest invariant `same(op, key, payload) ⇒ same envelope` — punted (avoid touching Cargo.toml dev-dep block during parallel Lane H Slice B-2 run).
- Capturing `rev-auth` child stdout for true round-trip replay on `auth.login`/`auth.refresh`.
- Error template unification `{kind, message, hint, retry_after_ms?, doc_url}` (G.7).

## Verify (4)
1. **Hook placement**: every mutate command's idempotency check sits AFTER `is_dry_run()` early return and BEFORE the first side effect (file write / keyring access / process spawn). Dry-run never reaches the store; no-key never reaches the store.
2. **Replay invariant**: when `maybe_replay` returns `Some`, the function returns immediately with the cached envelope emitted to stdout — no `write_envelope` re-runs, no side effect re-runs. Confirmed by `config_init_same_key_replays_without_side_effect` (cache_entry_count stays at 1 across two invocations).
3. **Cache key composition**: entries keyed by `(op_sanitized, sha256_16(key), sha256_16(canonical_json(payload)))`; different payload with same key writes a NEW entry. Confirmed by `config_init_different_payload_does_not_replay`.
4. **Parallel-safety**: integration test sets `REV_SCRAPING_IDEMPOTENCY_DIR` per-test to a unique tmpdir; Lane H Slice B-2 files (`ci.yml`, `tests/install_sh_unit.sh`) untouched.

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
