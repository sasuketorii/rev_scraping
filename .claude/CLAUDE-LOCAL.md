# Claude Local Contract

This file is the Claude orchestrator-specific operational contract for RevHarness.
It is NOT auto-read by Cursor CLI. Read this only when operating as a Claude Code
orchestrator, including top-level Claude Code sessions and `auto_orchestrate.sh`
flows. Root `CLAUDE.md` is intentionally vendor-neutral because Cursor CLI also
auto-reads it. Keep Claude-specific wrapper, role-switching, orchestration state,
and delegation rules in this file rather than the root bootstrap.

# Primary Directive
- Think in English, interact with the user in Japanese.

# Orchestrator Hard Rules（CRITICAL / MUST FOLLOW）

Orchestrator（統括担当）として動作する場合の**絶対遵守ルール**。

## 実装・編集の禁止
- **コード編集禁止**: `src/`、`test/` 配下のファイルを Edit/Write しない
- **ドキュメント編集禁止**: `docs/` 配下のファイルを Edit/Write しない
- **基盤ファイル変更禁止**: `.agent_rules/`、`.claude/commands/`、`.codex/` を変更しない
- **許可パス以外の書き込み禁止**: 上記「許可される操作」に明記したパス以外への Edit/Write は禁止

## 許可される操作
- **読み取り**: 全ファイルの Read は許可
- **オーケストレーション成果物の作成**:
  - `.agent/active/plan_*.md`（ExecPlan）
  - `.agent/active/prompts/**`（依頼プロンプト）
  - `.agent/active/sow/**`（SOW）
  - `.claude/tmp/**`（state.json 等）
  - `.agent/archive/**`（完了時のアーカイブ移動）
- **委譲実装ワークスペース**: Opus / Claude Code の実装担当へ Write/Edit を許可する場合、実装対象は `.claude/tmp/**` ではなく `workspace/<task>/**` の disposable workspace を明示する。`.claude/tmp/**` は prompt / packet / lease / report などの orchestration artifact 専用とする。`scripts/claude-wrapper.sh` 経由の実装 worker には `--implementation-workspace workspace/<task>` を渡す。

## Codex 呼び出しルール
- **wrapper 経由必須**: `codex exec` を直接呼ばず、必ず専用 wrapper 経由
  - **Canonical:** `./scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>`
  - **互換 shim:** `medium.sh -> standard`, `high.sh -> high-coder`, `xhigh.sh -> reviewer`
  - caller-facing な role は `--role` で明示する。`CODEX_WRAPPER_ROLE` / `AGENT_ROLE` は `--role` 省略時の互換フォールバック
  - Reviewer は `./scripts/codex-wrapper.sh --role reviewer` 固定で、互換 shim から別 role へ逃がさない
- **オプション指定禁止**: `-c model=...`、`-c model_reasoning_effort=...` を付与しない
- **入力ガード**:
  - canonical wrapper が無い、role 解決に失敗した、または shim 固定 role に対する role escape が検出された場合は fail-closed で停止する
  - `--cd` / `--add-dir` は警告して strip し、固定 sandbox 契約のまま実行する
  - `codex exec` へ直接フォールバックしない
- **自動化での session continuation 禁止**: `codex resume` や `--continue-session` / `--fork-session` のような継続系フラグはオーケストレーター経由の自動化フローで実行しない
  - **理由**: normal harness flow は non-interactive invariant を前提とし、継続系フラグは TTY/手動回復に閉じ込める
  - **代替手段**: 新規セッションで前回の結果をプロンプトに含めて再実行する

## Acceptance And Truth Read Order
- wrapper 契約は runtime entrypoint 契約であり、acceptance / LGTM 契約ではない
- acceptance / LGTM / completion は `docs/manual/verification-truth-matrix.md` に定義された deterministic checks を満たした時だけ成立する
- required deterministic checks の欠落は fail-closed とし、acceptance / completion は `BLOCK` 扱いにする
- required deterministic checks が未実行、結果未記録、または artifact path 不明のまま、ユーザー向けに「完了」「確認済み」「LGTM」を報告してはならない
- LGTM の有効性は role scope、deterministic checks の結果、artifact traceability がそろった時だけ成立する

acceptance 判断時の truth read order:

1. ユーザー指示と現在の scope
2. 対応 role の定義（`docs/roles/*.md`）
3. `docs/manual/verification-truth-matrix.md`
4. wrapper / entrypoint 契約（runtime truth のみ）

## Slice-First And Completion Gate
- broad task は coder / reviewer に渡す前に narrow slice へ分解する。未分解の broad task をそのまま委譲しない
- ユーザー向け completion report、acceptance、LGTM は required deterministic checks と evidence がそろうまで出してはならない
- required checks が未実行、結果未記録、または artifact path 不明なら fail-closed とし、完了扱いにしない

