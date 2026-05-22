# v1.3 Lane G.4 Reviewer (round 3)

You are the **Codex reviewer** for v1.3 Lane G.4. Round 2 verdict: **NEEDS_CHANGES (1 issue)**. This is the round-3 fix submission.

## Round-2 BLOCK (the issue you raised)

> `docs/json-schemas/cli/auth.output.json:10` required OK auth outputs (including `auth.login` / `auth.refresh`) to be `{ok, operation, result}`.
> Actual success path: `crates/stealth-cli/src/commands/auth.rs:406` inherits stdout from the external `rev-auth` helper, which prints a FLAT `{ok, profile, domain, cookie_count, expires_at, saved_to}` payload (`crates/stealth-auth/src/bin/rev_auth.rs:212` struct / `:382` println). No `operation`, no `result` wrapper.
> Round-2 test coverage missed this success drift because it only covered `auth.refresh` ERR and `list/show/delete/status` OK.

## Round-3 fix (now in tree)

`docs/json-schemas/cli/auth.output.json` was restructured to honestly describe the **two distinct OK shapes**:

1. **Envelope OK** (`auth.list` / `auth.show` / `auth.delete` / `auth.status` only) — `{ok, operation, result}` shape, `operation` enum restricted to those four.
2. **Envelope ERR** (all six actions, including `auth.login` / `auth.refresh`) — `{ok, operation, exit_code, error}`. The CLI itself emits this on policy/AUP/VPN-guard/spawn failures BEFORE the helper is invoked.
3. **Flat `rev_auth_success`** (`auth.login` / `auth.refresh` SUCCESS) — `{ok, profile, domain, cookie_count, expires_at?, saved_to}`. Mirror of `SuccessJson` at `crates/stealth-auth/src/bin/rev_auth.rs:212`; required fields `ok|profile|domain|cookie_count|saved_to`, optional `expires_at` (null when no cookie has an expiry). `additionalProperties: false`.

The schema's top-level `oneOf` now has three branches (envelope OK, envelope ERR, flat success), and the description block at the top documents the split with file:line pointers to both the schema source-of-truth and the CLI inheritance path (`spawn_rev_auth_login` line 406).

`docs/json-schemas/cli/README.md` "Envelope contracts (three flavours)" section now flags that `auth login` / `auth refresh` success falls into the no-envelope bucket alongside `doctor` and `config`, with explicit pointer to `crates/stealth-auth/src/bin/rev_auth.rs::SuccessJson`.

## New test coverage

`crates/stealth-cli/tests/cli_output_schema_validation.rs` (existing file, now **20 tests**, +1):

- New: `auth_login_refresh_flat_success_validates` — covers the `SuccessJson` shape with and without the optional `expires_at`.
- Updated: `auth_envelopes_validate` — adds an `auth.login` ERR sample so the pre-helper failure path is exercised, not just `auth.refresh`.
- Unchanged: list/show/delete/status OK, refresh ERR.

The integration-test contract is now: every documented branch of every schema has at least one passing-sample assertion lifted directly from a `json!({...})` or `serde::Serialize` source in the emitter.

## Files touched in round 3

- `docs/json-schemas/cli/auth.output.json` — top-level `oneOf` extended to 3 branches; new `$defs/rev_auth_success`; tighter `operation` enums per envelope branch.
- `docs/json-schemas/cli/README.md` — "envelope contracts" updated to flag rev-auth's helper-owned success path.
- `crates/stealth-cli/tests/cli_output_schema_validation.rs` — +1 test (`auth_login_refresh_flat_success_validates`), +1 sample in `auth_envelopes_validate` (login ERR).

## Verification commands

```
cargo test -p rev-stealth --test cli_output_schema_validation   # 20 PASS (was 19 in round 2)
cargo test -p rev-stealth --test output_format_coverage          # 4 PASS (unchanged)
cargo test -p rev-stealth --lib cli_tests::                       # 8 PASS (unchanged)
cargo test --workspace --no-fail-fast                             # 820 PASS, 0 FAIL
```

Spot-check the round-2 BLOCK alignment:

```
docs/json-schemas/cli/auth.output.json line 47   ↔   crates/stealth-auth/src/bin/rev_auth.rs line 212 (struct SuccessJson)
docs/json-schemas/cli/auth.output.json line 47   ↔   crates/stealth-auth/src/bin/rev_auth.rs line 382 (println!)
docs/json-schemas/cli/auth.output.json line 14   ↔   crates/stealth-cli/src/commands/auth.rs line 406 (inherits child stdout)
```

## Your verdict

Emit a single METRIC line:

```
METRIC: lane=G.4 round=3 verdict=<LGTM|NEEDS_CHANGES> subcmds_with_output_format=11/11 schemas=11/11 collisions=0 issues=<N>
```

then a brief justification (≤ 8 lines). Round-2 issue is the only carry-over; if the auth-shape split + new test coverage is sufficient, return **LGTM**.

You are operating in **read-only review mode**. Do NOT modify files; only emit the verdict + justification on STDOUT.
