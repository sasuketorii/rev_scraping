---
name: "scope-guard"
description: "実装前に要件・非目標・受け入れ条件を整理する役割。trigger: 'ざっくり' な依頼、曖昧な改修範囲、coder/reviewer に渡す前の scope 確定。"
source_specialty_file: "docs/roles/orchestrator/specialties/scope-guard.md"
source_manifest_hash: "57de162dbce445c8b91bdc4a594b974792973ba90d821b536ae32c47ef1f95dd"
canonical_role: "orchestrator"
generated_by: agent-core specialty project
---

# scope-guard

This skill is a SELECTION HINT (lens), not a workflow owner. It is an Orchestrator-primary lens. For workflow execution, use auto-orchestrator / system-planner / review-workflow / codex-caller as appropriate. The orchestrator reads `docs/roles/orchestrator/specialties/scope-guard.md` directly; this skill auto-trigger is a discovery hint only.

## Summary

Clarify requested outcome, requirements, non-goals, acceptance, ambiguity, and minimum shippable scope.

Lens type: Orchestrator-primary lens
Canonical source: `docs/roles/orchestrator/specialties/scope-guard.md`

## How to invoke

Orchestrator direct Read:
- Read `docs/roles/orchestrator/specialties/scope-guard.md` directly and apply its required_output_sections.
- Treat this skill auto-trigger as discovery only; do NOT use it as a substitute for workflow skills.

Specialty manifest hash: `57de162dbce445c8b91bdc4a594b974792973ba90d821b536ae32c47ef1f95dd`
