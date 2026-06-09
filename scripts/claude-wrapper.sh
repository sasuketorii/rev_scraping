#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Vendoring 防止 guard (shim warning より前に実行)
# shellcheck source=scripts/_canonical-guard.sh
source "${SCRIPT_DIR}/_canonical-guard.sh"
rev_harness_assert_canonical_root claude-wrapper
# shellcheck source=scripts/_outbound-deny.sh
source "${SCRIPT_DIR}/_outbound-deny.sh"
rev_harness_assert_no_cursor_parent "claude-wrapper"

# ---------------------------------------------------------------------------
# [DEPRECATED COMPATIBILITY SHIM]
# claude-wrapper.sh は 2026-06-15 Agent SDK billing 分離により
# default flow から除外されました (6/15 ±3日猶予)。
# 2026-06-15 〜 2026-07-14 の 30 日間は deprecated compatibility shim として
# passthrough 動作のみ提供します (実装変更なし、stderr に DEPRECATED warning)。
# 完全削除 or opt-in 化の判定は ~/.rev_harness/shim-hits.log の集計に基づき
# 2026-07-14 ゲートで実施。
# 詳細: docs/migration-agent-sdk-2026-06.md /
#       docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md
# ---------------------------------------------------------------------------
cat >&2 <<'__REV_SHIM_DEPRECATION__'
[DEPRECATED] scripts/claude-wrapper.sh: 2026-06-15 Agent SDK billing 分離により、default flow から除外されました (6/15 ±3日猶予)。Task tool / native subagent への移行を推奨。
2026-07-14 までは shim として動作 (passthrough)。
詳細: docs/agent-sdk-policy.md / docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md
__REV_SHIM_DEPRECATION__

# shim-hits.log への JSONL append (PII 排除・fail-open)
# shellcheck source=scripts/_shim-log.sh
if [[ -r "${SCRIPT_DIR}/_shim-log.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/_shim-log.sh"
  if declare -F shim_log_hit >/dev/null 2>&1; then
    # help is side-effect-free for deterministic I-5 parity; detect it only on a
    # STANDALONE --help/-h argument (identical to the parser's --help|-h) case),
    # so a non-help prompt that merely contains the substring still logs.
    _rev_is_help=false
    for _rev_arg in "$@"; do
      case "$_rev_arg" in
        --help|-h) _rev_is_help=true; break ;;
      esac
    done
    if [[ "$_rev_is_help" == false ]]; then
      shim_log_hit "task-tool" "$@" || true
    fi
    unset _rev_is_help _rev_arg
  fi
else
  echo "[shim-log] WARN: _shim-log.sh が見つかりません (continue)" >&2
fi
# ---------------------------------------------------------------------------

readonly WRAPPER_NAME="claude-wrapper"
readonly DEFAULT_MODEL="opus"
readonly DEFAULT_TIMEOUT=0
readonly DEFAULT_EFFORT="medium"
readonly DEFAULT_MODE="delegate-text"
readonly FIXED_PERMISSION_MODE="bypassPermissions"
readonly DELEGATION_NOTICE='[外部委譲モード] CLAUDE.mdの「外部委譲出力ルール」に厳密に従ってください。テキスト直出力のみ。ファイル操作禁止。前置き・後書き・コメント禁止。コンテンツ本文だけを出力してください。

---

'

log_info() { echo "[${WRAPPER_NAME}] INFO: $*" >&2; }
log_warn() { echo "[${WRAPPER_NAME}] WARN: $*" >&2; }
log_error() { echo "[${WRAPPER_NAME}] ERROR: $*" >&2; }

ensure_claude_cli() {
  if ! command -v claude >/dev/null 2>&1; then
    log_error "claude CLI not found in PATH"
    exit 1
  fi
}

resolve_model_alias() {
  case "${1:-}" in
    opus|sonnet) echo "$1" ;;
    *) return 1 ;;
  esac
}

validate_effort() {
  case "${1:-}" in
    low|medium|high|xhigh) echo "$1" ;;
    *) return 1 ;;
  esac
}

