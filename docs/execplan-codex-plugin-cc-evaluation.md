# ExecPlan: codex-plugin-cc 評価 / モデル名固定の正当性確認 / レビュー hook 実動作検証

Date: `2026-05-11`
Status: `draft`
Owner: `planner (Opus 4.7 medium)`
Lane: `initial_execplan_design` (`gpt-5.5` + `xhigh` + `cached`)
Target release: 未指定 (調査結果に応じて v0.x.y へ割当)

> **重要**: 本 ExecPlan はドキュメントベースの調査計画である。本 ExecPlan 自体の作成段階では実装・実行・設定書き換えは行わない。各 Step は後続の実装ロール (Codex worker / 手動オペレーター) に手渡す前提で記述する。

---

## 1. Objective / Goal

`rev_harness` の Codex マルチエージェント構成について以下3点を **調査・文書化** し、後続実装に必要な意思決定材料を揃える。

- **A.** `codex-plugin-cc` (openai/codex-plugin-cc) を opt-in 採用した場合のメリット / 移行コスト / 自前 hook 実装との重複範囲。
- **B.** `.agent/registry/model_policy.json` 等で参照される `gpt-5.5` モデル名の Codex CLI 実在性確認、および `gpt-5.5` 固定の正当性 (下位モデルへの暗黙 fallback 防止) を文書化し、固定維持に必要なガード (typo 検出 / EOL 監視通知) のみを設計する。代替モデルへの自動切替は明示的に non-goal とする。
- **C.** `.claude/hooks/codex-review-hook.sh` の classifier 呼び出しと governance gate が実動作しているかの検証手順策定。

### Non-Goals

- `codex-plugin-cc` を default autonomous loop に組み込むこと (operating-model policy `opt-in & monitored only` に反するため明確に除外)。
- `.codex/config.toml` / `.codex/agents/*.toml` の即時書き換え。
- 既存 `scripts/codex-wrapper.sh` の置換実装。
- `gpt-5.5` を別モデルへ置換すること、および quota 枯渇時の下位モデルへの自動 fallback を設計すること (下位モデル誤用防止のため固定が正)。

---

## 2. Context (背景要約)

- `rev_harness` は Claude Code をオーケストレーター、Codex CLI をマルチエージェント実行体として構成。
- 現状のマルチエージェント基盤は自前実装:
  - `scripts/codex-wrapper.sh`
  - `.claude/hooks/codex-review-hook.sh` (PostToolUse(Edit|Write) で起動を想定)
  - `.codex/agents/*.toml`
