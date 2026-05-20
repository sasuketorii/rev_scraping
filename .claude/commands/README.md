# .claude/commands

ClaudeCode / Codex のサブスク環境で使うローカルコマンド定義の置き場。
スクリプト化したワークフロー（例: オーケストレーター起動、ログ収集、レビューワイヤ送信）が増えたらここに追加する。

## 現在の見方

- command は**実行入口**。
- 再利用可能な workflow の owner は `.claude/skills/*.md`。
- `auto-orchestrator` は薄い router として、`review-workflow` / `research-handoff` / `system-planner` へ振り分ける。
- Codex 呼び出し契約は `codex-caller` が持ち、caller-facing runtime truth は `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>`。
- semantic MCP は `.claude/settings.json` と `.codex/config.toml` の repo-local 設定から `./scripts/launch-semantic-mcp.sh` を自動起動する。
- acceptance / truth placement の shared source of truth は `docs/manual/verification-truth-matrix.md`。

## Truth Hierarchy

1. ユーザー指示と task scope
2. 対応する role / workflow owner skill
3. `docs/manual/verification-truth-matrix.md`
4. command / wrapper の runtime contract

- repo-wide hard rule は `.agent_rules/RULES.md`。
- stable truth は manual / README / skill に置く。
- slice 固有の scope / required checks / checkpoint boundary は `.agent/active/plan_*.md` / `.agent/active/sow/*.md` / handoff prompt に置く。
- run artifact は `.claude/tmp/**` に置く。

## Verification By Surface

`docs/manual/verification-truth-matrix.md` に従い、最低ラインは次の通り。

| surface | minimum deterministic checks |
|---------|------------------------------|
| 純粋な説明文書のみ | `git diff --check -- <files>` |
| コマンド、パス、gate、review 条件、運用例を変更する文書 | `git diff --check -- <files>` と `test -e <path>` |
| script / wrapper / 実行入口 | `git diff --check -- <files>`、`bash -n <file>`、非破壊 help / syntax / existence probe |
| release / harness health | `bash test/integration/harness_release_gate.sh` |

- `scripts/quality_gate.sh` は補助 gate であり、authoritative release gate ではない。

## auto_orchestrate.sh - 完全自動化オーケストレーター

ClaudeCode（Coder）と Codex（Reviewer）を連携させる**実行エンジン**。
workflow 自体の owner は skill 側で、`auto_orchestrate.sh` は review/fix loop や state 管理を実行する。

### 基本的な使い方

```bash
# 1) 作業ブランチとプラン作成
./scripts/hydra new feat-foo

# 2) テストフェーズ（完全自動）
./.claude/commands/auto_orchestrate.sh \
  --plan .agent/active/plan_YYYYMMDD_HHMM_feat-foo.md \
  --phase test \
  --run-coder \
  --gate levelB

# 3) 実装フェーズ
./.claude/commands/auto_orchestrate.sh \
  --plan .agent/active/plan_YYYYMMDD_HHMM_feat-foo.md \
  --phase impl \
  --run-coder \
  --gate levelB
```

### オプション一覧

| オプション | 説明 |
|-----------|------|
| `--plan PATH` | プランファイルのパス（必須） |
| `--phase PHASE` | フェーズ名: test, impl など（必須） |
| `--run-coder` | ClaudeCode CLIでCoderを自動起動 |
| `--reviewers LIST` | レビュワー一覧（デフォルト: safety,perf,consistency） |
| `--coder-output FILE` | Coder出力ファイル（手動で用意する場合） |
| `--gate levelA\|B\|C` | 品質ゲートのレベル |
| `--max-iterations N` | レビュー反復の最大回数（デフォルト: 5） |

### 動作フロー

1. `auto-orchestrator` が pre-flight classification を行い、workflow owner skill を選ぶ
2. `--run-coder` 指定時: ClaudeCode CLI でフェーズ別プロンプトを実行
3. `review-workflow` の方針に従って Codex レビューを並列実行
4. `[High]` 指摘がある限り修正→再レビューを反復（最大 5 回）
5. `--gate` 指定時: `scripts/quality_gate.sh` を補助 gate として実行

注意:
- `--gate` は phase-local quality gate であり、release acceptance を確定しない。
- authoritative release gate は `bash test/integration/harness_release_gate.sh`。
- acceptance は `docs/manual/verification-truth-matrix.md` に沿って、surface ごとの required checks と evidence が揃ったときだけ成立する。

