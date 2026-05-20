# エージェントレビュー反復ワークフロー（Claude/Codex）

## 目的
本ドキュメントは、**Agent A（Coder）→ Agent B（Reviewer）→ 修正 → 再レビュー**を
**合格（LGTM）するまで反復**する標準ワークフローを、実運用に即して定義する。

Phase 2 では、この reusable workflow の owner は `.claude/skills/review-workflow/SKILL.md`。
`auto-orchestrator` は薄い router としてここへ処理を振り分け、`auto_orchestrate.sh` は実行面を担う。

## 役割と固定ルール
- **Agent A（Coder）:** Claude または Codex（実装担当）
- **Agent B（Reviewer）:** **Codex 固定 / `scripts/codex-wrapper.sh --role reviewer` 固定**
- **Orchestrator:** **dual-native / effort 既定 `medium`**。Claude top-level は Claude-native subagents、Codex top-level は Codex-native subagents を使う。caller-facing effort は `low|medium|high|xhigh` のみ許可し、`max` は使わない。同一 family delegation は wrapper 再帰起動禁止、cross-family は artifact packet と lease closeout を使う

詳細は以下を参照:
- `docs/roles/coder.md`
- `docs/roles/reviewer.md`
- `docs/roles/orchestrator.md`

## 標準フロー（反復ループ）

```
1) Coder (Claude/Codex) が実装
     ↓
2) Codex レビュワー **複数並列** 実行（毎回新規セッション）
   - デフォルト: safety, perf, consistency
   - --reviewers で変更可能
     ↓
3) fix-until 以上の指摘なし + valid reviewer LGTM → pending acceptance
     ↓
4) orchestrator acceptance recheck
   - required evidence / completion boundary / deterministic checks / budget を再確認
     ↓
5) 条件充足 → completed
     ↓
6) 指摘あり or acceptance 不成立:
   - --run-coder 指定時 → Coder が自動修正 → 再レビュー（2 へ戻る）
   - --run-coder なし → paused（手動修正待ち）
     ↓
7) max_iterations 到達 → エスカレーション（人間介入要求）
```

### フロー詳細

| ステップ | 動作 | 次の遷移 |
|---------|------|---------|
| 1. 実装 | Coder が Plan に従って実装 | → 2 |
| 2. レビュー | 複数レビュワーが並列実行、結果集約 | → 3 or 6 |
| 3. reviewer LGTM | valid reviewer LGTM を得る | → 4 |
| 4. acceptance recheck | orchestrator が acceptance gate を再確認 | → 5 or 6 |
| 5. completed | acceptance recheck 充足後にのみ完了 | → 終了 |
| 6a. 自動修正 | `--run-coder` 時、指摘を反映 | → 2 |
| 6b. 手動待ち | `--run-coder` なし、paused 状態 | → 中断 |
| 7. エスカレーション | max_iterations 到達、レポート生成 | → 失敗 |

## 事前準備（必須）
1. **Worktree 作成（原則必須）**  
   `./scripts/hydra new <task-name>`
2. **ExecPlan（複雑タスクのみ）**  
   `.agent/active/plan_YYYYMMDD_HHMM_<task>.md`
   - 新規 plan は `docs/manual/execplan-checklist-standard.md` に従い、`Status Board` と `Slice Board` を含める
   - 初回設計 / ExecPlan drafting / ExecPlan review planning は `.agent/registry/model_policy.json` の `initial_execplan_design` lane として `gpt-5.5` + `xhigh` + `cached` を使う。通常の docs-only / light planning ではない
3. **Codex 実行は必ずラッパー経由**
   - Canonical: `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>`
   - 互換 shim: `medium.sh -> standard`, `high.sh -> high-coder`（historical name）, `xhigh.sh -> reviewer`
   - caller-facing な role は `--role` で明示する。Reviewer は `--role reviewer` 固定で、shim から別 role へ逃がさない
   - review workflow の primary guidance は canonical wrapper。legacy shim は互換レイヤに留める

## 実行ステップ（詳細）

### 1) 実装フェーズ（Agent A）
- 変更実装
- テスト実行（必要な範囲）
- 監査（意地悪な監査員視点）
- SOW 作成: `.agent/active/sow/`

### 2) レビューフェーズ（Agent B）
- **複数の Codex レビュワーが並列実行**
  - デフォルト: `safety`, `perf`, `consistency`
  - `--reviewers` オプションで変更可能
  - `--reviewer-strategy auto` で動的選択（コード内容に応じて最適なレビュワーを選択）
