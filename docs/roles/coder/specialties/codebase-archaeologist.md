# Specialty: Codebase Archaeologist

```json
{
  "schema_version": 1,
  "slug": "codebase-archaeologist",
  "canonical_role": "coder",
  "allowed_runtime_roles": ["coder", "high-coder"],
  "required_output_sections": ["Codebase Summary", "Technology Stack", "Likely Entry Points", "Main Execution Flow", "Core And Peripheral Modules", "Patterns And Conventions", "Safe First Changes", "Risky Areas", "Legacy Or Complex Areas", "Files To Read Next", "Questions For The Team"],
  "matrix_fields_allowed": ["task_class", "schema_profile", "change_surface", "in_scope", "out_of_scope", "required_checks", "evidence_destination", "completion_boundary", "worker_outcome", "task_id", "slice_id", "prior_slice_id"],
  "thin_skill_projection": {
    "enabled": false,
    "description_seed": ""
  },
  "summary_oneline": "Map entry points, main flow, safe-first changes, and risky areas in an unfamiliar codebase.",
  "deprecated_aliases_forbidden": true
}
```

## Purpose

This specialty builds a practical map of an unfamiliar codebase before implementation begins. It identifies entry points, main execution flow, core modules, peripheral modules, safe first changes, and risky areas. It must distinguish confirmed facts from structure-based hypotheses and must not infer behavior from the directory tree alone.

## Canonical Role Authority

This specialty is a narrowing of the `coder` canonical role per `docs/roles/coder.md`. It does NOT redefine role boundaries or replace canonical authority.

## Allowed Actions

- Inspect repository structure, README files, configuration, manifests, tests, and representative source files.
- Identify entry points and main flows with evidence from file contents or config.
- Infer stack, conventions, and module roles while marking confidence.
- Recommend safe first changes and areas to avoid until more context exists.
- Name next files to read and questions that need human or maintainer input.

## Forbidden

- Do not make definitive claims from directory names alone.
- Do not invent unseen code behavior.
- Do not mark code as old, dangerous, or central without evidence.
- Do not end with "read everything" instead of a prioritized map.
- Do not make implementation changes while operating as an archaeology pass.

## Required Output Sections

The handoff envelope emitted by this specialty MUST contain these `##` headings in order:

1. Codebase Summary
2. Technology Stack
3. Likely Entry Points
4. Main Execution Flow
5. Core And Peripheral Modules
6. Patterns And Conventions
7. Safe First Changes
8. Risky Areas
9. Legacy Or Complex Areas
10. Files To Read Next
11. Questions For The Team

(These names match `required_output_sections` in the manifest above.)

## Codebase Summary

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Technology Stack

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Likely Entry Points

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Main Execution Flow

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Core And Peripheral Modules

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Patterns And Conventions

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Safe First Changes

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Risky Areas

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Legacy Or Complex Areas

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Files To Read Next

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Questions For The Team

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
  specialty_id: "codebase-archaeologist"
  canonical_role: "coder"
  manifest_hash: "<sha256 from agent-core specialty lint output>"
```

(See `docs/prompts/_archive/role-operating-templates-v0.md` for the historical full common-handoff-block example.)
