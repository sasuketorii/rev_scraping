# Migration Guide: Agent SDK Billing Separation (2026-06-15)

効力日: 2026-06-15 (±3日猶予、Anthropic 側の最終アナウンスに応じてスライド可能性あり)
shim 期間: 2026-06-15 〜 2026-07-14 (**30日**、`scripts/claude-wrapper.sh` が passthrough shim として動作する期間)
shim-hits.log retention: **60日** (cron rotate / gc 対象。shim 期間とは別概念)
最終撤去: 2026-07-14 (ゲート判定後、plan-v3-final.md と整合: shim 撤去 or opt-in 化)

## 1. 背景

2026-06-15 から Anthropic Agent SDK / `claude --print` / Claude Code GitHub Actions の課金が Max サブスク対話枠と分離され、新設の Agent SDK monthly credit (Pro $20 / Max5x $100 / Max20x $200、非ロールオーバー、超過分は標準API従量) から消費されるようになる。

出典:

- https://code.claude.com/docs/agent-sdk
- https://support.claude.com

## 2. 影響を受ける rev_harness の経路

- `scripts/claude-wrapper.sh:693` の `claude --print ...` 呼出
- これを default flow に組み込んだまま 6/15 を迎えると Agent SDK credit を消費する

## 3. 新しい default 運用方針

(commit c09fe32 で `AGENTS.md` / `CLAUDE.md` / `docs/agent-sdk-policy.md` にて確定済み)

- Claude Code を top-level orchestrator として常用
- Claude→Claude (same-family) は Task tool / native subagents で完結
- Claude→Codex (cross-family) は `scripts/codex-wrapper.sh` 経由 (Codex 課金は OpenAI 側)
- **Codex top-level → Claude (`claude-wrapper.sh` 経由) は default flow から除外・実行禁止**
- pty/expect 擬似化は完全禁止 (fail-closed)

## 4. shim 期間中の挙動 (6/15 〜 7/14、30日)

PR-A で実装される shim:

- `scripts/claude-wrapper.sh` は stderr に DEPRECATED warning を出す
- `~/.rev_harness/shim-hits.log` に JSONL 形式で呼出を記録 (SHA256 ハッシュのみ、PII禁止)
- 既存処理は passthrough して機能は壊さない
- shim-hits.log schema は [docs/shim-spec.md](shim-spec.md) を参照

なお、shim 動作期間 (30日) と shim-hits.log の retention (60日) は別概念:

- **shim 期間 = 30日 (6/15〜7/14)**: `claude-wrapper.sh` が passthrough shim として動作する期間。7/14 ゲートで撤去 or opt-in 化を判定。
- **shim-hits.log retention = 60日**: ログの gc 対象期間 (cron rotate 想定)。7/14 ゲート判定の後も、過去 14 日連続 0 ヒット評価などの集計のため少し長めに保持する。

## 5. ゲート判定 (2026-07-14)

評価指標 3つ:

1. Agent SDK 課金実績 vs 5/14 予測 (±20% 以内か)
2. `~/.rev_harness/shim-hits.log` の rewrite ヒット数 (14日連続 0 か)
3. Anthropic 側ポリシー変動の有無

分岐:

- 予測内 + ヒット0 → `scripts/claude-wrapper.sh` **完全削除**
- 予測内 + ヒット 1〜10 → 削除のみ実行、opt-in 復活は次スプリント別 PR
- 予測超過(>120%) → 緊急対応プラン発動、PR-D 保留

## 6. ユーザー向け移行手順

### 6.1 旧経路の停止

- Codex top-level orchestrator から `claude-wrapper.sh` を呼ぶスクリプトを停止
- cron / hooks / `.codex/agents/*.toml` の参照を除去

### 6.2 新経路への移行

- Claude top-level の TUI セッションを起点に Task tool / native subagent で並列化
- Codex を呼ぶ場合は `scripts/codex-wrapper.sh` 経由

### 6.3 緊急時の人間操作

- Codex 実行中に Claude 診断が必要なら、別ターミナルで Claude TUI を開いて手動対応

## 7. opt-in 復活手順 (将来検討)

shim 撤去後、業務上どうしても Codex→Claude cross-family bridge が必要になった場合:

- 次スプリントで別 PR を立てる
- Budget Guard 必須 (`~/.rev_harness/budget/agent-sdk.json` で月次 credit を計測)
- 明示 opt-in: 環境変数 `REV_OPT_IN_CROSS_FAMILY_CLAUDE=1` が必要
- audit log (`~/.rev_harness/audit/cross-family-claude.log`) に append-only
- CI/CD では opt-in 不可 (`CI=1` 検知で fail-closed)

## 8. 関連ファイル

- [AGENTS.md](../AGENTS.md) (Dual-native orchestration boundary + 6/15 addendum)
- [CLAUDE.md](../CLAUDE.md) (同上)
- [docs/agent-sdk-policy.md](agent-sdk-policy.md) (Policy v0.1)
- [docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md](plans/2026-06-agent-sdk-migration/plan-v3-final.md) (実装計画)
- [docs/shim-spec.md](shim-spec.md) (JSONL schema)
- [docs/discovery-2026-05.md](discovery-2026-05.md) (棚卸し)

## 9. 緊急対応プラン (Plan v3 §E より抜粋)

1. 6/15 が前倒し/延期 → ±3日猶予で吸収、超過時は merge 日スライド
2. Agent SDK 課金が予測の 200%超 → shim rewrite 即停止、明示 error + 移行案内に切替
3. shim auto-rewrite が破壊的バグ → 1コミット revert、rewrite 無効化 + passthrough hotfix
4. vendored copy で事故 → Discovery 棚卸表から個別連絡
