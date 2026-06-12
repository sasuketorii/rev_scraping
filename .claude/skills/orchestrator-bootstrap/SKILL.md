---
name: orchestrator-bootstrap
description: Session-start routine for orchestrator. Raw-read the required session context first, then optionally use a FRESH semantic capsule. Never block on absent or STALE semantic state.
---

# Skill: Orchestrator Bootstrap

## When to use
- orchestrator role で session を新規開始する直後
- 既存 handover を受けて bootstrap する直後

## Goal
session-open の必須 context は raw-read で取得し、semantic indexing は FRESH な場合だけ opt-in 補助として使う。

## Steps
1. Raw-read required session context:
   a. `AGENTS.md` と `.agent_rules/RULES.md` の applicable bootstrap / invariant sections。
   b. 現 active plan（例: `.agent/active/plan_*.md`）と current handover / worker packet。
   c. task-local acceptance / evidence instructions。
2. Optional semantic capsule (addon opt-in, 2-step):
   a. semantic addon が有効で FRESH index が利用可能な場合だけ `sem.context.top_k` を呼び、`changed_files = ["AGENTS.md", ".agent_rules/RULES.md", "<current active plan>"]` (repo-relative)、required `{project_id, task_id, phase}` を渡して `context_token` を取得。
   b. 30 分以内に `sem.capsule` を `{project_id, task_id, phase, context_token}` で呼ぶ。`top_k_symbols` フィールドは送信禁止（fail-closed JSON-RPC error）。
   c. semantic addon disabled / STALE / absent / cache miss / token expiry の場合は semantic を待たず step 1 の raw-read を継続する。STALE capsule body を根拠にしない。詳細は skill `revharness-semantic-mcp-usage` 参照。
3. Active lineage:
   `.agent/active/sow/task-lineage-ledger.md` の該当 lineage entry を raw-read する。FRESH な `sem.registry.query(lineage=<active-task>)` がある場合だけ補助として使ってよい。
4. Auto-memory consult: family-native memory path (`~/.claude/projects/<project>/memory/MEMORY.md` for Claude, `~/.Codex/projects/<project>/memory/MEMORY.md` for Codex) の index を読み、`baseline-protection`、`Option D`、`plan-lgtm`、`codex-two-stage`、`semantic-opt-in` など関連 pattern を identify する。
5. User meta-goal 再確認: user の session-start message と `.agent/PROJECT_CONTEXT.md` の meta-goal section を参照し、orchestrator の意思決定をそこへ align する。
6. Truth read order 検証: AGENTS.md §Read Order の numbered read order（step 3 = .agent_rules/RULES.md と incorporated shared modules）に従い authority を確認する。role 固有の詳細は docs/roles/orchestrator.md を参照する。

## Exit criteria
- 上記 6 step が完了している
- session-open context が `~30k token` 以内に収まっている
- 超過時は compression または fork を検討する

## References
- `$CLAUDE_HOME/projects/<project-slug>/memory/feedback_semantic_first_access.md`
