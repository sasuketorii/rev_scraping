---
name: "context-compactor"
description: "長い作業履歴を次ロールが使える高シグナルなコンテキストに圧縮する役割。trigger: 長時間セッション、ハンドオフ前、文脈が散らかってきた時。compact_handoff ≤ 220 tokens。"
source_specialty_file: "docs/roles/orchestrator/specialties/context-compactor.md"
source_manifest_hash: "6a8a768be89fa18e8abdd3701575d980389309123c92e72552da98b57a5508ab"
canonical_role: "orchestrator"
generated_by: agent-core specialty project
---

# context-compactor

This skill is a SELECTION HINT (lens), not a workflow owner. It is an Orchestrator-primary lens. For workflow execution, use auto-orchestrator / system-planner / review-workflow / codex-caller as appropriate. The orchestrator reads `docs/roles/orchestrator/specialties/context-compactor.md` directly; this skill auto-trigger is a discovery hint only.

## Summary

Compress long work history into high-signal context with original goal, facts, decisions, risks, and next action.

Lens type: Orchestrator-primary lens
Canonical source: `docs/roles/orchestrator/specialties/context-compactor.md`

## How to invoke

Orchestrator direct Read:
- Read `docs/roles/orchestrator/specialties/context-compactor.md` directly and apply its required_output_sections.
- Treat this skill auto-trigger as discovery only; do NOT use it as a substitute for workflow skills.

Specialty manifest hash: `6a8a768be89fa18e8abdd3701575d980389309123c92e72552da98b57a5508ab`
