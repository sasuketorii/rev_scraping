# Lane I R2 fix-up — Sub-phase B + C review (combined)

Role: reviewer (Codex gpt-5.5 xhigh). Sub-phase A already passed (round 3 LGTM-equivalent after doc-only nit). This pass covers the remaining four deltas (#2, #4, #5, #6).

## Deltas in this slice

### Delta 4 — CLI snapshot v3 (`scripts/cli-public-api-snapshot.sh`)

`$schema_version` bumped 2 → 3. Additive fields (no removals):

* `mcp_tools.schemas.<tool>.input_enums` — `{property: sorted([values])}` extracted from `crates/stealth-mcp/src/tools.rs` `input_schema: json!({…})` blocks. Captures every input-schema enum constraint so a narrowing is detectable.
* `mcp_tools.schemas.<tool>.output` — `{properties: [...], required: [...], enums: {dotted_path: [...]}}` sourced from `docs/json-schemas/<tool>.output.json`. The recursive walk traverses `properties`/`items`/`additionalProperties`/`oneOf`/`anyOf`/`allOf` and records every `enum` array by dotted path.
* `error_kinds` — `{count, variants: [{variant, wire_name}]}` parsed from `crates/stealth-agent-contracts/src/error.rs`'s `pub enum ErrorKind { ... }`. Both Rust CamelCase and serde-renamed snake_case wire names are captured; either side of a rename now drifts the snapshot.
* `deprecated_attrs` — `[{path, line, since, replace_with}]` walking `crates/*/src/` for every `#[deprecated(...)]` attribute. Currently empty (no deprecated items yet), but the path:line index means a future "silent removal of replacement string" shows up.
* `_notes` updated.

Regenerated and committed; current snapshot at `.agent/v1.3/cli-public-api.snapshot.json` (46596 bytes).

### Delta 2 — `scripts/mcp-schema-breaking.sh` base-vs-head expansion

Detects three new breaking shapes in addition to tool-removal + required-arg tightening:

* `input_enum_narrowed` — value present in BASE.input_enums but absent in LIVE.
* `output_prop_removed` — top-level output property removed.
* `output_enum_narrowed` — value present in BASE.output.enums.* but absent in LIVE.

Schema-version awareness: when either base or live has `$schema_version < 3`, the new diff is skipped (graceful degradation) and a note is printed in the unchanged-summary line. 3-valued exit-code contract from Sub-phase A is preserved (`rc=2` for any breaking shape; other nonzero ⇒ script failure).

Repo-root override via `MCP_SCHEMA_BREAKING_REPO_ROOT` env (used by fixture tests).

### Delta 4b — fixture tests (`scripts/cli-public-api-snapshot.test.sh`)

5 scenarios over throwaway git repos:

1. additive — new tool added → rc=0 PASS
2. breaking — output enum narrowing (`recipe_show.status` drops `Pending`) → rc=2 PASS
3. breaking — required-arg tightening (`spider.timeout_ms` added) → rc=2 PASS
4. breaking — output property removed (`recipe_show.endpoints`) → rc=2 PASS
5. drift — malformed JSON LIVE snapshot → rc ∉ {0, 2} PASS

All five PASS locally. New CI job `mcp-schema-breaking-fixture-tests` runs them on every PR.

### Delta 5 — `crates/stealth-cli/tests/deprecated_completeness.rs`

`removal_target_version` now required. Two accepted source sites:

1. inside `note`: `removal_target_version = "X.Y.Z"` (matches `replace_with` precedent — `#[deprecated]` does not natively define this key)
2. as `// removal_target_version = "X.Y.Z"` line comment immediately above the attribute (skipping past `// I6-LINT: skip`)

Value must pass a loose-semver triple check (digits.digits.digits + optional -prerelease/+build). Smoke test extended with Case 6 (missing), Case 7 (comment-style accepted), Case 8 (non-semver rejected). All workspace tests pass (796 / 0 fail vs 791 baseline).

### Delta 6 — `docs/compat.md`

New `## MCP schema breaking — worked examples` section with:

* Table of 7 diff shapes × breaking? × label × bump
* Case 1 — enum narrowing (output): `recipe_show.status` drops `Pending`
* Case 2 — required field tightening (input): `spider.timeout_ms` added
* Case 3 — output type widening (string → closed enum) — discusses the detector's limitation when the base snapshot had no enum to compare against, and the manual escalation rule.

"Where to look next" updated with: snapshot v3 fields, 3-valued exit code, fixture-tests script, changelog lint, release-please-config.json target.

## Local validation

```
$ cargo test --workspace --no-fail-fast 2>&1 | grep "^test result" | awk '{s+=$4;f+=$6} END {print s, f}'
796 0
$ bash scripts/cli-public-api-snapshot.test.sh | tail -1
[fixture-test] results: 5 passed, 0 failed
$ python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo YAML OK
YAML OK
$ python3 scripts/changelog-keepachangelog-lint.py CHANGELOG.rev_scraping.md
changelog lint OK
$ ./scripts/mcp-schema-breaking.sh --check; echo rc=$?
[mcp-schema-breaking] MCP surface unchanged vs origin/main (16 tools, identical required-args; base snapshot pre-v3 — enum/output diff skipped).
rc=0
```

## Files touched in Sub-phase B+C

* `scripts/cli-public-api-snapshot.sh` — v3 expansion (input_enums, output, error_kinds, deprecated_attrs)
* `scripts/mcp-schema-breaking.sh` — base-vs-head diff for enum narrowing + output property removal + output enum narrowing; `MCP_SCHEMA_BREAKING_REPO_ROOT` override
* `scripts/cli-public-api-snapshot.test.sh` — NEW (5 fixture cases)
* `.github/workflows/ci.yml` — new `mcp-schema-breaking-fixture-tests` job
* `.agent/v1.3/cli-public-api.snapshot.json` — regenerated at schema_version=3
* `crates/stealth-cli/tests/deprecated_completeness.rs` — removal_target_version requirement + 3 new smoke cases
* `docs/compat.md` — worked-examples table + 3 cases + updated pointers

## Re-review focus

* Sub-phase A Round-3 fixes still hold (no regressions).
* Snapshot v3 fields capture the four breaking shapes the detector now diffs against.
* The `output` walk in `cli-public-api-snapshot.sh` correctly traverses nested `items`/`oneOf` etc.
* `mcp-schema-breaking.sh`'s schema_v3 gate degrades cleanly when only one side is v3.
* `removal_target_version` lint correctly handles BOTH inline-note (with `\"` escapes that arrive at the parser) AND comment-above forms.
* Fixture tests cover the "drift = script failure ≠ breaking" axis distinctly from breaking detection.

## Out of scope

R2 scoring round (orchestrator will run R2 dual scoring after this LGTM).

## Verdict format

```
VERDICT: LGTM | NEEDS_FIXES
findings:
  - <file>:<line>: <issue>
```
