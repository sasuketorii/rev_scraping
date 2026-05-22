# Compatibility & semver policy

`rev_scraping` follows [Semantic Versioning 2.0](https://semver.org/) at the
project level, with **three independent compatibility tiers** documented below.
This file is the source of truth referenced from PR templates, CI gates, and
the v1.3 ExecPlan Lane I (API stability).

Last reviewed: **v1.3.0** (Lane I.3, 2026-05-23).

## At-a-glance

| Surface | Stability guarantee | Drift gate | Bumps |
|---------|---------------------|------------|-------|
| **MCP tool schema** (`tool_definitions()` in `stealth-mcp`) | **2 major versions** of backward compatibility from first appearance | `scripts/mcp-schema-breaking.sh --check` (CI: `mcp-schema-breaking-detector`) covers all four breaking shapes via base-vs-head snapshot diff at `$schema_version >= 3`: tool removal/rename, required-arg tightening, input-schema enum narrowing, and output-property removal / output enum narrowing. 3-valued exit code: 0 unchanged, 2 intentional breaking, other nonzero script failure. Fixture coverage: `scripts/cli-public-api-snapshot.test.sh` (CI: `mcp-schema-breaking-fixture-tests`). The `mcp-schema-lint` job (`gen_reference --check`) remains as a rendered-doc backstop. | Removing a tool, renaming a tool, tightening a required-arg list, narrowing an input or output value enum, or removing a documented output field requires a **major** bump and a `mcp-schema-breaking` PR label. |
| **CLI flags & exit codes** (`rev-stealth` binary) | **1 major version** of backward compatibility | `scripts/cli-public-api-snapshot.sh --check` (CI: `cli-public-api-snapshot`, **HARD — drift always fails; labels classify but do not waive**) | Any drift against the committed snapshot must be regenerated and committed in the same PR (`./scripts/cli-public-api-snapshot.sh && git add .agent/v1.3/cli-public-api.snapshot.json`). The PR then carries `api-additive` (new flag/cmd/env var) or `api-breaking` (removed, renamed, default-changed) or `mcp-schema-breaking` (MCP tool list / required-arg / enum / output change) to classify the regenerated diff. |
| **Internal Rust types** (every `pub` item in workspace crates that is not re-exported from `stealth-cli` or `stealth-mcp` as part of the public ABI) | **no guarantee** — may change between any two minor versions | `cargo-public-api-diff` (R2: HARD GATE, label-required) | Internal refactors do not bump the project version. If a refactor *does* surface in the snapshot or the cargo-public-api diff, the matching `api-additive` (new pub item) / `api-breaking` (removed or renamed pub item) PR label is mandatory and the gate fails closed without one. Crate-level `Cargo.toml` versions follow workspace lockstep until the crates are published independently (out-of-scope for v1.3). |

## What counts as "public surface"

### MCP layer
Anything visible to a remote client over JSON-RPC:

- Tool names (16 in v1.3 — see `.agent/v1.3/cli-public-api.snapshot.json`).
- Each tool's required parameters, parameter types, and value enums.
- Each tool's documented output fields and `ErrorKind` discriminants.
- `_meta.sanitize` envelope shape.
- JSON-RPC error codes returned by the dispatcher.

### CLI layer
Anything visible to a shell user or CI script:

- Every flag (long + short).
- Every documented environment variable (`REV_STEALTH_*`, `REV_SCRAPING_*`).
- Every documented exit code (0 / 1 / 3 / 7 / 10).
- Output column names + JSON field names when `--format=json` is set.
- Default values for any flag whose default is documented in `--help`.

### Internal types
Anything that is `pub` in a workspace crate but is **not** in the snapshot
above. These remain semver-flexible to let us refactor without dragging users
through churn. We still avoid gratuitous renames, and we still apply the
`#[deprecated(since=…, note=…, replace_with=…)]` lint (Lane I.6) when a name
change is unavoidable.

## Bumping rules

- **Patch** (`v1.3.0 → v1.3.1`): bugfix-only. No new CLI flag, no new MCP tool,
  no schema field change.
- **Minor** (`v1.3.x → v1.4.0`): additive surface only. PRs must carry the
  `api-additive` label.
- **Major** (`v1.x → v2.0.0`): any removal or rename on the **MCP** or **CLI**
  tier. PRs must carry the `api-breaking` or `mcp-schema-breaking` label, and
  the CHANGELOG must include a `Breaking Changes` section with a migration
  recipe per item. Removals or renames on the **internal Rust types** tier do
  NOT trigger a project-major bump (per that tier's "no guarantee" rule); they
  may still carry `api-additive` / `api-breaking` labels for reviewer
  visibility but the version bump rule does not apply to them.

## MCP 2-major guarantee in practice

When `tool_X` first ships in v1.x, it remains callable through v3.x (two full
major versions after the major in which the deprecation lands). To remove it
cleanly:

1. v1.x — ship the tool.
2. v2.0 — `#[deprecated]` the tool implementation; add a `_meta.deprecated`
   field to the response; keep it functionally identical. The deprecation
   warning must be visible for the entirety of the v2.x and v3.x lines.
3. v4.0 — remove the tool; CHANGELOG documents the replacement.

This deliberately protects long-lived Claude Code / Hermes wrappers from
breakage triggered by a single rev_scraping release. Skipping the v2.0
deprecation step (removing in v2.0 directly) is itself a breaking-policy
violation: the tool can only be removed in v4.0, not earlier.

## CLI 1-major guarantee in practice

When `--flag-x` first ships in v1.x, it remains accepted through v2.x (one
full major version after the major in which the deprecation lands). To
remove it:

1. v1.x — ship the flag.
2. v2.0 — emit a `[deprecated]` warning on use; add the replacement.
3. v3.0 — remove the flag; CHANGELOG documents the replacement.

Env-var renames follow the same lifecycle (warning emitted from the layer
that consumes the legacy name).

## Internal types — "no guarantee" in practice

Workspace-internal modules (`stealth-core::sanitize::*`,
`stealth-mcp::server::*`, `stealth-parse::*` non-tool helpers, etc.) may be
renamed, refactored, or removed in any minor release. Downstream code embedding
these crates as path dependencies must pin to an exact workspace version.
Once any crate is published independently to crates.io (Lane H.5), its own
semver lifecycle decouples from the rev_scraping project version.

## MCP schema breaking — worked examples

The MCP tool catalog is a structured contract: callers depend on tool names,
required input args, accepted input enum values, output property names, and
output enum values. The `scripts/mcp-schema-breaking.sh` detector classifies
each diff against the base snapshot into one of four breaking shapes plus
two non-breaking shapes. The table below pins down how to bump on each.

| Shape | Example | Breaking? | Required label | Required bump |
|---|---|---|---|---|
| Tool removal / rename | `cf_evaluate` removed from `mcp_tools.names` | yes | `mcp-schema-breaking` | major (cliff after 2-major visibility) |
| Required-arg added | `spider.required` gains `timeout_ms` while `url` is kept | yes | `mcp-schema-breaking` | major |
| Input enum narrowed | `vpn_rotate.strategy` drops the `random` value | yes | `mcp-schema-breaking` | major |
| Output property removed | `recipe_show.output.properties` drops `endpoints` | yes | `mcp-schema-breaking` | major |
| Output enum narrowed | `recipe_show.output.enums.status` drops `Pending` | yes | `mcp-schema-breaking` | major |
| New tool added | new entry in `mcp_tools.names` | no | `api-additive` | minor |
| Required-arg relaxed | a previously required arg becomes optional | no | `api-additive` | minor |

### Case 1 — Enum narrowing (output): `recipe_show.status` loses `Pending`

```diff
- "enums": { "status": ["Active", "Pending", "Retired"] }
+ "enums": { "status": ["Active", "Retired"] }
```

A consumer that previously did `match status { Pending => … }` now silently
loses the branch. This is **major-bump breaking**, not minor — even though
the response payload still parses. Label: `mcp-schema-breaking`. The
detector emits the line:

```
[mcp-schema-breaking] BREAKING vs <base>: output enum narrowed
    - recipe_show.status: removed "Pending"
```

### Case 2 — Required field added (input): keep `url`, add new required `timeout_ms`

```diff
- "required": ["url"]
+ "required": ["timeout_ms", "url"]
```

Old callers that omit `timeout_ms` will be rejected by the input-schema
validator, so this is **major-bump breaking**. Label:
`mcp-schema-breaking`. The detector emits:

```
[mcp-schema-breaking] BREAKING vs <base>: tightened required-args
    - spider.timeout_ms
```

If instead the new field were *optional*, the change would be additive —
`api-additive` + minor bump.

### Case 3 — Output type changed: `auth_status.status` widens from a free-form string to a closed enum

```diff
  "properties": {
    "status": {
-     "type": "string"
+     "type": "string",
+     "enum": ["Valid", "ExpiringSoon", "ExpiringCritical",
+              "PartiallyExpired", "AllExpired", "Missing"]
    }
  }
```

This is **subtle**: narrowing the *type* (from any-string to a closed enum)
locks future server-side additions to a follow-up bump, but existing callers
that already only emit valid values are unaffected. The R2 detector flags
this as an **output enum narrowing** vs *no enum at all* in the base
snapshot — but the relevant `mcp_tools.schemas.auth_status.output.enums`
entry **did not exist** in the base snapshot, so the narrowing detector
does not fire. To make this break the gate, the snapshot must already
carry the prior enum literal; if it doesn't (i.e. the field was previously
documented as a free-form string), promote this PR to
`mcp-schema-breaking` manually and bump major. Rule of thumb: any
*type-shape* change is a major bump even when the detector cannot prove
it from the snapshot diff alone.

## Where to look next

- `.agent/v1.3/cli-public-api.snapshot.json` — committed public surface
  (`$schema_version = 3` carries enum constraints + output-schema fields).
- `scripts/cli-public-api-snapshot.sh` — regenerator + drift checker.
- `scripts/mcp-schema-breaking.sh` — MCP tool-list drift checker with the
  3-valued exit-code contract (0 = unchanged, 2 = breaking diff, other
  nonzero = script execution failure).
- `scripts/cli-public-api-snapshot.test.sh` — fixture tests covering the
  additive / breaking / drift scenarios.
- `scripts/changelog-keepachangelog-lint.py` — structural lint that gates
  the `## [Unreleased]` cursor release-please depends on.
- `CHANGELOG.rev_scraping.md` — project-level changelog (keep-a-changelog),
  the path `release-please-config.json` targets.
- `docs/MCP_REFERENCE.md` — current MCP tool catalog.
- `.github/workflows/ci.yml` — `cli-public-api-snapshot`,
  `cargo-public-api-diff` (hard gate, label-aware),
  `mcp-schema-breaking-detector` (label-aware),
  `mcp-schema-breaking-fixture-tests`, `changelog-lint` jobs.