## 役割変更ルール
- **明示宣言必須**: 役割変更時は「役割を X → Y に変更します」と宣言してから切替
- **曖昧指示への対応**: 確認質問を挟み、現ロール維持が原則

## 委譲の原則
- **全ての実作業を委譲**: 実装・レビューは以下の手段で委譲
  - **Task ツール（Claude Code 内蔵）**: サブエージェントを起動して委譲
  - **auto_orchestrate.sh**: `./.claude/commands/auto_orchestrate.sh` で自動化フロー実行
  - **依頼プロンプト**: `.agent/active/prompts/` に依頼内容を記載
- **Task 起動時の AGENT_ROLE 明示**: `AGENT_ROLE=coder` 等をプロンプトに記載

## 並列Codex時のコンフリクト管理
- **単一Codex実行時:** ユーザー許可があればメインで作業可、Worktree不要
- **並列Codex実行時:** コンフリクトリスクがある場合は、オーケストレーターの責任でWorktreeを切る指示を出すこと
  - 同一ファイル/ディレクトリへの変更が予想される場合 → Worktree分離必須
  - 独立した機能の並列開発 → メインで作業可
- **判断基準:** コンフリクトリスクの有無はオーケストレーターが判断し、必要に応じてWorktree切り替えを指示

## サブエージェントへのプロンプト明記ルール（CRITICAL）
ユーザーがメインブランチでの作業を許可した場合、**サブエージェント（Codex/Claude Coder等）へのプロンプトに必ず以下を明記すること**：

- **許可の伝達必須:** 「メインで作業可」「Worktree不要」「現在のブランチで直接作業してください」等をプロンプト冒頭に記載
- **記載例:**
  ```
  ## 許可事項
  ユーザーからの明示的許可: メインブランチで作業してOKです。Worktree/ブランチを切る必要はありません。
  ```
- **理由:** サブエージェントはRULES.mdを読み込むが、ユーザー許可の有無はプロンプト経由でしか伝わらない
- **省略禁止:** この明記を省略すると、サブエージェントはデフォルト動作（Worktree作成）を実行する可能性がある

# Agent Configuration

このファイルは、**Claude CLI**の行動を規定する設定ファイルです。
以下の共通ルールファイルは、**本ファイルと同等の権限を持ち、絶対的な遵守が求められる不可分の一部**として読み込んでください。

- **共通ルール:** `.agent_rules/RULES.md` (CRITICAL / MUST FOLLOW)
- **役割定義:** `.agent_rules/RULES.md#13` → `docs/roles/*.md`
- **プロジェクトコンテキスト:** `.agent/PROJECT_CONTEXT.md` (プロジェクト固有設定)
- **Acceptance / Truth Matrix:** `docs/manual/verification-truth-matrix.md`

上記共通ルールと本ファイルの内容を統合し、ユーザーの指示を実行してください。

---

# 外部委譲出力ルール

以下のルールは、`scripts/claude-wrapper.sh` 経由で Claude が非インタラクティブ委譲された場合に適用される。
wrapper はプロンプト先頭に `[外部委譲モード]` を自動付与するため、その場合はこのセクションに**厳密に従うこと**。

## 出力形式
- **テキスト直出力のみ**: 回答は stdout に直接出力する
- **ファイル書き込み禁止**: Write/Edit でファイルを作成・編集しない
- **コンテンツのみ**: 前置き・後書き・感想・進捗報告を混ぜない

## トーン・文体
- **丁寧語（です/ます調）**: 委譲先 Claude の本文は丁寧語で統一する
- **過剰演出禁止**: 絵文字・煽り・雑談・不要な導入を入れない

## フォーマット
- **GFM 準拠**: Markdown は GitHub Flavored Markdown を使う
- **ATX 見出し**: 見出しは `#` 形式を使う

## 許可ツール
- **Read / Glob / Grep**: 入力データと参照情報の読取のみ

## 禁止ツール
- **Write / Edit**: ファイル変更
- **Bash**: シェル実行
- **WebFetch / WebSearch**: 外部通信

## 禁止事項
- **完了報告禁止**: 「できました」「保存しました」などの報告文を出力しない
- **脱線禁止**: 依頼内容と無関係な話題を混ぜない

## 目的
- wrapper 呼び出し時は「別の Claude へ本文生成だけを委譲する」用途を優先する
- 実ファイル変更が必要な Claude 実行は、通常どおり `session.sh` / `auto_orchestrate.sh` 経由で行う

---

# このファイルの範囲

| 含まれる内容 | 参照先 |
|------------|-------|
| Claude CLI設定・構成 | 本ファイル |
| Skills/Hooks/Commands | 本ファイル |
| セッション管理・state.json | 本ファイル |
| **役割（Coder/Reviewer/Orchestrator）** | → `RULES.md#13` + `docs/roles/*.md` |
| **開発プロセス（Phase 0-5）** | → `RULES.md#2` |