resolve_cli_effort() {
  case "${1:-}" in
    xhigh) echo "high" ;;
    low|medium|high) echo "$1" ;;
    *) return 1 ;;
  esac
}

validate_mode() {
  case "${1:-}" in
    delegate-text|orchestrator-full) echo "$1" ;;
    *) return 1 ;;
  esac
}

validate_implementation_workspace() {
  local input="$1"
  local path=""
  local current=""
  local part=""
  local -a parts=()

  [[ -n "$input" ]] || {
    log_error "--implementation-workspace にはパスが必要です"
    return 1
  }

  case "$input" in
    /*)
      case "$input" in
        "$PROJECT_ROOT"/workspace/*) path="${input#$PROJECT_ROOT/}" ;;
        "$PROJECT_ROOT"/.claude|"$PROJECT_ROOT"/.claude/*)
          log_error "implementation workspace must not be under .claude; use workspace/<task>: $input"
          return 1
          ;;
        *)
          log_error "implementation workspace must stay under repo-local workspace/<task>: $input"
          return 1
          ;;
      esac
      ;;
    *) path="$input" ;;
  esac

  case "$path" in
    workspace/*) ;;
    .claude|.claude/*)
      log_error "implementation workspace must not be under .claude; .claude/tmp is artifact-only. Use workspace/<task>: $path"
      return 1
      ;;
    *)
      log_error "implementation workspace must be workspace/<task>, not: $path"
      return 1
      ;;
  esac

  case "$path" in
    *"/../"*|*"/./"*|*/..|*/.|*//*)
      log_error "implementation workspace contains unsafe path components: $path"
      return 1
      ;;
  esac

  IFS='/' read -r -a parts <<< "$path"
  [[ "${#parts[@]}" -ge 2 && -n "${parts[1]}" ]] || {
    log_error "implementation workspace must name a task directory under workspace/: $path"
    return 1
  }

  current="$PROJECT_ROOT"
  for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || {
      log_error "implementation workspace contains unsafe path component: $path"
      return 1
    }
    current="$current/$part"
    if [[ -L "$current" ]]; then
      log_error "implementation workspace contains symlink component: $current"
      return 1
    fi
  done

  printf '%s\n' "$path"
}

is_truthy_flag_value() {
  case "${1:-}" in
    true|1|yes|on|"")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_falsey_flag_value() {
  case "${1:-}" in
    false|0|no|off)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

reject_bare_prefixed_value() {
  local option="$1"
  local value="$2"

  case "$value" in
    --bare*)
      log_error "$option の値に --bare* は指定できません: $value"
      exit 1
      ;;
  esac
}

is_boolean_flag_value() {
  case "${1:-}" in
    true|false|1|0|yes|no|on|off)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

generate_session_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi

  python3 - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
}

detect_timeout_cmd() {
  if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
  elif command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
  else
    TIMEOUT_CMD="perl"
  fi
}

