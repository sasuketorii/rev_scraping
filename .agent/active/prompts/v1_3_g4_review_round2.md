# v1.3 Lane G.4 Reviewer (round 2)

You are the **Codex reviewer** for v1.3 Lane G.4 (CLI `--output-format` matrix + JSON-schema inventory). Round 1 verdict: **NEEDS_CHANGES (1 issue)**. Round 2 fix is now ready for verdict.

## Round-1 BLOCK (the issue you previously raised)

> JSON schemas under `docs/json-schemas/cli/` did not match the actually-emitted JSON envelopes:
>
> - `measure.output.json` required top-level `action`/`ok`/`url`, but `measure.rs::emit_ok` emits `{"ok":true,"operation":"measure","result":{...}}`.
> - `captcha.output.json` expected flat `action/type/ok`, but `captcha_cmd.rs::emit_ok` emits the same `ok/operation/result` envelope.
> - `config.output.json` expected an action-tagged object for `paths`, but `config_cli.rs::run_paths` emits a top-level array. `validate`, `diff`, `get` also emit untagged shapes.
> - `hermes.output.json` required `ok`/`prefix`, but `hermes.rs::emit_ok` emits `{kind, action, status, report}` / `{kind, action, status, error}`.

## Round-2 fix (now in tree)

All 11 schemas under `docs/json-schemas/cli/` were rewritten to describe the **actually-emitted** envelopes. No emitter was changed (strict-additive).

1. **Shared envelope** (captcha / browser / vpn / spider / relocate / cf-evaluate / auth / measure) — each schema's top-level is a `oneOf` of:
   - OK: `{ok: true, operation: <const|enum>, result: <action-specific>}`
   - ERR: `{ok: false, operation: <const|enum>, exit_code: int, error: string}`
   - `operation` is constrained per file (`"measure"`, `"spider"`, `"cf-evaluate"`, `"relocate"`, `"browser.launch"`, `"vpn.rotate"|"vpn.status"`, `"captcha.solve"|"captcha.verify"`, `"auth.{login|list|show|delete|status|refresh}"`).
   - `result` payload fields lifted directly from the matching `json!({...})` macro in each emitter.

2. **Hermes** — distinct envelope `{kind: "hermes", action, status: "ok"|"error", report|error}`, mirroring `commands/hermes.rs::emit_ok`/`emit_err`. README flags that error envelope goes to STDERR.

3. **Doctor** — no envelope; top-level `anyOf` of:
   - `DoctorReport` (base + `--vps` text path)
   - `DeepReport` (`--deep` JSON path)
   - `Vec<DeepCheck>` (P10.3 `--vps` JSON path: top-level array)

4. **Config** — no envelope (pre-dates G.4); top-level `anyOf` over per-action shapes: `show` `{policy, authorized, sites, env}`, `paths` array, `validate` `{ok, reports, read_errors}`, `diff` `{diff}`, `get` `{key, value}`, init/migrate `{outcomes}`, write-action fallback `{ok, ...}`.

5. **Auth** — uses shared envelope; `result` is `anyOf` over `list_payload` / `show_or_login_payload` / `delete_payload` / `status_payload`. Cookie *values* never serialised — only sha256 prefixes and counts.

### `anyOf` vs `oneOf` (round-2 calibration — please note)

Three schemas (`auth`, `doctor`, `config`) use `anyOf` (not `oneOf`) at the top level because their per-action shapes structurally overlap (e.g. `auth.delete`'s `{profile, deleted}` also matches the looser `auth.show` payload; `config validate`'s `{ok, reports, read_errors}` also matches the write-action fallback `{ok, ...}`). Live emission disambiguates via the CLI action name. The schemas exposed as `oneOf` keep that keyword because OK and ERR envelopes are disjoint on the `ok` const discriminator.

This is explained in `docs/json-schemas/cli/README.md` (new "anyOf vs oneOf" subsection).

## New verification surface

`crates/stealth-cli/tests/cli_output_schema_validation.rs` (new file, **19 tests**):

- Compiles every schema as Draft-07 (`all_cli_output_schemas_compile_as_draft7`).
- Validates a representative OK and ERR sample for every shared-envelope subcommand (`measure`, `captcha.{solve|verify}`, `browser.launch`, `vpn.{rotate|status}`, `spider`, `relocate.{exact|fuzzy|ambiguous|no-match}`, `cf-evaluate`, `auth.{list|show|delete|status|refresh}`).
- Validates `hermes.{install|verify|error}`.
- Validates `doctor.{base|deep|vps-array}`.
- Validates `config.{show|paths|validate|diff|get|outcomes}`.

Samples are constructed directly from the `json!({...})` macros in each emitter source file, so the test is the contract between emitter shape and schema shape.

## Files touched in round 2

- `docs/json-schemas/cli/measure.output.json` (rewrite)
- `docs/json-schemas/cli/captcha.output.json` (rewrite)
- `docs/json-schemas/cli/browser.output.json` (rewrite)
- `docs/json-schemas/cli/vpn.output.json` (rewrite)
- `docs/json-schemas/cli/spider.output.json` (rewrite)
- `docs/json-schemas/cli/relocate.output.json` (rewrite)
- `docs/json-schemas/cli/cf-evaluate.output.json` (rewrite)
- `docs/json-schemas/cli/auth.output.json` (rewrite; `result` switched to `anyOf` to allow structural overlap between delete/show payloads)
- `docs/json-schemas/cli/hermes.output.json` (rewrite — `{kind, action, status, report|error}`)
- `docs/json-schemas/cli/doctor.output.json` (rewrite — top-level `anyOf` of `DoctorReport` / `DeepReport` / `Array<DeepCheck>`)
- `docs/json-schemas/cli/config.output.json` (rewrite — top-level `anyOf` per-action; secret-key redaction noted)
- `docs/json-schemas/cli/README.md` (envelope-flavours section + anyOf-vs-oneOf calibration)
- `crates/stealth-cli/tests/cli_output_schema_validation.rs` (new — 19 jsonschema-validation tests)

## Verification commands you can run

```
cargo test -p rev-stealth --test output_format_coverage   # 4 PASS (unchanged from round 1)
cargo test -p rev-stealth --test cli_output_schema_validation   # 19 PASS (new)
cargo test -p rev-stealth --lib cli_tests::   # 8 PASS (unchanged)
```

Optionally spot-check by reading any one schema alongside the emitter — e.g.:

```
docs/json-schemas/cli/measure.output.json   ↔   crates/stealth-cli/src/commands/measure.rs::emit_ok (line 162)
docs/json-schemas/cli/hermes.output.json    ↔   crates/stealth-cli/src/commands/hermes.rs::emit_ok  (line 401)
docs/json-schemas/cli/config.output.json    ↔   crates/stealth-cli/src/commands/config_cli.rs::run_paths/run_validate/run_diff/run_get
```

## Your verdict

Emit a single METRIC line:

```
METRIC: lane=G.4 round=2 verdict=<LGTM|NEEDS_CHANGES> subcmds_with_output_format=11/11 schemas=11/11 collisions=0 issues=<N>
```

then a brief justification (≤ 10 lines). Round-1 issue is the only blocker carried over; if you accept the schema-to-emitter alignment + the new jsonschema-validation coverage, return **LGTM**. If you find a *new* schema-vs-emitter drift, list it concretely (file:line on both sides) so round 3 can land a narrow fix.

You are operating in **read-only review mode**. Do NOT modify files; only emit the verdict + justification on STDOUT.
