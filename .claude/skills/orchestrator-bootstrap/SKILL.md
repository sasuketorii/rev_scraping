---
name: orchestrator-bootstrap
description: Session-start routine for orchestrator. Consume semantic capsule + memory consult + user meta-goal + truth read order before acting. Minimizes raw doc re-read.
---

# Skill: Orchestrator Bootstrap

## When to use
- orchestrator role で session を新規開始する直後
- 既存 handover を受けて bootstrap する直後

## Goal
raw doc 再読を最小化し、semantic indexing を first-class に使う。

## Steps
1. Semantic capsule pull (new contract, 2-step):
   a. `sem.context.top_k` を呼び、`changed_files = ["CLAUDE.md", ".agent_rules/RULES.md", "<current active plan>"]` (repo-relative)、required `{project_id, task_id, phase}` を渡して `context_token` を取得。
   b. 30 分以内に `sem.capsule` を `{project_id, task_id, phase, context_token}` で呼ぶ。`top_k_symbols` フィールドは送信禁止（fail-closed JSON-RPC error）。
   失敗時 fallback: `CLAUDE.md`、現 active plan、current handover を raw read。詳細は skill `revharness-semantic-mcp-usage` 参照。
2. Active lineage query: `sem.registry.query(lineage=<active-task>)` で Top-K read set を取得する。失敗時 fallback: `.agent/active/sow/task-lineage-ledger.md` の該当 lineage entry を raw read する。
3. Auto-memory consult: `~/.claude/projects/<project>/memory/MEMORY.md` の index を読み、`baseline-protection`、`Option D`、`plan-lgtm`、`codex-two-stage`、`semantic-first` など関連 pattern を identify する。
4. User meta-goal 再確認: user の session-start message と `.agent/PROJECT_CONTEXT.md` の meta-goal section を参照し、orchestrator の意思決定をそこへ align する。
5. Truth read order 検証: `docs/roles/orchestrator.md` の Truth Read Order に従い、`user -> role -> verification-truth-matrix -> runtime` の順で authority を確認する。

## Exit criteria
- 上記 5 step が完了している
- session-open context が `~30k token` 以内に収まっている
- 超過時は compression または fork を検討する

## References
- `$CLAUDE_HOME/projects/<project-slug>/memory/feedback_semantic_first_access.md`
