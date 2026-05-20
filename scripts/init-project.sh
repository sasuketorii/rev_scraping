#!/bin/bash
# ==============================================================================
# init-project.sh - プロジェクト初期化スクリプト
# ==============================================================================
# 用途: agent_baseを新しいプロジェクトにクローンした後、
#       プロジェクト固有の設定を初期化する
#
# 使用法:
#   ./scripts/init-project.sh [project_name]
#
# 実行内容:
#   1. 必要なディレクトリ構造の作成
#   2. repo-local immutable project_id artifact の生成
#   3. テンプレートファイルの生成
#   4. .gitignoreの更新
#   5. 初期化完了メッセージの表示
# ==============================================================================

set -euo pipefail

# カラー定義
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ログ関数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

write_literal_file() {
    local path="$1"
    shift

    printf '%s\n' "$@" > "$path" || {
        log_error "ファイル生成に失敗しました: $path"
        exit 1
    }
}

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PROJECT_ID_TOOL="${PROJECT_ROOT}/scripts/project-id.sh"

# プロジェクト名を取得（引数または現在のディレクトリ名）
PROJECT_NAME="${1:-$(basename "$PROJECT_ROOT")}"

# プロジェクト名の入力検証（コマンドインジェクション防止）
if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    log_error "無効なプロジェクト名です: $PROJECT_NAME"
    log_error "英字で始まり、英数字・ハイフン・アンダースコアのみ使用可能です"
    exit 1
fi

