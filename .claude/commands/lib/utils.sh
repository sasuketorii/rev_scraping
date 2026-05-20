#!/usr/bin/env bash
# utils.sh - 共通ユーティリティ関数
# エージェント自動化システム用

set -euo pipefail

# カラー定義
if [[ -z "${COLOR_RED+x}" ]]; then readonly COLOR_RED='\033[0;31m'; fi
if [[ -z "${COLOR_YELLOW+x}" ]]; then readonly COLOR_YELLOW='\033[0;33m'; fi
if [[ -z "${COLOR_GREEN+x}" ]]; then readonly COLOR_GREEN='\033[0;32m'; fi
if [[ -z "${COLOR_BLUE+x}" ]]; then readonly COLOR_BLUE='\033[0;34m'; fi
if [[ -z "${COLOR_RESET+x}" ]]; then readonly COLOR_RESET='\033[0m'; fi

# ログレベル
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# ログ関数
log_info() {
  echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $(get_timestamp) $*" >&2
}

log_warn() {
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $(get_timestamp) $*" >&2
}

log_error() {
  echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $(get_timestamp) $*" >&2
}

log_success() {
  echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $(get_timestamp) $*" >&2
}

log_debug() {
  if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
    echo -e "[DEBUG] $(get_timestamp) $*" >&2
  fi
}

# 致命的エラーで終了
die() {
  log_error "$*"
  exit 1
}

# タイムスタンプ取得（ISO8601形式）
get_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ローカルタイムスタンプ
get_timestamp_local() {
  date +"%Y-%m-%d %H:%M:%S"
}

