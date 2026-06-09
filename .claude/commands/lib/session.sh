#!/usr/bin/env bash
# session.sh - Claude CLI セッション管理
# エージェント自動化システム用
#
# 依存: utils.sh, state.sh, timeout.sh が先に読み込まれていること
# 依存: claude CLI, jq

# セッション設定
SESSION_TIMEOUT="${SESSION_TIMEOUT:-1800}"  # 30分（デフォルト）
CLAUDE_CODE_EFFORT_LEVEL_DEFAULT="${CLAUDE_CODE_EFFORT_LEVEL_DEFAULT:-medium}"
readonly CLAUDE_CODE_EFFORT_LEVEL_FALLBACK="medium"
_CLAUDE_THINKING_BUDGET_WARNED="${_CLAUDE_THINKING_BUDGET_WARNED:-0}"

# 現行 Claude Code CLI は --effort を使用する。
# 後方互換として CLAUDE_THINKING_BUDGET が残っている場合のみ effort に丸める。
_resolve_claude_default_effort_level() {
  local configured_default="${CLAUDE_CODE_EFFORT_LEVEL_DEFAULT:-$CLAUDE_CODE_EFFORT_LEVEL_FALLBACK}"
  case "$configured_default" in
    low|medium|high|xhigh)
      echo "$configured_default"
      ;;
    *)
      log_warn "Invalid CLAUDE_CODE_EFFORT_LEVEL_DEFAULT: $configured_default (must be low|medium|high|xhigh). Using default: $CLAUDE_CODE_EFFORT_LEVEL_FALLBACK"
      echo "$CLAUDE_CODE_EFFORT_LEVEL_FALLBACK"
      ;;
  esac
}

_validate_effort_level() {
  local effort="${1:-}"
  local fallback="${2:-$CLAUDE_CODE_EFFORT_LEVEL_FALLBACK}"
  case "$effort" in
    low|medium|high|xhigh)
      echo "$effort"
      ;;
    *)
      log_warn "Invalid CLAUDE_CODE_EFFORT_LEVEL: $effort (must be low|medium|high|xhigh). Using default: $fallback"
      echo "$fallback"
      ;;
  esac
}

_resolve_claude_effort_level() {
  local default_effort
  default_effort="$(_resolve_claude_default_effort_level)"

  if [[ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ]]; then
    _validate_effort_level "$CLAUDE_CODE_EFFORT_LEVEL" "$default_effort"
    return
  fi

  if [[ -n "${CLAUDE_THINKING_BUDGET:-}" ]]; then
    if [[ "${_CLAUDE_THINKING_BUDGET_WARNED:-0}" -eq 0 ]]; then
      log_warn "CLAUDE_THINKING_BUDGET is deprecated. Use CLAUDE_CODE_EFFORT_LEVEL instead."
      _CLAUDE_THINKING_BUDGET_WARNED=1
    fi

    if [[ "$CLAUDE_THINKING_BUDGET" =~ ^[0-9]+$ ]]; then
      if [[ "$CLAUDE_THINKING_BUDGET" -ge 10000 ]]; then
        echo "xhigh"
      elif [[ "$CLAUDE_THINKING_BUDGET" -ge 4000 ]]; then
        echo "high"
      elif [[ "$CLAUDE_THINKING_BUDGET" -ge 1000 ]]; then
        echo "medium"
      else
        echo "low"
      fi
      return
    fi

    log_warn "Invalid CLAUDE_THINKING_BUDGET: $CLAUDE_THINKING_BUDGET. Using default effort: $default_effort"
  fi

  echo "$default_effort"
}