settings_has_api_key_helper() {
  local source="$1"
  local path=""
  local trimmed=""

  if [[ -z "$source" ]]; then
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  trimmed="${source#"${source%%[![:space:]]*}"}"
  case "$trimmed" in
    \{*|\[*)
      printf '%s' "$source" | jq -e 'type == "object" and (.apiKeyHelper | type == "string" and length > 0)' >/dev/null 2>&1
      return $?
      ;;
  esac

  case "$source" in
    /*) path="$source" ;;
    *) path="$PROJECT_ROOT/$source" ;;
  esac
  [[ -f "$path" ]] || return 1
  jq -e 'type == "object" and (.apiKeyHelper | type == "string" and length > 0)' "$path" >/dev/null 2>&1
}

has_explicit_api_key_auth() {
  local source=""
  local home_settings=""

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    return 0
  fi

  for source in "${SETTINGS_SOURCES[@]}"; do
    settings_has_api_key_helper "$source" && return 0
  done

  settings_has_api_key_helper "$PROJECT_ROOT/.claude/settings.json" && return 0

  if [[ -n "${HOME:-}" ]]; then
    home_settings="$HOME/.claude/settings.json"
    settings_has_api_key_helper "$home_settings" && return 0
  fi

  return 1
}
detect_timeout_cmd

run_subscription_auth_guard() {
  local source=""
  local guard_args=("$PROJECT_ROOT/scripts/subscription-auth-guard.sh" check --provider claude)

  for source in "${SETTINGS_SOURCES[@]}"; do
    guard_args+=(--settings "$source")
  done

  bash "${guard_args[@]}" >&2
}

resolve_stderr_dir() {
  local root_input="$1"
  local session_id="$2"
  local tmp_root="$PROJECT_ROOT/.claude/tmp"
  local root=""
  local rel=""
  local current=""
  local part=""
  local -a parts=()
  local tmp_root_real=""
  local root_real=""

  case "$root_input" in
    /*) root="$root_input" ;;
    *) root="$PROJECT_ROOT/$root_input" ;;
  esac

  while [[ "$root" != "/" && "$root" == */ ]]; do
    root="${root%/}"
  done

  case "$root" in
    "$tmp_root"|"$tmp_root"/*) ;;
    *)
      log_error "CLAUDE_WRAPPER_STDERR_ROOT must stay inside repo-local .claude/tmp: $root"
      return 1
      ;;
  esac
  case "$root" in
    *"/../"*|*"/./"*|*/..|*/.)
      log_error "CLAUDE_WRAPPER_STDERR_ROOT contains unsafe path components: $root"
      return 1
      ;;
  esac

  mkdir -p "$tmp_root"
  tmp_root_real="$(cd "$tmp_root" && pwd -P)" || return 1
  rel="${root#$tmp_root}"
  rel="${rel#/}"
  current="$tmp_root"
  if [[ -n "$rel" ]]; then
    IFS='/' read -r -a parts <<< "$rel"
    for part in "${parts[@]}"; do
      [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || {
        log_error "CLAUDE_WRAPPER_STDERR_ROOT contains unsafe path components: $root"
        return 1
      }
      current="$current/$part"
      [[ ! -L "$current" ]] || {
        log_error "CLAUDE_WRAPPER_STDERR_ROOT contains symlink component: $current"
        return 1
      }
      if [[ -e "$current" && ! -d "$current" ]]; then
        log_error "CLAUDE_WRAPPER_STDERR_ROOT component is not a directory: $current"
        return 1
      fi
    done
  fi

  mkdir -p "$root"
  root_real="$(cd "$root" && pwd -P)" || return 1
  case "$root_real" in
    "$tmp_root_real"|"$tmp_root_real"/*) ;;
    *)
      log_error "CLAUDE_WRAPPER_STDERR_ROOT escapes repo-local .claude/tmp: $root"
      return 1
      ;;
  esac

  printf '%s/%s/stderr\n' "$root" "$session_id"
}

show_help() {
  printf '%s\n' \
    'Usage:' \
    '  claude-wrapper.sh --input <file> --output <file> [options]' \
    '  claude-wrapper.sh --output <file> "prompt" [options]' \
    '  claude-wrapper.sh --manual-session --resume <session-id> --output <file> [options] [prompt]' \
    '' \
    'Required:' \
    '  --output <file>          Output file path' \
    '' \
    'Input (one of):' \
    '  --input <file>           Read prompt from file' \
    '  "prompt"                 Direct prompt string' \
    '' \
    'Wrapper options:' \
    '  --model <opus|sonnet>    Model alias (default: opus)' \
    '  --effort <level>         Effort level: low|medium|high|xhigh (default: medium)' \
    '  --mode <mode>            Mode: delegate-text|orchestrator-full (default: delegate-text)' \
    '  --timeout <seconds>      Timeout in seconds (default: disabled, 0 disables)' \
    '  --implementation-workspace <workspace/task>' \
    '                            Writable target for delegated implementation work; must be under workspace/' \
    '  --resume <session-id>    Resume an existing session (manual TTY-only)' \
    '  --session-id <uuid>      Explicit session id for new/forked sessions' \
    '  --fork-session           Use with --resume to fork into a new session (manual TTY-only)' \
    '  --manual-session         Allow session continuation only from a real TTY' \
    '  --help                   Show this help message' \
    '' \
    'Safe passthrough options:' \
    '  --system-prompt <text>' \
    '  --append-system-prompt <text>' \
    '  --allowed-tools <tools>' \
    '  --disallowed-tools <tools>' \
    '  --tools <tools>' \
    '  --max-budget-usd <amount>' \
    '  --output-format <format>' \
    '  --add-dir <dir>' \
    '  --agent <agent>' \
    '  --agents <json>' \
    '  --mcp-config <configs>' \
    '  --settings <file-or-json>' \
    '  --strict-mcp-config' \
    '  --no-session-persistence' \
    '  --bare                  Rejected in subscription-only wrapper mode' \
    '' \
    'Fixed by wrapper:' \
    '  --print' \
    '  --permission-mode bypassPermissions' >&2
  exit 0
}

INPUT_FILE=""
OUTPUT_FILE=""
PROMPT=""
MODEL="$DEFAULT_MODEL"
EFFORT="$DEFAULT_EFFORT"
MODE="$DEFAULT_MODE"
TIMEOUT="$DEFAULT_TIMEOUT"
SESSION_ID=""
IMPLEMENTATION_WORKSPACE=""
RESUME_MODE=false
RESUME_SESSION_ID=""
FORK_SESSION=false
MANUAL_SESSION=false
MODEL_EXPLICIT=false
BARE_REQUESTED=false
PASSTHROUGH_ARGS=()
SETTINGS_SOURCES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      show_help
      ;;
    --input)
      [[ $# -ge 2 ]] || { log_error "--input にはファイルパスが必要です"; exit 1; }
      INPUT_FILE="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { log_error "--output にはファイルパスが必要です"; exit 1; }
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --resume)
      [[ $# -ge 2 ]] || { log_error "--resume にはセッションIDが必要です"; exit 1; }
      RESUME_MODE=true
      RESUME_SESSION_ID="$2"
      shift 2
      ;;
    --resume=*)
      RESUME_MODE=true
      RESUME_SESSION_ID="${1#--resume=}"
      [[ -n "$RESUME_SESSION_ID" ]] || { log_error "--resume にはセッションIDが必要です"; exit 1; }
      shift
      ;;
    --manual-session)
      MANUAL_SESSION=true
      shift
      ;;
    --manual-session=*)
      log_error "${1%%=*} は値付き指定をサポートしません。manual-only guard を回避しないでください"
      exit 1
      ;;
    --session-id)
      [[ $# -ge 2 ]] || { log_error "--session-id にはUUIDが必要です"; exit 1; }
      SESSION_ID="$2"
      shift 2
      ;;
    --fork-session)
      FORK_SESSION=true
      shift
      ;;
    --fork-session=*)
      log_error "${1%%=*} は値付き指定をサポートしません。自動経路では新規セッションを開始してください"
      exit 1
      ;;
    --continue-session|--continue)
      log_error "$1 は claude-wrapper ではサポートされません。自動経路では新規セッションを開始してください"
      exit 1
      ;;
    --continue-session=*|--continue=*)
      log_error "${1%%=*} は claude-wrapper ではサポートされません。自動経路では新規セッションを開始してください"
      exit 1
      ;;
    --model)
      [[ $# -ge 2 ]] || { log_error "--model には値が必要です"; exit 1; }
      MODEL="$2"
      MODEL_EXPLICIT=true
      shift 2
      ;;
    --effort)
      [[ $# -ge 2 ]] || { log_error "--effort には値が必要です"; exit 1; }
      EFFORT="$2"
      shift 2
      ;;
    --effort=*)
      EFFORT="${1#--effort=}"
      shift
      ;;
    --effort*)
      log_error "Unknown --effort option: $1"
      exit 1
      ;;
    --mode)
      [[ $# -ge 2 ]] || { log_error "--mode には値が必要です"; exit 1; }
      MODE="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || { log_error "--timeout には秒数が必要です"; exit 1; }
      TIMEOUT="$2"
      shift 2
      ;;
    --implementation-workspace)
      [[ $# -ge 2 ]] || { log_error "--implementation-workspace にはパスが必要です"; exit 1; }
      IMPLEMENTATION_WORKSPACE="$2"
      shift 2
      ;;
    --implementation-workspace=*)
      IMPLEMENTATION_WORKSPACE="${1#--implementation-workspace=}"
      shift
      ;;
    --permission-mode)
      log_warn "Blocked override attempt: --permission-mode ${2:-}"
      shift
      [[ $# -gt 0 && "$1" != --* ]] && shift
      ;;
    --permission-mode=*)
      log_warn "Blocked override attempt: $1"
      shift
      ;;
    --dangerously-skip-permissions|--allow-dangerously-skip-permissions)
      log_warn "Blocked unsafe option: $1"
      shift
      if [[ $# -gt 0 ]] && is_boolean_flag_value "$1"; then
        shift
      fi
      ;;
    --dangerously-skip-permissions=*|--allow-dangerously-skip-permissions=*)
      log_warn "Blocked unsafe option: $1"
      shift
      ;;
    --system-prompt|--append-system-prompt|--allowed-tools|--allowedTools|--disallowed-tools|--disallowedTools|--tools|--max-budget-usd|--output-format|--add-dir|--agent|--agents|--mcp-config)
      passthrough_option="$1"
      PASSTHROUGH_ARGS+=("$passthrough_option")
      shift
      if [[ $# -gt 0 ]]; then
        reject_bare_prefixed_value "$passthrough_option" "$1"
        PASSTHROUGH_ARGS+=("$1")
        shift
      fi
      ;;
    --system-prompt=*|--append-system-prompt=*|--allowed-tools=*|--allowedTools=*|--disallowed-tools=*|--disallowedTools=*|--tools=*|--max-budget-usd=*|--output-format=*|--add-dir=*|--agent=*|--agents=*|--mcp-config=*)
      passthrough_option="${1%%=*}"
      passthrough_value="${1#*=}"
      reject_bare_prefixed_value "$passthrough_option" "$passthrough_value"
      PASSTHROUGH_ARGS+=("$passthrough_option=$passthrough_value")
      shift
      ;;
    --settings)
      passthrough_option="$1"
      PASSTHROUGH_ARGS+=("$passthrough_option")
      shift
      if [[ $# -gt 0 ]]; then
        reject_bare_prefixed_value "$passthrough_option" "$1"
        SETTINGS_SOURCES+=("$1")
        PASSTHROUGH_ARGS+=("$1")
        shift
      fi
      ;;
    --settings=*)
      passthrough_option="${1%%=*}"
      passthrough_value="${1#*=}"
      reject_bare_prefixed_value "$passthrough_option" "$passthrough_value"
      SETTINGS_SOURCES+=("$passthrough_value")
      PASSTHROUGH_ARGS+=("$passthrough_option=$passthrough_value")
      shift
      ;;
    --strict-mcp-config|--no-session-persistence)
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --bare)
      BARE_REQUESTED=true
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    --bare=*)
      bare_value="${1#--bare=}"
      if is_truthy_flag_value "$bare_value"; then
        BARE_REQUESTED=true
        PASSTHROUGH_ARGS+=("--bare")
      elif is_falsey_flag_value "$bare_value"; then
        log_warn "Stripped disabled --bare alias: $1"
      else
        log_error "Unknown --bare value: $bare_value"
        exit 1
      fi
      shift
      ;;
    --bare*)
      log_error "Unknown --bare option: $1"
      exit 1
      ;;
    --*=--bare*)
      passthrough_option="${1%%=*}"
      passthrough_value="${1#*=}"
      log_error "$passthrough_option の値に --bare* は指定できません: $passthrough_value"
      exit 1
      ;;
    --*)
      log_warn "Unknown option forwarded: $1"
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    *)
      PROMPT="$1"
      shift
      ;;
  esac
done

if [[ -z "$OUTPUT_FILE" ]]; then
  log_error "--output は必須です"
  show_help
fi

if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  log_error "--timeout には数値を指定してください"
  exit 1
fi

if [[ "$FORK_SESSION" == true && "$RESUME_MODE" != true ]]; then
  log_error "--fork-session は --resume と一緒に使ってください"
  exit 1
fi

if [[ "$RESUME_MODE" == true ]]; then
  if [[ "$MANUAL_SESSION" != true ]]; then
    log_error "セッション継続は manual-only です。--manual-session を付けた実ターミナル実行だけ許可されます"
    exit 1
  fi

  if [[ ! -t 0 || ! -t 1 || ! -t 2 ]]; then
    log_error "セッション継続は real TTY が必要です。自動/オーケストレーション経路では新規セッションを開始してください"
    exit 1
  fi
fi

if [[ "$BARE_REQUESTED" == true ]]; then
  log_error "--bare は subscription-only wrapper mode では禁止です。Claude.ai OAuth/keychain 認証を読まず API-key/helper 認証に依存するため、--bare を省き、--no-session-persistence と明示 tools/budget を使ってください"
  exit 1
fi

if [[ -n "$INPUT_FILE" && ! -f "$INPUT_FILE" ]]; then
  log_error "入力ファイルが見つかりません: $INPUT_FILE"
  exit 1
fi

if [[ "$RESUME_MODE" == false && -z "$INPUT_FILE" && -z "$PROMPT" ]]; then
  log_error "プロンプトが指定されていません。--input か引数で指定してください"
  show_help
fi

REQUESTED_MODEL="$MODEL"
MODEL_ID="$(resolve_model_alias "$REQUESTED_MODEL")" || {
  log_error "無効なモデル: ${MODEL}（有効な値: opus, sonnet）"
  exit 1
}

REQUESTED_EFFORT="$EFFORT"
EFFORT="$(validate_effort "$REQUESTED_EFFORT")" || {
  log_error "無効な effort: ${REQUESTED_EFFORT}（有効な値: low, medium, high, xhigh）"
  exit 1
}
CLI_EFFORT="$(resolve_cli_effort "$EFFORT")" || {
  log_error "無効な CLI effort 変換: ${EFFORT}"
  exit 1
}

MODE="$(validate_mode "$MODE")" || {
  log_error "無効な mode: ${MODE}（有効な値: delegate-text, orchestrator-full）"
  exit 1
}

if [[ -n "$IMPLEMENTATION_WORKSPACE" ]]; then
  IMPLEMENTATION_WORKSPACE="$(validate_implementation_workspace "$IMPLEMENTATION_WORKSPACE")" || exit 1
fi

run_subscription_auth_guard

if [[ "$RESUME_MODE" == true && "$MODEL_EXPLICIT" == true ]]; then
  log_warn "--resume 時は --model を無視します"
fi

if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID="$(generate_session_id)"
fi

ensure_claude_cli

TMPPROMPT="$(mktemp)"
cleanup_tmp_prompt() {
  /bin/rm -f "$TMPPROMPT"
}

{
  if [[ "$MODE" == "delegate-text" ]]; then
    printf '%s' "$DELEGATION_NOTICE"
  fi
  if [[ -n "$IMPLEMENTATION_WORKSPACE" ]]; then
    printf 'Implementation workspace: `%s`. Write/Edit implementation files only under this workspace. `.claude/tmp/**` is for orchestration artifacts only, not implementation files.\n\n' "$IMPLEMENTATION_WORKSPACE"
  fi
  if [[ -n "$INPUT_FILE" ]]; then
    cat "$INPUT_FILE"
  elif [[ -n "$PROMPT" ]]; then
    printf '%s' "$PROMPT"
  else
    printf '続行してください。'
  fi
} > "$TMPPROMPT"

CMD=(claude --print --permission-mode "$FIXED_PERMISSION_MODE" --effort "$CLI_EFFORT")

if [[ "$RESUME_MODE" == true ]]; then
  CMD+=(--resume "$RESUME_SESSION_ID")
  if [[ "$FORK_SESSION" == true ]]; then
    CMD+=(--fork-session --session-id "$SESSION_ID")
    log_info "セッション分岐: ${RESUME_SESSION_ID} -> ${SESSION_ID}"
  else
    log_info "セッション再開: ${RESUME_SESSION_ID}"
  fi
else
  CMD+=(--model "$MODEL_ID" --session-id "$SESSION_ID")
  log_info "新規セッション: ${SESSION_ID}"
fi

CMD+=("${PASSTHROUGH_ARGS[@]}")

log_info "モデル: ${MODEL_ID}"
if [[ "$CLI_EFFORT" != "$EFFORT" ]]; then
  log_info "Effort: ${EFFORT} (Claude CLI: ${CLI_EFFORT})"
else
  log_info "Effort: ${EFFORT}"
fi
log_info "Mode: ${MODE}"
if [[ -n "$IMPLEMENTATION_WORKSPACE" ]]; then
  log_info "Implementation Workspace: ${IMPLEMENTATION_WORKSPACE}"
fi
log_info "Permission Mode: ${FIXED_PERMISSION_MODE}"
TIMEOUT_WRAPPER_ACTIVE=false
if [[ "$TIMEOUT" -gt 0 ]]; then
  TIMEOUT_WRAPPER_ACTIVE=true
  log_info "タイムアウト: ${TIMEOUT}秒"
else
  log_info "タイムアウト: 無効"
fi
log_info "出力: ${OUTPUT_FILE}"

if [[ "$TIMEOUT_WRAPPER_ACTIVE" == true ]]; then
  if [[ "$TIMEOUT_CMD" == "perl" ]]; then
    EXEC_CMD=(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "${CMD[@]}")
  else
    EXEC_CMD=("$TIMEOUT_CMD" "$TIMEOUT" "${CMD[@]}")
  fi
else
  EXEC_CMD=("${CMD[@]}")
fi

STDERR_ROOT="${CLAUDE_WRAPPER_STDERR_ROOT:-.claude/tmp/wrapper-stderr}"
STDERR_DIR="$(resolve_stderr_dir "$STDERR_ROOT" "$SESSION_ID")" || exit 1
mkdir -p "$STDERR_DIR"
STDERR_LOG="$STDERR_DIR/claude-wrapper.stderr.txt"
STDERR_POINTER="${OUTPUT_FILE}.stderr-pointer.txt"

set +e
"${EXEC_CMD[@]}" < "$TMPPROMPT" > "$OUTPUT_FILE" 2>"$STDERR_LOG"
EXIT_CODE=$?
set -e

if [[ -s "$STDERR_LOG" ]]; then
  {
    printf 'schema_version=artifact-lifecycle/stderr-pointer/v1\n'
    printf 'producer=scripts/claude-wrapper.sh\n'
    printf 'session_id=%s\n' "$SESSION_ID"
    printf 'stderr_path=%s\n' "$STDERR_LOG"
  } > "$STDERR_POINTER"
  log_warn "stderr 出力を検出: ${STDERR_LOG} (pointer: ${STDERR_POINTER})"
else
  /bin/rm -f "$STDERR_LOG"
  /bin/rm -f "$STDERR_POINTER" 2>/dev/null || true
fi

if [[ $EXIT_CODE -ne 0 ]]; then
  if [[ "$TIMEOUT_WRAPPER_ACTIVE" == true && ( $EXIT_CODE -eq 124 || $EXIT_CODE -eq 142 ) ]]; then
    log_error "タイムアウト (${TIMEOUT}秒) で中断されました"
  else
    log_error "claude --print が異常終了しました (exit code: ${EXIT_CODE})"
  fi
  cleanup_tmp_prompt
  exit "$EXIT_CODE"
fi

if [[ ! -s "$OUTPUT_FILE" ]]; then
  log_error "出力が空です: ${OUTPUT_FILE}"
  cleanup_tmp_prompt
  exit 1
fi

LINE_COUNT="$(wc -l < "$OUTPUT_FILE")"
if [[ "$LINE_COUNT" -lt 1 ]]; then
  log_warn "出力が短すぎる可能性があります (${LINE_COUNT}行): ${OUTPUT_FILE}"
fi

log_info "完了: ${OUTPUT_FILE} ($(wc -c < "$OUTPUT_FILE") bytes, ${LINE_COUNT} lines)"
cleanup_tmp_prompt
exit 0