---

# エージェント自動化フレームワーク

## 概要

Revharness は、複数のエージェント（Claude/Codex等）を連携させ、
フェーズ単位（test→impl→review→fix）で自動反復開発を実現する
**エージェント駆動開発基盤**です。canonical machine name は `rev_harness` です。`agent_base` / `agent-base` は legacy alias として扱います。

**役割とエージェントの対応（要約）:**
| 役割 | エージェント | 推論努力 | Wrapper |
|-----|------------|---------|---------|
| Coder | Claude/Codex両方可 | Claude は既定 `medium`、Codex は role で解決 | `codex-wrapper.sh --role standard|research|coder|high-coder` |
| Reviewer | **Codex 固定** | `reviewer` (`xhigh` + `cached`) | `codex-wrapper.sh --role reviewer` |
| Orchestrator | **dual-native** | Claude top-level は Claude-native、Codex top-level は Codex-native。既定 `medium`。caller-facing effort は `low|medium|high|xhigh` のみ許可し、`max` は使わない | same-family native delegation は wrapper 再帰起動禁止 |

詳細な source of truth は `scripts/codex-wrapper.sh` と `RULES.md#13` を参照

補足:
- wrapper が source of truth なのは caller-facing runtime 設定だけである
- acceptance と LGTM の source of truth は deterministic verification 側にあり、wrapper 設定では代替できない

**Addendum (2026-06-15 Agent SDK billing 分離):**
- 2026-06-15 以降、`claude --print` / Claude Agent SDK 経由の非対話実行は Max サブスク対話枠ではなく **Agent SDK monthly credit** (Pro $20 / Max5x $100 / Max20x $200、非ロールオーバー、超過は標準 API 従量) から課金される。
- **Default 構成:** Claude Code を top-level、cross-family は `scripts/codex-wrapper.sh` 経由で Codex を呼ぶ (Agent SDK credit を消費しない)。
- **Codex top-level からの Claude cross-family 委譲 (`scripts/claude-wrapper.sh`) は default flow から除外し、実行禁止**。Codex を top-level に置く開発フローでは Claude へ自動委譲しない。
- 例外: opt-in かつ Budget Guard 必須 (詳細は `docs/agent-sdk-policy.md`)。
- pty/expect 等で Agent SDK 課金経路を対話枠に擬似化する回避は禁止。

```
  ┌────────────────┐                     ┌────────────────┐
  │    Claude      │ ──────実装────────► │     Codex      │
  │  (Anthropic)   │                     │    (OpenAI)    │
  │                │ ◄────レビュー────── │                │
  └────────────────┘                     └────────────────┘
         │                                       │
         └───────────────────────────────────────┘
                           │
                           ▼
                  ┌────────────────┐
                  │  品質保証済み   │
                  │    コード      │
                  └────────────────┘
```

---

## フォルダ構成

### エージェント駆動開発の中核: `.agent/`

```
.agent/
├── requirements.md          # 要件定義書（ユーザー投下）
├── PROJECT_CONTEXT.md       # プロジェクト固有コンテキスト
│
├── active/                  # 現在進行中のタスク
│   ├── plan_YYYYMMDD_*.md   # ExecPlan（実装中）
│   ├── sow/                 # セッション別SOW
│   └── prompts/             # ハンドオーバー/レビュー用
│
└── archive/                 # 完了した作業
    ├── plans/               # 完了したプラン
    ├── sow/                 # 完了したSOW
    ├── prompts/             # 完了したハンドオーバー
    ├── feedback/            # 過去のレビューフィードバック
    ├── test/                # アーカイブされたテスト
    └── docs/                # アーカイブされたドキュメント
```

### Claude CLI 設定: `.claude/`

```
.claude/
├── settings.json            # Hook設定
├── commands/
│   ├── auto_orchestrate.sh  # メインオーケストレーター
│   ├── README.md            # コマンド使用ガイド
│   └── lib/                 # 共有ライブラリ
├── hooks/
│   └── codex-review-hook.sh # PostToolUseフック
├── skills/
│   ├── auto-orchestrator/   # Phase 2 router skill
│   ├── codex-caller/        # Codex 呼び出し契約
│   ├── review-workflow/     # review/fix loop
│   ├── research-handoff/    # 外部調査の handoff
│   └── system-planner/      # planning workflow
└── tmp/                     # 一時ファイル
```

---

## Skills マッピング

Phase 2 では、再利用可能 workflow の owner は skill 側に置く。command は execution surface に留める。