# セッションID検証（セキュリティ強化版）
# Claude CLI のセッションIDは UUID 形式または類似のIDフォーマット
# Usage: _validate_session_id <session_id>
# Returns: 0 if valid, 1 if invalid
_validate_session_id() {
  local session_id="$1"

  if [[ -z "$session_id" ]]; then
    return 1
  fi

  # セッションIDの許可パターン（最小8文字で安全性向上）:
  # - UUID形式: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  # - 英数字とハイフン/アンダースコアの組み合わせ（8〜64文字）
  # Note: bash 3.x互換のため{m,n}量指定子を使わず、長さを別途チェック
  local len=${#session_id}
  if [[ $len -lt 8 || $len -gt 64 ]]; then
    return 1
  fi
  local pattern='^[a-zA-Z0-9_-]+$'
  if [[ "$session_id" =~ $pattern ]]; then
    return 0
  else
    return 1
  fi
}

# Claude wrapper 存在確認
CLAUDE_WRAPPER="${CLAUDE_WRAPPER:-}"
CODEX_WRAPPER_CODER_CANONICAL="${CODEX_WRAPPER_CODER_CANONICAL:-${CODEX_WRAPPER_HIGH:-}}"
_SESSION_LIB_DIR="${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
_SESSION_REPO_ROOT="${REPO_ROOT:-$(cd "$_SESSION_LIB_DIR/../../.." && pwd)}"
_SESSION_MODEL_IO_GUARD="${REV_HARNESS_MODEL_IO_GUARD:-${_SESSION_REPO_ROOT}/scripts/rev-harness-model-io-guard.sh}"

_session_model_io_quarantine_dir() {
  local repo_root=""
  repo_root="$(cd "$_SESSION_REPO_ROOT" && pwd -P 2>/dev/null)" || repo_root="$_SESSION_REPO_ROOT"
  printf '%s\n' "${repo_root}/.claude/tmp/call-invoke-guard/quarantine"
}

_session_guard_prompt_file() {
  local prompt_file="$1"
  local label="$2"

  if [[ -x "$_SESSION_MODEL_IO_GUARD" ]]; then
    bash "$_SESSION_MODEL_IO_GUARD" prompt-budget --file "$prompt_file" --label "$label" \
      --max-bytes "${REV_HARNESS_MODEL_IO_PROMPT_MAX_BYTES:-262144}" \
      --warn-bytes "${REV_HARNESS_MODEL_IO_PROMPT_WARN_BYTES:-196608}" || return 1
  fi
}

_session_write_sanitized_model_io_stub() {
  local output_file="$1"
  local label="$2"

  {
    printf '[ERROR] model I/O guard blocked unsafe output for %s.\n' "$label"
    printf 'See sanitized guard metadata under .claude/tmp/call-invoke-guard/.\n'
  } > "$output_file"
}

_session_scan_output_file() {
  local output_file="$1"
  local label="$2"

  if [[ -x "$_SESSION_MODEL_IO_GUARD" ]]; then
    if ! bash "$_SESSION_MODEL_IO_GUARD" scan-output --file "$output_file" --label "$label" --quarantine-dir "$(_session_model_io_quarantine_dir)"; then
      _session_write_sanitized_model_io_stub "$output_file" "$label"
      return 1
    fi
  fi
}

_session_resolve_canonical_wrapper_path() {
  local candidate="${1:-}"
  local wrapper_name="$2"
  local env_name="$3"
  local canonical_path="${_SESSION_REPO_ROOT}/scripts/${wrapper_name}"
  if [[ -z "$candidate" ]]; then
    printf '%s\n' "$canonical_path"
    return 0
  fi

  local candidate_dir=""
  candidate_dir="$(cd "$(dirname "$candidate")" && pwd -P 2>/dev/null)" || {
    die "${env_name} must resolve to canonical repo path: ${canonical_path}"
    return 1
  }

  local resolved_candidate="${candidate_dir}/$(basename "$candidate")"
  if [[ "$resolved_candidate" != "$canonical_path" ]]; then
    die "${env_name} must resolve to canonical repo path: ${canonical_path}"
    return 1
  fi

  printf '%s\n' "$canonical_path"
}

_ensure_claude_wrapper() {
  CLAUDE_WRAPPER="$(_session_resolve_canonical_wrapper_path "$CLAUDE_WRAPPER" "claude-wrapper.sh" "CLAUDE_WRAPPER")" || return 1

  if [[ ! -x "$CLAUDE_WRAPPER" ]]; then
    die "claude-wrapper.sh not found or not executable: $CLAUDE_WRAPPER"
  fi
}

_session_run_claude_wrapper() {
  local caller_name="$1"
  local prompt_prefix="$2"
  local output_prefix="$3"
  local failure_message="$4"
  local timeout_secs="$5"
  local prompt="$6"
  local output_file="${7:-}"
  shift 7

  _ensure_claude_wrapper || return 1

  local prompt_file=""
  local temp_output=""
  local target_output=""
  local effort_level=""

  prompt_file="$(create_temp_file "$prompt_prefix")"
  if [[ -z "$prompt_file" ]]; then
    log_error "${caller_name}: failed to create temp file for prompt"
    return 1
  fi

  if ! printf '%s' "$prompt" > "$prompt_file"; then
    /bin/rm -f "$prompt_file" 2>/dev/null
    die "${caller_name}: failed to write prompt file"
  fi
  if ! _session_guard_prompt_file "$prompt_file" "$caller_name"; then
    /bin/rm -f "$prompt_file" "$temp_output" 2>/dev/null
    log_error "${caller_name}: prompt budget guard blocked launch"
    return 1
  fi

  if [[ -n "$output_file" ]]; then
    target_output="$output_file"
  else
    temp_output="$(create_temp_file "$output_prefix")"
    target_output="$temp_output"
  fi

  effort_level="$(_resolve_claude_effort_level)"

  local wrapper_exit=0
  if "$CLAUDE_WRAPPER" "$@" \
    --mode orchestrator-full \
    --input "$prompt_file" \
    --output "$target_output" \
    --effort "$effort_level" \
    --timeout "$timeout_secs"; then
    :
  else
    wrapper_exit=$?
    if [[ -f "$target_output" ]]; then
      _session_scan_output_file "$target_output" "$caller_name" || true
    fi
    /bin/rm -f "$prompt_file" "$temp_output" 2>/dev/null
    log_error "$failure_message"
    return "$wrapper_exit"
  fi

  if ! _session_scan_output_file "$target_output" "$caller_name"; then
    /bin/rm -f "$prompt_file" "$temp_output" 2>/dev/null
    log_error "${caller_name}: output marker guard blocked promotion"
    return 1
  fi

  if [[ -z "$output_file" ]]; then
    cat "$target_output"
    /bin/rm -f "$temp_output" 2>/dev/null
  fi

  /bin/rm -f "$prompt_file" 2>/dev/null
  return 0
}

_generate_session_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    python3 - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
  fi
}

