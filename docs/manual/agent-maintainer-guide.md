# Agent Maintainer Guide

## 誰向けか

この文書は、このハーネスを見直し、保守し、アップグレードする次のエージェント向けです。ゼロコンテキストで再着任しても current truth に戻れることを目的にします。

## 最初に読む文書

1. `AGENTS.md`
2. `.agent_rules/RULES.md`
3. `.agent/PROJECT_CONTEXT.md`
4. `docs/roles/orchestrator.md`
5. `docs/manual/verification-truth-matrix.md`
6. `docs/manual/harness-release-gate.md`
7. `docs/manual/common-task-contract.md`
8. `docs/manual/harness-user-guide.md`

## 再開時の確認ポイント

1. `git status --short --branch` で dirty state を確認する
2. `.agent/active/plan_*.md`、`.agent/active/sow/`、`.agent/active/prompts/` を確認する
3. `.claude/tmp/harness-release-gate/latest.json` から `.claude/tmp/harness-release-gate/runs/<run-id>/summary.md` の latest gate evidence を確認する
4. `.claude/tmp/<task>/state.json` と `.claude/tmp/<task>/task-contract.json` を current run artifact として読む
5. `docs/README.md` から stable docs の authority を辿る

## どこを trust するか

trust する:

- `AGENTS.md`
- `.agent_rules/RULES.md`
- `.agent/PROJECT_CONTEXT.md`
- `docs/manual/verification-truth-matrix.md`
- current ExecPlan / current SOW / current handover
- current gate artifact
- run-local `stderr/` directories pointed to by wrapper / reviewer `*.stderr-pointer.txt`

trust しない:

- 古い dated plan を current authority と見なすこと
- `.claude/tmp/**` の export を durable authority と見なすこと
- `README.md` の summary だけで acceptance を判断すること

## current implemented state

- common task contract Slice A は implemented
- non-interactive automatic flow の session continuation は fail-closed
- semantic MCP auto-start parity は retired。Core は semantic MCP を自動起動せず、addon を明示 enable した場合だけ `addon-absent-or-compliant-check.sh --semantic` で config を検証する
- semantic preflight / capsule / registry protections は implemented
- Claude/Opus review の `--bare` は API-key auth (`ANTHROPIC_API_KEY` / `apiKeyHelper`) が明示された場合だけ許可する。OAuth/keychain 認証の非対話 review では `--bare` を省き、`--no-session-persistence`、明示 tools、`--permission-mode dontAsk`、budget を使う
- browser stack rollout は roadmap 段階であり、current stable flow ではない

## 主要コマンド

- `git status --short --branch`
- `git diff --check -- <files...>`
- `bash test/integration/harness_release_gate.sh`
- `bash test/integration/common_task_contract_smoke.sh`
- `( cd harness-rust && cargo test -p semantic-mcp )`
- `scripts/codex-wrapper.sh --help`
- `scripts/claude-wrapper.sh --help`
- `.claude/commands/lib/reviewer.sh`

## Frontier-push 後の API 表面 (2026-05 以降)

semantic-mcp tool surface に以下が追加されています。正典は skill `revharness-semantic-mcp-usage`:

- `sem.context.top_k`: server-side Top-K + context_token 発行 (TTL 30 min)
- `sem.capsule`: 必須 `{project_id, task_id, phase, context_token}`、`top_k_symbols` 送信禁止、`INDEX_VERSION` / `FILE_SHA_ROLLUP` 行追加
- `sem.search`: 既定 `kind="fts5"` (BM25 + 48h recency)、prefix wildcard なし、`legacy-like` は opt-in
- `sem.admin.gc`: orphan DB cleanup (`dry_run=true && force=false` default、実削除は `--dry-run=false --force` 両方明示)
- placement v2: `<XDG/Library/LOCALAPPDATA>/Revharness/semantic-mcp/v1/{project_id}/semantic.db`
- test isolation: `REVHARNESS_TEST_HARNESS=1` + `SEMANTIC_MCP_HOME=...`
