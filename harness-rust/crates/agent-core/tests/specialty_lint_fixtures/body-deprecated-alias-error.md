# Specialty: Body Deprecated Alias Error

```json
{
  "schema_version": 1,
  "slug": "body-deprecated-alias-error",
  "canonical_role": "coder",
  "allowed_runtime_roles": ["coder", "high-coder"],
  "required_output_sections": ["Findings", "Verdict"],
  "matrix_fields_allowed": ["task_class", "schema_profile", "change_surface", "in_scope", "out_of_scope", "required_checks", "evidence_destination", "completion_boundary"],
  "thin_skill_projection": {
    "enabled": false,
    "description_seed": ""
  },
  "summary_oneline": "Fixture for deprecated alias body lint.",
  "deprecated_aliases_forbidden": true
}
```

## Purpose

Fixture file for R15.

## Findings

checkpoint boundary: old field name

## Verdict

This section has concrete content.