_deny_interactive_session_continuation() {
  local helper_name="$1"
  log_error "${helper_name}: interactive session continuation is disabled in orchestrated/automatic flow"
  log_error "${helper_name}: start a fresh session and carry forward the required context in the prompt instead"
  return 1
}

# 新規セッション開始
# Usage: session_start <prompt> [output_file]
# Returns: session_id（stdoutに出力）
# Note: 出力ファイルが指定されている場合、Claude の出力はそのファイルに保存される
# セキュリティ: セッションID取得失敗時はフォールバックせずエラーを返す
session_start() {
  local prompt="$1"
  local output_file="${2:-}"

  if [[ -z "$prompt" ]]; then
    die "session_start: prompt is required"
  fi

  local session_id=""
  session_id="$(_generate_session_id)"

  if ! _session_run_claude_wrapper \
    "session_start" \
    "claude_prompt" \
    "claude_output" \
    "Claude wrapper failed while starting session" \
    "$SESSION_TIMEOUT" \
    "$prompt" \
    "$output_file" \
    --session-id "$session_id"; then
    return 1
  fi

  log_info "Session started: $session_id"
  echo "$session_id"
}

# セッション継続（手動専用。オーケストレーションでは fail-closed）
# Usage: session_resume <session_id> <prompt> [output_file]
# Returns: 0 on success, 1 on failure
session_resume() {
  local session_id="$1"
  local prompt="$2"
  local output_file="${3:-}"

  if [[ -z "$session_id" ]]; then
    die "session_resume: session_id is required"
  fi

  if ! _validate_session_id "$session_id"; then
    die "session_resume: invalid session_id format: $session_id"
  fi

  if [[ -z "$prompt" ]]; then
    die "session_resume: prompt is required"
  fi

  _deny_interactive_session_continuation "session_resume" || return 1
}

# セッション分岐（手動専用。オーケストレーションでは fail-closed）
# Usage: session_fork <parent_session_id> <prompt> [output_file]
# Returns: new_session_id（stdoutに出力）
# セキュリティ: セッションID取得失敗時はフォールバックせずエラーを返す
session_fork() {
  local parent_session_id="$1"
  local prompt="$2"
  local output_file="${3:-}"

  if [[ -z "$parent_session_id" ]]; then
    die "session_fork: parent_session_id is required"
  fi

  if ! _validate_session_id "$parent_session_id"; then
    die "session_fork: invalid parent_session_id format: $parent_session_id"
  fi

  if [[ -z "$prompt" ]]; then
    die "session_fork: prompt is required"
  fi

  _deny_interactive_session_continuation "session_fork" || return 1
}

