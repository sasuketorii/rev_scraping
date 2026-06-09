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
   a. `CLAUDE.md` と `AGENTS.md` の applicable bootstrap / invariant sections。
   b. 現 active plan（例: `.agent/active/plan_*.md`）と current handover / worker packet。
   c. task-local acceptance / evidence instructions。
2. Optional semantic capsule:
   a. FRESH index が利用可能な場合だけ `sem.context.top_k` -> `sem.capsule` を使ってよい。
   b. STALE / absent / cache miss / token expiry の場合は semantic を待たずに raw-read を継続する。STALE capsule body を根拠にしない。
   c. 詳細は skill `revharness-semantic-mcp-usage` 参照。
3. Active lineage:
   `.agent/active/sow/task-lineage-ledger.md` の該当 lineage entry を raw-read する。FRESH な `sem.registry.query(lineage=<active-task>)` がある場合だけ補助として使ってよい。
4. Auto-memory consult: `~/.claude/projects/<project>/memory/MEMORY.md` の index を読み、`baseline-protection`、`Option D`、`plan-lgtm`、`codex-two-stage`、`semantic-opt-in` など関連 pattern を identify する。
5. User meta-goal 再確認: user の session-start message と `.agent/PROJECT_CONTEXT.md` の meta-goal section を参照し、orchestrator の意思決定をそこへ align する。
6. Truth read order 検証: `docs/roles/orchestrator.md` の Truth Read Order に従い、`user -> role -> verification-truth-matrix -> runtime` の順で authority を確認する。

## Exit criteria
- 上記 6 step が完了している
- session-open context が `~30k token` 以内に収まっている
- 超過時は compression または fork を検討する

## References
- `$CLAUDE_HOME/projects/<project-slug>/memory/feedback_semantic_first_access.md`
