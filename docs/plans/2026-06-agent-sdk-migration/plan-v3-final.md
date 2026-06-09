# Plan v3 (Final) — rev_harness Agent SDK 課金分離対応

期日: 2026-06-15 (±3日猶予) / 起案日: 2026-05-14 / 残32日

## 0. 背景と参照

- 関連 commit: c09fe32 (`docs/agent-sdk-policy.md` 先行投入)
- 関連 docs: `docs/agent-sdk-policy.md`, `AGENTS.md` (dual-native section), `CLAUDE.md`
- ユーザー方針: Claude top-level + Codex via wrapper を正、Codex top-level から Claude 呼び出しは default 禁止
- 本計画は v2 へのレビュワー指摘 (パス相違: `bin/` `tests/` ではなく `scripts/` `test/integration/` が実在) を反映した最終版

## A. 全体タイムライン

| マイルストーン | 日付 | 内容 |
| --- | --- | --- |
| Discovery | 2026-05-17 | org 横断スキャン、棚卸 |
| PR-A | 2026-05-21 | shim 化 + 計測基盤投入 |
| PR-B | 2026-05-25 | skill 強化 + negative test 化 |
| PR-C | 2026-05-29 | docs + 移行ガイド |
| 中間レビュー | 2026-06-14 | shim ログ集計、撤収可否判定 |
| 期日 | 2026-06-15 (±3日) | Agent SDK 課金分離切替 |
| PR-D | 2026-07-14 | ゲート判定 + shim 撤去 |

## B. 各 PR 詳細

### Discovery (2026-05-17): org 横断スキャン

- `grep -rn "claude-wrapper" ~/dev`
- `gh search code --owner REV-C "claude-wrapper.sh"`
- `find ~/dev -name ".gitmodules" -exec grep -l rev_harness {} \;`
- 成果物: `docs/discovery-2026-05.md` (参照件数、vendored copy 一覧、想定月次呼出頻度の初期見積)

### PR-A (2026-05-21): shim 化 + 計測基盤

- 変更: `scripts/claude-wrapper.sh`
  - deprecation warning を stderr 出力
  - Task tool 等価呼び出しへの auto-rewrite
  - JSONL 形式の呼び出しログ書き込み
- 新規: `scripts/_shim-log.sh`, `docs/shim-spec.md`
- ログ: `~/.rev_harness/shim-hits.log`
  - フィールド: `ts`, `caller_hash`, `pid`, `rewrite_target`, `argv_hash`
  - SHA256 ハッシュのみ記録、prompt 本文・argv 生値・PII は禁止
- 検証: `test/integration/cross_agent_wrapper_matrix_test.sh` の X1〜X6 通過
- 観測窓: マージ後 24h

### PR-B (2026-05-25): skill 強化 + negative test 化

- 変更: `.claude/skills/codex-caller/SKILL.md`
  - description 冒頭で Codex top-level → Claude 呼び出し禁止を明記
  - trigger に negative example を追加
- 変更: `test/integration/cross_agent_wrapper_matrix_test.sh`
  - X7〜X13 は `# NEGATIVE TEST: Codex top-level→Claude must be blocked` コメントを付与して残置
  - assertion を反転 (拒否側が PASS)
- 検証: matrix_test 全通過、別セッションで skill 誤誘発を手動で 3 回確認
- 観測窓: マージ後 24h

### PR-C (2026-05-29): docs + 移行ガイド

- 変更: `README.md` に Agent SDK 課金分離セクション追加、`CHANGELOG.md` 追記
- 新規: `docs/migration-agent-sdk-2026-06.md`
  - 6/15 ±3日 の猶予明記
  - shim 期間 60 日 (〜2026-07-14)
  - 撤収条件、opt-in 復活手順
- 検証: markdownlint、内部リンク切れチェック

### PR-D (2026-07-14): ゲート判定 + 撤去

- 評価指標
  - Agent SDK 課金実績 vs 5/14 時点予測 (±20% 以内が許容)
  - `shim-hits.log` の rewrite ヒット数が 14 日連続 0
  - Anthropic 側ポリシー変動の有無
- 分岐
  - 予測内 + ヒット 0 → `scripts/claude-wrapper.sh` 完全削除
  - 予測内 + ヒット 1〜10 → 削除のみ実施、opt-in 復活は次スプリント別 PR で扱う
  - 予測超過 (>120%) → 緊急対応発動、PR-D 保留
- 新規: `docs/gate-decision-2026-07.md`

## C. 中間レビュー (2026-06-14)

- `shim-hits.log` 集計、auto-rewrite ヒット数、Agent SDK 課金実績、Anthropic 側変動の確認
- 早期撤収判定: ヒット 0 が 14 日連続なら 7/14 を前倒し可
- 成果物: `docs/mid-review-2026-06.md`

## D. 監査・記録

| ファイル | 用途 | 保持期間 |
| --- | --- | --- |
| `docs/discovery-2026-05.md` | 棚卸スナップショット | 永続 |
| `docs/mid-review-2026-06.md` | 中間判定記録 | 永続 |
| `docs/gate-decision-2026-07.md` | 最終ゲート判定 | 永続 |
| `~/.rev_harness/shim-hits.log` | shim 呼出計測 | 60 日 (cron rotate) |

PII 方針: prompt 本文・argv 生値は記録せず、SHA256 ハッシュのみ保持する。

## E. 緊急対応プラン

1. 6/15 前倒し / 延期 → README に明記した ±3日 猶予で吸収、超過時は merge 日をスライド
2. Agent SDK 課金 200% 超過 → shim rewrite を即停止、明示 error + 移行案内へ切替。原因は `rewrite_target` 分布で特定
3. shim auto-rewrite に破壊的バグ → 1 コミット revert、rewrite 無効化 + passthrough の hotfix を当てる
4. vendored copy 起因の事故 → Discovery 棚卸表から個別連絡、GitHub Security Advisory 起票を検討

## F. ゲート判定の予測値定義 (運用明確化)

予測 100% = Discovery で検出された `claude-wrapper` 参照件数 × 月次想定呼出頻度 × Agent SDK credit 単価。

5/14 時点で確定し、PR-D の判定では当該値に対する実績比で評価する。

## G. rollback 手順

- 各 PR マージ前に `pre-PR-A`, `pre-PR-B`, `pre-PR-C`, `pre-PR-D` タグを打つ
- 通常撤回は `git revert <merge-commit>` で復元
- 緊急時のみ該当タグへ `git reset --hard` (force-push が必要なため admin 承認下で実施)

## Critical Files (実在パス確認済み)

- `./scripts/claude-wrapper.sh`
- `./test/integration/cross_agent_wrapper_matrix_test.sh`
- `./.claude/skills/codex-caller/SKILL.md`
- `./docs/agent-sdk-policy.md` (既存、commit c09fe32)