| Skill | 説明 | 実装パス |
|-------|------|---------|
| **auto-orchestrator** | workflow owner skill へ振り分ける薄い router | `.claude/skills/auto-orchestrator/SKILL.md` |
| **codex-caller** | canonical wrapper 契約で Codex を呼ぶ | `.claude/skills/codex-caller/SKILL.md` |
| **review-workflow** | review/fix loop の reusable workflow owner | `.claude/skills/review-workflow/SKILL.md` |
| **research-handoff** | 外部調査と handoff の reusable workflow owner | `.claude/skills/research-handoff/SKILL.md` |
| **system-planner** | planning と plan handoff の reusable workflow owner | `.claude/skills/system-planner/SKILL.md` |

### auto-orchestrator の呼び出し

```bash
# 標準実行
./.claude/commands/auto_orchestrate.sh \
  --plan .agent/active/plan_*.md \
  --phase impl \
  --run-coder \
  --fix-until high

# orchestration state の再開
./.claude/commands/auto_orchestrate.sh \
  --resume .claude/tmp/task/state.json
```

---

## Command Library

### メインコマンド: `auto_orchestrate.sh`

**用途:** Phase ごとの自動反復（test→impl→review→fix）

**基本オプション:**

| オプション | 必須 | 説明 |
|-----------|------|------|
| `--plan PATH` | 新規時 | プランファイルのパス |
| `--phase PHASE` | 新規時 | フェーズ名（test, impl等） |
| `--resume STATE_FILE` | 再開時 | orchestration state.json へのパス |
| `--run-coder` | 任意 | Claude Code で Coder を自動起動 |
| `--continue-session` | 任意 | 予約済み。non-interactive invariant により fail-closed |
| `--fork-session` | 任意 | 予約済み。non-interactive invariant により fail-closed |
| `--fix-until LEVEL` | 任意 | 修正対象レベル（high/medium/low/all） |
| `--max-iterations N` | 任意 | レビュー反復回数（デフォルト: 5） |
| `--reviewers LIST` | 任意 | レビュワー一覧（デフォルト: safety,perf,consistency） |
| `--reviewer-strategy MODE` | 任意 | fixed / auto（動的選択） |
| `--agent-strategy MODE` | 任意 | fixed / dynamic（複数Coder） |
| `--gate levelA\|B\|C` | 任意 | 品質ゲートレベル |
| `--codex-timeout SECS` | 任意 | Codex タイムアウト（デフォルト: 7200） |
| `--claude-timeout SECS` | 任意 | Claude タイムアウト（デフォルト: 1800） |
| `--recover` | 任意 | stale state をリカバリ |
| `--status` | 任意 | 状態サマリーを表示 |

### ライブラリ関数（lib/）

#### utils.sh - ユーティリティ関数

```bash
# ログ出力
log_info "message"       # [INFO] メッセージ
log_warn "message"       # [WARN] メッセージ
log_error "message"      # [ERROR] メッセージ
log_success "message"    # [OK] メッセージ
die "message"            # [ERROR] で終了（exit 1）

# タイムスタンプ・UUID
get_timestamp            # ISO8601 形式（UTC）
generate_uuid            # UUID v4 生成

# ファイル操作
ensure_cmd "command"     # コマンド存在確認
ensure_dir "path"        # ディレクトリ作成
ensure_file "path"       # ファイル存在確認

# ロック
lock_acquire "lock_file" [timeout]
lock_release "lock_file"

# セキュリティ検証
_validate_identifier "value" "name"  # 英数字・-・_・. のみ許可
```

#### state.sh - 実行状態管理

```bash
# 初期化・読込・保存
state_init "plan_path" "task_name" [output_dir]
state_load "state_file"
state_save

# 値操作（jq パス検証済み）
state_get ".status"
state_set ".status" '"running"'
state_append ".phases" '{...}'

# フェーズ管理
state_upsert_phase "phase_name" [max_iterations]
state_set_phase_status "phase_name" "status"

# セッション記録
state_record_session "session_id" "phase" "iteration"
state_get_last_session [phase]

# その他
state_show_summary
state_is_stale [threshold_secs]
```

#### coder.sh - Claude CLI 制御

```bash
# セッション管理
coder_run "plan" "phase" "output_file"
coder_resume "session_id" "prompt" "output_file"   # fail-closed（自動経路では禁止）
coder_fork "parent_session_id" "prompt" "output_file"  # fail-closed（自動経路では禁止）

# 修正実行
coder_run_fix "plan" "phase" "reviews" "iteration" "output_file" "session_id"

# ユーティリティ
coder_build_prompt "plan" "phase" "context"
coder_analyze_task_complexity "plan_path"
```

#### reviewer.sh - Codex CLI 制御

```bash
# 並列レビュー
reviewer_run_all "safety,perf,consistency" "coder_output" "task_tmpdir" "phase"

# 動的選択
reviewer_select_dynamic "coder_output"
reviewer_list_available

# セッション管理（※関数は state.sh に定義）
# reviewer_get_session_id "phase" "reviewer_name"
# reviewer_set_session_id "phase" "iteration" "reviewer_name" "session_id"
```

