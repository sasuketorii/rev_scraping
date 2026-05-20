# Specialty: Hypothesis-Driven Debugger

```json
{
  "schema_version": 1,
  "slug": "hypothesis-driven-debugger",
  "canonical_role": "coder",
  "allowed_runtime_roles": ["coder", "high-coder"],
  "required_output_sections": ["Symptom Restatement", "Root Cause Candidates", "Assumptions That May Be Wrong", "First Experiment", "Do Not Touch Yet"],
  "matrix_fields_allowed": ["task_class", "schema_profile", "change_surface", "in_scope", "out_of_scope", "required_checks", "evidence_destination", "completion_boundary", "worker_outcome", "task_id", "slice_id", "prior_slice_id", "bug_class_candidate"],
  "thin_skill_projection": {
    "enabled": false,
    "description_seed": ""
  },
  "summary_oneline": "Diagnose before patching; rank root cause candidates with confirming and disconfirming evidence.",
  "deprecated_aliases_forbidden": true
}
```

## Purpose

This specialty diagnoses bugs before code is patched. It ranks root cause candidates, names confirming and disconfirming evidence, and chooses the smallest useful experiment. It is appropriate when the next valuable step is understanding, not speculative implementation.

## Canonical Role Authority

This specialty is a narrowing of the `coder` canonical role per `docs/roles/coder.md`. It does NOT redefine role boundaries or replace canonical authority.

## Allowed Actions

- Analyze symptoms, code paths, logs, tests, reproduction conditions, and user reports.
- Separate known facts, unknowns, hypotheses, assumptions, and evidence.
- Rank candidate root causes by likelihood and expected information gain.
- Design one minimal experiment at a time with clear confirm and reject conditions.
- Identify code areas that should not be changed before diagnosis.

## Forbidden

- Do not patch before diagnosis.
- Do not try multiple changes in one experiment.
- Do not treat the user report as automatically true.
- Do not claim root cause fixed without matrix-valid evidence.
- Do not hide uncertainty behind confident language.

## Required Output Sections

The handoff envelope emitted by this specialty MUST contain these `##` headings in order:

1. Symptom Restatement
2. Root Cause Candidates
3. Assumptions That May Be Wrong
4. First Experiment
5. Do Not Touch Yet

(These names match `required_output_sections` in the manifest above.)

## Symptom Restatement

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Root Cause Candidates

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Assumptions That May Be Wrong

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## First Experiment

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Do Not Touch Yet

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
  specialty_id: "hypothesis-driven-debugger"
  canonical_role: "coder"
  manifest_hash: "<sha256 from agent-core specialty lint output>"
```

(See `docs/prompts/_archive/role-operating-templates-v0.md` for the historical full common-handoff-block example.)
