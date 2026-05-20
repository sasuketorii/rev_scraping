#!/bin/bash
# ==============================================================================
# bootstrap.sh - エージェント駆動開発セットアップスクリプト
# ==============================================================================
# 用途: setup_rules.md の手順を自動化し、エージェント駆動開発環境を構築
#
# 使用法:
#   ./setup/bootstrap.sh [--check-only] [--skip-interactive]
#
# オプション:
#   --check-only       環境チェックのみ実行（変更なし）
#   --skip-interactive 対話的プロンプトをスキップ
#
# 実行内容:
#   1. 必要なCLIツールの確認
#   2. ディレクトリ構造の初期化（init-project.sh呼び出し）
#   3. 要件定義書の確認
#   4. 最初のExecPlan生成の案内
# ==============================================================================

set -euo pipefail

# カラー定義
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# ログ関数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# オプション
CHECK_ONLY=false
SKIP_INTERACTIVE=false

# オプション解析
while [[ $# -gt 0 ]]; do
    case $1 in
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --skip-interactive)
            SKIP_INTERACTIVE=true
            shift
            ;;
        *)
            log_error "不明なオプション: $1"
            exit 1
            ;;
    esac
done

# ==============================================================================
# Step 1: 必要なCLIツールの確認
# ==============================================================================
check_required_tools() {
    log_step "Step 1: 必要なツールを確認中..."

    local required_tools=("jq" "git")
    local optional_tools=("claude" "codex")
    local missing_required=()
    local missing_optional=()

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" &> /dev/null; then
            log_success "  $tool: インストール済み"
        else
            missing_required+=("$tool")
            log_error "  $tool: 見つかりません"
        fi
    done

    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" &> /dev/null; then
            log_success "  $tool: インストール済み"
        else
            missing_optional+=("$tool")
            log_warn "  $tool: 見つかりません（オプション）"
        fi
    done

    if [[ ${#missing_required[@]} -gt 0 ]]; then
        echo ""
        log_error "必須ツールが不足しています:"
        for tool in "${missing_required[@]}"; do
            echo "  - $tool"
        done
        echo ""
        echo "インストール方法:"
        echo "  jq:    brew install jq (macOS) / apt install jq (Linux)"
        echo "  git:   brew install git (macOS) / apt install git (Linux)"
        exit 1
    fi

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        echo ""
        log_warn "オプションツールが不足しています（エージェント駆動開発には必要）:"
        for tool in "${missing_optional[@]}"; do
            echo "  - $tool"
        done
        echo ""
        echo "インストール方法:"
        echo "  claude: npm install -g @anthropic-ai/claude-code"
        echo "  codex:  npm install -g @openai/codex"
    fi

    echo ""
}

# ==============================================================================
# Step 2: ディレクトリ構造の初期化
# ==============================================================================
initialize_directories() {
    log_step "Step 2: ディレクトリ構造を初期化中..."

    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_info "  --check-only: スキップ"
        return
    fi

    local init_script="${PROJECT_ROOT}/scripts/init-project.sh"

    if [[ -x "$init_script" ]]; then
        "$init_script"
    else
        log_warn "  init-project.sh が見つかりません。手動で実行してください。"
    fi

    echo ""
}

# ==============================================================================
# Step 3: 要件定義書の確認
# ==============================================================================
check_requirements() {
    log_step "Step 3: 要件定義書を確認中..."

    local requirements="${PROJECT_ROOT}/.agent/requirements.md"

    if [[ -f "$requirements" ]]; then
        log_success "  .agent/requirements.md: 存在します"

        # テンプレートのままかどうかチェック
        if grep -q "まだ要件が記載されていません" "$requirements" 2>/dev/null; then
            log_warn "  要件がまだ記載されていません"
            echo ""
            echo "  次のステップ:"
            echo "    1. .agent/requirements.md を編集して要件を記載"
            echo "    2. エージェントに ExecPlan 生成を依頼"
        else
            log_success "  要件が記載されています"
        fi
    else
        log_warn "  .agent/requirements.md: 見つかりません"
        echo ""
        echo "  作成方法:"
        echo "    ./scripts/init-project.sh を実行"
    fi

    echo ""
}

# ==============================================================================
# Step 4: プロジェクトコンテキストの確認
# ==============================================================================
check_project_context() {
    log_step "Step 4: プロジェクトコンテキストを確認中..."

    local context="${PROJECT_ROOT}/.agent/PROJECT_CONTEXT.md"

    if [[ -f "$context" ]]; then
        log_success "  .agent/PROJECT_CONTEXT.md: 存在します"

        # 技術スタックが記載されているかチェック
        if grep -q "<!-- 例:" "$context" 2>/dev/null; then
            log_warn "  技術スタックがまだ記載されていません"
            echo ""
            echo "  次のステップ:"
            echo "    .agent/PROJECT_CONTEXT.md を編集して技術スタックを記載"
        else
            log_success "  技術スタックが記載されています"
        fi
    else
        log_warn "  .agent/PROJECT_CONTEXT.md: 見つかりません"
    fi

    echo ""
}

# ==============================================================================
# Step 5: Codex設定の確認
# ==============================================================================
check_codex_config() {
    log_step "Step 5: Codex設定を確認中..."

    local config="${PROJECT_ROOT}/.codex/config.toml"

    if [[ -f "$config" ]]; then
        log_success "  .codex/config.toml: 存在します"

        # モデル設定を表示（grep未ヒット時もエラーにしない）
        local model
        model=$(grep "^model = " "$config" 2>/dev/null | cut -d'"' -f2 || true)
        local effort
        effort=$(grep "^model_reasoning_effort = " "$config" 2>/dev/null | cut -d'"' -f2 || true)

        if [[ -n "$model" ]]; then
            log_info "    モデル: $model"
        fi
        if [[ -n "$effort" ]]; then
            log_info "    推論努力: $effort"
        fi
    else
        log_warn "  .codex/config.toml: 見つかりません"
    fi

    echo ""
}

# ==============================================================================
# Step 5.5: Codexモデルポリシーの確認
# ==============================================================================
check_model_policy() {
    log_step "Step 5.5: Codexモデルポリシーを確認中..."

    local model_policy_script="${PROJECT_ROOT}/scripts/model-policy.sh"

    if [[ ! -x "$model_policy_script" ]]; then
        log_error "  scripts/model-policy.sh: 見つからないか実行できません"
        exit 1
    fi

    "$model_policy_script" validate >/dev/null
    log_success "  model-policy validate: PASS"

    "$model_policy_script" generate --check >/dev/null
    log_success "  model-policy generate --check: PASS"

    echo ""
}

# ==============================================================================
# Step 6: Claude設定の確認
# ==============================================================================
check_claude_config() {
    log_step "Step 6: Claude設定を確認中..."

    local settings="${PROJECT_ROOT}/.claude/settings.json"

    if [[ -f "$settings" ]]; then
        log_success "  .claude/settings.json: 存在します"

        # フック設定を確認
        if jq -e '.hooks.PostToolUse' "$settings" &>/dev/null; then
            log_success "  PostToolUseフック: 設定済み"
        else
            log_warn "  PostToolUseフック: 未設定"
        fi
    else
        log_warn "  .claude/settings.json: 見つかりません"
    fi

    echo ""
}

# ==============================================================================
# Step 7: 次のステップの案内
# ==============================================================================
show_next_steps() {
    log_step "Step 7: セットアップ完了"

    echo ""
    echo "=============================================="
    echo "  次のステップ"
    echo "=============================================="
    echo ""
    echo "1. 要件を記載:"
    echo "   vim .agent/requirements.md"
    echo ""
    echo "2. プロジェクトコンテキストを編集:"
    echo "   vim .agent/PROJECT_CONTEXT.md"
    echo ""
    echo "3. エージェントにExecPlan生成を依頼:"
    echo "   「.agent/requirements.md の要件を元に"
    echo "    .agent/active/plan_YYYYMMDD_*.md を生成して」"
    echo ""
    echo "4. オーケストレーターを実行:"
    echo "   ./.claude/commands/auto_orchestrate.sh \\"
    echo "     --plan .agent/active/plan_*.md \\"
    echo "     --phase impl \\"
    echo "     --run-coder"
    echo ""
    echo "=============================================="
}

# ==============================================================================
# メイン処理
# ==============================================================================
main() {
    echo ""
    echo "=============================================="
    echo "  Agent Base セットアップ"
    echo "=============================================="
    echo "  プロジェクト: $(basename "$PROJECT_ROOT")"
    echo "  モード: $(if $CHECK_ONLY; then echo 'チェックのみ'; else echo '通常'; fi)"
    echo "=============================================="
    echo ""

    check_required_tools
    initialize_directories
    check_requirements
    check_project_context
    check_codex_config
    check_model_policy
    check_claude_config

    if [[ "$CHECK_ONLY" != "true" ]]; then
        show_next_steps
    fi
}

main "$@"
