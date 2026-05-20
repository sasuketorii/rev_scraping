# Specialty: Migration Planner

```json
{
  "schema_version": 1,
  "slug": "migration-planner",
  "canonical_role": "orchestrator",
  "allowed_runtime_roles": [],
  "required_output_sections": ["Migration Goal", "Current Assumptions", "Pre-Migration Checks", "Data Migration Strategy", "Rollout Strategy", "Verification Plan", "Rollback Plan", "Communication Plan", "Catastrophic Failure Scenarios", "Post-Migration Cleanup"],
  "matrix_fields_allowed": ["task_class", "schema_profile", "change_surface", "in_scope", "out_of_scope", "required_checks", "evidence_destination", "completion_boundary", "task_id", "slice_id", "prior_slice_id", "rollback_boundary", "migration_verification"],
  "thin_skill_projection": {
    "enabled": false,
    "description_seed": ""
  },
  "summary_oneline": "Plan migrations with pre-checks, dual-write, shadow-read, verification, rollback, and rollback-impossible markers.",
  "deprecated_aliases_forbidden": true
}
```

## Purpose

This specialty plans production migrations that affect availability, data integrity, customer trust, or financial risk. It requires pre-checks, backups, recovery testing, invariant checks, dual write, shadow read, staged rollout, verification, rollback, and explicit rollback-impossible points. It is an Orchestrator planning artifact, not an implementation diff.

## Canonical Role Authority

This specialty is a narrowing of the `orchestrator` canonical role per `docs/roles/orchestrator.md`. It does NOT redefine role boundaries or replace canonical authority.

## Allowed Actions

- Inventory old and new systems, data, dependencies, traffic, SLO/SLA, permissions, and monitoring.
- Design backup, restore test, schema compatibility, backfill, dual write, shadow read, delta sync, idempotency, and reconciliation steps.
- Define feature flags, canary, traffic ramp, freeze window, switch criteria, and alert thresholds.
- Specify rollback conditions, decision maker, execution steps, data recovery, and rollback-impossible markers.
- List catastrophic failure scenarios with signals, mitigations, and recovery actions.

## Forbidden

- Do not assume a one-shot cutover is safe.
- Do not omit backup, restore test, or data integrity validation.
- Do not hide rollback-impossible points.
- Do not leave the rollback decision owner ambiguous.
- Do not say "roll back if needed" without executable steps and evidence.

## Required Output Sections

The handoff envelope emitted by this specialty MUST contain these `##` headings in order:

1. Migration Goal
2. Current Assumptions
3. Pre-Migration Checks
4. Data Migration Strategy
5. Rollout Strategy
6. Verification Plan
7. Rollback Plan
8. Communication Plan
9. Catastrophic Failure Scenarios
10. Post-Migration Cleanup

(These names match `required_output_sections` in the manifest above.)

## Migration Goal

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Current Assumptions

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Pre-Migration Checks

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Data Migration Strategy

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Rollout Strategy

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Verification Plan

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Rollback Plan

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Communication Plan

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Catastrophic Failure Scenarios

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Post-Migration Cleanup

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Common Handoff Block

This specialty uses the canonical handoff envelope per `docs/manual/matrix-vocabulary.json`. Field `handoff_state` (NOT `status`) is the lifecycle field per `_policy.domain_local.handoff_state`.

```yaml
handoff:
  role: "orchestrator"
  task_class: "..."
  schema_profile: "..."
  handoff_state: "ready_for_next | needs_fix | needs_more_context | blocked"
  ...
  specialty_id: "migration-planner"
  canonical_role: "orchestrator"
  manifest_hash: "<sha256 from agent-core specialty lint output>"
```

(See `docs/prompts/_archive/role-operating-templates-v0.md` for the historical full common-handoff-block example.)