#### session.sh - セッションライフサイクル

```bash
session_start "prompt"
session_resume "session_id" "prompt"   # fail-closed（自動経路では禁止）
session_fork "parent_id" "prompt"      # fail-closed（自動経路では禁止）

_validate_session_id "session_id"  # UUID形式検証
```

`session.sh` の Claude CLI 呼び出しは、現行仕様に合わせて `--effort medium` と `--permission-mode bypassPermissions` を既定で使用する。
また、実行入口は canonical `scripts/claude-wrapper.sh` に集約する。通常の自動フローは `session_start` / `session_run_with_timeout` による新規セッションのみを許可し、`session_resume` / `session_fork` は fail-closed で拒否する。`CLAUDE_WRAPPER` は caller 制御の escape hatch として扱わず、canonical path 以外なら fail-closed で拒否する。
Codex helper 側も canonical `scripts/codex-wrapper.sh --role coder` を通常経路に使い、security-sensitive / 複雑な実装では `--role high-coder` を使う契約とする。legacy `codex-wrapper-high.sh` は `high-coder` への互換 shim に限定する。
wrapper は `--permission-mode` / `--permission-mode=...` の上書きと `--dangerously-skip-permissions` / `--allow-dangerously-skip-permissions` の space form・equals form を警告して strip し、固定 `bypassPermissions` で続行する。

#### Claude `--bare` 認証ガード

Root cause: `claude -p --bare ...` は Claude.ai OAuth/keychain login を読まず、API key または `apiKeyHelper` が必要になる。そのため、OAuth/keychain 認証で非対話の Claude/Opus review を走らせる場合、`--bare` を既定にしてはならない。

- OAuth/keychain 認証の非対話 review では `--bare` を省く。
- `--bare` は `ANTHROPIC_API_KEY` または明示的な `apiKeyHelper` 設定がある場合だけ許可する。
- `--bare` を使う caller は、必要な context/config をすべて自分で供給する責任を持つ。
- `scripts/claude-wrapper.sh` は `--bare` を受け取った場合、API-key auth が確認できなければ fail-closed にする。

安全な直接実行例:

```bash
claude -p \
  --model opus \
  --no-session-persistence \
  --allowed-tools Read,Grep,Glob \
  --permission-mode dontAsk \
  --max-budget-usd 5 \
  < review_prompt.md > opus_review.md
```

#### timeout.sh - タイムアウト管理

```bash
timeout_run "secs" "command" [args...]
```

---

## Hooks 設定

**依存関係:** caller-facing hook ingress は `./.claude/hooks/codex-review-hook.sh` のまま維持し、内部では Rust の `hook-review-queue hook review-queue` に委譲します。public な queue ingress / adapter は引き続き `scripts/semantic-review-queue.sh` のままとし、その背後の durable queue authority は repo-local semantic-mcp backend（Rust 優先 / Node 互換）に委譲します。
- hard dependency: trusted runtime dir allowlist 上の先頭候補から、`cargo` を authoritative に解決できること（trusted direct binary または rustup/mise が report する concrete executable 経由）。built-in allowlist は real-user canonical home を trust root として固定し、caller-overridden な `HOME` では widen しない。trusted roots には `/usr/bin`、`/bin`、`/usr/local/bin`、`/opt/homebrew/bin`、`<real-user-canonical-home>/.cargo/bin`、`<real-user-canonical-home>/.rustup/toolchains/*/bin`、`<real-user-canonical-home>/.local/bin`、`<real-user-canonical-home>/.local/share/mise/{shims,installs/*/*/bin}`、`<real-user-canonical-home>/.mise/{shims,installs/*/*/bin}` を含む。canonical path matching を用い、symlink 済み trusted dir と symlink binary は reject し、public env から trusted runtime dir を追加して widen してはならない
- hard dependency: repo-local Rust workspace `harness-rust/Cargo.toml` と `hook-review-queue` build 対象 / binary が存在すること
- fail-closed: 上記依存が欠ける、trusted cargo resolution 経由の `hook-review-queue` build target / binary の解決または build が失敗する、allowlist 外の absolute prefix しか無い、shim-only runtime しか見つからない、manager lookup が concrete executable を返さない、manager が allowlist 外の binary を返す、空/相対/current-dir 由来の PATH entry しか候補にならない、symlink 済み trusted dir または symlink binary しか一致しない、enqueue-eligible な repo-local allowlist file が authoritative helper path で project_id 解決に到達した時に malformed・CR byte を含む control-byte・multiline の `.shared/project_id` が reject される、または entrypoint の実行ビットが欠ける場合、hook は非ゼロ終了する

### PostToolUse フック

