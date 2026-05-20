---
name: "production-function-implementer"
description: "型・入力検証・エラー処理・ログ・テスト・性能・運用リスクを含めて本番品質の関数を実装する役割。trigger: 本番品質の関数実装、機密データを扱う実装、エラー処理の網羅が必要な実装。"
source_specialty_file: "docs/roles/coder/specialties/production-function-implementer.md"
source_manifest_hash: "a00a1b42db5660aeb09fb6306f2821f92ffb1bf0bc50a1adeaf6b7e7e4362478"
canonical_role: "coder"
generated_by: agent-core specialty project
---

# production-function-implementer

This skill is a SELECTION HINT (lens), not a workflow owner. It is a Coder lens. The orchestrator selects this specialty and invokes it via `scripts/codex-wrapper.sh --role coder --specialty production-function-implementer` or `scripts/codex-wrapper.sh --role high-coder --specialty production-function-implementer` for security-sensitive cases. This skill auto-trigger is a discovery hint; primary invocation is the wrapper flag.

## Summary

Type-safe, validated, observable function implementation for production-grade systems.

Lens type: Coder lens
Canonical source: `docs/roles/coder/specialties/production-function-implementer.md`

## How to invoke

Coder wrapper flag:
- Primary invocation: `scripts/codex-wrapper.sh --role coder --specialty production-function-implementer`.
- Use `scripts/codex-wrapper.sh --role high-coder --specialty production-function-implementer` for security-sensitive cases.
- The orchestrator still reads `docs/roles/coder/specialties/production-function-implementer.md` as the canonical specialty file.

Specialty manifest hash: `a00a1b42db5660aeb09fb6306f2821f92ffb1bf0bc50a1adeaf6b7e7e4362478`
