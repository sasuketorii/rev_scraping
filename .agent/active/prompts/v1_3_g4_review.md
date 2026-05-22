# v1.3 Lane G.4 Reviewer (round 1)

You are the Codex reviewer for Lane G.4 — `--output-format {json|yaml|text}` on every `rev-stealth` sub-command + JSON-schema inventory. G.1/G.2/G.3 LGTM. Read-only.

## Spec (ExecPlan + driver brief)

Goal: ship `--output-format` as a first-class flag on every top-level `rev-stealth` sub-command, with one Draft-07 JSON-output schema per command committed under `docs/json-schemas/cli/`.

Constraints:
- Backward compatible: the existing global `--format {human|json}` MUST continue to parse (v1.2.x callers / scripts).
- Two sub-commands extend the value enum locally and MUST keep doing so:
  - `doctor --output-format {json|text}` (HANDOFF v0.0.4 §2.1 P0 — pre-existing).
  - `config --output-format {text|json|yaml}` (P6.1 — pre-existing).
- Everywhere else uses the shared `OutputFormat` enum (`human|json`), same as the global flag.
- CI lint must assert every top-level sub-command accepts `--output-format json`.
- `clap::CommandFactory::command().debug_assert()` must pass (no arg-id collision).

## Implementation summary

New module `crates/stealth-cli/src/commands/output_format.rs`:
- `pub struct OutputFormatOverride { #[arg(long="output-format")] pub output_format: Option<OutputFormat> }`
- `resolve(global: OutputFormat) -> OutputFormat` returns the local override when set, else falls back to the global value.

Each parent sub-command that owns an `Args` struct or a `Command::Xxx { … }` variant flattens this shim:
- `Cli::Command::{Captcha, Browser, Vpn}` — flattened at the variant level (action verbs are children → the new flag sits between noun and verb: `rev-stealth captcha --output-format json solve …`).
- `SpiderArgs`, `RelocateArgs`, `CfEvaluateArgs`, `AuthArgs`, `MeasureArgs`, `HermesArgs` — flattened at the struct level.
- `DoctorArgs` and `ConfigArgs` are left untouched because they own the richer local `--output-format` enum (`text`/`yaml`).

Dispatch in `run_async`:
- Each subcommand's `run` is called with `args.output_format.resolve(cli.format)` as the effective `OutputFormat`.
- The captcha/browser/vpn variants are destructured to extract both `output_format` and `action`.

Test-only re-exports (doc-hidden, prefix `__`) added to `lib.rs` so the integration test in `tests/output_format_coverage.rs` can drive clap without spawning a binary:
- `__cli_parse_for_test(argv: &[&str]) -> Result<(), clap::Error>`
- `__cli_command_for_test() -> clap::Command`

Test: `crates/stealth-cli/tests/output_format_coverage.rs` (new) — 4 tests:
1. `every_subcommand_accepts_output_format_json` — 14 leaf cases, parses cleanly.
2. `global_format_json_remains_compatible` — 3 cases on captcha/spider/doctor.
3. `clap_command_tree_has_no_arg_id_collision` — `debug_assert()` on the live tree.
4. `json_schema_inventory_matches_subcommand_set` — 11 schema files exist under `docs/json-schemas/cli/`.

Schemas (11 Draft-07 files + README):
- `captcha.output.json`, `browser.output.json`, `vpn.output.json` — `oneOf` over actions.
- `spider.output.json` — sectioned via `$defs` (auth / cf / recipe / example_site) per G.1 review.
- `relocate.output.json`, `cf-evaluate.output.json`, `measure.output.json` — single-shape.
- `auth.output.json`, `hermes.output.json`, `config.output.json` — `oneOf` over actions.
- `doctor.output.json` — mirrors `DoctorReport`.
- `README.md` — matrix table, rationale for `text`/`yaml` extensions, schema inventory.

CLI public-api snapshot regenerated (`scripts/cli-public-api-snapshot.sh`) → 577 lines additive, 4 modified. This is **api-additive** per `docs/compat.md`.

## Changes

```
git status --short | grep -E 'output_format|json-schemas/cli|stealth-cli/src/(lib|commands)|cli-public-api.snapshot'
git diff --stat -- crates/stealth-cli/src/lib.rs crates/stealth-cli/src/commands/{mod,output_format,spider,relocate,cf_evaluate,auth,measure,hermes}.rs crates/stealth-cli/tests/output_format_coverage.rs docs/json-schemas/cli/ .agent/v1.3/cli-public-api.snapshot.json
```

## Verify

1. **No clap collision**: `cargo test -p rev-stealth --lib cli_tests::` passes (8 tests) including `clap_command_passes_debug_assert`. `cargo test -p rev-stealth --test output_format_coverage` passes (4 tests).
2. **Coverage**: every top-level subcommand in `.agent/v1.3/cli-public-api.snapshot.json` (excluding hidden `completions`) carries either `--output-format` (G.4 shim) OR its pre-existing native local flag. Doctor + config keep their richer enums; everywhere else exposes the unified human/json enum.
3. **Backward compat**: `rev-stealth --format json <subcommand> …` still parses on every subcommand (covered by `global_format_json_remains_compatible` + pre-existing `global_format_json_still_parses_for_non_doctor_subcommand`).
4. **Schema inventory parity**: 11 schemas, one per top-level command, listed in `docs/json-schemas/cli/README.md`. `json_schema_inventory_matches_subcommand_set` is the CI gate.
5. **API additive only**: snapshot diff shows additions of `--output-format` flag rows; no flag REMOVALS or default-value changes for existing flags.
6. **Doctor/config untouched**: `doctor::DoctorFormat` still exposes `json|text` with `id="doctor_format"`. `config_cli::ConfigFormat` still exposes `text|json|yaml` with `id="config_output_format"`. No drift.
7. **No runtime behavior change beyond format resolution**: each subcommand's `run()` signature still takes `format: OutputFormat`; only the call site in `run_async` changed to resolve the override.
8. **Test isolation**: the test helper re-exports are `#[doc(hidden)] pub` with `__` prefix and called out as test-only in their doc comments — not part of the published surface.

## Out of scope / deferred

- `--dry-run` and `--explain` on mutate commands → Lane G.5.
- Strict JSON-schema *validation* of live CLI output (jsonschema crate) → deferred; the coverage test only validates the flag surface.
- captcha/browser/vpn position-tolerance: today the new flag must precede the action verb. Repositioning to the leaf would require adding the shim to every action variant (~6 variants); the global `--format` already covers post-verb position, so G.4 ships the noun-position flag.

## Baseline

Pre-G.4: 796 PASS / 0 FAIL (G.3 +5 over earlier 791).
Post-G.4: 800 PASS / 0 FAIL (+4 from `output_format_coverage`).

## Result Format

```
METRIC: lane=G.4 round=1 verdict=<LGTM|NEEDS_CHANGES> subcmds_with_output_format=<n>/<total> schemas=<n>/11 collisions=<count> issues=<count>
```
Then enumerate issues. LGTM = explicit. NEEDS_CHANGES = narrow actionable list.

Note: ignore pre-existing clippy errors in `crates/stealth-cli/tests/deprecated_completeness.rs` — those are owned by a parallel Lane I/J/K worktree, not G.4.