- Reviewer 実行プロファイルは `scripts/codex-wrapper.sh --role reviewer` に固定
- `--cd` / `--add-dir` は wrapper が警告して strip する。reviewer からの role escape は fail-closed で停止する
- **常に新規セッションで実行**（自動運用では `codex resume` を使わず、前回結果はプロンプトに含めて引き継ぐ）
- 出力は `docs/roles/reviewer.md` の `Code Review Report` 形式に準拠
  - 指摘ゼロでも `## Findings` は `- None.`、`## Verdict` は `LGTM`
- 結果は state.json で管理され、重大度別にカウント
  - `[High]`: ブロッカー（必ず修正が必要）
  - `[Medium]`: 推奨修正
  - `[Low]`: 軽微な指摘

### 3) 修正フェーズ（Agent A）
- `--run-coder` 指定時: Coder が自動で指摘内容を反映
- `--run-coder` なし: `paused` 状態となり、手動修正を待機
- 変更点を明確化
- 必要に応じてテスト再実行

### 4) 再レビューフェーズ（Agent B）
- **常に新規セッションで再レビュー**（自動運用では `codex resume` を使わず、前回結果はプロンプトに含めて引き継ぐ）
- 前回レビュー結果はプロンプトに含めてコンテキストを引き継ぐ
- `--fix-until` で指定したレベル以上の指摘がなくなるまで反復
  - `high`: `[High]` のみ修正（デフォルト: `all`）
  - `medium`: `[High]` + `[Medium]` を修正
  - `low` / `all`: すべての指摘を修正

## 状態管理
進捗は `.claude/tmp/<task>/state.json` で管理される。

### ステータス一覧

| status | 意味 | 次のアクション |
|--------|------|---------------|
| `running` | 実行中 | 自動継続 |
| `paused` | 手動修正待ち | 修正後、`--resume` で再開 |
| `completed` | 正常完了 | なし |
| `failed` | 失敗（エスカレーション含む） | レポート確認、手動対応 |
| `interrupted` | 中断（シグナル受信） | `--resume` で再開 |
| `recovered` | リカバリ済み | `--resume` で再開 |

### フェーズステータス

| phase.status | 意味 |
|--------------|------|
| `pending` | 未開始 |
| `running` | Coder 実行中 |
| `review` | レビュー実行中 |
| `fixing` | 修正実行中 |
| `completed` | 完了 |
| `escalated` | エスカレーション済み |
| `failed` | 失敗 |

### state.json 例:
```json
{
  "status": "running",
  "task": {
    "name": "feat-foo",
    "plan_path": ".agent/active/plan_YYYYMMDD_feat-foo.md"
  },
  "phases": [
    {
      "name": "impl",
      "status": "review",
      "iteration": 2,
      "max_iterations": 5,
      "reviews": [
        {
          "iteration": 1,
          "has_blockers": true,
          "severity_counts": {"high": 2, "medium": 3, "low": 1}
        }
      ]
    }
  ]
}
```

## Codex セッション運用ルール
**重要:** 自動運用では `codex resume` を使わず、常に `scripts/codex-wrapper.sh --role reviewer` から新規レビューセッションを開始する。

### 運用ルール
1. **Codex レビュワーは常に新規セッションで実行**
2. **コンテキスト引き継ぎはプロンプト内で明示的に行う**（前回レビュー結果を含める等）
3. **`codex resume` は手動実行（ターミナル直接）でのみ使用可能**
4. **fail-closed:** `scripts/codex-wrapper.sh` が無い、role 解決に失敗した、または reviewer からの role escape が検出された場合はレビュー処理を停止し、CLI 直呼び出しへフォールバックしない
5. **workspace 拡張フラグの扱い:** `--cd` / `--add-dir` はレビュー経路では使わず、渡された場合も wrapper が警告して strip する
6. **session helper の wrapper 固定:** 自動運用の Claude 実行は canonical `scripts/claude-wrapper.sh` に集約し、`CLAUDE_WRAPPER` を caller 制御の escape hatch として扱わない

### Codex / wrapper 不足時の挙動
canonical wrapper が見つからない、または role 解決に失敗した場合は、**wrapper 契約に従って fail-closed で停止**する。

```
[ERROR] codex-wrapper.sh not found
```

`codex` CLI 自体が見つからない場合も reviewer prerequisite failure として扱い、レビュー反復をスキップして続行してはならない。

```
[BLOCK] codex CLI が見つからないため reviewer prerequisite failure
```

このケースでは reviewer evidence が成立しないため、`pending acceptance` / `completed` / `LGTM` を主張してはならない。Codex をインストールするには:
```bash
# Codex CLI のインストール
npm install -g @openai/codex
```

## Claude / Opus Review Auth Guard

