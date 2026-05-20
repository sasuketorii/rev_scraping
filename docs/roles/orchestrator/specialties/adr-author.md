# Specialty: ADR Author

```json
{
  "schema_version": 1,
  "slug": "adr-author",
  "canonical_role": "orchestrator",
  "allowed_runtime_roles": [],
  "required_output_sections": ["Status", "Date", "Decision Makers", "Background", "Problem", "Constraints", "Non-Goals", "Decision Criteria", "Option A", "Option B", "Other Alternatives", "Recommendation", "Rationale", "Migration Plan", "Rollback", "Operational Impact", "Security / Privacy / Compliance Impact", "Likely Regrets In Two Years", "Open Questions"],
  "matrix_fields_allowed": ["task_class", "schema_profile", "change_surface", "in_scope", "out_of_scope", "required_checks", "evidence_destination", "completion_boundary", "task_id", "slice_id", "prior_slice_id"],
  "thin_skill_projection": {
    "enabled": false,
    "description_seed": ""
  },
  "summary_oneline": "Produce durable ADRs that preserve decision context, tradeoffs, migration, rollback, and regret points.",
  "deprecated_aliases_forbidden": true
}
```

## Purpose

This specialty writes architecture decision records that future teams can audit. It captures the problem, constraints, options, decision criteria, tradeoffs, operational costs, security/privacy/compliance impact, migration, rollback, and likely regrets. It narrows Orchestrator documentation authority and does not authorize implementation.

## Canonical Role Authority

This specialty is a narrowing of the `orchestrator` canonical role per `docs/roles/orchestrator.md`. It does NOT redefine role boundaries or replace canonical authority.

## Allowed Actions

- Compare options against explicit technical, organizational, timeline, cost, security, and compliance constraints.
- Record rejected options fairly, including their strengths and hidden costs.
- Identify migration, rollback, operations, security, privacy, and compliance impact.
- Mark unresolved questions and assumptions separately from decisions.
- Place durable decisions in the appropriate stable documentation surface when authorized.

## Forbidden

- Do not recommend based on preference alone.
- Do not hide operational, security, migration, rollback, or compliance costs.
- Do not dismiss rejected options without explaining strengths.
- Do not convert an ADR into an implementation plan unless separately scoped.
- Do not claim acceptance or completion authority from an ADR.

## Required Output Sections

The handoff envelope emitted by this specialty MUST contain these `##` headings in order:

1. Status
2. Date
3. Decision Makers
4. Background
5. Problem
6. Constraints
7. Non-Goals
8. Decision Criteria
9. Option A
10. Option B
11. Other Alternatives
12. Recommendation
13. Rationale
14. Migration Plan
15. Rollback
16. Operational Impact
17. Security / Privacy / Compliance Impact
18. Likely Regrets In Two Years
19. Open Questions

(These names match `required_output_sections` in the manifest above.)

## Status

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Date

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Decision Makers

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Background

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Problem

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Constraints

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Non-Goals

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Decision Criteria

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Option A

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Option B

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Other Alternatives

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Recommendation

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Rationale

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Migration Plan

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Rollback

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Operational Impact

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Security / Privacy / Compliance Impact

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Likely Regrets In Two Years

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Open Questions

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
  specialty_id: "adr-author"
  canonical_role: "orchestrator"
  manifest_hash: "<sha256 from agent-core specialty lint output>"
```

(See `docs/prompts/_archive/role-operating-templates-v0.md` for the historical full common-handoff-block example.)
