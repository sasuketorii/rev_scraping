---
name: codex-caller
description: "[2026-06-15 Agent SDK billing addendum] 本 skill は Claude→Codex の cross-family delegation 専用 (Claude top-level orchestrator から Codex を呼ぶケース)。Codex top-level orchestrator から Claude (claude-wrapper.sh 経由) への逆方向 cross-family は default flow から除外・実行禁止 (`claude --print` が Agent SDK monthly credit を消費するため)。Call Codex CLI through the canonical wrapper contract. Use when you need to run Codex for coding, review, or research."
allowed-tools: Read, Bash, Grep, Glob
---

# Skill: Codex Caller

Phase 2 では、Codex の caller-facing entrypoint は常に `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>`。workflow の所有は別 skill に分かれるが、**Codex の起動契約**はこの skill が持つ。

## Primary Contract

| role | reasoning effort | web search | 用途 |
|------|------------------|------------|------|
| `standard` | `medium` | `cached` | 軽量な生成、要約、補助作業 |
| `research` | `high` | `live` | 外部調査、最新版確認、調査メモ生成 |
| `coder` | `medium` | `cached` | 通常の実装、修正 |
| `high-coder` | `high` | `cached` | security-sensitive / 複雑な実装 |
| `reviewer` | `xhigh` | `cached` | レビュー専用 |

Native routing note: initial design / ExecPlan drafting / ExecPlan review planning is not a caller-facing wrapper role. It uses the `initial_execplan_design` lane from `.agent/registry/model_policy.json`: `gpt-5.5` + `xhigh` + `cached` via native `system_planner` / `plan_reviewer`, and must not be downgraded to ordinary docs-only / light planning.

## Canonical Invocation

```bash
# 軽量タスク
cat PROMPT.md PAYLOAD.md \
  | ./scripts/codex-wrapper.sh --role standard --stdin \
  > output.md

# 外部調査
cat PROMPT.md PAYLOAD.md \
  | ./scripts/codex-wrapper.sh --role research --stdin \
  > output.md

# 実装・修正
cat PROMPT.md PAYLOAD.md \
  | ./scripts/codex-wrapper.sh --role coder --stdin \
  > output.md

# 複雑 / security-sensitive な実装
cat PROMPT.md PAYLOAD.md \
  | ./scripts/codex-wrapper.sh --role high-coder --stdin \
  > output.md

# レビュー
cat PROMPT.md PAYLOAD.md \
  | ./scripts/codex-wrapper.sh --role reviewer --stdin \
  > output.md
```

## Compatibility Only

| legacy shim | canonical role |
|-------------|----------------|
| `scripts/codex-wrapper-medium.sh` | `standard` |
| `scripts/codex-wrapper-high.sh` | `high-coder`（historical name） |
| `scripts/codex-wrapper-xhigh.sh` | `reviewer` |

- 互換 shim は移行用の入口に限る。
- primary guidance、サンプル、運用手順では canonical wrapper を先に示す。
- reviewer 固定経路や shim 固定 role から別 role へ逃がさない。

## When NOT to use
- Codex top-level orchestrator の中から Claude (claude-wrapper.sh) を呼ぶケース。
  これは default flow から禁止されている (2026-06-15 Agent SDK billing 分離)。
  該当ケースでは人間が別の Claude TUI セッションを開いて対応すること。

## Guardrails
- `codex exec` を直接呼ばない。
- `-c model=...` と `-c model_reasoning_effort=...` を付けない。
- caller-facing role は `--role` で明示する。`CODEX_WRAPPER_ROLE` / `AGENT_ROLE` は省略時の互換フォールバックに留める。
- 入力は必ず `--stdin` で渡す。
- `--cd` / `--add-dir` は caller から前提にしない。wrapper が警告して strip する。
- canonical wrapper 不在、role 解決失敗、shim 固定 role escape は fail-closed で停止し、direct `codex exec` へフォールバックしない。

## Negative Boundary
- native Codex multi-agent / subagent orchestration は Codex セッション内部で完結させる。caller-facing / manual / external な起動契約として wrapper に載せ替えない。
- wrapper の内側から別の `scripts/codex-wrapper.sh` を再帰起動しない。subagent 利用を理由に wrapper recursion を作らない。
- wrapper が失敗しても、hidden direct `codex exec` fallback を実装しない。失敗はそのまま上位へ返し、route か入力を修正する。
- `scripts/codex-wrapper.sh --role ...` は external entrypoint 用であり、native subagent preset や内部オーケストレーションの transport には使わない。

## Session Rule
- 自動化フローでは wrapper 経由の**新規実行**を使う。
- `--resume` は手動 TTY セッションでのみ使う。

## Goal Workflow Boundary

- Codex `/goal` is allowed as an interactive TUI operator convenience only.
- Non-interactive wrapper stdin must not receive raw `/goal` slash-command injection.
- Codex app-server Goal transport, if added later, is optional opt-in transport and must set/clear Goal explicitly per run.
- Goal is runtime steering only. It does not replace task contract, evidence, deterministic checks, reviewer verdict rules, or `docs/manual/verification-truth-matrix.md`.
- For Goal / app-server / prompting behavior changes, route through `harness-official-docs-update` before changing harness behavior.

## Claude Side Note
- Claude 側の effort 既定値は `medium`。
- caller-facing effort は `low|medium|high|xhigh` のみ許可し、`max` は使わない。

## 関連 workflow owner
- `auto-orchestrator`: どの workflow skill に振るかを決める
- `review-workflow`: review/fix loop を所有する
- `research-handoff`: 調査から handoff までを所有する
- `system-planner`: planning と plan handoff を所有する
- `harness-official-docs-update`: Codex / Claude Code upstream docs から local authority mapping を作る