補助的に Claude/Opus review を非対話で実行する場合、`claude -p --bare ...` を OAuth/keychain 認証の既定にしない。Root cause は、Claude Code の `--bare` が Claude.ai OAuth/keychain login を読まず、API key または `apiKeyHelper` を要求すること。

OAuth/keychain 認証での安全な直接実行例:

```bash
claude -p \
  --model opus \
  --no-session-persistence \
  --allowed-tools Read,Grep,Glob \
  --permission-mode dontAsk \
  --max-budget-usd 5 \
  < review_prompt.md > opus_review.md
```

`--bare` は `ANTHROPIC_API_KEY` または明示的な `apiKeyHelper` 設定がある場合だけ使う。caller は必要な context/config をすべて供給し、OAuth/keychain を期待する review invocation では `--bare` を省く。`scripts/claude-wrapper.sh` は API-key auth を確認できない `--bare` を fail-closed にする。

## 合格条件（LGTM）
`--fix-until` で指定したレベル以上の指摘がなくなり、reviewer が valid な `LGTM` を返した時点で review loop 合格。

| --fix-until | 合格条件 |
|-------------|---------|
| `high` | `[High]` が 0 件 |
| `medium` | `[High]` + `[Medium]` が 0 件 |
| `low` / `all` | すべての指摘が 0 件（`## Findings` が `- None.`） |

ただし canonical next status は `pending acceptance` であり、`completed` は orchestrator acceptance recheck 後にだけ使える。
指摘が残る場合は **必ず修正 → 再レビュー** に戻る。

## セッション終了条件
**修正と再レビューで valid reviewer LGTM を得て、その後の orchestrator acceptance recheck まで通った時点で初めて completed として閉じる。**
reviewer 未通過、または acceptance recheck 未了の状態では、`completed` として閉じずに反復または holding status を継続する。

例外（やむを得ない中断）:
- タイムアウトや環境障害で継続不能になった場合
- ユーザーが明示的に中断を指示した場合

## エスカレーション条件
以下は Orchestrator がユーザーへ確認・判断を求める条件:

### 自動エスカレーション
- **max_iterations 到達**: デフォルト 5 回、`--max-iterations` で変更可能
  - エスカレーションレポートが自動生成される
  - レポート: `.claude/tmp/<task>/<phase>_escalation_report_<timestamp>.md`

### 手動エスカレーション
- **仕様が曖昧で合意が取れない**
- **技術的に解決不能**
- **構造的/アーキテクチャ上の問題で自動修正不可**

### エスカレーションレポートの内容
```
# Escalation Report

## Quick Summary
| Severity | Count |
|----------|-------|
| [High]   | N     |
| [Medium] | N     |
| [Low]    | N     |

## Context
- Phase: impl
- Iterations Attempted: 5 / 5
- Status: FAILED - Issues remain after maximum iterations

## Remaining Issues
（未解決の指摘一覧）

## Recommendation
Human intervention required.
```

## 成果物（運用で残すもの）
- ExecPlan: `.agent/active/plan_YYYYMMDD_HHMM_<task>.md`
- SOW: `.agent/active/sow/`
- Coder 出力: `.claude/tmp/<task>/<phase>_coder.md`
- 修正出力: `.claude/tmp/<task>/<phase>_coder_fix<N>.md`
- レビュー出力: `.claude/tmp/<task>/<phase>_reviews.md`（集約済み）
- 個別レビュー: `.claude/tmp/<task>/<phase>_review_<reviewer>.md`
- エスカレーションレポート: `.claude/tmp/<task>/<phase>_escalation_report_<timestamp>.md`
- state.json: `.claude/tmp/<task>/state.json`

## コマンドオプション一覧

| オプション | 説明 | デフォルト |
|-----------|------|-----------|
| `--plan PATH` | プランファイルのパス | 必須（新規時） |
| `--phase PHASE` | フェーズ名（test, impl 等） | 必須（新規時） |
| `--resume STATE_FILE` | orchestration state.json から再開 | - |
| `--run-coder` | Coder を自動起動 | false |
| `--reviewers LIST` | レビュワー一覧 | `safety,perf,consistency` |
| `--reviewer-strategy MODE` | `fixed` / `auto` | `fixed` |
| `--fix-until LEVEL` | 修正対象レベル | `all` |
| `--max-iterations N` | 反復上限 | `5` |
| `--gate LEVEL` | 品質ゲート | - |
| `--continue-session` | 予約済み。non-interactive invariant により fail-closed | false |
| `--fork-session` | 予約済み。non-interactive invariant により fail-closed | false |
| `--recover` | stale state リカバリ | false |
| `--status` | 状態サマリー表示 | false |
