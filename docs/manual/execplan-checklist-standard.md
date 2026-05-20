# ExecPlan Checklist Standard

Date: `2026-04-22`
Status: `active`

## Purpose

This standard makes active ExecPlans machine-scannable and operator-readable by requiring a small checkbox-driven progress surface.

The goal is not to replace the existing narrative sections. The goal is to make it obvious, at a glance, what is done, what is still open, and what release boundary a plan belongs to.

Initial design, ExecPlan drafting, and ExecPlan review planning use the `initial_execplan_design` lane from `.agent/registry/model_policy.json`: `gpt-5.5` + `xhigh` + `cached` via the native `system_planner` / `plan_reviewer` presets. This is separate from routine docs-only or light planning.

## Required Sections

Every new active ExecPlan must contain at least:

1. `Objective`
2. `Status Board`
3. `Slice Board`
4. `In Scope`
5. `Out Of Scope`
6. `Required Deterministic Checks`
7. `Completion Boundary`

## Checkbox Rules

Use these conventions:

- `[x]` complete
- `[ ]` not yet complete

If a slice is blocked or intentionally deferred, keep it unchecked and annotate the reason inline rather than inventing a third checkbox state.

Examples:

- `[ ] Slice C: thin coordinator extraction (blocked by reviewer traceability hardening)`
- `[ ] Slice D: benchmark budget enforcement (deferred to v0.10.0 after policy digest wiring)`

## Status Board Contract

`Status Board` tracks plan-level or release-level milestones.

Recommended minimum entries:

- `[ ] Plan approved`
- `[ ] Implementation started`
- `[ ] Deterministic checks green`
- `[ ] xhigh review LGTM recorded`
- `[ ] Merged to main`
- `[ ] Release tag cut`
- `[ ] Archived / superseded`

Not every item must apply to every plan. If an item is not applicable, omit it instead of checking it.

## Slice Board Contract

`Slice Board` tracks child slices or major workstreams. Each line should map to a concrete implementation boundary that could be handed to a worker or reviewer.

Good:

- `[ ] Slice A: reviewer artifact traceability hardening`
- `[ ] Slice B: verdict projection and next-status projection`

Bad:

- `[ ] Improve harness`
- `[ ] Make things better`

## Release Target

If the plan belongs to a release train, declare it near the header and reflect that in `Status Board`.

Examples:

- `target release: v0.10.0`
- `current stable boundary: v0.9.2 @ <commit>`

## Specialty-Using Slices (Conditional Required Fields)

A slice is "specialty-using" if any of the following apply:

- The slice's `change surface` or `in-scope` includes a path matching `docs/roles/<canonical>/specialties/<slug>.md`.
- The slice's handoff envelope is emitted via `codex-wrapper.sh --specialty <slug>` invocation (Slice C).
- The slice's worker reads a specialty file directly as orchestrator narrowing context (orchestrator specialties via direct Read).
- The slice's emitted envelope is produced via `agent-core envelope render --specialty <slug>` (Slice B).

For specialty-using slices, the per-slice canonical-schema MUST include these conditional fields, in addition to the standard per-slice fields:

| Field | Value semantics |
|---|---|
| `specialty_id` | The specialty slug, e.g. `refactor-safety-analyst`. Lowercase kebab-case. |
| `canonical_role` | One of `coder | reviewer | orchestrator`. MUST match the parent directory of the specialty file. |
| `invocation_path` | One of `wrapper-flag | direct-read | generated-skill-hint`. Documents how the specialty was applied. |
| `selection_reason` | Free-text (1-3 sentences). Why this specialty was selected for this slice. |
| `manifest_hash` | Hex sha256 of the specialty manifest at slice authoring time. Obtain via `agent-core specialty lint --output-json <path>`. |

These fields are NOT required across all plans. They apply ONLY when a slice uses a specialty. Non-specialty slices follow the existing per-slice canonical-schema unchanged.

### Example

```yaml
slice_contract:
  slice_id: pr-x-some-refactor
  task_class: heavy
  schema_profile: heavy-canonical-final-packet
  change_surface: harness-rust/crates/agent-core/src/cmd/foo.rs
  in_scope: refactor extract helper
  required_checks:
    - cargo check -p agent-core
    - "cargo test -p agent-core foo::"
  specialty_id: refactor-safety-analyst
  canonical_role: coder
  invocation_path: wrapper-flag
  selection_reason: This slice does a non-trivial refactor; refactor-safety-analyst lens enumerates caller map + blast radius before any code change.
  manifest_hash: <hex from agent-core specialty lint>
```

### Lint Integration

`agent-core specialty lint --check-projections` (Slice B) already validates specialty file manifests.

### Machine-validated by `agent-core execplan lint`

Run `(cd harness-rust && cargo run -p agent-core -- execplan lint <plan.md>)` to verify each specialty-using slice in an ExecPlan carries the 5 conditional fields with correct semantics. The lint enforces:

- specialty_id present and matches `^[a-z0-9][a-z0-9-]*$`
- canonical_role matches the cited specialty file's parent directory and manifest
- invocation_path ∈ {wrapper-flag | direct-read | generated-skill-hint}
- manifest_hash matches the live specialty file's hash (freshness check)
- selection_reason is non-empty (warning if thin)

Rule IDs use the `execplan.*` namespace. Output schema matches the existing
`envelope lint` lint.json format. The lint is opt-in (explicit target); it
does NOT auto-run against all `.agent/active/plan_*.md` files. Use
`scripts/check-execplan-lint.sh <plan.md>` if you want a wrapper.

## Template

Use this file as the default starter when creating a new checkbox-driven ExecPlan:

- `.agent/templates/execplan_checklist_template.md`