# ==============================================================================
# ディレクトリ作成
# ==============================================================================
create_directories() {
    log_info "ディレクトリ構造を作成中..."

    local dirs=(
        ".agent/active/sow"
        ".agent/active/prompts"
        ".agent/archive/plans"
        ".agent/archive/sow"
        ".agent/archive/prompts"
        ".agent/archive/feedback"
        ".agent/archive/test"
        ".agent/archive/docs"
        ".claude/tmp"
        "docs/requirements"
        "docs/design"
        "docs/manual"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "${PROJECT_ROOT}/${dir}"
        # .gitkeepを追加（空ディレクトリをgitに追跡させる）
        touch "${PROJECT_ROOT}/${dir}/.gitkeep"
    done

    log_success "ディレクトリ構造を作成しました"
}

# ==============================================================================
# repo-local immutable project_id artifact
# ==============================================================================
bootstrap_project_id() {
    if [[ ! -x "$PROJECT_ID_TOOL" ]]; then
        log_error "project_id helper が見つからないか実行不可です: $PROJECT_ID_TOOL"
        exit 1
    fi

    log_info "repo-local project_id artifact を初期化中..."

    local project_id=""
    project_id="$(PROJECT_ID_REPO_ROOT="$PROJECT_ROOT" bash "$PROJECT_ID_TOOL" bootstrap "$PROJECT_NAME")" || {
        log_error "project_id artifact の生成に失敗しました"
        exit 1
    }

    local artifact_path=""
    artifact_path="$(PROJECT_ID_REPO_ROOT="$PROJECT_ROOT" bash "$PROJECT_ID_TOOL" artifact-path)" || {
        log_error "project_id artifact path の解決に失敗しました"
        exit 1
    }

    log_success "project_id artifact を準備しました: ${project_id} (${artifact_path})"
}

# ==============================================================================
# 要件定義テンプレート生成
# ==============================================================================
create_requirements_template() {
    local target="${PROJECT_ROOT}/.agent/requirements.md"

    if [[ -f "$target" ]] && [[ -s "$target" ]]; then
        log_warn "requirements.md は既に存在します。スキップします。"
        return
    fi

    log_info "要件定義テンプレートを生成中..."

    write_literal_file "$target" \
        '# Requirements / 要件定義書' \
        '' \
        'このファイルは、エージェント駆動開発の「入り口」です。' \
        '新しいプロジェクトや機能を開始する際、ユーザーはこのファイルに要件を記載してください。' \
        '' \
        '---' \
        '' \
        '## 使い方' \
        '' \
        '1. 以下のテンプレートを参考に、要件を記載' \
        '2. エージェントが `.agent/active/plan_YYYYMMDD_*.md` にExecPlanを生成' \
        '3. 開発完了後、プランは自動的に `archive/plans/` へ移動' \
        '' \
        '---' \
        '' \
        '## テンプレート' \
        '' \
        '### プロジェクト名' \
        '(例: My Awesome Project)' \
        '' \
        '### ゴール' \
        '(例: ユーザーがログインして売上データを確認できるダッシュボードを作成する)' \
        '' \
        '### 機能要件' \
        '1. (例: ユーザー認証機能)' \
        '2. (例: データ可視化ダッシュボード)' \
        '3. ...' \
        '' \
        '### 非機能要件' \
        '- (例: レスポンス時間 500ms以内)' \
        '- (例: 99.9%の可用性)' \
        '' \
        '### 技術スタック' \
        '- Language: (例: TypeScript)' \
        '- Framework: (例: Next.js 14)' \
        '- DB: (例: PostgreSQL)' \
        '- ...' \
        '' \
        '### 制約事項' \
        '- (例: 既存のAPI仕様との互換性維持)' \
        '- (例: モバイルファースト設計)' \
        '' \
        '### 成功条件' \
        '- (例: 全テストケース通過)' \
        '- (例: パフォーマンス基準達成)' \
        '' \
        '---' \
        '' \
        '## 現在の要件' \
        '' \
        '<!-- ここにユーザーの要件を記載 -->' \
        '' \
        '(まだ要件が記載されていません。上記テンプレートを参考に要件を追加してください。)'

    log_success "requirements.md を生成しました"
}

# ==============================================================================
# プロジェクトコンテキスト生成
# ==============================================================================
create_project_context() {
    local target="${PROJECT_ROOT}/.agent/PROJECT_CONTEXT.md"

    if [[ -f "$target" ]] && [[ -s "$target" ]]; then
        log_warn "PROJECT_CONTEXT.md は既に存在します。スキップします。"
        return
    fi

    log_info "プロジェクトコンテキストを生成中..."

    write_literal_file "$target" \
        '# Project Context / プロジェクトコンテキスト' \
        '' \
        'このファイルは、プロジェクト固有の情報をエージェントに伝えるためのコンテキストファイルです。' \
        '`.agent_rules/RULES.md` の汎用ルールを補完し、本プロジェクト固有の設定を定義します。' \
        '' \
        '---' \
        '' \
        '## プロジェクト概要' \
        '' \
        "**${PROJECT_NAME}**" \
        '' \
        '<!-- プロジェクトの概要を記載 -->' \
        '' \
        '---' \
        '' \
        '## 技術スタック' \
        '' \
        '| カテゴリ | 技術 | バージョン/備考 |' \
        '|---------|------|----------------|' \
        '| 言語 | <!-- 例: TypeScript --> | <!-- 例: 5.0+ --> |' \
        '| フレームワーク | <!-- 例: Next.js --> | <!-- 例: 14 --> |' \
        '| DB | <!-- 例: PostgreSQL --> | <!-- 例: 15 --> |' \
        '| CLI | Claude Code CLI | Anthropic |' \
        '| CLI | Codex CLI | OpenAI |' \
        '' \
        '---' \
        '' \
        '## ディレクトリ構造' \
        '' \
        '```' \
        "${PROJECT_NAME}/" \
        '├── .agent/                  # エージェント駆動開発の中核' \
        '│   ├── requirements.md      # 要件定義書' \
        '│   ├── PROJECT_CONTEXT.md   # このファイル' \
        '│   ├── active/              # 現在進行中のタスク' \
        '│   └── archive/             # 完了した作業' \
        '│' \
        '├── .agent_rules/            # 汎用ルール' \
        '├── .claude/                 # Claude CLI設定' \
        '├── .codex/                  # Codex CLI設定' \
        '├── docs/                    # プロジェクトドキュメント' \
        '├── scripts/                 # ビルド・ユーティリティ' \
        '└── ...' \
        '```' \
        '' \
        '---' \
        '' \
        '## 開発ワークフロー' \
        '' \
        '### 1. 要件定義' \
        '```bash' \
        '# ユーザーが .agent/requirements.md に要件を記載' \
        '```' \
        '' \
        '### 2. プラン生成' \
        '```bash' \
        '# エージェントが .agent/active/plan_YYYYMMDD_*.md を生成' \
        '```' \
        '' \
        '### 3. 実装（Coder）' \
        '```bash' \
        './.claude/commands/auto_orchestrate.sh \' \
        '  --plan .agent/active/plan_*.md \' \
        '  --phase impl \' \
        '  --run-coder' \
        '```' \
        '' \
        '### 4. レビュー（Reviewer）' \
        '```bash' \
        '# auto_orchestrate.sh が自動でCodexレビューを実行' \
        '```' \
        '' \
        '---' \
        '' \
        '## テスト実行' \
        '' \
        '```bash' \
        '# テストコマンドを記載' \
        '# 例: npm test' \
        '```' \
        '' \
        '---' \
        '' \
        '## コミット規約' \
        '' \
        '```' \
        '<type>: <subject>' \
        '' \
        'Types:' \
        '- feat: 新機能' \
        '- fix: バグ修正' \
        '- docs: ドキュメント' \
        '- refactor: リファクタリング' \
        '- test: テスト追加/修正' \
        '- chore: 雑務' \
        '```' \
        '' \
        '---' \
        '' \
        '## 注意事項' \
        '' \
        '1. **mainブランチ直接編集禁止**: 必ずWorktreeを使用' \
        '2. **Codex呼び出し**: `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>` を使う（Reviewer は `--role reviewer` 固定、legacy shim は互換用）' \
        '3. **Claude effort 既定値**: `medium`。caller-facing effort は `low|medium|high|xhigh` のみ許可し、`max` は使わない' \
        '4. **Wrapper ガード**: Codex wrapper は `--cd` / `--add-dir` を警告して strip し、shim 固定 role に対する role escape は fail-closed で拒否する' \
        '5. **セッション継続**: API課金なしでコンテキスト保持可能' \
        '6. **Session helper の入口**: Claude 実行は canonical `scripts/claude-wrapper.sh` を使い、`CLAUDE_WRAPPER` は caller 制御の escape hatch として扱わず canonical path 以外なら fail-closed で拒否する'

    log_success "PROJECT_CONTEXT.md を生成しました"
}

# ==============================================================================
# .gitignore更新
# ==============================================================================
update_gitignore() {
    local gitignore="${PROJECT_ROOT}/.gitignore"

    log_info ".gitignore を確認中..."

    local entries=(
        ".claude/tmp/"
        "workspace/"
        "*.log"
        ".DS_Store"
    )

    for entry in "${entries[@]}"; do
        if ! grep -qF "$entry" "$gitignore" 2>/dev/null; then
            echo "$entry" >> "$gitignore"
            log_info "  追加: $entry"
        fi
    done

    log_success ".gitignore を更新しました"
}

# ==============================================================================
# docs/requirements テンプレート
# ==============================================================================
create_docs_template() {
    local target="${PROJECT_ROOT}/docs/requirements/README.md"

    if [[ -f "$target" ]]; then
        log_warn "docs/requirements/README.md は既に存在します。スキップします。"
        return
    fi

    log_info "docs/requirements テンプレートを生成中..."

    write_literal_file "$target" \
        '# Requirements Documentation' \
        '' \
        'このディレクトリには、プロジェクトの要件定義ドキュメントを配置します。' \
        '' \
        '## ファイル構成' \
        '' \
        '- `features.md` - 機能要件' \
        '- `constraints.md` - 制約条件' \
        '- `api-spec.md` - API仕様' \
        '' \
        '## 関連ファイル' \
        '' \
        '- `.agent/requirements.md` - エージェント駆動開発の入り口' \
        '- `.agent/PROJECT_CONTEXT.md` - プロジェクト固有コンテキスト'

    log_success "docs/requirements テンプレートを生成しました"
}

# ==============================================================================
# メイン処理
# ==============================================================================
main() {
    echo ""
    echo "=============================================="
    echo "  Agent Base プロジェクト初期化"
    echo "=============================================="
    echo "  プロジェクト: ${PROJECT_NAME}"
    echo "  ルート: ${PROJECT_ROOT}"
    echo "=============================================="
    echo ""

    create_directories
    bootstrap_project_id
    create_requirements_template
    create_project_context
    update_gitignore
    create_docs_template

    echo ""
    echo "=============================================="
    log_success "初期化が完了しました"
    echo "=============================================="
    echo ""
    echo "次のステップ:"
    echo "  1. .agent/requirements.md に要件を記載"
    echo "  2. .agent/PROJECT_CONTEXT.md を編集"
    echo "  3. ./setup/bootstrap.sh でセットアップを完了"
    echo ""
}

main "$@"
