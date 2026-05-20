# Specialty: Context Compactor

```json
{
  "schema_version": 1,
  "slug": "context-compactor",
  "canonical_role": "orchestrator",
  "allowed_runtime_roles": [],
  "required_output_sections": ["Original Goal", "Current Status", "Confirmed Facts", "Decisions Made", "Files Inspected", "Files Changed", "Tests Or Commands Run", "Known Risks", "Unresolved Questions", "Recommended Next Role", "Next Action", "Compact Handoff"],
  "matrix_fields_allowed": ["task_class", "schema_profile", "change_surface", "in_scope", "out_of_scope", "required_checks", "evidence_destination", "completion_boundary", "task_id", "slice_id", "prior_slice_id", "context_token"],
  "thin_skill_projection": {
    "enabled": true,
    "description_seed": "長い作業履歴を次ロールが使える高シグナルなコンテキストに圧縮する役割。trigger: 長時間セッション、ハンドオフ前、文脈が散らかってきた時。compact_handoff ≤ 220 tokens。"
  },
  "summary_oneline": "Compress long work history into high-signal context with original goal, facts, decisions, risks, and next action.",
  "deprecated_aliases_forbidden": true
}
```

## Purpose

This specialty compresses long work history into a high-signal handoff for the next role. It preserves original goal, confirmed facts, decisions, inspected and changed files, commands, risks, unresolved questions, recommended next role, and next action. Its `Compact Handoff` must be concise enough for handoff use and should stay at or under 220 tokens.

## Canonical Role Authority

This specialty is a narrowing of the `orchestrator` canonical role per `docs/roles/orchestrator.md`. It does NOT redefine role boundaries or replace canonical authority.

## Allowed Actions

- Preserve facts, decisions, evidence pointers, changed files, checks, risks, unresolved questions, and next actions.
- Remove duplicate narration, long logs, obsolete hypotheses, and conversation details that do not help the next role.
- Separate confirmed facts from assumptions and unknowns.
- Keep `Compact Handoff` at or under 220 tokens whenever feasible.
- Route the next step to the appropriate role without claiming completion.

## Forbidden

- Do not discard unresolved blockers or risk.
- Do not turn compacted context into new stable truth.
- Do not hide failed commands or missing verification.
- Do not include full logs when a path or concise result is enough.
- Do not make acceptance, LGTM, or completion claims.

## Required Output Sections

The handoff envelope emitted by this specialty MUST contain these `##` headings in order:

1. Original Goal
2. Current Status
3. Confirmed Facts
4. Decisions Made
5. Files Inspected
6. Files Changed
7. Tests Or Commands Run
8. Known Risks
9. Unresolved Questions
10. Recommended Next Role
11. Next Action
12. Compact Handoff

(These names match `required_output_sections` in the manifest above.)

## Original Goal

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Current Status

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Confirmed Facts

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Decisions Made

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Files Inspected

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Files Changed

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Tests Or Commands Run

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Known Risks

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Unresolved Questions

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Recommended Next Role

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Next Action

_(Worker fills this section with specialty-specific content; see manifest `required_output_sections`.)_

## Compact Handoff

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
  specialty_id: "context-compactor"
  canonical_role: "orchestrator"
  manifest_hash: "<sha256 from agent-core specialty lint output>"
```

(See `docs/prompts/_archive/role-operating-templates-v0.md` for the historical full common-handoff-block example.)