# UUID v4 生成（macOS/Linux互換）
generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -f /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    # フォールバック: /dev/urandom から UUID v4 準拠で生成
    # UUID v4 仕様: バージョンビット=4, バリアントビット=8/9/a/b
    # セキュリティ要件: /dev/urandom は必須（$RANDOM ベースのフォールバックは予測攻撃の対象となるため禁止）
    if [[ ! -r /dev/urandom ]]; then
      die "generate_uuid: /dev/urandom is not readable. Cryptographically secure random source is required."
    fi

    local hex
    hex=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
    if [[ ${#hex} -lt 32 ]]; then
      # od が失敗した場合、xxd で再試行
      hex=$(head -c 16 /dev/urandom | xxd -p 2>/dev/null | tr -d '\n')
    fi
    if [[ ${#hex} -lt 32 ]]; then
      # od/xxd 両方失敗した場合はエラー終了（非暗号学的フォールバックは使用しない）
      die "generate_uuid: Failed to read from /dev/urandom. Both 'od' and 'xxd' commands failed."
    fi
    # UUID v4 フォーマット: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
    # バージョンビット (13桁目) を '4' に設定
    # バリアントビット (17桁目) を '8', '9', 'a', 'b' のいずれかに設定
    local byte6="${hex:12:2}"
    local byte8="${hex:16:2}"
    # バージョン4を設定: 上位4ビットを0100に
    byte6=$(printf '%02x' $(( (0x$byte6 & 0x0f) | 0x40 )))
    # バリアントを設定: 上位2ビットを10に
    byte8=$(printf '%02x' $(( (0x$byte8 & 0x3f) | 0x80 )))

    printf '%s-%s-%s%s-%s%s-%s\n' \
      "${hex:0:8}" \
      "${hex:8:4}" \
      "${byte6}" "${hex:14:2}" \
      "${byte8}" "${hex:18:2}" \
      "${hex:20:12}"
  fi
}

# コマンド存在確認
ensure_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Required command not found: $cmd"
  fi
}

# ディレクトリ存在確認・作成
ensure_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" || die "Failed to create directory: $dir"
    log_debug "Created directory: $dir"
  fi
}

# ファイル存在確認
ensure_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    die "Required file not found: $file"
  fi
}

# ファイル存在チェック（エラーなし）
file_exists() {
  [[ -f "$1" ]]
}

# ディレクトリ存在チェック（エラーなし）
dir_exists() {
  [[ -d "$1" ]]
}

# 日付差分計算（秒）- macOS/Linux互換
date_diff_secs() {
  local ts1="$1"
  local ts2="$2"

  if date --version >/dev/null 2>&1; then
    # GNU date (Linux)
    local s1 s2
    s1=$(date -d "$ts1" +%s 2>/dev/null) || return 1
    s2=$(date -d "$ts2" +%s 2>/dev/null) || return 1
    echo $((s2 - s1))
  else
    # BSD date (macOS)
    local s1 s2
    s1=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts1" +%s 2>/dev/null) || return 1
    s2=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts2" +%s 2>/dev/null) || return 1
    echo $((s2 - s1))
  fi
}

# 経過時間を人間可読形式に変換
format_duration() {
  local secs="$1"
  local hours=$((secs / 3600))
  local mins=$(((secs % 3600) / 60))
  local s=$((secs % 60))

  if [[ $hours -gt 0 ]]; then
    printf "%dh %dm %ds" "$hours" "$mins" "$s"
  elif [[ $mins -gt 0 ]]; then
    printf "%dm %ds" "$mins" "$s"
  else
    printf "%ds" "$s"
  fi
}

# ファイルロック取得
lock_acquire() {
  local lock_file="$1"
  local timeout="${2:-30}"
  local elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    if mkdir "$lock_file" 2>/dev/null; then
      log_debug "Lock acquired: $lock_file"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  log_error "Failed to acquire lock after ${timeout}s: $lock_file"
  return 1
}

# ファイルロック解放
lock_release() {
  local lock_file="$1"
  if [[ -d "$lock_file" ]]; then
    rmdir "$lock_file" 2>/dev/null || true
    log_debug "Lock released: $lock_file"
  fi
}

# 安全な一時ファイル作成（TMPDIR 環境変数を尊重）
create_temp_file() {
  local prefix="${1:-tmp}"
  mktemp "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
}

# 安全な一時ディレクトリ作成（TMPDIR 環境変数を尊重）
create_temp_dir() {
  local prefix="${1:-tmp}"
  mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
}

# 注: json_escape(), json_get_simple() は未使用のため削除済み（セキュリティリスク回避）
# JSON操作はすべて jq 経由で安全に実行すること

# プログレスバー表示
show_progress() {
  local current="$1"
  local total="$2"
  local width="${3:-50}"

  # Guard against division by zero
  if [[ "$total" -eq 0 ]]; then
    printf "\r[%${width}s] %3d%%" "" 0
    return
  fi

  local percent=$((current * 100 / total))
  local filled=$((current * width / total))
  local empty=$((width - filled))

  printf "\r["
  printf "%${filled}s" | tr ' ' '#'
  printf "%${empty}s" | tr ' ' '-'
  printf "] %3d%%" "$percent"
}

# スピナー表示（バックグラウンド用）
start_spinner() {
  local message="${1:-Working}"
  local pid="$2"
  local spinchars='|/-\\'
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r%s %s" "$message" "${spinchars:i++%4:1}"
    sleep 0.1
  done
  printf "\r%s done\n" "$message"
}

# 安全な識別子検証（英数字、ハイフン、アンダースコア、ドットのみ許可）
# Usage: _validate_identifier <value> <name>
# Returns: 0 if valid, exits with error if invalid
_validate_identifier() {
  local value="$1"
  local name="$2"

  if [[ -z "$value" ]]; then
    die "$name cannot be empty"
  fi

  # 許可パターン: 英数字、ハイフン、アンダースコア、ドット
  local pattern='^[a-zA-Z0-9._-]+$'
  if [[ ! "$value" =~ $pattern ]]; then
    die "Invalid $name: '$value' (allowed: alphanumeric, hyphen, underscore, dot)"
  fi
}

# NOTE: create_prompt_file() は削除済み（resume 機能廃止のため）

# 最新の Codex セッションID を取得
# Usage: get_latest_codex_session [after_epoch]
# Args:
#   after_epoch: この UNIX epoch 以降に作成されたセッションのみを対象（オプション）
# Returns: session_id (stdout), empty if not found
# Note: ~/.codex/sessions/ から最新の rollout-*.jsonl を探し、UUIDを抽出
# Note: after_epoch を指定すると、並列実行時の誤紐付けリスクを軽減できる
get_latest_codex_session() {
  local after_epoch="${1:-0}"
  local sessions_dir="$HOME/.codex/sessions"

  if [[ ! -d "$sessions_dir" ]]; then
    return 1
  fi

  local latest_file=""

  if [[ "$after_epoch" -gt 0 ]]; then
    # 指定時刻以降に作成されたファイルのみを対象
    # macOS と Linux で -newermt の動作が異なるため、find + stat を使用
    local file
    while IFS= read -r file; do
      if [[ -n "$file" ]]; then
        local file_mtime
        if [[ "$(uname)" == "Darwin" ]]; then
          file_mtime=$(stat -f %m "$file" 2>/dev/null || echo 0)
        else
          file_mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
        fi
        if [[ "$file_mtime" -ge "$after_epoch" ]]; then
          # 最新のファイルを追跡
          if [[ -z "$latest_file" ]]; then
            latest_file="$file"
          else
            local latest_mtime
            if [[ "$(uname)" == "Darwin" ]]; then
              latest_mtime=$(stat -f %m "$latest_file" 2>/dev/null || echo 0)
            else
              latest_mtime=$(stat -c %Y "$latest_file" 2>/dev/null || echo 0)
            fi
            if [[ "$file_mtime" -gt "$latest_mtime" ]]; then
              latest_file="$file"
            fi
          fi
        fi
      fi
    done < <(find "$sessions_dir" -name "rollout-*.jsonl" -type f 2>/dev/null)
  else
    # 従来の動作: 最新のファイルを取得
    latest_file=$(find "$sessions_dir" -name "rollout-*.jsonl" -type f 2>/dev/null | sort -r | head -1)
  fi

  if [[ -z "$latest_file" ]]; then
    return 1
  fi

  # ファイル名から session_id を抽出
  # 形式: rollout-YYYY-MM-DDTHH-mm-ss-UUID.jsonl
  local filename
  filename=$(basename "$latest_file")

  # UUID部分を抽出 (ハイフン区切りの5セグメント: 8-4-4-4-12)
  local session_id
  session_id=$(echo "$filename" | sed 's/rollout-[0-9T-]*-\([0-9a-f-]*\)\.jsonl/\1/')

  if [[ -n "$session_id" && "$session_id" != "$filename" ]]; then
    echo "$session_id"
    return 0
  fi

  return 1
}

# 指数バックオフ付きリトライ
# Usage: retry_with_backoff <max_retries> <initial_delay_ms> <command> [args...]
# Args:
#   max_retries: 最大リトライ回数（数値）
#   initial_delay_ms: 初期遅延（ミリ秒）。リトライごとに2倍
#   command: 実行するコマンド
#   args: コマンドの引数
# Returns: 0 on success, 1 if all retries exhausted
# Example: retry_with_backoff 3 100 curl -s https://api.example.com/health
retry_with_backoff() {
  # 引数数を先にチェック（shift 前に検証）
  if [[ $# -lt 3 ]]; then
    log_error "retry_with_backoff: max_retries, initial_delay_ms, and command are required"
    return 1
  fi

  local max_retries="${1:-}"
  local initial_delay_ms="${2:-}"
  shift 2

  # max_retries が数値かチェック
  if ! [[ "$max_retries" =~ ^[0-9]+$ ]]; then
    log_error "retry_with_backoff: max_retries must be a positive integer, got '$max_retries'"
    return 1
  fi

  # initial_delay_ms が数値かチェック
  if ! [[ "$initial_delay_ms" =~ ^[0-9]+$ ]]; then
    log_error "retry_with_backoff: initial_delay_ms must be a positive integer, got '$initial_delay_ms'"
    return 1
  fi

  if [[ $# -eq 0 ]]; then
    log_error "retry_with_backoff: command is required"
    return 1
  fi

  # max_retries は「リトライ回数」なので、総試行回数 = max_retries + 1
  local max_attempts=$((max_retries + 1))
  local attempt=1
  local delay_ms="$initial_delay_ms"

  while [[ $attempt -le $max_attempts ]]; do
    # コマンド実行
    if "$@"; then
      return 0
    fi

    # 最後の試行で失敗した場合はリトライしない
    if [[ $attempt -eq $max_attempts ]]; then
      log_error "[RETRY] All $max_attempts attempts ($max_retries retries) failed for: $*"
      return 1
    fi

    log_warn "[RETRY] Attempt $attempt/$max_attempts failed, waiting ${delay_ms}ms..."

    # ミリ秒を秒に変換してスリープ
    # printf を使用（bc 不要、macOS/Linux互換）
    local delay_secs
    delay_secs=$(printf '%d.%03d' $((delay_ms / 1000)) $((delay_ms % 1000)))
    sleep "$delay_secs"

    # 次回の遅延を2倍に
    delay_ms=$((delay_ms * 2))
    attempt=$((attempt + 1))
  done

  return 1
}
