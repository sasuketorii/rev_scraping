# Specialty: Body Missing Example Orchestrator

```json
{
  "schema_version": 1,
  "slug": "body-missing-example-orchestrator",
  "canonical_role": "orchestrator",
  "allowed_runtime_roles": [],
  "required_output_sections": ["Classification", "Slice Contract", "Routing"],
  "matrix_fields_allowed": ["task_class", "schema_profile", "change_surface", "in_scope", "out_of_scope", "required_checks", "evidence_destination", "completion_boundary"],
  "thin_skill_projection": {
    "enabled": false,
    "description_seed": ""
  },
  "summary_oneline": "Fixture for orchestrator body quality lint.",
  "deprecated_aliases_forbidden": true
}
```

## Purpose

Fixture file for R14.

## Classification

Record the selected task class, gate tier, and schema profile with the command used to derive them.

## Slice Contract

Record the allowed surface, evidence destination, required checks, and completion boundary before routing.

## Routing

State the next role and whether the request is valid for reviewer intake.
