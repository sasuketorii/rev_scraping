# Review v1.3 Lane G.6.b round 2 — payload completeness + config.edit carveout

Round-1 verdict: `BLOCK: idempotency payloads omit behavior-changing inputs, so same key + changed command args can incorrectly replay and skip a distinct mutation`.

Round-1 findings (both addressed):
1. `config.edit` payload only included `target`; reviewer reproduced replay-skipping a genuinely different edit.
2. `auth.login` / `auth.refresh` payloads missing `completion_pattern`, `obscura_bin`, `rev_auth_bin`, `aad_context`, `require_vpn`, `allow_no_vpn`.

## Round-2 fixes

### `config.edit` carveout (`crates/stealth-cli/src/commands/config_cli.rs`)
Removed the idempotency hook from `run_edit` entirely. Documented inline:

> `config.edit` deliberately does NOT participate in the idempotent replay store. The mutation is driven by interactive editor input which is not knowable from the CLI args alone — keying replay on `(target,)` would let a same-key second invocation skip a genuinely-different edit. `--idempotency-key` remains accepted on the surface for shape consistency across mutate commands but is a no-op here; callers needing at-most-once edit semantics should instead pin the candidate via `config set` (whose payload includes the value).

Pinned by new test `config_edit_idempotency_key_is_a_no_op` — invokes `config edit --editor true --idempotency-key X` twice with `--output-format json`, asserts cache_entry_count remains 0.

### `auth.login` / `auth.refresh` payload completion (`crates/stealth-cli/src/commands/auth.rs`)
Expanded payload to include every CLI arg that changes the spawned `rev-auth` child's behavior or its security envelope:

```rust
("profile",            json!(args.profile.clone())),
("url",                json!(args.url.clone())),
("domain",             json!(args.domain.clone())),
("completion_pattern", json!(args.completion_pattern.clone())),
("obscura_bin",        json!(args.obscura_bin.as_ref().map(|p| p.display().to_string()))),
("rev_auth_bin",       json!(args.rev_auth_bin.as_ref().map(|p| p.display().to_string()))),
("aad_context",        json!(args.aad_context.clone())),
("require_vpn",        json!(args.require_vpn)),
("allow_no_vpn",       json!(args.allow_no_vpn)),
```

Same expansion applied to `run_refresh`.

## Other payloads audited (no change required)
- `vpn.rotate`: provider, strategy, region, reason — covers every input to `RotationRequest`.
- `hermes.install`: prefix, source, force — covers every InstallArgs field.
- `hermes.uninstall`: prefix — only UninstallArgs field.
- `auth.delete`: profile, force — only DeleteArgs fields.
- `config.init`: target, force.
- `config.set`: target, key, value_sha (raw value never stored to avoid secret leakage; sha256_16 is sufficient for "different value → different cache entry").
- `config.migrate`: dry_run_inner (the only behavior-changing arg; migration is deterministic from on-disk `schema_version`).
- `config.rollback`: target, bak_name.
- `config.gc`: target, keep.
- `config.profile.{create,switch,delete}`: name (+ yes for delete).

## Gates PASS
- `cargo build -p rev-stealth`: clean.
- `cargo test --workspace --no-fail-fast`: 858 passed / 0 failed / 38 ignored (was 857 in round-1; +1 from the new `config_edit_idempotency_key_is_a_no_op` test).
- `cargo test -p rev-stealth --test idempotency_replay`: 6 / 6 PASS.
- `cargo test -p rev-stealth --test dry_run_zero_side_effect`: 16 / 16 PASS.

## Reviewer round-1 repro pinned in CI
The blocker reviewer reproduced manually (`config edit` w/ same key + changed editor input → second run incorrectly replayed) is now a CI regression test (`config_edit_idempotency_key_is_a_no_op`).

## Verify (4)
1. `config.edit` no longer touches `IdempotencyStore` — confirmed by `config_edit_idempotency_key_is_a_no_op` (cache stays empty across two edits with same key).
2. `auth.login` / `auth.refresh` payloads include every behavior-changing arg. Inspect `payload_value(...)` call sites in `auth.rs`.
3. No other mutate command has a payload gap of the kind reviewed in round-1 — see "Other payloads audited" above; each payload covers the full set of fields on its Args struct.
4. Workspace baseline preserved: 858 passed, 0 failed (838 G.5 baseline + 14 idempotency unit + 6 integration).

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`