# セッションとの対話実行（タイムアウト付き）
# Usage: session_run_with_timeout <timeout_secs> <session_id> <prompt> [output_file]
# Returns: 0 on success, 124 on timeout, other on error
# セキュリティ:
#   - session_id は _validate_session_id() で検証済みであること
#   - プロンプトは一時ファイル経由で渡し、引数インジェクションを防止
#   - 引数終端 `--` を使用し、特殊文字で始まるパスの誤解釈を防止
session_run_with_timeout() {
  local timeout_secs="$1"
  local session_id="$2"
  local prompt="$3"
  local output_file="${4:-}"

  # セッションID検証（空文字/"new" 以外の場合は必須）
  if [[ -n "$session_id" && "$session_id" != "new" ]]; then
    if ! _validate_session_id "$session_id"; then
      log_error "session_run_with_timeout: invalid session_id format: $session_id"
      return 1
    fi
  fi

  local wrapper_args=()
  if [[ -z "$session_id" || "$session_id" == "new" ]]; then
    wrapper_args+=(--session-id "$(_generate_session_id)")
  else
    _deny_interactive_session_continuation "session_run_with_timeout" || return 1
  fi

  if ! _session_run_claude_wrapper \
    "session_run_with_timeout" \
    "session_prompt" \
    "session_output" \
    "Claude wrapper failed while running session" \
    "$timeout_secs" \
    "$prompt" \
    "$output_file" \
    "${wrapper_args[@]}"; then
    return 1
  fi

  return 0
}

# =====================================================
# Codex CLI セッション管理
# =====================================================

# Canonical codex-wrapper.sh のパス（Coder用: role=coder）
# CODEX_WRAPPER_HIGH は互換入力としてのみ受け付けるが、canonical path 以外は拒否する。

# Codex ラッパー存在確認（内部関数）
_ensure_coder_codex_wrapper() {
  CODEX_WRAPPER_CODER_CANONICAL="$(_session_resolve_canonical_wrapper_path "$CODEX_WRAPPER_CODER_CANONICAL" "codex-wrapper.sh" "CODEX_WRAPPER_CODER_CANONICAL")" || return 1

  if [[ ! -x "$CODEX_WRAPPER_CODER_CANONICAL" ]]; then
    die "Canonical codex-wrapper.sh not found or not executable: $CODEX_WRAPPER_CODER_CANONICAL"
  fi
}

# NOTE: _validate_codex_session_id() は削除済み（resume 機能廃止のため）

# Codex セッション開始（初回実行）
# Usage: codex_session_start <prompt_file> <output_file> [timeout_secs]
# Returns: session_id (stdout)
# Note: codex exec で実行し、最新のセッションIDを返す
codex_session_start() {
  local prompt_file="$1"
  local output_file="$2"
  local timeout_secs="${3:-7200}"  # デフォルト2時間

  if [[ -z "$prompt_file" || ! -f "$prompt_file" ]]; then
    log_error "codex_session_start: prompt_file not found: $prompt_file"
    return 1
  fi

  if [[ -z "$output_file" ]]; then
    log_error "codex_session_start: output_file is required"
    return 1
  fi

  _ensure_coder_codex_wrapper

  log_info "Starting Codex session..."
  if ! _session_guard_prompt_file "$prompt_file" "codex_session_start"; then
    log_error "codex_session_start: prompt budget guard blocked launch"
    return 1
  fi

  # セッションID誤紐付け防止: Codex実行前のepoch時刻を記録
  local start_epoch
  start_epoch=$(date +%s)

  # codex exec 実行
  local exit_code=0
  if timeout_run "$timeout_secs" "$CODEX_WRAPPER_CODER_CANONICAL" --role coder --stdin < "$prompt_file" > "$output_file" 2>&1; then
    log_info "Codex execution completed"
  else
    exit_code=$?
    log_warn "Codex execution returned: $exit_code"
  fi

  if [[ -f "$output_file" ]] && ! _session_scan_output_file "$output_file" "codex_session_start"; then
    return 1
  fi

  # 最新のセッションIDを取得（after_epochで実行開始以降のセッションのみ対象）
  local session_id
  session_id=$(get_latest_codex_session "$start_epoch")

  if [[ -n "$session_id" ]]; then
    log_info "Codex session: $session_id"
    echo "$session_id"
    return $exit_code
  else
    log_warn "Could not retrieve Codex session ID"
    return 1
  fi
}

# NOTE: codex_session_resume() は削除済み（TTY必須のためオーケストレーター経由では動作しない）
