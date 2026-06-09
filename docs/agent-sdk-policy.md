# Agent SDK Billing Policy (rev_harness)

- **効力日:** 2026-06-15
- **バージョン:** v0.1 (minimal, Plan v2 先行版)
- **ステータス:** 運用ポリシー (default flow を規定)

本ドキュメントは、Anthropic の Agent SDK 課金分離に伴う rev_harness 内のオーケストレーション運用ポリシーを定める。`AGENTS.md` / `CLAUDE.md` の "Dual-native orchestration boundary" セクションの addendum と整合する。

---

## 1. 背景

2026-06-15 から、Claude Agent SDK 経由の非対話実行 (`claude --print` を含む) は、Max サブスクの対話枠とは **別の Agent SDK monthly credit** から課金される。

- 対象プラン別 credit (非ロールオーバー):
  - Pro: $20 / month
  - Max 5x: $100 / month
  - Max 20x: $200 / month
- credit 超過分は標準 API 従量課金に切り替わる。
- 対話 (Claude Code interactive / Claude.ai chat) の消費枠とは分離されるため、自動化フローで `claude --print` を多用すると意図しない課金が発生し得る。

出典:
- Agent SDK overview: https://code.claude.com/docs/agent-sdk
- Agent SDK billing details: https://support.claude.com

---

## 2. 影響を受ける呼び出し

以下はすべて Agent SDK credit を消費する経路として扱う。

- `claude --print` (`claude -p` 含む) の非対話実行
- Claude Agent SDK (TypeScript / Python) を直接利用するコード
- Claude Code GitHub Actions 経由の自動実行
- Agent SDK を基盤として組み込んだ 3rd party アプリ / 統合
- 上記を内部で利用するラッパースクリプト (`scripts/claude-wrapper.sh` など)

対話 Claude Code セッション (TUI) 自体はこの分離の対象外だが、その中から SDK 経路を起動した場合は SDK 側として課金される。

---

## 3. Default Orchestration Policy

rev_harness のデフォルトオーケストレーションは次のとおり。

1. **Top-level orchestrator は Claude Code とする。**
2. Same-family (Claude → Claude) は Claude native subagents / Task tool で委譲し、`scripts/claude-wrapper.sh` を再帰的に通さない。
3. Cross-family (Claude → Codex) は `scripts/codex-wrapper.sh --role ...` 経由で委譲する。Codex 側は Agent SDK credit を消費しない。
4. **Codex top-level orchestrator から Claude を呼ぶ cross-family 委譲は default flow から除外する。**
   - Codex を起点とする開発フローでは `scripts/claude-wrapper.sh` の実行を **禁止** する。
   - 理由: 6/15 以降 `claude --print` が Agent SDK credit を消費し、対話枠と分離されるため、これを default の自動化に組み込むと意図しない従量課金が発生し得る。
5. Codex top-level → Codex same-family は Codex native subagents / `.codex/agents/*.toml` で委譲する。

要約表:

| Top-level | Same-family 委譲 | Cross-family 委譲 | 既定可否 |
|-----------|------------------|--------------------|-----------|
| Claude Code | Claude native subagents / Task tool | `scripts/codex-wrapper.sh` 経由 Codex | 可 (推奨デフォルト) |
| Codex | Codex native subagents | Claude (`scripts/claude-wrapper.sh`) | **不可** (例外規定参照) |

---

## 4. 例外規定

Codex top-level → Claude cross-family 委譲を残すのは、以下をすべて満たす opt-in & monitored ケースに限る。

- 実行前に **Budget Guard** が動作すること (Agent SDK credit 残量 / 想定コストのチェックと、閾値超過時の fail-closed)。
- 当該実行は `codex-plugin-cc` と同等の隔離 / 監査トレース下に置くこと。
- 個別開発で opt-in 宣言を行い、default flow への組み込みは禁止する。
- 監査ログに SDK 経由実行であることが明示されること。

例外運用の詳細枠組みは `docs/execplan-codex-plugin-cc-evaluation.md` に揃える。

---

## 5. 関連ファイル

- `AGENTS.md` — Dual-native orchestration boundary + 6/15 Addendum
- `CLAUDE.md` — 同 Addendum (Claude Code 視点)
- `scripts/claude-wrapper.sh` — Claude 非対話実行ラッパー (Codex top-level からは default 禁止)
- `scripts/codex-wrapper.sh` — Codex 委譲ラッパー (default cross-family 経路)
- `test/integration/cross_agent_wrapper_matrix_test.sh` — wrapper の cross-family 振る舞いマトリクス

---

## 6. 擬似化の禁則

pty / expect / TTY emulation 等で Agent SDK 経由実行を対話セッションに見せかけ、課金経路を回避する実装は **禁止** する。

- Anthropic 側の課金分類はクライアント側の擬似化では覆らないため、回避策として無効。
- 監査・コスト把握を歪めるため、内部運用上も許容しない。
- 違反は Reviewer による fail-closed 対象とする。

---

## 改訂履歴

- 2026-05-14: v0.1 初版 (Plan v2 先行最小版)。
