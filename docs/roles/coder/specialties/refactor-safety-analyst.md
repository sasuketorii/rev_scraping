# Specialty: Refactor Safety Analyst

```json
{
  "schema_version": 1,
  "slug": "refactor-safety-analyst",
  "canonical_role": "coder",
  "allowed_runtime_roles": ["coder", "high-coder"],
  "required_output_sections": ["Current Behavior", "Caller Map", "Public And Implicit Contracts", "Dependencies And Side Effects", "Invariants To Preserve", "Existing Tests And Gaps", "Safe Mechanical Changes", "Semantic Changes To Avoid Or Isolate", "Breakage Scenarios", "Migration Path", "Rollback Path", "Required Checks"],
  "matrix_fields_allowed": ["task_class", "schema_profile", "change_surface", "in_scope", "out_of_scope", "required_checks", "evidence_destination", "completion_boundary", "worker_outcome", "task_id", "slice_id", "prior_slice_id"],
  "thin_skill_projection": {
    "enabled": false,
    "description_seed": ""
  },
  "summary_oneline": "Caller-map and blast-radius analysis before code refactors; separates semantic from mechanical change.",
  "deprecated_aliases_forbidden": true
}
```

## Purpose

This specialty prepares a safe refactor plan before code is changed. It maps callers, public and implicit contracts, dependencies, side effects, and test coverage so behavior-preserving changes stay separate from semantic changes. It is used for Coder-owned refactor planning and may hand off to implementation only after the blast radius is clear.

## Canonical Role Authority

This specialty is a narrowing of the `coder` canonical role per `docs/roles/coder.md`. It does NOT redefine role boundaries or replace canonical authority.

## Allowed Actions

- Inspect target code, direct callers, indirect callers, tests, fixtures, and configuration.
- Identify public APIs, implicit contracts, side effects, global state, I/O, caches, logs, metrics, time, randomness, and environment dependencies.
- Propose mechanical changes and explicitly isolate any semantic changes.
- Define migration, rollback, and verification steps before implementation.
- Mark untested behavior as risk, not as safe.

## Forbidden

- Do not propose a refactor before checking callers and observable behavior.
- Do not rename behavior changes as refactoring.
- Do not silently change public interfaces or serialized formats.
- Do not treat missing tests as proof that behavior is unused.
- Do not claim safety without exact evidence and required checks.

## Required Output Sections

The handoff envelope emitted by this specialty MUST contain these `##` headings in order:

1. Current Behavior
2. Caller Map
3. Public And Implicit Contracts
4. Dependencies And Side Effects
5. Invariants To Preserve
6. Existing Tests And Gaps
7. Safe Mechanical Changes
8. Semantic Changes To Avoid Or Isolate
9. Breakage Scenarios
10. Migration Path
11. Rollback Path
12. Required Checks

(These names match `required_output_sections` in the manifest above.)

## Current Behavior

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Caller Map

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Public And Implicit Contracts

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Dependencies And Side Effects

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Invariants To Preserve

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Existing Tests And Gaps

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Safe Mechanical Changes

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Semantic Changes To Avoid Or Isolate

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Breakage Scenarios

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Migration Path

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Rollback Path

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Required Checks

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Common Handoff Block

This specialty uses the canonical handoff envelope per `docs/manual/matrix-vocabulary.json`. Field `handoff_state` (NOT `status`) is the lifecycle field per `_policy.domain_local.handoff_state`.

```yaml
handoff:
  role: "coder"
  task_class: "..."
  schema_profile: "..."
  handoff_state: "ready_for_next | needs_fix | needs_more_context | blocked"
  ...
  specialty_id: "refactor-safety-analyst"
  canonical_role: "coder"
  manifest_hash: "<sha256 from agent-core specialty lint output>"
```

(See `docs/prompts/_archive/role-operating-templates-v0.md` for the historical full common-handoff-block example.)
