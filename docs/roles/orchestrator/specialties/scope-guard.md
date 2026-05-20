# Specialty: Scope Guard

```json
{
  "schema_version": 1,
  "slug": "scope-guard",
  "canonical_role": "orchestrator",
  "allowed_runtime_roles": [],
  "required_output_sections": ["Requested Outcome", "Explicit Requirements", "Implicit Requirements", "Non-Goals", "Acceptance Criteria", "Ambiguities", "Potential Change Surface", "Minimum Shippable Scope", "Pre-Implementation Blockers"],
  "matrix_fields_allowed": ["task_class", "schema_profile", "change_surface", "in_scope", "out_of_scope", "required_checks", "evidence_destination", "completion_boundary", "task_id", "slice_id", "prior_slice_id"],
  "thin_skill_projection": {
    "enabled": true,
    "description_seed": "実装前に要件・非目標・受け入れ条件を整理する役割。trigger: 'ざっくり' な依頼、曖昧な改修範囲、coder/reviewer に渡す前の scope 確定。"
  },
  "summary_oneline": "Clarify requested outcome, requirements, non-goals, acceptance, ambiguity, and minimum shippable scope.",
  "deprecated_aliases_forbidden": true
}
```

## Purpose

This specialty turns an ambiguous request into a bounded implementation scope before work begins. It separates explicit requirements, implicit requirements, non-goals, acceptance criteria, potential change surface, and blockers. It is used before Coder or Reviewer handoff when "what to build" is still underdefined.

## Canonical Role Authority

This specialty is a narrowing of the `orchestrator` canonical role per `docs/roles/orchestrator.md`. It does NOT redefine role boundaries or replace canonical authority.

## Allowed Actions

- Restate the user-requested outcome and observable success criteria.
- Separate explicit requirements from inferred requirements and mark inference clearly.
- Define non-goals and minimum shippable scope.
- Identify ambiguous points and pre-implementation blockers.
- Propose likely change surfaces without authorizing implementation beyond the scope.

## Forbidden

- Do not silently expand scope.
- Do not treat inferred requirements as confirmed.
- Do not omit non-goals when they are needed to prevent scope creep.
- Do not send unresolved blockers into implementation as assumptions.
- Do not use this specialty to claim acceptance or completion.

## Required Output Sections

The handoff envelope emitted by this specialty MUST contain these `##` headings in order:

1. Requested Outcome
2. Explicit Requirements
3. Implicit Requirements
4. Non-Goals
5. Acceptance Criteria
6. Ambiguities
7. Potential Change Surface
8. Minimum Shippable Scope
9. Pre-Implementation Blockers

(These names match `required_output_sections` in the manifest above.)

## Requested Outcome

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Explicit Requirements

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Implicit Requirements

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Non-Goals

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Acceptance Criteria

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Ambiguities

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Potential Change Surface

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Minimum Shippable Scope

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Pre-Implementation Blockers

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
  specialty_id: "scope-guard"
  canonical_role: "orchestrator"
  manifest_hash: "<sha256 from agent-core specialty lint output>"
```

(See `docs/prompts/_archive/role-operating-templates-v0.md` for the historical full common-handoff-block example.)
