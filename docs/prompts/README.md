# Reviewer Prompt Templates

このディレクトリは、**レビュワープロンプトのテンプレート**を格納する場所です。
Phase 2 では、再利用可能なレビュー本文の契約をここに置き、shell は互換ルーティングに留めます。

## 責務

| ディレクトリ | 用途 |
|-------------|------|
| `docs/prompts/` | **テンプレート**（再利用可能なプロンプト定義） |
| `.agent/active/prompts/` | **実運用**（作業中のハンドオーバー/レビュー依頼） |
| `.agent/archive/prompts/` | **アーカイブ**（完了したプロンプト） |

## 使用方法

カスタムレビュワーを追加する場合、このディレクトリにプロンプトファイルを配置します。

```bash
# 例: セキュリティ特化レビュワーを追加
cat > docs/prompts/security_reviewer.md << 'EOF'
# Security Reviewer

## 観点
- SQLインジェクション
- XSS
- 認証・認可の脆弱性
- 機密情報のハードコード

## 出力フォーマット
docs/roles/reviewer.md に従うこと
EOF
```

`reviewer_batch.md` は `auto_orchestrate.sh` のバッチレビュー用テンプレートです。
- Specialty operating templates: `docs/roles/<coder|reviewer|orchestrator>/specialties/<slug>.md` (each with embedded JSON manifest). Historical v0 form (single prose file) archived at `docs/prompts/_archive/role-operating-templates-v0.md`.

- shell 側が保持するもの: public review queue ingress / adapter、state、wrapper/template の fail-closed ガード、diff スナップショット作成
- durable な review queue backend は repo-local semantic-mcp 側が保持し、現行 slice では Rust-backed / Node-compatible の両方を許容する
- `docs/prompts/` 側が保持するもの: 再利用可能なレビュー本文と batch-specific guidance
- `reviewer_batch.md` の `__BATCH_REVIEW_METADATA__` と `__BATCH_REVIEW_DIFF__` は shell が実行時に差し込みます
- reviewer schema / enum / mandatory sections の canonical source は `docs/roles/reviewer.md`
- machine validation と fail-closed intake は `.claude/commands/auto_orchestrate.sh` が保持します
- packet projection と reviewer contract の runtime subset source は `.agent/registry/orchestration_policy_projection.json`
- `Worker Outcome Payload Reviewed` の `contract source` は `docs/manual/verification-truth-matrix.md :: Worker Outcome Contract` を使います
- file-backed な required verification artifact pointer は、runtime から存在確認できる path を指す必要があります
- pretty-printed multi-line transport JSON も single-line transport blob と同様に invalid で、fenced code block 内でも fail-closed です

## 参照箇所

以下のスクリプトがこのディレクトリを参照しています：

- `.claude/commands/auto_orchestrate.sh`
- `.claude/commands/lib/coder.sh`
- `.claude/commands/lib/reviewer.sh`

## 関連ドキュメント

- `docs/roles/reviewer.md` - Reviewer の詳細ワークフロー
- `.agent_rules/RULES.md` - 共通ルール