**設定:** `.claude/settings.json`

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "./.claude/hooks/codex-review-hook.sh"
          }
        ]
      }
    ]
  }
}
```

**動作:** Edit/Write ツール使用後、hook ingress は Rust で repo-relative 正規化・repo 外 skip・拡張子 allowlist を判定し、その後 caller-facing shell adapter `scripts/semantic-review-queue.sh enqueue` へ委譲する。public 契約としてサポートする queue ingress は実行ビット付きの `./scripts/semantic-review-queue.sh ...` で、absolute shebang から起動する。`bash scripts/semantic-review-queue.sh ...` のような明示 interpreter override は shebang hardening を迂回するため public contract ではない。queue ingress / hook ingress は unsafe runtime resolution を検出した時点で fail-closed とする。shell は `harness-rust/` workspace、`harness-rust/Cargo.toml`、`harness-rust/crates/semantic-mcp/src/main.rs` の 3 path が存在し、かつ各 path が repo-local real-path validation を通る場合に限って repo-local semantic-mcp backend の Rust CLI を優先する。manifest 不在に限らず、この 3 path のいずれかが欠ける場合や、これらの path が symlink component を含む、または repo 外へ解決されるため repo-local real-path validation を通らない場合は Node compatibility surface へ fallback する。fallback 側でも `scripts/semantic-mcp-server/dist/cli.js` が repo-local real file でなければ fail-closed とする。runtime 解決は空 PATH 要素、`.`、相対 PATH entry を候補に含めず、built-in の trusted runtime dir allowlist 上で canonical path matching により最初に見つかった実行候補だけを対象にする。trusted runtime dir allowlist の trust root は real-user canonical home に固定し、caller-overridden な `HOME` では widen しない。symlink 済み trusted dir と symlink binary は reject する。`$HOME/.local/bin/<bin>` と mise path は real-user canonical home trust root 配下にある場合だけ trusted とし、temp/fixture `HOME` は trusted root を広げない。shim 扱いは manager-owned path（`<real-user-canonical-home>/.local/share/mise/shims/<bin>`、`<real-user-canonical-home>/.mise/shims/<bin>`、`<real-user-canonical-home>/.cargo/bin/cargo`）に限定する。先頭候補が rustup/mise shim の場合は manager-authoritative lookup（`rustup which cargo` / `mise which <bin>`）で active に選択された concrete executable を引き、install/toolchain の走査で別バージョンを推測しない。hook は bare `command -v cargo` / bare `cargo build` を使わず、trusted cargo resolution を用いる。lookup に失敗する、shim/proxy しか返せない、または manager が allowlist 外の binary を返す先頭候補は後続 PATH へ逃がさず fail-closed とする。さらに、enqueue-eligible な repo-local allowlist file が authoritative helper path で project_id 解決に到達した際に、malformed / control-byte（CR byte 含む） / multiline な `.shared/project_id` を reject した場合も fail-closed とする。poison-PATH behavior の主張は focused repro に裏付けられた範囲に限る。`.claude/tmp/review_queue.json` への compatibility export も authority には昇格させない

---

## 状態管理（state.json）

**ファイル:** `.claude/tmp/<task_name>/state.json`

**スキーマ概要:**

```json
{
  "version": "1.0.0",
  "task": {
    "id": "uuid",
    "name": "task_name",
    "plan_path": "path/to/plan.md"
  },
  "status": "running|completed|error",
  "phases": [
    {
      "name": "impl",
      "status": "pending|running|review|fixing|completed|escalated",
      "iteration": 1,
      "max_iterations": 5,
      "coder": { "session_id": "...", "output_file": "..." },
      "reviews": [...],
      "fixes": [...]
    }
  ],
  "sessions": { "coder_sessions": [], "reviewer_sessions": [] },
  "quality_gate": { "level": "levelB", "status": "passed|failed" },
  "heartbeat": { "last_updated": "...", "pid": 12345 },
  "error": null
}
```

**用途:**
- 中断→再開時のコンテキスト復元
- Phase ステータス追跡
- セッションID記録
- エラー/エスカレーション情報保存

---

## ワークフロー例

### 標準フロー（全自動）

```bash
# 1. 要件を .agent/requirements.md に記載

# 2. プラン作成
# エージェントが .agent/active/plan_YYYYMMDD_feat-foo.md を生成

# 3. テストフェーズ
./.claude/commands/auto_orchestrate.sh \
  --plan .agent/active/plan_YYYYMMDD_feat-foo.md \
  --phase test \
  --run-coder \
  --gate levelB

# 4. 実装フェーズ
./.claude/commands/auto_orchestrate.sh \
  --plan .agent/active/plan_YYYYMMDD_feat-foo.md \
  --phase impl \
  --run-coder \
  --gate levelB
```

### 中断・再開フロー

```bash
# 前回の state.json から orchestration を再開
./.claude/commands/auto_orchestrate.sh \
  --resume .claude/tmp/feat-foo/state.json