### 必要な CLI

- `claude` (Claude Code CLI) - `--run-coder` 使用時
- `codex` (Codex CLI) - レビュー実行時

### 入出力ファイル

- 入力: `.agent/active/plan_*.md`
- 出力: `.claude/tmp/<task>/<phase>_*.md`
- slice 固有の verification / checkpoint: `.agent/active/plan_*.md` / `.agent/active/sow/*.md`

## claude-wrapper.sh - Claude 外部委譲ラッパー

`scripts/claude-wrapper.sh` は、Claude から Claude を外部委譲するときの共通入口です。

- 固定値:
  - `--print`
  - `--permission-mode bypassPermissions`
- 既定値:
  - `--model opus`
  - `--effort medium`
- 用途:
  - Claude/Codex のどちらからでも、ファイルベースで Claude へ本文生成を委譲する
  - `session.sh` からの Claude 実行を一箇所に集約する
- ガード:
  - `--permission-mode` の上書きは space form / equals form の両方でブロックされ、flag は strip される
  - `--dangerously-skip-permissions` / `--allow-dangerously-skip-permissions` は space form / equals form を問わず許可せず、flag は strip される
  - `session.sh` は canonical `scripts/claude-wrapper.sh` を使う。`CLAUDE_WRAPPER` の caller-controlled override はサポートせず、canonical path 以外は fail-closed で拒否する
  - `[外部委譲モード]` 付き実行では `CLAUDE.md` の「外部委譲出力ルール」に従う

基本形:
```bash
./scripts/claude-wrapper.sh --output /tmp/out.md "prompt"
./scripts/claude-wrapper.sh --input prompt.md --output /tmp/out.md
./scripts/claude-wrapper.sh --manual-session --resume <session_id> --output /tmp/out.md "follow-up"
```

## codex CLI 呼び出しガイド（オーケストレーター向け）

**重要:** Codex CLI は必ず `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>` 経由で呼び出すこと。
legacy `medium/high/xhigh` wrapper は移行互換 shim であり、source of truth ではない。

基本形（標準入力でプロンプトを渡す）:
```bash
# Coder（実装）用
cat PROMPT.md PAYLOAD.md \
  | ./scripts/codex-wrapper.sh --role coder --stdin \
  > /tmp/output.md

# Reviewer（レビュー）用
cat PROMPT.md PAYLOAD.md \
  | ./scripts/codex-wrapper.sh --role reviewer --stdin \
  > /tmp/output.md
```

ポイント
- **モデル・reasoning effort・search はラッパーで強制固定** (`gpt-5.5` + role allowlist)。`-c model=...` や `-c model_reasoning_effort=...` は自動的にブロックされる。
- caller-facing role map は `standard -> medium/cached`, `research -> high/live`, `coder -> medium/cached`, `high-coder -> high/cached`, `reviewer -> xhigh/cached`。
- caller-facing な role は explicit `--role` で渡す。`CODEX_WRAPPER_ROLE` / `AGENT_ROLE` は互換フォールバックであり、呼び出し契約としては使わない。
- Reviewer は `--role reviewer` 固定で、legacy shim は互換入口としてのみ使う。
- role 未指定時の既定は `standard`。
- Claude 側の effort 既定値は `medium`。caller-facing effort は `low|medium|high|xhigh` のみ許可し、`max` は使わない。
- **sandbox / 承認ポリシーもラッパーで固定** (`workspace-write` + `approval_policy=never`)。
- **入力ガード**: canonical wrapper が無い、role 解決に失敗した、または shim 固定 role に対する role escape が検出された場合は停止し、direct `codex exec` にフォールバックしない。
- `--cd` / `--add-dir` は受け付けず、警告して strip したうえで固定 sandbox 契約のまま実行する。
- **`-c` オプションは原則禁止**。Wrapper が必要な設定を自動適用するため、追加のオプション指定は不要。
- 入力は必ず `--stdin` で渡す（ファイル名を渡してもコンテキストにならないため）。
- 出力は Markdown で保存し、オーケストレーターが次のエージェントに渡せるパスを明示する。
- エラー時は終了コードをそのまま拾い、上位で再実行する（リトライ回数はオーケストレーター側で制御）。
- native Codex multi-agent / subagent orchestration は wrapper 契約の外にあり、wrapper recursion や hidden direct `codex exec` fallback を作らない。
