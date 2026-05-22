# Compatibility & semver policy

`rev_scraping` follows [Semantic Versioning 2.0](https://semver.org/) at the
project level, with **three independent compatibility tiers** documented below.
This file is the source of truth referenced from PR templates, CI gates, and
the v1.3 ExecPlan Lane I (API stability).

Last reviewed: **v1.3.0** (Lane I.3, 2026-05-23).

## At-a-glance

| Surface | Stability guarantee | Drift gate | Bumps |
|---------|---------------------|------------|-------|
| **MCP tool schema** (`tool_definitions()` in `stealth-mcp`) | **2 major versions** of backward compatibility from first appearance | `scripts/mcp-schema-breaking.sh --check` covers tool-name removals/renames and required-arg tightening (CI: `mcp-schema-breaking-detector`). The `mcp-schema-lint` CI job (`gen_reference --check`) is a freshness check — it only catches enum/output-field changes that the contributor *forgot to regenerate* in `docs/MCP_REFERENCE.md`; if the contributor regenerates the docs, an enum narrow / output rename will pass. Extending the snapshot diff to cover enums and output fields is tracked for **v1.4** (Lane I-followup). For v1.3, those narrows are policy-only and rely on the reviewer applying the `mcp-schema-breaking` label by hand. | Removing a tool, renaming a tool, tightening a required-arg list, narrowing a value enum, or changing a documented output field requires a **major** bump and a `mcp-schema-breaking` PR label. |
| **CLI flags & exit codes** (`rev-stealth` binary) | **1 major version** of backward compatibility | `scripts/cli-public-api-snapshot.sh --check` (CI: `cli-public-api-snapshot`) | Any drift against the committed snapshot requires `api-additive` (new flag/cmd/env var) or `api-breaking` (removed, renamed, default-changed). |
| **Internal Rust types** (every `pub` item in workspace crates that is not re-exported from `stealth-cli` or `stealth-mcp` as part of the public ABI) | **no guarantee** — may change between any two minor versions | `cargo-public-api-diff` (advisory in v1.3, hardened in v1.4) | Internal refactors do not bump the project version. If a refactor *does* surface in the snapshot or the cargo-public-api diff, the same `api-additive` (new pub item) / `api-breaking` (removed or renamed pub item) labels apply at the discretion of the reviewer. Crate-level `Cargo.toml` versions follow workspace lockstep until the crates are published independently (out-of-scope for v1.3). |

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

## Where to look next

- `.agent/v1.3/cli-public-api.snapshot.json` — committed public surface.
- `scripts/cli-public-api-snapshot.sh` — regenerator + drift checker.
- `scripts/mcp-schema-breaking.sh` — MCP tool-list drift checker.
- `CHANGELOG.rev_scraping.md` — project-level changelog (keep-a-changelog).
- `docs/MCP_REFERENCE.md` — current MCP tool catalog.
- `.github/workflows/ci.yml` — `cli-public-api-snapshot`, `cargo-public-api-diff`,
  `mcp-schema-breaking-detector` jobs.