# stale state をリカバリ
./.claude/commands/auto_orchestrate.sh \
  --resume .claude/tmp/feat-foo/state.json \
  --recover

# 状態確認
./.claude/commands/auto_orchestrate.sh \
  --resume .claude/tmp/feat-foo/state.json \
  --status
```

`--continue-session` / `--fork-session` は non-interactive invariant により自動経路では拒否されます。必要なら前回の文脈を新規プロンプトへ明示的に引き継いでください。

---

## セキュリティ

### 入力検証

- **識別子検証:** `_validate_identifier()` で全入力をチェック
- **jq パス検証:** `_validate_jq_path()` で JSON操作を検証
- **セッション検証:** UUID形式のセッションIDのみ許可

### 保護対象

| 脅威 | 対策 | 実装箇所 |
|-----|------|---------|
| コマンドインジェクション | printf '%s' でのエスケープ | session.sh |
| 引数インジェクション | `--` 引数終端子 | session.sh |
| パストラバーサル | ホワイトリスト検証 | reviewer.sh |
| セッションID偽装 | UUID形式検証 | session.sh |
| 環境変数インジェクション | effort 値のホワイトリスト検証 | session.sh |
| レースコンディション | mkdir ベースロック | auto_orchestrate.sh |
| jq パスインジェクション | ホワイトリストパターン | state.sh |

---

## トラブルシューティング

### Q1. 実行が stale state で止まる

```bash
./.claude/commands/auto_orchestrate.sh \
  --resume .claude/tmp/task/state.json \
  --recover
```

### Q2. 指摘が解消されない（max-iterations 到達）

→ エスカレーションレポートが `.claude/tmp/task/escalation_report_*.md` に生成
→ 手動レビューが必要

### Q3. 前回の state から再開したい

```bash
./.claude/commands/auto_orchestrate.sh \
  --resume .claude/tmp/task/state.json
```

agent session 自体の continue / fork は自動経路では禁止です。前回成果物を新規プロンプトへ引き継いでください。

### Q4. レビュワーを追加したい

```bash
# カスタムレビュワープロンプトを作成
# docs/prompts/ にレビュワープロンプトを追加後

./.claude/commands/auto_orchestrate.sh \
  --plan .agent/active/plan_*.md \
  --phase impl \
  --run-coder \
  --reviewers safety,perf,my_custom_reviewer
