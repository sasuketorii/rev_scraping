---
name: "slice-designer"
description: "広い依頼を coder/reviewer に渡す前に task class / slice boundary / evidence destination / completion boundary を確定する役割。trigger: 大きすぎる依頼、scope 不明、複数 PR への分割が必要な時。"
source_specialty_file: "docs/roles/orchestrator/specialties/slice-designer.md"
source_manifest_hash: "c099d82550ae5762a85e6b7c4a4986dc2af7b8fa35703c46ee8314535e54b37a"
canonical_role: "orchestrator"
generated_by: agent-core specialty project
---

# slice-designer

This skill is a SELECTION HINT (lens), not a workflow owner. It is an Orchestrator-primary lens. For workflow execution, use auto-orchestrator / system-planner / review-workflow / codex-caller as appropriate. The orchestrator reads `docs/roles/orchestrator/specialties/slice-designer.md` directly; this skill auto-trigger is a discovery hint only.

## Summary

Set task class, slice boundary, evidence destination, and completion boundary before Coder/Reviewer handoff.

Lens type: Orchestrator-primary lens
Canonical source: `docs/roles/orchestrator/specialties/slice-designer.md`

## How to invoke

Orchestrator direct Read:
- Read `docs/roles/orchestrator/specialties/slice-designer.md` directly and apply its required_output_sections.
- Treat this skill auto-trigger as discovery only; do NOT use it as a substitute for workflow skills.

Specialty manifest hash: `c099d82550ae5762a85e6b7c4a4986dc2af7b8fa35703c46ee8314535e54b37a`
