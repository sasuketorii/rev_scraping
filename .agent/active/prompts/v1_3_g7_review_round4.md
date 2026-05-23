# Review v1.3 Lane G.7 — round 4 (round-3 finding addressed)

## Round-3 blocking finding → fixed

**Explicit local `--output-format text` must win over global `--format json`**
([config_cli.rs::run]($REPO_ROOT/crates/stealth-cli/src/commands/config_cli.rs:618))

The round-2 default-equals check (`args.format == Text` → promote) could
not distinguish "user typed `--output-format text`" from "user passed
nothing", silently overriding an explicit local text. Resolution:
argv-peek for `--output-format` in either accepted shape (split or
combined), and only promote when the local flag is genuinely absent.

```rust
let local_set_explicitly = std::env::args().any(|a| {
    a == "--output-format" || a.starts_with("--output-format=")
});
if matches!(global, GlobalFormat::Json)
    && matches!(args.format, ConfigFormat::Text)
    && !local_set_explicitly
{
    args.format = ConfigFormat::Json;
}
```

## Verification (manual)
```
$ rev-stealth --format json config --output-format text get __missing__
  # stderr: "key not found: __missing__"; stdout empty — explicit text wins
$ rev-stealth --format json config get __missing__
  # stdout: {"doc_url":...,"error":"not_found",...,"kind":"not_found",...}
$ rev-stealth --format json config --output-format json get __missing__
  # stdout: same JSON envelope (explicit json identical to promoted)
```

## New test
`config_explicit_local_text_wins_over_global_json` — asserts stdout is
NOT JSON and stderr carries the human "key not found" message when
local `--output-format text` is explicitly passed under a global `--format
json` session.

## Gates
- `cargo test --workspace --no-fail-fast` → **876 passed / 0 failed / 38 ignored** (858 + 11 integration + 7 unit).
- `cargo test -p rev-stealth --test error_template_uniform` → **11/11 PASS**.
- `cargo test -p rev-stealth --test cli_output_schema_validation` → **20/20 PASS** (no regression).

## Precedence rule honored
- Local `--output-format <x>` (explicit) → wins (any x).
- Local omitted + global `--format json` → promotes to JSON.
- Local omitted + global default → unchanged (text).

This matches the documented contract in
`docs/json-schemas/cli/README.md:24` and preserves backward compat with
v1.2.x callers that only ever pass `--format`.

## Constraints honored
- No `Cargo.toml` / lockfile churn.
- `unsafe_code = forbid` preserved.
- No new clippy / rustc warnings beyond pre-existing G.6.

LGTM or list residual blocking findings.
