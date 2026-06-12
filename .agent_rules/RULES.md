# Universal Agent Rules Index

This file is the shared-rule index for RevHarness. It incorporates the binding
shared modules below and keeps only index-level directives that every agent
family must find quickly.

## Index-Level Directives

- [RS-WORK-01] For complex feature work, broad refactors, mutation-authorizing
  plans, or high-risk policy changes, use an ExecPlan at
  `.agent/active/plan_YYYYMMDD_HHMM_<task>.md`.
- [RS-WORK-02] New ExecPlans follow
  `docs/manual/execplan-checklist-standard.md` and include at least a Status
  Board, Slice Board, Required Deterministic Checks, and Completion Boundary.
- [RS-WORK-03] Initial ExecPlan design, ExecPlan drafting, and ExecPlan review
  planning use the `initial_execplan_design` lane in
  `.agent/registry/model_policy.json`; do not downgrade that lane into routine
  docs-only planning.
- [RS-WORK-04] Reuse `.agent/templates/execplan_checklist_template.md` when a
  local template is needed.

## Incorporation By Reference

The rules in `.agent_rules/shared-language.md` are incorporated by reference and are binding as if written in this file. Clients that do not automatically expand file references MUST open and read the literal path `.agent_rules/shared-language.md` before acting on any surface it governs.

The rules in `.agent_rules/shared-safety.md` are incorporated by reference and are binding as if written in this file. Clients that do not automatically expand file references MUST open and read the literal path `.agent_rules/shared-safety.md` before acting on any surface it governs.

The rules in `.agent_rules/shared-workflow.md` are incorporated by reference and are binding as if written in this file. Clients that do not automatically expand file references MUST open and read the literal path `.agent_rules/shared-workflow.md` before acting on any surface it governs.

The rules in `.agent_rules/shared-acceptance.md` are incorporated by reference and are binding as if written in this file. Clients that do not automatically expand file references MUST open and read the literal path `.agent_rules/shared-acceptance.md` before acting on any surface it governs.

The rules in `.agent_rules/shared-delegation.md` are incorporated by reference and are binding as if written in this file. Clients that do not automatically expand file references MUST open and read the literal path `.agent_rules/shared-delegation.md` before acting on any surface it governs.

The rules in `.agent_rules/shared-semantic.md` are incorporated by reference and are binding as if written in this file. Clients that do not automatically expand file references MUST open and read the literal path `.agent_rules/shared-semantic.md` before acting on any surface it governs.

Skipping an incorporated module is equivalent to skipping this file.

## Module Charter Table

| Module | Charter | Trigger |
|---|---|---|
| `.agent_rules/shared-language.md` | Natural-language convention and canonical vocabulary. | Always. |
| `.agent_rules/shared-safety.md` | Secrets, project identity, destructive opt-in, slice discipline, and fail-closed defaults. | Always. |
| `.agent_rules/shared-workflow.md` | ExecPlan, development workflow, worktree/Hydra, SOW, and folder map. | Always. |
| `.agent_rules/shared-acceptance.md` | Acceptance language guard, worker outcome vocabulary, evidence pointers. | Always. |
| `.agent_rules/shared-delegation.md` | Wrapper role map, no direct binary, native-vs-cross-family boundaries. | When invoking or reasoning about agent delegation, wrappers, roles, or model lanes. |
| `.agent_rules/shared-semantic.md` | Transitional semantic-coordination extraction seed for the addon split. | When semantic capsule, Shadow Verify, semantic MCP, or index freshness is in scope. |
| `.agent_rules/shared-frontend.md` | Conditional frontend product guidance. | Read only when the active slice touches web frontend product code; it is not incorporated into the default binding core. |

## Anti-Circularity

- [RS-WORK-05] Shared modules may point only to down-stack authorities:
  `docs/manual/verification-truth-matrix.md`,
  `docs/canonical-invariants.md`, `docs/roles/**`, and `docs/manual/**`.
- [RS-WORK-06] Shared modules must not copy truth-matrix state machines,
  status/verdict tables, ceilings, or schema field lists; use a pointer and at
  most a one-line gloss.
- [RS-WORK-07] Shared modules must not reference vendor directories for binding
  policy. Vendor-specific files point to this index and keep family-specific
  invocation mechanics.
- [RS-WORK-08] Only this index incorporates shared modules. Modules do not
  incorporate each other.
- [RS-WORK-09] Self-priority clauses are forbidden in shared modules. Conflict
  resolution is owned by `AGENTS.md` read order and the matrix's acceptance
  authority.

## Reporting Template Ownership

- [RS-ACC-01] Role-specific report templates live in `docs/roles/*.md`.
  This index does not own a merged generic completion template.
- [RS-ACC-02] Matrix field definitions, valid status/verdict transitions,
  worker outcome payload semantics, loop ceilings, and final acceptance
  language are owned by `docs/manual/verification-truth-matrix.md`.
