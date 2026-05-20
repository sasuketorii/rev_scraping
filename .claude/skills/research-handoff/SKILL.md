---
name: research-handoff
description: Own the reusable external research and handoff workflow for Phase 2.
allowed-tools: Read, Bash, Grep, Glob
---

# Skill: Research Handoff

外部調査が必要な作業は、この skill が所有する。調査結果をそのまま planner/coder/reviewer に渡せる形へ整えるところまでを責務に含める。

## 使う場面
- ユーザーが「調査して」「確認して」「最新を見て」と明示した
- バージョン、仕様、料金、API、法令など、鮮度が重要な情報が必要
- planning や implementation が外部不確実性で止まっている

## 呼び出し契約

```bash
cat PROMPT.md PAYLOAD.md \
  | ./scripts/codex-wrapper.sh --role research --stdin \
  > research.md
```

- caller-facing runtime truth は canonical wrapper。
- legacy shim は互換レイヤであり、調査手順の primary guidance にしない。
- live research が不要ならこの route を使わない。

## 出力要件
- 調査結果の要約
- 根拠リンクまたは出典
- 何が確定したか / 何が未確定か
- 次に planner/coder/reviewer が取るべきアクション

## Official Docs Update Handoff

Codex / Claude Code / OpenAI prompting / subagent / skill / hook / Goal workflow の調査では、`docs/official-docs-links.md` と `.claude/skills/harness-official-docs-update/SKILL.md` を優先する。handoff には次を含める。

- consulted official pages
- upstream recommendation or behavior
- local Revharness authority file that should absorb the change
- boundaries that must not change, especially wrapper policy and `docs/manual/verification-truth-matrix.md`
- whether implementation should proceed, block, or require a separate ExecPlan

## handoff 先
- 計画更新が必要なら `system-planner`
- 実装に進めるなら coder
- 判断済み差分の検証なら `review-workflow`

## 補足
- Claude 側の effort 既定値は `medium`。調査起点でも自動で高 effort 前提にはしない。
- semantic MCP は Claude / Codex の両 CLI で repo-local 設定から自動起動する前提で扱う。