```

---

## 関連ドキュメント

| ドキュメント | パス | 説明 |
|------------|------|------|
| 共通ルール | `.agent_rules/RULES.md` | 全エージェント共通ルール |
| プロジェクトコンテキスト | `.agent/PROJECT_CONTEXT.md` | プロジェクト固有設定 |
| Acceptance / Truth Matrix | `docs/manual/verification-truth-matrix.md` | deterministic checks と truth placement の正本 |
| 要件定義書 | `.agent/requirements.md` | ユーザー要件の入り口 |
| Skills | `.claude/skills/` | reusable workflow owner 一覧 |
| コマンドガイド | `.claude/commands/README.md` | コマンド使用法詳細 |
| Codex設定 | `.codex/config.toml` | Codex CLI設定 |
| セットアップ | `setup/setup_rules.md` | セットアップ手順 |

---

## 追加運用規約（Task 6.2 / Semantic Coordination）

以下は既存ルールへの追記。矛盾時は本節を優先する。

### 4層コンテキスト最適化モデル（運用要約）

- **Layer 0 / Ground Truth**: repo core policy、`.shared/project_id`、placement v2 `Revharness/semantic-mcp/v1/{project_id}/semantic.db` / authoritative registry
- **Layer 1 / Pre-flight**: scope/conflict/lock、diff影響分析、graph rank / Top-K選定。`.agent/context/**` や JSONL export は derived analysis 用の export / cache / debug artifact として扱う
- **Layer 2 / Prompt Capsule**: 200tok本体 + 20tokメタ（合計220tok上限、fail-closed）
- **Layer 3 / Execution Feedback**: Shadow Verify（機械検証）+ review/fix loop（論理レビュー）

### Shadow Verify 運用（QG-1 / QG-2）

- 実行順は `Coder -> Shadow Verify -> Reviewer`。Shadow Verify未通過でReviewerへ進まない。
- **QG-1**: `quality_gate.status in {failed, skipped}` は fail-closed で即失敗。
- **QG-2**: 言語別必須コマンド（`pnpm|npm`, `cargo`, `pytest` 等）不足時は fail-closed で即失敗。
- Shadow Verify失敗時は修正ループに戻し、**3回失敗でエスカレーション**する。

### カプセル生成ルール（fail-closed）

- カプセル上限は **220tok**（本体200 + メタ/JSON 20）。
- 220tok超過時は `BLOCK` を返し、過長カプセルを受理しない。
- `sem.capsule` は caller 提供の `top_k_symbols` を受理しない。`sem.context.top_k` が発行した `context_token` を必須入力とし、token は 30 分 TTL とする。
- capsule body は `TOPK_SHA256=` 直後に `INDEX_VERSION=<u64>` と `FILE_SHA_ROLLUP=<sha256>` を含める。`INDEX_VERSION` は情報行であり `CAPSULE_SHA256` の hash 入力から固定 slot index で除外する。`FILE_SHA_ROLLUP` は hash 入力に含める。
- `sem.capsule` は token 発行時の `file_sha_rollup` と現在の `file_parse_cache.file_hash` 由来 rollup を再比較し、不一致なら fail-closed で `sem.context.top_k` の再発行を要求する。
- `agent-core/cmd/capsule.rs::build_capsule_with_symbols` も `shared::freshness` 経由で `file_sha_rollup` / `index_version` を bind する。`build_capsule` の no-symbols fallback は freshness 無し path として残置し、別 plan で扱う。
- `agent-core` と `semantic-mcp` は freshness invariant を共有するが、`CAPSULE_SHA256` の byte format は同一と主張しない。`INDEX_VERSION` は fixed slot exclusion、`FILE_SHA_ROLLUP` は hash 入力に含める。
- `CAPSULE_SHA256` を保持し、外部参照時も同一ルールで運用する。

### MCP Semantic Server 設定

- semantic MCP の repo-local parity は Claude / Codex の両 CLI で設定済みであり、各 CLI の repo-local 設定から `./scripts/launch-semantic-mcp.sh` を自動起動する。
- Rust semantic-mcp は起動時に semantic schema と tree-sitter-index schema を同一 SQLite DB へ冪等 migration し、`sem.context.top_k` で server-side Top-K / `context_token` を発行する。
- DB placement v2 は `{XDG_DATA_HOME or platform default}/Revharness/semantic-mcp/v1/{project_id}/semantic.db` とする。macOS は `~/Library/Application Support/Revharness/semantic-mcp/v1/{project_id}/semantic.db`、Linux は `${XDG_DATA_HOME:-~/.local/share}/Revharness/semantic-mcp/v1/{project_id}/semantic.db`、Windows は `%LOCALAPPDATA%/Revharness/semantic-mcp/v1/{project_id}/semantic.db`。
- `SEMANTIC_MCP_HOME` は test harness 専用 override であり、`REVHARNESS_TEST_HARNESS=1` と併用された場合だけ通常 build で受理する。通常 runtime では platform data directory を使う。
- source of truth は Claude では `.claude/settings.json`、Codex では `.codex/config.toml` とする。Codex 側だけ別途手動設定する前提は置かない。
- Claude CLI 側は `.claude/settings.json` の `mcpServers.semantic` を使用する。
- Codex CLI 側は `.codex/config.toml` の `mcp_servers.semantic` を使用する。
- 設定例（既定）:

```json
{
  "mcpServers": {
    "semantic": {
      "command": "./scripts/launch-semantic-mcp.sh",
      "env": {}
    }
  }
}
```

- Codex 側の既定 stanza は次のとおり。

```toml
[mcp_servers.semantic]
command = "./scripts/launch-semantic-mcp.sh"
```

- Codex CLI 側は追加の feature flag を前提とせず、repo の `.codex/config.toml` と wrapper 経由で自動利用する。
- 接続確認は `sem.health` を呼び出して行う。
- MCP不通時はCLIフォールバック方針（`context_analysis.sh` / `context_capsule.sh`）を維持する。

### 新コマンド（Semantic/MCP運用）

```bash
# semantic-mcp-server 依存取得
npm --prefix scripts/semantic-mcp-server install

# ビルド
npm --prefix scripts/semantic-mcp-server run build

# 開発起動（stdio）
npm --prefix scripts/semantic-mcp-server run dev -- --project-id demo_project

# 本番相当起動（dist）
npm --prefix scripts/semantic-mcp-server run start -- --project-id demo_project

# 単体テスト
npm --prefix scripts/semantic-mcp-server run test
```

### モデルルーティング（Coder）

- 既定の実装タスク -> `codex-wrapper.sh --role coder`
- 軽量タスク -> `codex-wrapper.sh --role standard`
- 外部調査が本質なタスク -> `codex-wrapper.sh --role research`
- `security-sensitive=true` -> **full-context + `high-coder` (`high` + `cached`)** 強制
- Reviewerは `codex-wrapper.sh --role reviewer` 固定

### `dependency_preflight` / `dependency_policy` 境界（P1）

- semantic-coordinationは `dependency_verdict` を**受理・表示する境界I/Fのみ**を担当する。
- 判定ロジック本体（`dependency_preflight`）と `.agent/registry/dependency_policy.json` の管理は独立ExecPlan（P1）で扱う。
- 境界未接続時でも既存P0フローを停止させない（後方互換維持）。
