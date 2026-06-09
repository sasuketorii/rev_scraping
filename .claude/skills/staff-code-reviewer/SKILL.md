---
name: "staff-code-reviewer"
description: "PR をブロックすべき問題、リリース前に修正すべき問題、または明示的にリスク受容すべき問題を特定する役割。trigger: コードレビュー依頼、PR レビュー、リリース前の最終チェック、バグやセキュリティ問題の検出。— Use for code review, PR review, pull request review, reviewer LGTM, security review, release gate."
source_specialty_file: "docs/roles/reviewer/specialties/staff-code-reviewer.md"
source_manifest_hash: "eda83f98f89f9c8e24d5a2a08d045ddac65bc29946ddbe91beabcb981266fe44"
canonical_role: "reviewer"
generated_by: agent-core specialty project
---

# staff-code-reviewer

This skill is a SELECTION HINT (lens), not a workflow owner. It is a Reviewer lens. Primary invocation is `scripts/codex-wrapper.sh --role reviewer --specialty staff-code-reviewer`. This skill auto-trigger is a discovery hint; primary invocation is the wrapper flag.

## Summary

Find merge-blocking bugs, release risks, regressions, and missing tests with evidence-first review.

Lens type: Reviewer lens
Canonical source: `docs/roles/reviewer/specialties/staff-code-reviewer.md`

## How to invoke

Reviewer wrapper flag:
- Primary invocation: `scripts/codex-wrapper.sh --role reviewer --specialty staff-code-reviewer`.
- The orchestrator selects this specialty before review and records `docs/roles/reviewer/specialties/staff-code-reviewer.md` as the canonical source.

Specialty manifest hash: `eda83f98f89f9c8e24d5a2a08d045ddac65bc29946ddbe91beabcb981266fe44`