- `codex-plugin-cc` (https://github.com/openai/codex-plugin-cc) は **未採用**。
- `docs/manual/worldclass-harness-operating-model.md:59-64` で「default autonomous loop に使うな (usage limit を消費するため opt-in & monitored only)」と policy 明記。
- 直前調査で判明した懸念:
  1. 公式 plugin 機能の取りこぼし、および自前実装との機能重複。
  2. `gpt-5.5` は下位モデル流出防止のため意図的に hard-code されているが、typo / EOL 検出ガードが効いているかは未確認。
  3. PostToolUse(Edit|Write) hook の matcher が広すぎる可能性 / classifier 実動作未確認。

---

## 3. Scope

### A. codex-plugin-cc opt-in 検証 & 移行コスト試算

- 公式 README / リリースノート / issue tracker から提供機能と設定オプションを棚卸し。
- 自前 `codex-wrapper.sh` / `codex-review-hook.sh` / `.codex/agents/*.toml` の役割を洗い出し、機能マッピング表を作成。
- subscription usage への影響 (plugin 経由呼び出しが課金/quota にどう乗るか) を文書ベースで把握。
- operating-model policy との整合性 (opt-in & monitored only の維持方法) を整理。
- 隔離 worktree (本番設定不可侵) での手動承認付き dry-run 実測により、自前 hook との競合・quota 消費パターンを実証する。

### B. `gpt-5.5` モデル名の実在性確認 & 固定維持ガード確認 (下位モデル fallback は明示禁止)

- `.agent/registry/model_policy.json` および周辺設定ファイル内で `gpt-5.5` を参照している箇所を洗い出し。
- Codex CLI が認識する model 列挙手段 (例: `codex models list` 系コマンドの存在確認、公式 docs 参照) を文書化。
- typo / EOL 検出時の **fail-loud (停止 + 人間通知)** 設計案。**下位モデルへの自動 fallback は禁止** (ユーザー方針: 下位モデルが暗黙使用されるため固定が必須)。
- 設計案は **提案のみ** とし、実書き換えは別 PR へ委譲。

### C. `codex-review-hook.sh` classifier / governance gate 実動作確認

- `.claude/hooks/codex-review-hook.sh` の matcher / classifier / gate ロジックを静的読解。
- PostToolUse(Edit|Write) の matcher 範囲を再確認 (どのファイル種別で発火するか、過剰発火の有無)。
- classifier が想定通り分岐するかを確認する **ドライラン手順** (実行は別ロールに委ねる) を定義。
- 検証用 fixture / sample diff の用意方針を記述。

---

## 4. Status Board

- [ ] Plan approved (xhigh reviewer LGTM)
- [ ] Slice A 調査完了
- [ ] Slice B 調査完了
- [ ] Slice C 調査完了
- [ ] Findings 統合レポート作成
- [ ] Deterministic checks green (本 Plan は docs-only のため `markdownlint` 相当)
- [ ] xhigh review LGTM recorded
- [ ] Merged to main
- [ ] Archived / superseded

---

## 5. Slice Board

- [ ] **Slice A**: codex-plugin-cc 機能棚卸し & 重複範囲マッピング + 隔離 dry-run 実測
- [ ] **Slice B**: `gpt-5.5` 参照箇所列挙 & 固定維持ガード (fail-loud) 設計
- [ ] **Slice C**: codex-review-hook 静的読解 & ドライラン手順定義
- [ ] **Slice D**: 統合 findings + 後続 ExecPlan 雛形提案

---

## 6. In Scope (Step-by-step execution)

> 各 Step は調査・文書化のみ。**設定の書き換え・plugin インストール・hook 改変は本 Plan の範囲外**。

### Slice A: codex-plugin-cc 評価

A-1. 公式情報収集 (read-only)
  - `gh repo view openai/codex-plugin-cc --json description,url,defaultBranchRef` で概要取得。
  - README / `docs/` / `CHANGELOG.md` を `gh api repos/openai/codex-plugin-cc/contents/...` で取得して読む。
  - issue/PR 一覧で「known limitation」「usage limit」関連を検索。
  - **成果物**: `docs/research/codex-plugin-cc-feature-survey.md` (機能・設定オプション一覧)。

A-2. 自前実装の機能インベントリ
  - `scripts/codex-wrapper.sh` を読み、責務 (argv 整形 / model 切替 / log 整形等) を箇条書き。
  - `.claude/hooks/codex-review-hook.sh` を読み、matcher / classifier / gate を箇条書き。
  - `.codex/agents/*.toml` の agent 定義を一覧化。
  - **成果物**: `docs/research/codex-self-hosted-inventory.md`。

A-3. 機能マッピング表
  - 列: 機能 / plugin 提供有無 / 自前実装有無 / 重複判定 / 移行コスト概算 (S/M/L) / policy 影響。
  - **成果物**: `docs/research/codex-plugin-vs-self-hosted-matrix.md`。

A-4. policy 整合性チェック
  - `docs/manual/worldclass-harness-operating-model.md:59-64` を再読し、opt-in 採用時に守るべき条件を抽出。
  - **手動承認ゲート明記**: plugin install / config 変更は人間オペレーターの明示承認を伴うこと。

A-5. 隔離 worktree での手動承認付き dry-run 実測
  - A-5a. 隔離環境構築: `git worktree add ../rev_harness-plugin-eval $(git rev-parse HEAD)` で別 worktree を作成。`CLAUDE_CONFIG_DIR` と `CODEX_HOME` を当該 worktree 配下の一時パスへ上書きし、本番 `.claude/settings.json` / `.codex/config.toml` を一切 touch しないことを確認。
  - A-5b. 人間オペレーター承認ゲート: worktree path / 影響範囲 / 想定 quota 消費を提示し、Y/n 確認を取得してから `codex-plugin-cc` install コマンド列を実行 (実行は別ロール / 手動)。承認なしで install しないこと。
  - A-5c. dry-run scenario: 隔離 worktree 内で 1 ファイルの軽微編集を実施し、plugin hook と自前 `codex-review-hook.sh` の起動順序・重複・quota 消費パターンを `logs/plugin-eval/*.jsonl` に記録。
  - A-5d. 後始末 (fail-safe): `git worktree remove --force ../rev_harness-plugin-eval`、`CLAUDE_CONFIG_DIR` / `CODEX_HOME` の unset、subscription usage の前後 diff を記録。途中で失敗してもこの手順を必ず実行できるよう scripted 化する。
  - A-5e. 実測反映: A-3 のマッピング表に「実測列 (起動有無 / 重複可否 / quota delta)」を追記し、docs 読解推測と実測の差分を Slice D へ集約。
  - **成果物**: `docs/research/codex-plugin-cc-isolated-dryrun-log.md` (dry-run trace と usage diff)。

### Slice B: `gpt-5.5` 固定維持 & fail-loud ガード設計

B-1. 参照箇所の網羅
  - `rg -n "gpt-5\.5" ./` で全 hit を列挙。
  - `.agent/registry/model_policy.json` / `.codex/config.toml` / `.codex/agents/*.toml` / `docs/**/*.md` を確認。
  - **成果物**: `docs/research/gpt-5_5-references.md` (file:line 一覧)。

B-2. Codex CLI 実在モデル確認手段
  - 公式 docs (`docs/official-docs-links.md` 起点) で「現在利用可能な model 一覧の確認コマンド」を特定。
  - もしコマンドが無ければ、READMEや changelog からのテキスト抽出方法を記録。
  - **実行は別ロール**: 本 Plan ではコマンド候補の提示までに留める。

B-3. 固定維持ガード設計案
  - `gpt-5.5` は下位モデル流出防止のため意図的固定。fallback table は作らない。
  - typo (`gpt-5.5` 以外の文字列混入) を CI / pre-commit で検出する正規表現案。
  - EOL / 404 検出時は fail-loud (即停止 + 人間オペレーター通知) とし、自動切替は行わない。
  - **成果物**: `docs/design/model-pinning-guard-strategy.md` (draft)。

### Slice C: codex-review-hook 実動作検証手順

C-1. 静的読解
  - `.claude/hooks/codex-review-hook.sh` の全行コメント付き要約。
  - matcher の正規表現 / glob を抽出し「想定外に発火するケース」を列挙。
  - **成果物**: `docs/research/codex-review-hook-static-analysis.md`。

C-2. ドライラン手順設計 (実行は別ロール)
  - sample diff (一般的な Rust / TS / md 変更) を fixture 化する方針を記述。
  - hook を **dry-run モードで** 起動する想定コマンド列を提示 (例: `CLAUDE_HOOK_DRYRUN=1 .claude/hooks/codex-review-hook.sh < fixture.json`)。
  - classifier 出力の期待値テーブルを作成。
  - **成果物**: `docs/research/codex-review-hook-dryrun-protocol.md`。

C-3. 観測項目
  - hook 起動回数 / 平均レイテンシ / classifier 分岐分布 / subscription usage 消費量。
  - 観測ログの保存先案 (`logs/codex-review-hook/*.jsonl`) を提示。

### Slice D: 統合 findings

D-1. 上記 A/B/C の結果を `docs/research/codex-multiagent-followup-findings.md` に統合。
D-2. 後続 ExecPlan の雛形 (実装フェーズ) を別ファイルで起票する案を提示。
D-3. 各 finding に「優先度 (P0/P1/P2)」と「policy 影響度」を付与。

---

## 7. Deliverables (成果物ファイルパス案)

すべて `rev_harness` リポジトリ配下、Markdown:

- `docs/research/codex-plugin-cc-feature-survey.md` (A-1)
- `docs/research/codex-self-hosted-inventory.md` (A-2)
- `docs/research/codex-plugin-vs-self-hosted-matrix.md` (A-3)
- `docs/research/codex-plugin-cc-isolated-dryrun-log.md` (A-5)
- `docs/research/gpt-5_5-references.md` (B-1)
- `docs/design/model-pinning-guard-strategy.md` (B-3, draft)
- `docs/research/codex-review-hook-static-analysis.md` (C-1)
- `docs/research/codex-review-hook-dryrun-protocol.md` (C-2)
- `docs/research/codex-multiagent-followup-findings.md` (D-1, 統合)

> `docs/research/` が未存在の場合、作成も後続 Slice 開始時に手動承認のうえで行う。

---

## 8. Required Deterministic Checks

本 Plan は docs-only のため:

- [ ] 全 Markdown ファイルが UTF-8 / LF。
- [ ] `docs/manual/execplan-checklist-standard.md` の Required Sections を満たす。
- [ ] 各 deliverable の冒頭に `Date` / `Status` / `Owner` を記載。
- [ ] 外部リンクは `docs/official-docs-links.md` に集約 (新規リンク追加時)。
- [ ] `rg "TODO|FIXME" docs/research docs/design` が想定外残置を示さない。

---

## 9. Risk & Mitigation

| Risk | 影響 | Mitigation |
|---|---|---|
| `codex-plugin-cc` の調査中に plugin install / enable を誤って実行 | subscription usage 消費 / policy 違反 | 本 Plan 範囲内では **隔離 worktree + 手動承認ゲート下でのみ install 許可**、本番 `.claude/` / `.codex/` への書き込みは禁止。それ以外の Step は read-only コマンド (`gh repo view` / `gh api contents` 等) に限定。 |
| `gpt-5.5` を別モデルへ置換、もしくは自動 fallback を実装してしまう (下位モデル流出リスク) | model_policy 破壊的変更 / 下位モデル誤用 | 固定維持が方針。実装は別 ExecPlan + 手動承認。本 Plan では `docs/design/model-pinning-guard-strategy.md` (draft) までに留める。 |
| codex-review-hook のドライランで本番 classifier を叩く | usage 消費 / 不要 review 発火 | `CLAUDE_HOOK_DRYRUN=1` 相当の env / fixture 入力に限定。本 Plan では手順記述のみ、実行は別ロール。 |
| operating-model policy `opt-in & monitored only` への抵触 | governance 違反 | A-4 で policy 抜粋を再掲し、自動有効化を提案する文言が無いことをレビュー必須化。 |
| `.codex/config.toml` / `.claude/settings.json` の意図せぬ書き換え | 破壊的変更 | 本 Plan は設定書き換えを Step に含めない。書き換えが必要になった時点で別 ExecPlan を起票し、人間承認ゲートを入れる。 |
| 機密情報の docs 出力 (API key / token) | secret leak | 調査出力に環境変数値を貼らない。`rg` 結果は file:line と key 名のみ記載。 |

---

## 10. Acceptance Criteria (LGTM 基準)

- [ ] Slice A の 4 成果物 (dry-run log を含む) が揃い、機能マッピング表で「plugin 採用時の get / lose」が一目で分かる。
- [ ] Slice B の参照棚卸しが完了し、固定維持ガード draft が **fail-loud (自動 fallback 禁止)** 方針を明示し、typo / EOL 検出手段を提示している。
- [ ] Slice C の静的解析で hook matcher の発火範囲が文書化され、ドライラン手順が **コピペで実行可能** な粒度。
- [ ] Slice D の統合 findings に各項目の優先度と policy 影響度が付与されている。
- [ ] 本 Plan を含むすべての deliverable が `execplan-checklist-standard.md` の Required Sections を満たす。
- [ ] `codex-plugin-cc` の default autonomous loop 採用を提案する文言が **一切無い** ことを reviewer が確認。
- [ ] 破壊的変更 (config / hook 書き換え) を伴う作業は、すべて「別 ExecPlan + 手動承認」へ委譲されている。
- [ ] xhigh reviewer (gpt-5.5 / xhigh / cached) の LGTM が記録されている。

---

## 11. Out Of Scope (今回やらないこと)

- **本番** `.claude/` / `.codex/` への 実 install / enable / 設定書き換え (隔離 worktree での dry-run は Slice A-5 の範囲内で許可)。
- `gpt-5.5` の model_policy.json 書き換え、および下位モデルへの自動 fallback 実装 (方針上禁止)。
- `codex-review-hook.sh` のコード改変 / matcher 縮小。
- `.codex/agents/*.toml` の agent 定義変更。
- `scripts/codex-wrapper.sh` の置換実装。
- subscription / quota 実測 (実コマンド発火を伴うため別 Plan)。
- default autonomous loop への plugin 組み込み (operating-model policy で禁止)。
- 他リポジトリ側への波及作業 (詳細は非公開ログ参照)。

---

## 12. Completion Boundary

本 ExecPlan は以下が揃った時点で `archived` へ遷移する:

1. Section 7 のすべての deliverable が main へ merge。
2. Section 10 の Acceptance Criteria が全 check 済み。
3. 後続実装 ExecPlan (A/B/C 各 1 本以上) が、dry-run 実測結果 (A-5 成果物) を踏まえた上で起票され、本 Plan の findings と link されている。
4. operating-model policy への抵触が無いことが reviewer により確認済み。

---

## Appendix: 参照

- `docs/manual/worldclass-harness-operating-model.md` (policy 根拠)
- `docs/manual/execplan-checklist-standard.md` (本 Plan の format 根拠)
- `docs/manual/subscription-orchestration.md` (usage 消費観点)
- `docs/design/harness-plugin-boundary.md` (plugin 境界設計)
- `docs/design/harness-plugin-mcp-trust-matrix.md` (plugin 信頼境界)
- `docs/official-docs-links.md` (外部リンク集約)
- https://github.com/openai/codex-plugin-cc (調査対象 / read-only)
