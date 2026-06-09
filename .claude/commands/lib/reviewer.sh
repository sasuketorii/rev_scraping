#!/usr/bin/env bash
# reviewer.sh - Reviewer (Codex) 実行関数
# エージェント自動化システム用
#
# 依存: utils.sh, state.sh, timeout.sh が先に読み込まれていること
# 依存: codex CLI, jq

# レビュワー設定
REVIEWER_TIMEOUT="${REVIEWER_TIMEOUT:-7200}"  # 2時間（Codex xhigh用）
REVIEWER_PARALLEL_MAX="${REVIEWER_PARALLEL_MAX:-3}"  # 最大並列数
REVIEWER_DEFAULT_LIST="safety,perf,consistency"  # デフォルトレビュワー一覧
REVIEWER_DEP_ALERT_MAX="${REVIEWER_DEP_ALERT_MAX:-5}"
REVIEWER_PACKET_MAX_TOKENS="${REVIEWER_PACKET_MAX_TOKENS:-1200}"
REVIEWER_PACKET_MAX_TOKENS_SECURITY="${REVIEWER_PACKET_MAX_TOKENS_SECURITY:-2400}"
REVIEWER_PACKET_DIFF_CHAR_BUDGET="${REVIEWER_PACKET_DIFF_CHAR_BUDGET:-2200}"
REVIEWER_PACKET_SECTION_CHAR_BUDGET="${REVIEWER_PACKET_SECTION_CHAR_BUDGET:-700}"
REVIEWER_SECURITY_PINLIST_CHAR_BUDGET="${REVIEWER_SECURITY_PINLIST_CHAR_BUDGET:-500}"
REVIEWER_VULN_PATTERN_CHAR_BUDGET="${REVIEWER_VULN_PATTERN_CHAR_BUDGET:-650}"
REVIEWER_VULN_PATTERN_MAX_FILES="${REVIEWER_VULN_PATTERN_MAX_FILES:-12}"
REVIEWER_ARCH_CAPSULE_MIN_TOKENS="${REVIEWER_ARCH_CAPSULE_MIN_TOKENS:-30}"
REVIEWER_ARCH_CAPSULE_MAX_TOKENS="${REVIEWER_ARCH_CAPSULE_MAX_TOKENS:-50}"
REVIEWER_LAST_OUTPUT_STATUS=""
_REVIEWER_LIB_DIR="${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
_REVIEWER_REPO_ROOT="${REPO_ROOT:-$(cd "$_REVIEWER_LIB_DIR/../../.." && pwd)}"
_REVIEWER_MODEL_IO_GUARD="${REV_HARNESS_MODEL_IO_GUARD:-${_REVIEWER_REPO_ROOT}/scripts/rev-harness-model-io-guard.sh}"

_reviewer_model_io_quarantine_dir() {
  local repo_root=""
  repo_root="$(cd "$_REVIEWER_REPO_ROOT" && pwd -P 2>/dev/null)" || repo_root="$_REVIEWER_REPO_ROOT"
  printf '%s\n' "${repo_root}/.claude/tmp/call-invoke-guard/quarantine"
}

_reviewer_guard_prompt_file() {
  local prompt_file="$1"
  local label="$2"

  if [[ -x "$_REVIEWER_MODEL_IO_GUARD" ]]; then
    bash "$_REVIEWER_MODEL_IO_GUARD" prompt-budget --file "$prompt_file" --label "$label" \
      --max-bytes "${REV_HARNESS_MODEL_IO_PROMPT_MAX_BYTES:-262144}" \
      --warn-bytes "${REV_HARNESS_MODEL_IO_PROMPT_WARN_BYTES:-196608}" || return 1
  fi
}

_reviewer_scan_output_file() {
  local output_file="$1"
  local label="$2"

  if [[ -x "$_REVIEWER_MODEL_IO_GUARD" ]]; then
    bash "$_REVIEWER_MODEL_IO_GUARD" scan-output --file "$output_file" --label "$label" --quarantine-dir "$(_reviewer_model_io_quarantine_dir)" || return 1
  fi
}

# =====================================================
# 動的レビュワー選択
# =====================================================

# 利用可能なレビュワー一覧を取得
# Usage: reviewer_list_available
# Returns: カンマ区切りのレビュワー名一覧
reviewer_list_available() {
  local prompt_dir
  prompt_dir=$(_get_prompt_dir)

  local reviewers=()
  for f in "$prompt_dir"/reviewer_*.md; do
    if [[ -f "$f" ]]; then
      local name
      name=$(basename "$f" | sed 's/^reviewer_//' | sed 's/\.md$//')
      if _validate_reviewer_name "$name" 2>/dev/null; then
        reviewers+=("$name")
      fi
    fi
  done

  # カンマ区切りで返す
  local IFS=','
  echo "${reviewers[*]}"
}

# タスク内容を分析し、適切なレビュワーを動的に選択
# Usage: reviewer_select_dynamic <coder_output> [task_description]
# Returns: カンマ区切りのレビュワー名一覧 (stdout)
# Note: Codex/Claude に問い合わせてタスク内容に最適なレビュワーを選択
reviewer_select_dynamic() {
  local coder_output="$1"
  local task_description="${2:-}"

  if [[ -z "$coder_output" || ! -f "$coder_output" ]]; then
    log_warn "reviewer_select_dynamic: coder_output not found, using defaults"
    echo "$REVIEWER_DEFAULT_LIST"
    return
  fi

  # 利用可能なレビュワー一覧を取得
  local available
  available=$(reviewer_list_available)

  if [[ -z "$available" ]]; then
    log_warn "No reviewers available, using defaults"
    echo "$REVIEWER_DEFAULT_LIST"
    return
  fi

  # コード内容からヒューリスティックにレビュワーを選択
  # （将来的にはCodex/Claudeで分析可能）
  local selected=()
  local content
  content=$(cat "$coder_output" 2>/dev/null || true)

  # 常に基本レビュワーを含める
  selected+=("safety")

  # SQL/DB関連コードがあればsql_injectionレビュワーを追加
  if echo "$content" | grep -qiE '(SELECT|INSERT|UPDATE|DELETE|sql|database|query)'; then
    if echo "$available" | grep -q "sql_injection"; then
      selected+=("sql_injection")
    fi
  fi

  # パフォーマンス関連
  if echo "$content" | grep -qiE '(loop|iteration|cache|memory|performance|async|await)'; then
    selected+=("perf")
  fi

  # フロントエンド/UI関連
  if echo "$content" | grep -qiE '(component|render|style|css|html|jsx|tsx|vue)'; then
    if echo "$available" | grep -q "accessibility"; then
      selected+=("accessibility")
    fi
    selected+=("consistency")
  else
    # バックエンド/汎用の場合
    selected+=("consistency")
  fi

  # 認証/セキュリティ関連
  if echo "$content" | grep -qiE '(auth|login|password|token|jwt|session|cookie|credential)'; then
    if echo "$available" | grep -q "auth_security"; then
      selected+=("auth_security")
    fi
  fi

  # 重複を除去
  local unique_arr
  mapfile -t unique_arr < <(printf '%s\n' "${selected[@]}" | sort -u)

  # available との交差処理（存在しないレビュワーを除外）
  # available はカンマ区切り → 配列に変換
  local available_arr
  IFS=',' read -ra available_arr <<< "$available"

  local final_selected=()
  for sel in "${unique_arr[@]}"; do
    for avail in "${available_arr[@]}"; do
      if [[ "$sel" == "$avail" ]]; then
        final_selected+=("$sel")
        break
      fi
    done
  done

  # 交差後に空になった場合はデフォルトにフォールバック
  if [[ ${#final_selected[@]} -eq 0 ]]; then
    log_warn "Dynamic selection resulted in no valid reviewers, using defaults"
    echo "$REVIEWER_DEFAULT_LIST"
    return
  fi

  local result
  result=$(IFS=','; echo "${final_selected[*]}")

  log_info "Dynamic reviewer selection: $result (from candidates: $(IFS=','; echo "${unique_arr[*]}"))"
  echo "$result"
}

# レビュワー名検証（パストラバーサル/インジェクション防止）
# Usage: _validate_reviewer_name <name>
# Returns: 0 if valid, 1 if invalid (exits on invalid)
_validate_reviewer_name() {
  local name="$1"

  if [[ -z "$name" ]]; then
    log_error "Reviewer name cannot be empty"
    return 1
  fi

  # 許可パターン: 英数字、ハイフン、アンダースコアのみ（1-50文字）
  # Note: bash 3.x互換のため{m,n}量指定子を使わず、長さを別途チェック
  local len=${#name}
  if [[ $len -lt 1 || $len -gt 50 ]]; then
    log_error "Invalid reviewer name: '$name' (allowed: 1-50 chars)"
    return 1
  fi

  local pattern='^[a-zA-Z0-9_-]+$'
  if [[ ! "$name" =~ $pattern ]]; then
    log_error "Invalid reviewer name: '$name' (allowed: alphanumeric, hyphen, underscore)"
    return 1
  fi

  # 追加チェック: パストラバーサル文字を明示的に拒否
  if [[ "$name" == *".."* ]] || [[ "$name" == *"/"* ]] || [[ "$name" == *"\\"* ]]; then
    log_error "Invalid reviewer name: '$name' contains path traversal characters"
    return 1
  fi

  return 0
}

# Canonical codex-wrapper.sh のパス（Reviewer用: role=reviewer）
# CODEX_WRAPPER_CANONICAL は互換入力としてのみ受け付けるが、
# canonical path 以外は fail-closed で拒否する。
CODEX_WRAPPER_CANONICAL="${CODEX_WRAPPER_CANONICAL:-}"
REVIEWER_CODEX_ROLE="${REVIEWER_CODEX_ROLE:-reviewer}"

_reviewer_scripts_dir() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  printf '%s\n' "$(cd "$script_dir/../../../scripts" && pwd -P)"
}

_reviewer_resolve_canonical_wrapper_path() {
  local candidate="${1:-}"
  local canonical_path=""

  canonical_path="$(_reviewer_scripts_dir)/codex-wrapper.sh"
  if [[ -z "$candidate" ]]; then
    printf '%s\n' "$canonical_path"
    return 0
  fi

  local candidate_dir=""
  candidate_dir="$(cd "$(dirname "$candidate")" && pwd -P 2>/dev/null)" || {
    die "CODEX_WRAPPER_CANONICAL must resolve to canonical repo path: ${canonical_path}"
    return 1
  }

  local resolved_candidate="${candidate_dir}/$(basename "$candidate")"
  if [[ "$resolved_candidate" != "$canonical_path" ]]; then
    die "CODEX_WRAPPER_CANONICAL must resolve to canonical repo path: ${canonical_path}"
    return 1
  fi

  printf '%s\n' "$canonical_path"
}

_reviewer_validate_codex_role() {
  local role="$1"

  if [[ "$role" != "reviewer" ]]; then
    log_error "Invalid Codex reviewer role: '$role' (must be reviewer)"
    return 1
  fi

  return 0
}

# Codex ラッパー存在確認
_ensure_codex_wrapper() {
  CODEX_WRAPPER_CANONICAL="$(_reviewer_resolve_canonical_wrapper_path "$CODEX_WRAPPER_CANONICAL")" || return 1

  if [[ ! -x "$CODEX_WRAPPER_CANONICAL" ]]; then
    die "Canonical codex-wrapper.sh not found or not executable: $CODEX_WRAPPER_CANONICAL"
  fi

  if ! _reviewer_validate_codex_role "$REVIEWER_CODEX_ROLE"; then
    die "Reviewer role resolution failed: ${REVIEWER_CODEX_ROLE:-<empty>}"
  fi
}

_reviewer_finalize_stderr_sidecar() {
  local stderr_capture="$1"
  local stderr_sidecar="$2"
  local log_label="$3"
  local repo_root=""
  local run_id=""
  local stderr_dir=""
  local stderr_file=""
  local pointer_file=""

  if [[ -s "$stderr_capture" ]]; then
    repo_root="$(_reviewer_repo_root)"
    run_id="$(date -u +%Y%m%dT%H%M%SZ)_$$"
    stderr_dir="$(_reviewer_resolve_stderr_dir "$repo_root" "$run_id")" || return 1
    mkdir -p "$stderr_dir"
    stderr_file="$stderr_dir/$(basename "${stderr_sidecar%.stderr.log}").stderr.txt"
    pointer_file="${stderr_sidecar%.stderr.log}.stderr-pointer.txt"
    cp "$stderr_capture" "$stderr_file"
    {
      printf 'schema_version=artifact-lifecycle/stderr-pointer/v1\n'
      printf 'producer=.claude/commands/lib/reviewer.sh\n'
      printf 'label=%s\n' "$log_label"
      printf 'stderr_path=%s\n' "$stderr_file"
    } > "$pointer_file"
    /bin/rm -f "$stderr_sidecar" 2>/dev/null || true
    log_warn "$log_label stderr captured: $stderr_file (pointer: $pointer_file)"
  else
    /bin/rm -f "$stderr_sidecar" 2>/dev/null || true
    /bin/rm -f "${stderr_sidecar%.stderr.log}.stderr-pointer.txt" 2>/dev/null || true
  fi
}

_reviewer_resolve_stderr_dir() {
  local repo_root="$1"
  local run_id="$2"
  local root="${REVIEWER_STDERR_ROOT:-$repo_root/.claude/tmp/reviewer-stderr}"
  local tmp_root="$repo_root/.claude/tmp"
  local tmp_root_real=""
  local root_real=""
  local rel=""
  local current=""
  local part=""
  local -a parts=()

  case "$root" in
    /*) ;;
    *) root="$repo_root/$root" ;;
  esac

  while [[ "$root" != "/" && "$root" == */ ]]; do
    root="${root%/}"
  done

  case "$root" in
    "$tmp_root"|"$tmp_root"/*) ;;
    *)
      log_error "REVIEWER_STDERR_ROOT must stay inside repo-local .claude/tmp: $root"
      return 1
      ;;
  esac
  case "$root" in
    *"/../"*|*"/./"*|*/..|*/.)
      log_error "REVIEWER_STDERR_ROOT contains unsafe path components: $root"
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
        log_error "REVIEWER_STDERR_ROOT contains unsafe path components: $root"
        return 1
      }
      current="$current/$part"
      [[ ! -L "$current" ]] || {
        log_error "REVIEWER_STDERR_ROOT contains symlink component: $current"
        return 1
      }
      if [[ -e "$current" && ! -d "$current" ]]; then
        log_error "REVIEWER_STDERR_ROOT component is not a directory: $current"
        return 1
      fi
    done
  fi

  mkdir -p "$root"
  root_real="$(cd "$root" && pwd -P)" || return 1
  case "$root_real" in
    "$tmp_root_real"|"$tmp_root_real"/*) ;;
    *)
      log_error "REVIEWER_STDERR_ROOT escapes repo-local .claude/tmp: $root"
      return 1
      ;;
  esac

  printf '%s/%s/stderr\n' "$root" "$run_id"
}

_reviewer_write_sanitized_stub() {
  local output_file="$1"
  local reason="${2:-reviewer output quarantined}"
  local compact_reason=""

  compact_reason=$(printf '%s' "$reason" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  {
    printf '[ERROR] %s\n' "$compact_reason"
    printf 'See sanitized guard metadata under .claude/tmp/call-invoke-guard/ when model I/O guard quarantine applies.\n'
  } > "$output_file"
}

_reviewer_quarantine_raw_stdout() {
  local raw_output="$1"
  local output_file="$2"
  local reason="$3"

  if [[ -f "$raw_output" && -s "$raw_output" ]]; then
    /bin/rm -f "$raw_output" 2>/dev/null || true
    log_warn "Reviewer stdout replaced with sanitized stub"
  else
    /bin/rm -f "$raw_output" 2>/dev/null || true
  fi

  _reviewer_write_sanitized_stub "$output_file" "$reason"
}

_reviewer_promote_validated_stdout() {
  local raw_output="$1"
  local output_file="$2"
  local log_label="$3"
  local invalid_reason="${4:-$log_label produced invalid reviewer output format}"

  REVIEWER_LAST_OUTPUT_STATUS=""

  if [[ ! -s "$raw_output" ]]; then
    REVIEWER_LAST_OUTPUT_STATUS="empty_output"
    _reviewer_quarantine_raw_stdout "$raw_output" "$output_file" "$log_label produced empty reviewer output"
    return 1
  fi

  if ! _reviewer_scan_output_file "$raw_output" "$log_label"; then
    REVIEWER_LAST_OUTPUT_STATUS="model_io_guard_block"
    _reviewer_quarantine_raw_stdout "$raw_output" "$output_file" "$log_label produced unsafe model I/O markers"
    return 1
  fi

  if ! validate_review_output_format "$raw_output"; then
    REVIEWER_LAST_OUTPUT_STATUS="invalid_format"
    _reviewer_quarantine_raw_stdout "$raw_output" "$output_file" "$invalid_reason"
    return 1
  fi

  mv "$raw_output" "$output_file"
  REVIEWER_LAST_OUTPUT_STATUS="valid"
  return 0
}

# プロンプトディレクトリ（呼び出し元で設定されていなければ推測）
_get_prompt_dir() {
  if [[ -n "${PROMPT_DIR:-}" ]]; then
    echo "$PROMPT_DIR"
    return
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "$(cd "$script_dir/../../../docs/prompts" && pwd)"
}

_reviewer_truthy() {
  local value="${1:-}"
  local normalized=""
  normalized=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  case "$normalized" in
    1|true|yes|y|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Token estimator (wc -c base):
# - English/ASCII: 1 token ~= 4 chars
# - Japanese/non-ASCII: 1 token ~= 1.5 chars
_reviewer_estimate_tokens() {
  local text="${1:-}"
  local total_bytes=0
  local ascii_bytes=0
  local non_ascii_bytes=0
  local non_ascii_chars=0

  total_bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
  ascii_bytes=$(printf '%s' "$text" | LC_ALL=C tr -cd '\000-\177' | wc -c | tr -d ' ')
  [[ -z "$total_bytes" ]] && total_bytes=0
  [[ -z "$ascii_bytes" ]] && ascii_bytes=0

  non_ascii_bytes=$((total_bytes - ascii_bytes))
  if [[ "$non_ascii_bytes" -lt 0 ]]; then
    non_ascii_bytes=0
  fi

  # UTF-8 Japanese chars are typically 3 bytes.
  non_ascii_chars=$(((non_ascii_bytes + 2) / 3))

  awk -v ascii="$ascii_bytes" -v non_ascii="$non_ascii_chars" '
    BEGIN {
      est = (ascii / 4.0) + (non_ascii / 1.5)
      if (est < 0) est = 0
      i = int(est)
      if (est > i) i = i + 1
      print i
    }
  '
}

_reviewer_truncate_chars() {
  local text="${1:-}"
  local max_chars="${2:-1200}"
  local suffix="${3-[truncated]}"

  if ! [[ "$max_chars" =~ ^[0-9]+$ ]] || [[ "$max_chars" -le 0 ]]; then
    max_chars=1200
  fi

  if [[ ${#text} -le "$max_chars" ]]; then
    printf '%s' "$text"
    return 0
  fi

  local marker=""
  if [[ -n "$suffix" ]]; then
    marker=$'\n'"$suffix"
  fi

  local keep=$((max_chars - ${#marker}))
  if [[ "$keep" -lt 0 ]]; then
    keep=0
    marker=""
  fi

  printf '%s%s' "${text:0:$keep}" "$marker"
}

_reviewer_truncate_to_token_budget() {
  local text="${1:-}"
  local token_budget="${2:-1200}"
  local suffix="${3-[truncated: reviewer packet token budget exceeded]}"

  if ! [[ "$token_budget" =~ ^[0-9]+$ ]] || [[ "$token_budget" -le 0 ]]; then
    token_budget=1200
  fi

  local estimated=0
  estimated=$(_reviewer_estimate_tokens "$text")
  if [[ "$estimated" -le "$token_budget" ]]; then
    printf '%s' "$text"
    return 0
  fi

  local marker=""
  if [[ -n "$suffix" ]]; then
    marker=$'\n'"$suffix"
  fi

  local left=0
  local right=${#text}
  local best="$text"

  while [[ "$left" -le "$right" ]]; do
    local mid=$(((left + right) / 2))
    local candidate="${text:0:$mid}"
    local candidate_with_marker="${candidate}${marker}"
    local cand_tokens=0
    cand_tokens=$(_reviewer_estimate_tokens "$candidate_with_marker")

    if [[ "$cand_tokens" -le "$token_budget" ]]; then
      best="$candidate_with_marker"
      left=$((mid + 1))
    else
      right=$((mid - 1))
    fi
  done

  printf '%s' "$best"
}

_reviewer_use_full_context() {
  local coder_output="${1:-}"

  if _reviewer_truthy "${REVIEW_FULL_CONTEXT:-}"; then
    return 0
  fi
  if _reviewer_truthy "${REVIEWER_FULL_CONTEXT:-}"; then
    return 0
  fi

  if [[ -n "${REVIEWER_FLAGS:-}" ]] && [[ "$REVIEWER_FLAGS" == *"--review-full-context"* ]]; then
    return 0
  fi

  if [[ -f "$coder_output" ]] && grep -qiE '^[[:space:]]*(--review-full-context|REVIEW_FULL_CONTEXT=(1|true|yes|y|on))[[:space:]]*$' "$coder_output" 2>/dev/null; then
    return 0
  fi

  return 1
}

_reviewer_path_matches_pattern() {
  local path="$1"
  local pattern="$2"

  local p="$path"
  local g="$pattern"
  p="${p#./}"
  g="${g#./}"

  shopt -s nocasematch
  # shellcheck disable=SC2053
  if [[ "$p" == $g ]]; then
    shopt -u nocasematch
    return 0
  fi
  shopt -u nocasematch

  local token=""
  for token in $(printf '%s' "$g" | tr '*./' ' '); do
    [[ ${#token} -lt 3 ]] && continue
    shopt -s nocasematch
    if [[ "$p" == *"$token"* ]]; then
      shopt -u nocasematch
      return 0
    fi
    shopt -u nocasematch
  done

  return 1
}

_reviewer_security_config_json() {
  local repo_root=""
  repo_root=$(_reviewer_repo_root)

  local config_path="${REVIEWER_SECURITY_CONFIG_FILE:-$repo_root/.agent/registry/security_critical.json}"
  if [[ -f "$config_path" ]]; then
    local parsed=""
    if parsed=$(jq -c '.' "$config_path" 2>/dev/null); then
      echo "$parsed"
      return 0
    fi
    log_warn "_reviewer_security_config_json: failed to parse $config_path, using default config"
  fi

  cat <<'EOF'
{"file_path_patterns":["**/auth/**","**/middleware/**","**/security/**","**/crypto/**","**/config/security*","**/config/auth*","**/guard/**","**/permission/**","**/rbac/**","**/acl/**","**/session/**","**/token/**","**/sanitize/**","**/validate/**"],"symbol_name_patterns":["authenticate*","authorize*","validateToken*","verifySignature*","hashPassword*","generateToken*","checkPermission*","sanitize*","escape*","encrypt*","decrypt*","sign*","verify*","rateLimit*"],"import_from_patterns":["bcrypt","jsonwebtoken","passport","helmet","cors","csurf","express-rate-limit","crypto"]}
EOF
}

_reviewer_detect_security_reviewer_mode() {
  local coder_output="$1"
  local output_dir="$2"
  local phase_for_state="$3"

  if _reviewer_truthy "${REVIEWER_SECURITY_REVIEWER_MODE:-}"; then
    echo "true|env.REVIEWER_SECURITY_REVIEWER_MODE"
    return 0
  fi

  local preflight_file="$output_dir/${phase_for_state}_coord_preflight.json"
  if [[ -f "$preflight_file" ]]; then
    local preflight_sensitive="false"
    preflight_sensitive=$(jq -r 'if (.security_sensitive // false) then "true" else "false" end' "$preflight_file" 2>/dev/null || echo "false")
    if [[ "$preflight_sensitive" == "true" ]]; then
      echo "true|preflight.security_sensitive"
      return 0
    fi
  fi

  if [[ -f "$coder_output" ]] && grep -qiE "[\"']?security[-_ ]sensitive[\"']?[[:space:]]*[:=][[:space:]]*[\"']?true[\"']?" "$coder_output" 2>/dev/null; then
    echo "true|coder_output.security_sensitive"
    return 0
  fi

  echo "false|none"
}

_reviewer_collect_security_pinlist() {
  local repo_root="$1"
  local changed_files_json="$2"
  local diff_impact_json="$3"
  local char_budget="${4:-$REVIEWER_SECURITY_PINLIST_CHAR_BUDGET}"

  local security_cfg_json=""
  security_cfg_json=$(_reviewer_security_config_json)

  local file_patterns=""
  file_patterns=$(jq -r '(.file_path_patterns // [])[]? | select(type == "string" and length > 0)' <<< "$security_cfg_json")
  local symbol_patterns=""
  symbol_patterns=$(jq -r '(.symbol_name_patterns // [])[]? | select(type == "string" and length > 0)' <<< "$security_cfg_json")
  local import_patterns=""
  import_patterns=$(jq -r '(.import_from_patterns // [])[]? | select(type == "string" and length > 0)' <<< "$security_cfg_json")

  local pins_tmp=""
  local sorted_tmp=""
  pins_tmp=$(create_temp_file "reviewer_security_pins")
  sorted_tmp=$(create_temp_file "reviewer_security_pins_sorted")
  : > "$pins_tmp"

  local changed_file=""
  while IFS= read -r changed_file; do
    [[ -n "$changed_file" ]] || continue
    local pattern=""
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] || continue
      if _reviewer_path_matches_pattern "$changed_file" "$pattern"; then
        printf 'file:%s\n' "$changed_file" >> "$pins_tmp"
        break
      fi
    done <<< "$file_patterns"
  done < <(jq -r '.[]? // empty' <<< "$changed_files_json")

  local changed_symbols_json='[]'
  changed_symbols_json=$(jq -c '.changed_symbols // []' <<< "$diff_impact_json" 2>/dev/null || echo '[]')

  local sym_id=""
  local sym_name=""
  while IFS=$'\t' read -r sym_id sym_name; do
    [[ -n "$sym_id" || -n "$sym_name" ]] || continue

    local matched="false"
    local sym_pattern=""
    while IFS= read -r sym_pattern; do
      [[ -n "$sym_pattern" ]] || continue
      shopt -s nocasematch
      # shellcheck disable=SC2053
      if [[ "$sym_id" == $sym_pattern || "$sym_name" == $sym_pattern ]]; then
        matched="true"
      fi
      shopt -u nocasematch
      if [[ "$matched" == "true" ]]; then
        break
      fi
    done <<< "$symbol_patterns"

    if [[ "$matched" == "true" ]] || grep -qiE '(auth|token|session|jwt|oauth|csrf|permission|rbac|acl|encrypt|decrypt|sanitize|validate|password|secret|credential|api[_-]?key)' <<< "$sym_id $sym_name"; then
      if [[ -n "$sym_id" ]]; then
        printf 'symbol:%s\n' "$sym_id" >> "$pins_tmp"
      else
        printf 'symbol:%s\n' "$sym_name" >> "$pins_tmp"
      fi
    fi
  done < <(jq -r '.[]? | [(.logical_id // .name // ""), (.name // .logical_id // "")] | @tsv' <<< "$changed_symbols_json")

  while IFS= read -r changed_file; do
    [[ -n "$changed_file" ]] || continue
    local abs_file="$repo_root/$changed_file"
    [[ -f "$abs_file" ]] || continue

    local import_pattern=""
    while IFS= read -r import_pattern; do
      [[ -n "$import_pattern" ]] || continue
      if grep -qFi "$import_pattern" "$abs_file" 2>/dev/null; then
        printf 'import:%s (%s)\n' "$changed_file" "$import_pattern" >> "$pins_tmp"
        break
      fi
    done <<< "$import_patterns"
  done < <(jq -r '.[]? // empty' <<< "$changed_files_json")

  sed '/^[[:space:]]*$/d' "$pins_tmp" | sort -u > "$sorted_tmp"
  local pin_count=0
  pin_count=$(wc -l < "$sorted_tmp" | tr -d ' ')

  local section="count=${pin_count}"
  if [[ "$pin_count" -gt 0 ]]; then
    local pin_lines=""
    pin_lines=$(sed -n '1,20p' "$sorted_tmp" | sed 's/^/- /')
    section="$section"$'\n'"$pin_lines"
  else
    section="$section"$'\n'"- (none detected)"
  fi

  /bin/rm -f "$pins_tmp" "$sorted_tmp"
  _reviewer_truncate_chars "$section" "$char_budget" "[truncated: security pin list]"
}

_reviewer_count_pattern_hits() {
  local regex="$1"
  local file="$2"
  local count=0

  count=$(grep -Eio "$regex" "$file" 2>/dev/null | wc -l | tr -d ' ')
  [[ -z "$count" ]] && count=0
  echo "$count"
}

_reviewer_collect_vulnerability_pattern_matches() {
  local repo_root="$1"
  local changed_files_json="$2"
  local diff_text="$3"
  local char_budget="${4:-$REVIEWER_VULN_PATTERN_CHAR_BUDGET}"

  local scan_tmp=""
  local findings_tmp=""
  scan_tmp=$(create_temp_file "reviewer_vuln_scan")
  findings_tmp=$(create_temp_file "reviewer_vuln_findings")
  : > "$scan_tmp"
  : > "$findings_tmp"

  printf '%s\n' "$diff_text" > "$scan_tmp"

  local max_files="$REVIEWER_VULN_PATTERN_MAX_FILES"
  if ! [[ "$max_files" =~ ^[0-9]+$ ]] || [[ "$max_files" -le 0 ]]; then
    max_files=12
  fi

  local scanned_files=0
  local changed_file=""
  while IFS= read -r changed_file; do
    [[ -n "$changed_file" ]] || continue
    local abs_file="$repo_root/$changed_file"
    [[ -f "$abs_file" ]] || continue
    {
      printf '\n# FILE: %s\n' "$changed_file"
      sed -n '1,180p' "$abs_file" 2>/dev/null || true
    } >> "$scan_tmp"
    scanned_files=$((scanned_files + 1))
    if [[ "$scanned_files" -ge "$max_files" ]]; then
      break
    fi
  done < <(jq -r '.[]? // empty' <<< "$changed_files_json")

  local hardcoded_secret_count=0
  hardcoded_secret_count=$(_reviewer_count_pattern_hits '(api[_-]?key|secret|password|private[_-]?key)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._/-]{8,}' "$scan_tmp")
  if [[ "$hardcoded_secret_count" -gt 0 ]]; then
    printf '%s\n' "- [Critical] hardcoded_secret_like count=$hardcoded_secret_count" >> "$findings_tmp"
  fi

  local sqli_count=0
  sqli_count=$(_reviewer_count_pattern_hits '(query|execute)[^[:cntrl:]]*(\+|\$\{|format\()|((SELECT|INSERT|UPDATE|DELETE)[^[:cntrl:]]*(\+|\$\{|format\()))' "$scan_tmp")
  if [[ "$sqli_count" -gt 0 ]]; then
    printf '%s\n' "- [High] sql_injection_like count=$sqli_count" >> "$findings_tmp"
  fi

  local cmdi_count=0
  cmdi_count=$(_reviewer_count_pattern_hits '(exec\(|os\.system\(|subprocess\.(Popen|run)\(|Runtime\.getRuntime\(\)\.exec\(|spawn\()[^[:cntrl:]]*(\+|\$\{|format\()' "$scan_tmp")
  if [[ "$cmdi_count" -gt 0 ]]; then
    printf '%s\n' "- [High] command_injection_like count=$cmdi_count" >> "$findings_tmp"
  fi

  local xss_count=0
  xss_count=$(_reviewer_count_pattern_hits '(dangerouslySetInnerHTML|innerHTML[[:space:]]*=|v-html|document\.write\()' "$scan_tmp")
  if [[ "$xss_count" -gt 0 ]]; then
    printf '%s\n' "- [High] xss_like count=$xss_count" >> "$findings_tmp"
  fi

  local path_traversal_count=0
  path_traversal_count=$(_reviewer_count_pattern_hits '(\.\./|path\.join\([^)]*(req\.|params|query|input)|read(File|FileSync)\([^)]*(req\.|params|query|input))' "$scan_tmp")
  if [[ "$path_traversal_count" -gt 0 ]]; then
    printf '%s\n' "- [High] path_traversal_like count=$path_traversal_count" >> "$findings_tmp"
  fi

  local ssrf_count=0
  ssrf_count=$(_reviewer_count_pattern_hits '(fetch\(|axios\.|http\.get\(|https\.get\(|request\()[^[:cntrl:]]*(req\.|params|query|input|url)' "$scan_tmp")
  if [[ "$ssrf_count" -gt 0 ]]; then
    printf '%s\n' "- [High] ssrf_like count=$ssrf_count" >> "$findings_tmp"
  fi

  local auth_bypass_count=0
  auth_bypass_count=$(_reviewer_count_pattern_hits '(skipAuth|disableAuth|ignoreExpiration|verify[[:space:]]*[:=][[:space:]]*false|auth[[:space:]]*[:=][[:space:]]*false)' "$scan_tmp")
  if [[ "$auth_bypass_count" -gt 0 ]]; then
    printf '%s\n' "- [High] auth_bypass_like count=$auth_bypass_count" >> "$findings_tmp"
  fi

  local weak_crypto_count=0
  weak_crypto_count=$(_reviewer_count_pattern_hits '(md5|sha1|Math\.random\(|createHash\([[:space:]]*"?md5|createHash\([[:space:]]*"?sha1)' "$scan_tmp")
  if [[ "$weak_crypto_count" -gt 0 ]]; then
    printf '%s\n' "- [Medium] weak_crypto_like count=$weak_crypto_count" >> "$findings_tmp"
  fi

  local section="scan_scope=diff+changed_files sampled_files=$scanned_files"
  if [[ -s "$findings_tmp" ]]; then
    section="$section"$'\n'"high_signal_matches=true"$'\n'"$(cat "$findings_tmp")"
  else
    section="$section"$'\n'"high_signal_matches=false"$'\n'"- (no obvious vulnerable pattern hits)"
  fi

  /bin/rm -f "$scan_tmp" "$findings_tmp"
  _reviewer_truncate_chars "$section" "$char_budget" "[truncated: vulnerability pattern matches]"
}

_reviewer_context_analysis_script() {
  local repo_root="$1"
  echo "$repo_root/.claude/commands/lib/context_analysis.sh"
}

_reviewer_extract_iteration_from_phase() {
  local phase_for_files="${1:-}"
  if [[ "$phase_for_files" =~ _iter([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  echo "0"
}

_reviewer_find_shadow_verify_json() {
  local output_dir="$1"
  local phase_for_state="$2"
  local phase_for_files="$3"

  local iter=0
  iter=$(_reviewer_extract_iteration_from_phase "$phase_for_files")
  if [[ "$iter" =~ ^[0-9]+$ ]] && [[ "$iter" -gt 0 ]]; then
    local exact_file="$output_dir/${phase_for_state}_shadow_verify_iter${iter}.json"
    if [[ -f "$exact_file" ]]; then
      echo "$exact_file"
      return 0
    fi
  fi

  local best_file=""
  local best_iter=-1
  shopt -s nullglob
  local candidates=("$output_dir"/"${phase_for_state}"_shadow_verify_iter*.json)
  shopt -u nullglob

  local f=""
  for f in "${candidates[@]}"; do
    local name
    name=$(basename "$f")
    if [[ "$name" =~ _iter([0-9]+)\.json$ ]]; then
      local f_iter="${BASH_REMATCH[1]}"
      if [[ "$f_iter" -gt "$best_iter" ]]; then
        best_iter="$f_iter"
        best_file="$f"
      fi
    fi
  done

  if [[ -n "$best_file" ]]; then
    echo "$best_file"
  fi
}

_reviewer_collect_shadow_verify_section() {
  local output_dir="$1"
  local phase_for_state="$2"
  local phase_for_files="$3"
  local char_budget="${4:-$REVIEWER_PACKET_SECTION_CHAR_BUDGET}"

  local shadow_json_file=""
  shadow_json_file=$(_reviewer_find_shadow_verify_json "$output_dir" "$phase_for_state" "$phase_for_files")

  if [[ -z "$shadow_json_file" || ! -f "$shadow_json_file" ]]; then
    printf '%s' "status=unavailable; note=shadow_verify_result_not_found"
    return 0
  fi

  local meta_line=""
  meta_line=$(jq -r '
    "status=" + (.status // "unknown")
    + "; iteration=" + ((.iteration // 0) | tostring)
    + "; lint=" + (.lint.status // "unknown")
    + "; typecheck=" + (.typecheck.status // "unknown")
    + "; test=" + (.test.status // "unknown")
    + "; quality_gate=" + (.quality_gate.status // "unknown")
    + "; sast=" + (.sast.status // "unknown")
    + "; sast_high=" + ((.sast.findings.high // 0) | tostring)
    + "; sast_critical=" + ((.sast.findings.critical // 0) | tostring)
    + "; changed_files=" + ((.changed_files_count // 0) | tostring)
    + "; selected_tests=" + ((.selected_tests_count // 0) | tostring)
  ' "$shadow_json_file" 2>/dev/null || echo "status=unknown")

  local diagnostics_path=""
  diagnostics_path=$(jq -r '.diagnostics // empty' "$shadow_json_file" 2>/dev/null || true)
  local diagnostics_status="none"
  local diagnostics_summary=""
  if [[ -n "$diagnostics_path" && -f "$diagnostics_path" ]]; then
    diagnostics_status="present"
  elif [[ -n "$diagnostics_path" ]]; then
    diagnostics_status="missing"
  fi

  diagnostics_summary="diagnostics_status=$diagnostics_status"
  if [[ -n "$diagnostics_path" ]]; then
    diagnostics_path=$(printf '%s' "$diagnostics_path" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
    diagnostics_path=$(_reviewer_truncate_chars "$diagnostics_path" 220 "")
    diagnostics_summary="$diagnostics_summary; diagnostics_path=$diagnostics_path"
  fi

  local section="$meta_line; $diagnostics_summary"

  _reviewer_truncate_chars "$section" "$char_budget" "[truncated: shadow verify diagnostics]"
}

_reviewer_collect_diff_text() {
  local repo_root="$1"
  local char_budget="${2:-$REVIEWER_PACKET_DIFF_CHAR_BUDGET}"

  local diff_text=""
  if (cd "$repo_root" && git rev-parse --verify HEAD >/dev/null 2>&1); then
    diff_text=$(cd "$repo_root" && git diff --no-color HEAD -- . 2>/dev/null || true)
  else
    diff_text=$(
      cd "$repo_root" && {
        git diff --no-color --cached -- . 2>/dev/null || true
        git diff --no-color -- . 2>/dev/null || true
      }
    )
  fi

  if [[ -z "$diff_text" ]] && (cd "$repo_root" && git rev-parse --verify HEAD~1 >/dev/null 2>&1); then
    diff_text=$(cd "$repo_root" && git diff --no-color HEAD~1 HEAD -- . 2>/dev/null || true)
  fi

  if [[ -z "$diff_text" ]]; then
    diff_text="# no git diff detected"
  fi

  _reviewer_truncate_chars "$diff_text" "$char_budget" "[truncated: diff snippet]"
}

_reviewer_collect_diff_impact_json() {
  local repo_root="$1"
  local context_analysis_sh=""
  context_analysis_sh=$(_reviewer_context_analysis_script "$repo_root")

  local output=""
  if declare -F context_diff_impact >/dev/null 2>&1; then
    output=$(context_diff_impact 2>/dev/null || true)
  elif [[ -f "$context_analysis_sh" ]]; then
    output=$(bash "$context_analysis_sh" diff-impact 2>/dev/null || true)
  fi

  if [[ -n "$output" ]] && jq -e '.changed_symbols and .impacted_symbols and .changed_files' <<< "$output" >/dev/null 2>&1; then
    echo "$output"
    return 0
  fi

  echo '{"changed_symbols":[],"impacted_symbols":[],"changed_files":[]}'
}

_reviewer_fallback_changed_symbols_json() {
  local repo_root="$1"
  local changed_files_json="$2"

  local symbol_meta_json='[]'
  symbol_meta_json=$(_reviewer_build_symbol_metadata_json "$repo_root")

  jq -nc \
    --argjson files "$changed_files_json" \
    --argjson symbols "$symbol_meta_json" \
    '
      [
        $symbols[]
        | select((.file // "") as $f | ($files | index($f)) != null)
        | {
            logical_id: (.logical_id // ""),
            file: (.file // ""),
            line: (.line // 0),
            name: (.name // "")
          }
      ]
      | unique_by(.logical_id)
      | .[:12]
    ' 2>/dev/null || echo '[]'
}

_reviewer_build_changed_symbols_section() {
  local repo_root="$1"
  local diff_impact_json="$2"
  local changed_files_json="$3"

  local changed_symbols_json='[]'
  changed_symbols_json=$(jq -c '.changed_symbols // []' <<< "$diff_impact_json" 2>/dev/null || echo '[]')
  local changed_count=0
  changed_count=$(jq 'length' <<< "$changed_symbols_json" 2>/dev/null || echo "0")

  if [[ "$changed_count" -eq 0 ]]; then
    changed_symbols_json=$(_reviewer_fallback_changed_symbols_json "$repo_root" "$changed_files_json")
  fi

  local lines=""
  lines=$(jq -r '
    if length == 0 then
      "- (none detected)"
    else
      .[:12]
      | map(
          "- "
          + ((.logical_id // .name // "unknown_symbol") | tostring)
          + " ("
          + ((.file // "unknown_file") | tostring)
          + ":"
          + (((.line // 0) | tonumber? // 0) | tostring)
          + ")"
        )
      | join("\n")
    end
  ' <<< "$changed_symbols_json" 2>/dev/null || echo "- (none detected)")

  _reviewer_truncate_chars "$lines" "$REVIEWER_PACKET_SECTION_CHAR_BUDGET" "[truncated: changed symbols]"
}

_reviewer_build_change_impact_graph() {
  local diff_impact_json="$1"
  local char_budget="${2:-$REVIEWER_PACKET_SECTION_CHAR_BUDGET}"

  local graph_text=""
  graph_text=$(jq -r '
    (.changed_symbols // []) as $changed
    | (.impacted_symbols // []) as $impacted
    | "method=context_diff_impact; changed_nodes=" + (($changed | length) | tostring) + "; impacted_nodes=" + (($impacted | length) | tostring)
      + "\nchanged_top="
      + (
          ($changed[:6] | map(.logical_id // .name // "unknown_symbol"))
          | if length == 0 then "none" else join(", ") end
        )
      + "\nimpacted_top="
      + (
          ($impacted[:8]
            | map(
                (.logical_id // .name // "unknown_symbol")
                + "@"
                + ((.impact_score // 0) | tostring)
              )
          )
          | if length == 0 then "none" else join(", ") end
        )
  ' <<< "$diff_impact_json" 2>/dev/null || echo "method=context_diff_impact; impacted_top=none")

  _reviewer_truncate_chars "$graph_text" "$char_budget" "[truncated: change impact graph]"
}

_reviewer_extract_delete_impacts_summary() {
  local output_dir="$1"
  local phase_for_state="$2"

  local preflight_file="$output_dir/${phase_for_state}_coord_preflight.json"
  if [[ -f "$preflight_file" ]]; then
    local summary=""
    summary=$(jq -r '.delete_impacts_summary // empty' "$preflight_file" 2>/dev/null || true)
    if [[ -n "$summary" ]]; then
      printf '%s' "$summary"
      return 0
    fi
  fi

  local capsule_file="$output_dir/${phase_for_state}_coord_capsule.json"
  if [[ -f "$capsule_file" ]]; then
    local summary_line=""
    summary_line=$(jq -r '.capsule // empty' "$capsule_file" 2>/dev/null | sed -n 's/^DELETE_IMPACTS=//p' | head -n 1 || true)
    if [[ -n "$summary_line" ]]; then
      printf '%s' "$summary_line"
      return 0
    fi
  fi

  printf '%s' "none"
}

_reviewer_build_architecture_convention_capsule() {
  local output_dir="$1"
  local phase_for_state="$2"
  local diff_impact_json="$3"
  local changed_files_json="$4"

  local policy="PASS"
  local context_mode="diff"
  local security_sensitive="false"
  local preflight_file="$output_dir/${phase_for_state}_coord_preflight.json"
  if [[ -f "$preflight_file" ]]; then
    policy=$(jq -r '.verdict // "PASS"' "$preflight_file" 2>/dev/null || echo "PASS")
    context_mode=$(jq -r '.context_mode // "diff"' "$preflight_file" 2>/dev/null || echo "diff")
    security_sensitive=$(jq -r '.security_sensitive // false' "$preflight_file" 2>/dev/null || echo "false")
  fi

  local changed_count=0
  changed_count=$(jq '(.changed_symbols // []) | length' <<< "$diff_impact_json" 2>/dev/null || echo "0")
  local impacted_count=0
  impacted_count=$(jq '(.impacted_symbols // []) | length' <<< "$diff_impact_json" 2>/dev/null || echo "0")

  local changed_files_top=""
  changed_files_top=$(jq -r '.[:4] | if length == 0 then "none" else join(", ") end' <<< "$changed_files_json" 2>/dev/null || echo "none")

  local capsule="Preserve existing module boundaries, naming conventions, and shell portability. Keep API and behavior stable outside changed scope; avoid unrelated refactors. policy=$policy context_mode=$context_mode security_sensitive=$security_sensitive changed_symbols=$changed_count impacted_symbols=$impacted_count changed_files=$changed_files_top."

  local min_tokens="$REVIEWER_ARCH_CAPSULE_MIN_TOKENS"
  local max_tokens="$REVIEWER_ARCH_CAPSULE_MAX_TOKENS"
  if ! [[ "$min_tokens" =~ ^[0-9]+$ ]]; then
    min_tokens=30
  fi
  if ! [[ "$max_tokens" =~ ^[0-9]+$ ]]; then
    max_tokens=50
  fi
  if [[ "$max_tokens" -lt "$min_tokens" ]]; then
    max_tokens="$min_tokens"
  fi

  local tokens=0
  tokens=$(_reviewer_estimate_tokens "$capsule")
  if [[ "$tokens" -lt "$min_tokens" ]]; then
    capsule="$capsule Keep logging/error format consistent and validate caller-side compatibility for renamed symbols."
  fi

  capsule=$(_reviewer_truncate_to_token_budget "$capsule" "$max_tokens" "")
  _reviewer_truncate_chars "$capsule" 240 ""
}

_reviewer_build_packet() {
  local coder_output="$1"
  local output_dir="$2"
  local phase_for_files="${3:-phase}"
  local phase_for_state="${4:-$phase_for_files}"

  if _reviewer_use_full_context "$coder_output"; then
    log_info "_reviewer_build_packet: full-context mode enabled (--review-full-context)"
    echo "$coder_output"
    return 0
  fi

  ensure_cmd jq
  ensure_cmd git

  local packet_budget="$REVIEWER_PACKET_MAX_TOKENS"
  if ! [[ "$packet_budget" =~ ^[0-9]+$ ]] || [[ "$packet_budget" -le 0 ]]; then
    packet_budget=1200
  fi

  local security_packet_budget="$REVIEWER_PACKET_MAX_TOKENS_SECURITY"
  if ! [[ "$security_packet_budget" =~ ^[0-9]+$ ]] || [[ "$security_packet_budget" -le 0 ]]; then
    security_packet_budget=2400
  fi

  local security_mode_meta=""
  security_mode_meta=$(_reviewer_detect_security_reviewer_mode "$coder_output" "$output_dir" "$phase_for_state")
  local security_reviewer_mode="${security_mode_meta%%|*}"
  local security_mode_reason="${security_mode_meta#*|}"
  if [[ -z "$security_reviewer_mode" ]]; then
    security_reviewer_mode="false"
  fi
  if [[ "$security_mode_reason" == "$security_mode_meta" ]]; then
    security_mode_reason="none"
  fi

  if [[ "$security_reviewer_mode" == "true" ]]; then
    packet_budget="$security_packet_budget"
  fi

  local repo_root=""
  repo_root=$(_reviewer_repo_root)

  local changed_files_json='[]'
  changed_files_json=$(_reviewer_collect_changed_files_json "$repo_root")

  local diff_impact_json='{"changed_symbols":[],"impacted_symbols":[],"changed_files":[]}'
  diff_impact_json=$(_reviewer_collect_diff_impact_json "$repo_root")
  if ! jq -e '.changed_symbols and .impacted_symbols and .changed_files' <<< "$diff_impact_json" >/dev/null 2>&1; then
    diff_impact_json='{"changed_symbols":[],"impacted_symbols":[],"changed_files":[]}'
  fi

  diff_impact_json=$(jq -nc \
    --argjson diff "$diff_impact_json" \
    --argjson changed "$changed_files_json" \
    '
      $diff
      | .changed_files = ([($diff.changed_files // [])[], $changed[]] | map(select(type=="string" and length > 0)) | unique)
    ' 2>/dev/null || echo "$diff_impact_json")

  changed_files_json=$(jq -c '.changed_files // []' <<< "$diff_impact_json" 2>/dev/null || echo "$changed_files_json")

  local changed_files_section=""
  changed_files_section=$(jq -r '
    if length == 0 then
      "- (none detected)"
    else
      .[:20] | map("- " + .) | join("\n")
    end
  ' <<< "$changed_files_json" 2>/dev/null || echo "- (none detected)")

  local changed_symbols_section=""
  changed_symbols_section=$(_reviewer_build_changed_symbols_section "$repo_root" "$diff_impact_json" "$changed_files_json")

  local change_impact_graph=""
  change_impact_graph=$(_reviewer_build_change_impact_graph "$diff_impact_json")

  local delete_impacts_summary=""
  delete_impacts_summary=$(_reviewer_extract_delete_impacts_summary "$output_dir" "$phase_for_state")
  delete_impacts_summary=$(_reviewer_truncate_chars "$delete_impacts_summary" 300 "[truncated: delete impacts summary]")

  local architecture_convention_capsule=""
  architecture_convention_capsule=$(_reviewer_build_architecture_convention_capsule "$output_dir" "$phase_for_state" "$diff_impact_json" "$changed_files_json")

  local shadow_verify_section=""
  shadow_verify_section=$(_reviewer_collect_shadow_verify_section "$output_dir" "$phase_for_state" "$phase_for_files")

  local diff_text=""
  diff_text=$(_reviewer_collect_diff_text "$repo_root" "$REVIEWER_PACKET_DIFF_CHAR_BUDGET")

  local security_pinlist_section="security_reviewer_mode=false"
  local vulnerability_pattern_section="security_reviewer_mode=false"
  if [[ "$security_reviewer_mode" == "true" ]]; then
    security_pinlist_section=$(_reviewer_collect_security_pinlist "$repo_root" "$changed_files_json" "$diff_impact_json" "$REVIEWER_SECURITY_PINLIST_CHAR_BUDGET")
    vulnerability_pattern_section=$(_reviewer_collect_vulnerability_pattern_matches "$repo_root" "$changed_files_json" "$diff_text" "$REVIEWER_VULN_PATTERN_CHAR_BUDGET")
  fi

  local coder_excerpt=""
  coder_excerpt=$(sed -n '1,80p' "$coder_output" 2>/dev/null || true)
  coder_excerpt=$(_reviewer_truncate_chars "$coder_excerpt" 420 "[truncated: coder excerpt]")

  local packet_content=""
  packet_content=$(
    printf '%s\n' \
      "# Reviewer Input Packet (diff-centered)" \
      "mode=diff-centered" \
      "token_budget=${packet_budget}" \
      "instruction=Use shadow verify diagnostics as reference. Do not rerun lint/typecheck/test from reviewer." \
      "security_reviewer_mode=${security_reviewer_mode}" \
      "security_reviewer_reason=${security_mode_reason}" \
      "" \
      "## architecture_convention_capsule" \
      "${architecture_convention_capsule}" \
      "" \
      "## delete_impacts_summary" \
      "${delete_impacts_summary}" \
      "" \
      "## change_impact_graph" \
      "${change_impact_graph}" \
      "" \
      "## shadow_verify_reference" \
      "${shadow_verify_section}" \
      "" \
      "## security_pinlist" \
      "${security_pinlist_section}" \
      "" \
      "## vulnerability_pattern_matches" \
      "${vulnerability_pattern_section}" \
      "" \
      "## changed_files" \
      "${changed_files_section}" \
      "" \
      "## changed_symbols" \
      "${changed_symbols_section}" \
      "" \
      "## diff" \
      '```diff' \
      "${diff_text}" \
      '```' \
      "" \
      "## coder_output_excerpt" \
      "${coder_excerpt}"
  )

  packet_content=$(_reviewer_truncate_to_token_budget "$packet_content" "$packet_budget" "[truncated: reviewer packet budget=${packet_budget}]")

  local packet_file=""
  packet_file=$(create_temp_file "reviewer_packet")
  printf '%s\n' "$packet_content" > "$packet_file"

  local packet_tokens=0
  packet_tokens=$(_reviewer_estimate_tokens "$packet_content")
  log_info "_reviewer_build_packet: mode=diff packet_tokens=$packet_tokens budget=$packet_budget security_reviewer_mode=$security_reviewer_mode reason=$security_mode_reason"

  echo "$packet_file"
}

# 単一レビュワー実行
# Usage: reviewer_run_single <reviewer_name> <coder_output> <output_file> [timeout_secs]
# Returns: 0 on success, 124 on timeout, 1 on error
# Note: codex resume は TTY 必須のため、常に新規セッションで実行
#       session_id/task_tmpdir パラメータは後方互換性のため受け取るが無視される
reviewer_run_single() {
  local reviewer_name="$1"
  local coder_output="$2"
  local output_file="$3"
  local timeout_secs="${4:-$REVIEWER_TIMEOUT}"
  # 後方互換性: session_id/task_tmpdir は受け取るが使用しない（codex resume は TTY 必須）
  # local session_id="${5:-}"
  # local task_tmpdir="${6:-}"

  if [[ -z "$reviewer_name" ]]; then
    log_error "reviewer_run_single: reviewer_name is required"
    return 1
  fi

  # セキュリティ: レビュワー名を検証
  if ! _validate_reviewer_name "$reviewer_name"; then
    return 1
  fi

  if [[ -z "$coder_output" || ! -f "$coder_output" ]]; then
    log_error "reviewer_run_single: coder_output not found: $coder_output"
    return 1
  fi

  if [[ -z "$output_file" ]]; then
    log_error "reviewer_run_single: output_file is required"
    return 1
  fi

  _ensure_codex_wrapper

  local prompt_dir
  prompt_dir=$(_get_prompt_dir)
  if [[ -z "$prompt_dir" || ! -d "$prompt_dir" ]]; then
    log_error "reviewer_run_single: prompt_dir not found: ${prompt_dir:-<empty>}"
    return 1
  fi
  local prompt_file="$prompt_dir/reviewer_${reviewer_name}.md"

  if [[ ! -f "$prompt_file" ]]; then
    log_warn "Reviewer prompt not found: $prompt_file (skip)"
    return 1
  fi

  # プロンプト内容を結合
  local combined_content
  local dependency_alert_section="${REVIEWER_DEP_ALERT_SECTION:-}"
  if [[ -n "$dependency_alert_section" ]]; then
    combined_content=$(
      {
        cat "$prompt_file"
        printf '\n%s\n\n' "$dependency_alert_section"
        cat "$coder_output"
      }
    )
  else
    combined_content=$(cat "$prompt_file" "$coder_output")
  fi

  local exit_code=0
  local stderr_capture=""
  local stderr_sidecar=""
  local stdout_capture=""

  # 常に新規セッションで実行（codex resume は TTY 必須のため使用不可）
  log_info "Running reviewer: $reviewer_name (codex_role: $REVIEWER_CODEX_ROLE, timeout: ${timeout_secs}s)"

  # 入力を一時ファイルに結合
  local combined_input
  combined_input=$(create_temp_file "review_input_${reviewer_name}")
  echo "$combined_content" > "$combined_input"
  if ! _reviewer_guard_prompt_file "$combined_input" "reviewer:$reviewer_name"; then
    /bin/rm -f "$combined_input" 2>/dev/null || true
    log_error "Reviewer prompt budget guard blocked launch: $reviewer_name"
    return 1
  fi
  stderr_capture=$(create_temp_file "review_stderr_${reviewer_name}")
  stdout_capture=$(create_temp_file "review_stdout_${reviewer_name}")
  stderr_sidecar="${output_file}.stderr.log"

  if timeout_run "$timeout_secs" "$CODEX_WRAPPER_CANONICAL" --role "$REVIEWER_CODEX_ROLE" --stdin < "$combined_input" > "$stdout_capture" 2> "$stderr_capture"; then
    if _reviewer_promote_validated_stdout "$stdout_capture" "$output_file" "Reviewer $reviewer_name"; then
      log_info "Reviewer $reviewer_name completed"
      exit_code=0
    else
      log_warn "Reviewer $reviewer_name produced quarantined stdout"
      exit_code=1
    fi
  else
    exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
      log_warn "Reviewer $reviewer_name timed out after ${timeout_secs}s"
      _reviewer_quarantine_raw_stdout "$stdout_capture" "$output_file" "Reviewer $reviewer_name timed out after ${timeout_secs}s"
    else
      log_warn "Reviewer $reviewer_name returned non-zero: $exit_code"
      _reviewer_quarantine_raw_stdout "$stdout_capture" "$output_file" "Reviewer $reviewer_name returned non-zero: $exit_code"
    fi
  fi

  _reviewer_finalize_stderr_sidecar "$stderr_capture" "$stderr_sidecar" "Reviewer $reviewer_name"

  /bin/rm -f "$combined_input" "$stderr_capture" "$stdout_capture"

  return $exit_code
}

# 並列レビュワー実行
# Usage: reviewer_run_parallel <reviewer_list> <coder_output> <output_dir> [timeout_secs] [phase_for_files] [task_tmpdir] [phase_for_state]
# Returns: 0 if all succeeded, number of failures otherwise
# Note: reviewer_list はカンマ区切り（例: "safety,perf,consistency"）
# Note: 各レビュワーの結果は <output_dir>/<phase_for_files>_review_<reviewer>.md に保存
# Note: task_tmpdir / phase_for_state は後方互換のため受け取るが、reviewer session は state に永続化しない
reviewer_run_parallel() {
  local reviewer_list="$1"
  local coder_output="$2"
  local output_dir="$3"
  local timeout_secs="${4:-$REVIEWER_TIMEOUT}"
  local phase_for_files="${5:-phase}"
  local task_tmpdir="${6:-}"
  local phase_for_state="${7:-$phase_for_files}"  # state.json 用フェーズ名（suffix なし）
  : "$task_tmpdir" "$phase_for_state"

  if [[ -z "$reviewer_list" ]]; then
    log_warn "reviewer_run_parallel: reviewer_list is empty"
    return 0
  fi

  if [[ -z "$coder_output" || ! -f "$coder_output" ]]; then
    log_error "reviewer_run_parallel: coder_output not found: $coder_output"
    return 1
  fi

  mkdir -p "$output_dir"

  _ensure_codex_wrapper

  local prompt_dir
  prompt_dir=$(_get_prompt_dir)
  if [[ -z "$prompt_dir" || ! -d "$prompt_dir" ]]; then
    log_error "reviewer_run_parallel: prompt_dir not found: ${prompt_dir:-<empty>}"
    return 1
  fi

  # レビュワーリストをパース
  IFS=',' read -ra reviewers <<<"$reviewer_list"
  local num_reviewers=${#reviewers[@]}

  if [[ $num_reviewers -eq 0 ]]; then
    log_warn "No reviewers specified"
    return 0
  fi

  log_info "Starting parallel review with $num_reviewers reviewers: ${reviewer_list}"

  local dependency_alert_section=""
  dependency_alert_section=$(_reviewer_build_out_of_window_dependency_alert "$coder_output")
  if [[ -n "$dependency_alert_section" ]]; then
    export REVIEWER_DEP_ALERT_SECTION="$dependency_alert_section"
    log_warn "reviewer_run_parallel: injected out-of-window dependency alert into reviewer input"
  else
    unset REVIEWER_DEP_ALERT_SECTION || true
  fi

  local review_input_file="$coder_output"
  local generated_packet_file=""
  if review_input_file=$(_reviewer_build_packet "$coder_output" "$output_dir" "$phase_for_files" "$phase_for_state"); then
    if [[ "$review_input_file" != "$coder_output" ]]; then
      generated_packet_file="$review_input_file"
    fi
  else
    log_warn "reviewer_run_parallel: packet build failed, fallback to full coder output"
    review_input_file="$coder_output"
  fi

  if [[ -z "$review_input_file" || ! -f "$review_input_file" ]]; then
    log_warn "reviewer_run_parallel: invalid review input file, fallback to full coder output"
    review_input_file="$coder_output"
    generated_packet_file=""
  fi

  # バックグラウンドジョブで並列実行
  local pids=()
  local outputs=()
  local names=()
  local stagger_idx=0  # 1秒スタガー用インデックス

  for r in "${reviewers[@]}"; do
    # セキュリティ: レビュワー名を検証
    if ! _validate_reviewer_name "$r"; then
      log_warn "Skipping invalid reviewer: $r"
      continue
    fi
    local prompt_file="$prompt_dir/reviewer_${r}.md"
    if [[ ! -f "$prompt_file" ]]; then
      log_warn "Reviewer prompt not found: $prompt_file (skip)"
      continue
    fi

    local outfile="$output_dir/${phase_for_files}_review_${r}.md"

    # 1秒スタガー起動で瞬間的なリソース衝突を抑える
    if [[ $stagger_idx -gt 0 ]]; then
      log_debug "Stagger delay: ${stagger_idx}s for reviewer $r"
      sleep "$stagger_idx"
    fi

    # バックグラウンドで実行
    # Note: ループ変数をサブシェル用に保存（レースコンディション対策）
    local _outfile="$outfile"
    local _reviewer="$r"
    local _timeout="$timeout_secs"
    local _coder_output="$review_input_file"
    (
      reviewer_run_single "$_reviewer" "$_coder_output" "$_outfile" "$_timeout"
    ) &

    pids+=($!)
    outputs+=("$outfile")
    names+=("$r")
    stagger_idx=$((stagger_idx + 1))  # 次のレビュワー用にインクリメント
  done

  # 全レビュワーの完了を待機
  local failures=0
  local i=0
  for pid in "${pids[@]}"; do
    # set -e 環境でも個別失敗を集計できるように wait を明示分岐で扱う
    local ret=0
    if wait "$pid"; then
      ret=0
    else
      ret=$?
    fi
    if [[ $ret -ne 0 ]]; then
      log_warn "Reviewer ${names[$i]} exited with code $ret"
      failures=$((failures + 1))
    fi

    i=$((i + 1))
  done

  if [[ -n "$generated_packet_file" && -f "$generated_packet_file" ]]; then
    /bin/rm -f "$generated_packet_file"
  fi

  log_info "Parallel review completed: ${#pids[@]} reviewers, $failures failures"
  return $failures
}

# レビュー結果集約
# Usage: reviewer_aggregate <output_dir> <phase> [output_file]
# Returns: path to aggregated file (stdout)
reviewer_aggregate() {
  local output_dir="$1"
  local phase="$2"
  local output_file="${3:-}"

  if [[ -z "$output_file" ]]; then
    output_file="$output_dir/${phase}_reviews.md"
  fi

  local tmp_output=""
  tmp_output=$(create_temp_file "review_aggregate")
  : > "$tmp_output"

  # レビューファイルを検索して集約
  local count=0
  for review_file in "$output_dir"/${phase}_review_*.md; do
    if [[ -f "$review_file" ]]; then
      local basename
      basename=$(basename "$review_file")
      if ! validate_review_output_format "$review_file"; then
        log_error "reviewer_aggregate: invalid review output format: $review_file"
        {
          printf '## %s\n' "$basename"
          printf '[ERROR] Review output quarantined before aggregation. Source: %s\n\n' "$review_file"
        } >> "$tmp_output"
        mv "$tmp_output" "$output_file"
        return 1
      fi
      echo "## $basename" >> "$tmp_output"
      cat "$review_file" >> "$tmp_output"
      echo "" >> "$tmp_output"
      count=$((count + 1))
    fi
  done

  mv "$tmp_output" "$output_file"

  log_info "Aggregated $count review files -> $output_file"
  echo "$output_file"
}

# ブロッカー（High重大度）検出
# Usage: reviewer_has_blockers <reviews_file>
# Returns: 0 if blockers found, 1 if not
reviewer_has_blockers() {
  local reviews_file="$1"

  if [[ -z "$reviews_file" || ! -f "$reviews_file" ]]; then
    return 1
  fi

  # [High] タグを検索（大文字小文字区別なし）
  if grep -qi '\[High\]' "$reviews_file" 2>/dev/null; then
    return 0
  fi

  return 1
}

# 重大度別カウント
# Usage: reviewer_count_by_severity <reviews_file>
# Returns: JSON object with counts (stdout)
# Example: {"high": 3, "medium": 5, "low": 2}
reviewer_count_by_severity() {
  local reviews_file="$1"

  if [[ -z "$reviews_file" || ! -f "$reviews_file" ]]; then
    echo '{"high": 0, "medium": 0, "low": 0}'
    return
  fi

  local high_count medium_count low_count

  # 大文字小文字を区別せずカウント
  high_count=$(grep -ci '\[High\]' "$reviews_file" 2>/dev/null || echo 0)
  medium_count=$(grep -ci '\[Medium\]' "$reviews_file" 2>/dev/null || echo 0)
  low_count=$(grep -ci '\[Low\]' "$reviews_file" 2>/dev/null || echo 0)

  # jq で安全にJSON生成
  jq -n \
    --argjson high "$high_count" \
    --argjson medium "$medium_count" \
    --argjson low "$low_count" \
    '{high: $high, medium: $medium, low: $low}'
}

# レビュー結果のサマリーを表示
# Usage: reviewer_show_summary <reviews_file>
reviewer_show_summary() {
  local reviews_file="$1"

  if [[ -z "$reviews_file" || ! -f "$reviews_file" ]]; then
    log_warn "Reviews file not found: $reviews_file"
    return 1
  fi

  local counts
  counts=$(reviewer_count_by_severity "$reviews_file")

  local high medium low
  high=$(echo "$counts" | jq -r '.high')
  medium=$(echo "$counts" | jq -r '.medium')
  low=$(echo "$counts" | jq -r '.low')

  echo "=== Review Summary ==="
  echo "File: $reviews_file"
  echo ""
  echo "Severity Counts:"
  echo "  [High]:   $high"
  echo "  [Medium]: $medium"
  echo "  [Low]:    $low"
  echo ""

  if [[ $high -gt 0 ]]; then
    echo "Status: BLOCKERS FOUND"
    return 0
  else
    echo "Status: PASS (no blockers)"
    return 0
  fi
}

# レビュー結果の durable payload は live state.json に記録しない
# Usage: reviewer_record_to_state <phase> <iteration> <reviews_file>
reviewer_record_to_state() {
  local phase="$1"
  local iteration="$2"
  local reviews_file="$3"

  if [[ -z "$phase" ]]; then
    log_warn "reviewer_record_to_state: phase is empty"
    return 1
  fi

  # セキュリティ: iteration が数値であることを検証
  if [[ ! "$iteration" =~ ^[0-9]+$ ]]; then
    log_warn "reviewer_record_to_state: invalid iteration: $iteration"
  fi

  if [[ -z "$reviews_file" || ! -f "$reviews_file" ]]; then
    log_warn "reviewer_record_to_state: reviews_file not found: $reviews_file"
    return 1
  fi

  log_debug "reviewer_record_to_state: durable reviewer payload removed from live state.json (phase: $phase, iteration: $iteration)"
  return 0
}

# 全レビュー実行（ワンショット関数）
# Usage: reviewer_run_all <reviewer_list> <coder_output> <output_dir> <phase> [suffix] [timeout_secs] [task_tmpdir]
# Returns: path to aggregated reviews file (stdout), exit code 0 on success, 1 if all reviewers failed
reviewer_run_all() {
  local reviewer_list="$1"
  local coder_output="$2"
  local output_dir="$3"
  local phase="$4"
  local suffix="${5:-}"
  local timeout_secs="${6:-$REVIEWER_TIMEOUT}"
  local task_tmpdir="${7:-$output_dir}"  # デフォルトは output_dir

  # 並列実行
  # phase_with_suffix: ファイル命名用（例: impl_iter2）
  # phase: state.json 用（例: impl）
  local phase_with_suffix="${phase}${suffix}"
  local failures=0
  reviewer_run_parallel "$reviewer_list" "$coder_output" "$output_dir" "$timeout_secs" "$phase_with_suffix" "$task_tmpdir" "$phase" || failures=$?

  # レビュワー数をカウント
  local num_reviewers
  IFS=',' read -ra _rev_array <<< "$reviewer_list"
  num_reviewers=${#_rev_array[@]}

  # 全レビュワーが失敗した場合はエラー
  if [[ $failures -ge $num_reviewers && $num_reviewers -gt 0 ]]; then
    log_error "All $num_reviewers reviewers failed"
    return 1
  fi

  if [[ $failures -gt 0 ]]; then
    log_warn "$failures of $num_reviewers reviewers failed (continuing with partial results)"
  fi

  # 集約
  local agg_file="$output_dir/${phase}_reviews${suffix}.md"
  reviewer_aggregate "$output_dir" "$phase_with_suffix" "$agg_file"

  echo "$agg_file"
}

_reviewer_repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "$(cd "$script_dir/../../.." && pwd)"
}

_reviewer_collect_changed_files_json() {
  local repo_root="$1"
  local changed_tmp=""
  changed_tmp=$(create_temp_file "reviewer_changed_files")

  (
    cd "$repo_root"
    {
      git diff --name-only HEAD~1 HEAD 2>/dev/null || true
      git diff --name-only --cached 2>/dev/null || true
      git diff --name-only 2>/dev/null || true
    } | sed '/^[[:space:]]*$/d' | sed 's#^\./##' | sort -u
  ) > "$changed_tmp"

  local changed_json='[]'
  if [[ -s "$changed_tmp" ]]; then
    changed_json=$(jq -R . "$changed_tmp" | jq -s 'map(select(length > 0))')
  fi

  /bin/rm -f "$changed_tmp"
  echo "$changed_json"
}

_reviewer_build_symbol_metadata_json() {
  local repo_root="$1"
  local repomap_dir="$repo_root/.agent/context/repomap"
  if [[ ! -d "$repomap_dir" ]]; then
    echo '[]'
    return 0
  fi

  shopt -s nullglob
  local repomap_files=("$repomap_dir"/*.jsonl)
  shopt -u nullglob
  if [[ ${#repomap_files[@]} -eq 0 ]]; then
    echo '[]'
    return 0
  fi

  jq -s '
    [
      .[]
      | if type == "array" then .[]? elif type == "object" then . else empty end
      | select(type == "object")
      | {
          logical_id: (.logical_id // .semantic_id // ""),
          file: (.file // ""),
          line: (.line // 0),
          name: (.name // "")
        }
      | select((.logical_id | length) > 0)
    ]
    | unique_by(.logical_id)
  ' "${repomap_files[@]}" 2>/dev/null || echo '[]'
}

_reviewer_build_out_of_window_dependency_alert() {
  local coder_output="${1:-}"
  if [[ -n "$coder_output" && ! -f "$coder_output" ]]; then
    echo ""
    return 0
  fi

  ensure_cmd jq
  ensure_cmd git

  local repo_root=""
  repo_root=$(_reviewer_repo_root)

  local graph_rank_path="$repo_root/.agent/context/graph_rank.json"
  if [[ ! -f "$graph_rank_path" ]]; then
    echo ""
    return 0
  fi

  local adjacency_path=""
  adjacency_path=$(jq -r '.adjacency_path // empty' "$graph_rank_path" 2>/dev/null || echo "")
  if [[ -z "$adjacency_path" ]]; then
    adjacency_path="$repo_root/.agent/context/adjacency.jsonl"
  elif [[ "$adjacency_path" != /* ]]; then
    adjacency_path="$repo_root/${adjacency_path#./}"
  fi
  if [[ ! -f "$adjacency_path" ]]; then
    echo ""
    return 0
  fi

  local changed_files_json='[]'
  changed_files_json=$(_reviewer_collect_changed_files_json "$repo_root")
  local changed_count=0
  changed_count=$(jq 'length' <<< "$changed_files_json" 2>/dev/null || echo "0")
  if [[ "$changed_count" -eq 0 ]]; then
    echo ""
    return 0
  fi

  local symbols_tmp=""
  symbols_tmp=$(create_temp_file "reviewer_symbol_meta")
  _reviewer_build_symbol_metadata_json "$repo_root" > "$symbols_tmp"

  local alerts_tmp=""
  alerts_tmp=$(create_temp_file "reviewer_dependency_alert")
  set +e
  jq -n \
    --argjson changed "$changed_files_json" \
    --slurpfile symbols "$symbols_tmp" \
    --slurpfile ranked "$graph_rank_path" \
    --slurpfile edges "$adjacency_path" \
    '
      def file_from_id($logical_id):
        if ($logical_id | type) != "string" then
          ""
        elif ($logical_id | contains(":")) then
          ($logical_id | split(":")[0])
        else
          ""
        end;

      ($symbols[0] // []) as $symbols
      | ($symbols | map({key:.logical_id, value:.}) | from_entries) as $meta
      | (($ranked[0].ranked_symbols // []) | map({key:.logical_id, value:(.score // 0)}) | from_entries) as $score_map
      | ($edges | if (length > 0 and (.[0] | type) == "array") then .[0] else . end) as $edge_rows
      | [
          $edge_rows[]
          | select((.source_logical_id? | type) == "string")
          | select((.target_logical_id? | type) == "string")
          | . as $edge
          | ($meta[$edge.source_logical_id] // {}) as $src
          | ($meta[$edge.target_logical_id] // {}) as $tgt
          | (
              (($src.file // "") | tostring) as $src_file
              | if ($src_file | length) > 0 then $src_file else file_from_id($edge.source_logical_id) end
            ) as $source_file
          | (
              (($tgt.file // "") | tostring) as $tgt_file
              | if ($tgt_file | length) > 0 then $tgt_file else file_from_id($edge.target_logical_id) end
            ) as $target_file
          | select(($target_file | length) > 0)
          | select(($changed | index($target_file)) != null)
          | select(($changed | index($source_file)) == null)
          | {
              source_logical_id: $edge.source_logical_id,
              source_symbol: (
                (($src.name // "") | tostring)
                | if length > 0 then . else ($edge.source_logical_id | tostring) end
              ),
              source_file: $source_file,
              source_line: (($src.line // 1) | tonumber? // 1),
              target_file: $target_file,
              target_line: (($tgt.line // 1) | tonumber? // 1),
              score: (($score_map[$edge.source_logical_id] // 0) | tonumber? // 0)
            }
        ]
      | unique_by(.source_logical_id + "|" + .target_file + "|" + (.target_line | tostring))
      | sort_by(-.score, .source_file, .source_line, .source_logical_id)
    ' > "$alerts_tmp"
  local jq_status=$?
  set -e

  if [[ $jq_status -ne 0 || ! -s "$alerts_tmp" ]]; then
    /bin/rm -f "$symbols_tmp" "$alerts_tmp"
    echo ""
    return 0
  fi

  local alert_count=0
  alert_count=$(jq 'length' "$alerts_tmp" 2>/dev/null || echo "0")
  if [[ "$alert_count" -eq 0 ]]; then
    /bin/rm -f "$symbols_tmp" "$alerts_tmp"
    echo ""
    return 0
  fi

  local max_alerts="$REVIEWER_DEP_ALERT_MAX"
  if ! [[ "$max_alerts" =~ ^[0-9]+$ ]]; then
    max_alerts=5
  fi
  if [[ "$max_alerts" -le 0 ]]; then
    max_alerts=5
  fi

  local alert_md=""
  alert_md=$(jq -r \
    --argjson max_alerts "$max_alerts" \
    '
      .[:$max_alerts]
      | (
          ["## Dependency Alert (out-of-window)"]
          + (
            map(
              "- "
              + (.source_logical_id // .source_symbol // "unknown_symbol")
              + " depends on "
              + (.target_file // "unknown_file")
              + ":"
              + (
                  (
                    if (.target_line | type) == "number" and .target_line > 0 then
                      .target_line
                    else
                      1
                    end
                  )
                  | tostring
                )
            )
          )
        )
      | join("\n")
    ' "$alerts_tmp" 2>/dev/null || echo "")

  /bin/rm -f "$symbols_tmp" "$alerts_tmp"
  echo "$alert_md"
}

# =====================================================
# Batch Review Runtime
# =====================================================

# バッチレビュー用 queue runtime error scratch
REVIEW_QUEUE_LAST_ERROR=""
REVIEW_QUEUE_LAST_ERROR_KIND=""

_review_queue_exec() {
  local command="${1:-}"
  shift || true

  if [[ ! -x "$SEMANTIC_REVIEW_QUEUE_SCRIPT" ]]; then
    log_error "semantic review queue helper not found or not executable: $SEMANTIC_REVIEW_QUEUE_SCRIPT"
    return 1
  fi

  case "$command" in
    queue)
      local subcommand="${1:-}"
      shift || true
      case "$subcommand" in
        lease|complete|requeue)
          "$SEMANTIC_REVIEW_QUEUE_SCRIPT" "$subcommand" --repo-root "$REPO_ROOT" "$@"
          ;;
        *)
          log_error "unsupported semantic review queue subcommand: $subcommand"
          return 1
          ;;
      esac
      ;;
    *)
      log_error "unsupported semantic review queue command: $command"
      return 1
      ;;
  esac
}

_review_queue_lease() {
  local lease_run_id="$1"

  _review_queue_exec \
    queue lease \
    --lease-run-id "$lease_run_id" \
    --lease-seconds "$REVIEW_QUEUE_LEASE_SECONDS"
}

_batch_review_state_path() {
  local phase="$1"
  local phase_idx
  phase_idx=$(state_find_phase "$phase")

  if [[ "$phase_idx" == "-1" ]]; then
    die "Phase not found for batch review runtime state: $phase"
  fi

  printf '.phases[%s].batch_review_runtime\n' "$phase_idx"
}

_batch_review_state_write_lease() {
  local phase="$1"
  local project_id="$2"
  local lease_json="$3"
  local lease_run_id="$4"
  local state_path=""
  local runtime_json=""
  local now
  now=$(get_timestamp)
  state_path=$(_batch_review_state_path "$phase")

  runtime_json=$(jq -nc \
    --arg status "leased" \
    --arg project_id "$project_id" \
    --arg lease_run_id "$lease_run_id" \
    --arg updated_at "$now" \
    --argjson lease "$lease_json" '
      {
        status: $status,
        project_id: $project_id,
        lease_owner: ($lease.lease_owner // null),
        lease_run_id: (if ($lease.lease_run_id // null) != null then $lease.lease_run_id else $lease_run_id end),
        expected_files: ($lease.expected_files // []),
        leased_at: ($lease.leased_at // null),
        lease_expires_at: ($lease.lease_expires_at // null),
        leased_count: ($lease.leased_count // 0),
        updated_at: $updated_at,
        last_error: null,
        finalization: null
      }')

  state_set "$state_path" "$runtime_json"
  state_save
}

_batch_review_state_read() {
  local phase="$1"
  local state_path=""
  state_path=$(_batch_review_state_path "$phase")
  jq -c "$state_path // null" "$STATE_FILE"
}

_batch_review_state_transition() {
  local phase="$1"
  local status="$2"
  local error_message="${3:-}"
  local result_json="${4:-null}"
  local state_path=""
  local current_json=""
  local updated_json=""
  local now
  now=$(get_timestamp)
  state_path=$(_batch_review_state_path "$phase")
  current_json=$(_batch_review_state_read "$phase")

  if [[ -z "$current_json" || "$current_json" == "null" ]]; then
    die "Batch review runtime state missing for phase: $phase"
  fi

  updated_json=$(jq -c \
    --arg status "$status" \
    --arg updated_at "$now" \
    --arg finalized_at "$now" \
    --arg error_message "$error_message" \
    --argjson result "$result_json" '
      .status = $status
      | .updated_at = $updated_at
      | .finalized_at = $finalized_at
      | .last_error = (if $error_message == "" then null else $error_message end)
      | .finalization = $result
    ' <<< "$current_json")

  state_set "$state_path" "$updated_json"
  state_save
}

_batch_review_fail_closed() {
  local phase="$1"
  local code="$2"
  local message="$3"
  local current_json=""

  current_json=$(_batch_review_state_read "$phase" 2>/dev/null || echo "null")
  if [[ "$current_json" != "null" && -n "$current_json" ]]; then
    _batch_review_state_transition "$phase" "failed_closed" "$message" 'null'
  fi

  state_set_error "$code" "$message" "$phase"
  state_save
  log_error "$message"
  return 1
}

_review_queue_project_id_is_valid() {
  local project_id="${1:-}"

  [[ -n "$project_id" ]] || return 1
  [[ "$project_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || return 1
  [[ "$project_id" != "agent_base" ]] || return 1
  return 0
}

_review_queue_finalize_from_state() {
  local phase="$1"
  local action="$2"
  local error_context="${3:-}"
  local runtime_json=""
  local project_id=""
  local lease_owner=""
  local lease_run_id=""
  local output=""
  local err_file=""
  local args=()
  local expected_count=0

  REVIEW_QUEUE_LAST_ERROR=""
  REVIEW_QUEUE_LAST_ERROR_KIND=""

  runtime_json=$(_batch_review_state_read "$phase")
  if ! jq -e '
    type == "object"
    and (.project_id | type == "string")
    and (.project_id != "agent_base")
    and (.project_id | test("^[A-Za-z0-9_-]{1,64}$"))
    and ((.lease_owner // "") | length > 0)
    and (.expected_files | type == "array")
    and ((.expected_files | length) > 0)
  ' <<< "$runtime_json" >/dev/null 2>&1; then
    REVIEW_QUEUE_LAST_ERROR="batch review runtime state is incomplete for strict queue finalization"
    REVIEW_QUEUE_LAST_ERROR_KIND="runtime_state_invalid"
    return 1
  fi

  project_id=$(jq -r '.project_id // empty' <<< "$runtime_json")
  if ! _review_queue_project_id_is_valid "$project_id"; then
    REVIEW_QUEUE_LAST_ERROR="batch review runtime state has invalid project_id"
    REVIEW_QUEUE_LAST_ERROR_KIND="runtime_state_invalid"
    return 1
  fi
  lease_owner=$(jq -r '.lease_owner // empty' <<< "$runtime_json")
  lease_run_id=$(jq -r '.lease_run_id // empty' <<< "$runtime_json")
  expected_count=$(jq -r '.expected_files | length' <<< "$runtime_json")

  args=(queue "$action" --project-id "$project_id" --lease-owner "$lease_owner")
  if [[ -n "$lease_run_id" ]]; then
    args+=(--lease-run-id "$lease_run_id")
  fi

  while IFS= read -r file; do
    if [[ -n "$file" ]]; then
      args+=(--expected-file "$file")
    fi
  done < <(jq -r '.expected_files[]? // empty' <<< "$runtime_json")

  if [[ "$action" == "requeue" ]]; then
    args+=(--error "$error_context")
  fi

  if [[ "$expected_count" -eq 0 ]]; then
    REVIEW_QUEUE_LAST_ERROR="queue $action requires strict expected files"
    REVIEW_QUEUE_LAST_ERROR_KIND="runtime_state_invalid"
    return 1
  fi

  err_file=$(create_temp_file "queue_${action}_stderr")
  if output=$(_review_queue_exec "${args[@]}" 2> "$err_file"); then
    /bin/rm -f "$err_file" 2>/dev/null || true
    printf '%s\n' "$output"
    return 0
  fi

  local rc=$?
  REVIEW_QUEUE_LAST_ERROR="$(cat "$err_file" 2>/dev/null || true)"
  /bin/rm -f "$err_file" 2>/dev/null || true
  if [[ -z "$REVIEW_QUEUE_LAST_ERROR" ]]; then
    REVIEW_QUEUE_LAST_ERROR="queue $action failed (rc=$rc)"
  fi

  if [[ "$REVIEW_QUEUE_LAST_ERROR" == *"lost queue lease ownership"* ]]; then
    REVIEW_QUEUE_LAST_ERROR_KIND="lease_lost"
  else
    REVIEW_QUEUE_LAST_ERROR_KIND="command_failed"
  fi

  return 1
}

_review_queue_build_error_context() {
  local reason="$1"
  local review_output="${2:-}"
  local context=""
  local review_verdict=""

  context=$(_coordination_compact_failure_reason "$reason")
  if [[ -n "$review_output" && -f "$review_output" ]] && validate_review_output_format "$review_output"; then
    if review_verdict=$(_extract_review_report_verdict "$review_output" 2>/dev/null); then
      case "$reason" in
        *"$review_verdict"*)
          ;;
        *)
          context=$(_coordination_compact_failure_reason "$context | verdict=$review_verdict")
          ;;
      esac
    fi
  fi

  printf '%s\n' "$context"
}

review_create_diff_snapshot() {
  local output_file="$1"
  local queued_files="${2:-}"
  local diff_content=""

  if [[ -z "$queued_files" ]]; then
    log_info "No leased files to review"
    return 1
  fi

  local file
  while IFS= read -r file; do
    if [[ -n "$file" ]] && [[ -f "$file" ]]; then
      if ! git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
        git add -N -- "$file" 2>/dev/null || true
      fi
    fi
  done <<< "$queued_files"

  local files_array=()
  while IFS= read -r file; do
    if [[ -n "$file" ]]; then
      files_array+=("$file")
    fi
  done <<< "$queued_files"

  if [[ ${#files_array[@]} -gt 0 ]]; then
    diff_content=$(git diff HEAD -- "${files_array[@]}" 2>/dev/null || true)
  fi

  if [[ -z "$diff_content" ]]; then
    log_info "No changes to review in leased files"
    return 1
  fi

  printf '%s\n' "$diff_content" > "$output_file"
  log_info "Diff snapshot created: $output_file ($(wc -l < "$output_file") lines, ${#files_array[@]} files)"
  return 0
}

render_batch_review_prompt() {
  local template_file="$1"
  local metadata_file="$2"
  local diff_file="$3"
  local output_file="$4"

  if [[ ! -r "$template_file" ]]; then
    log_error "Batch review template not readable: $template_file"
    return 1
  fi

  if [[ ! -f "$metadata_file" || ! -r "$metadata_file" ]]; then
    log_error "Batch review metadata source not readable: $metadata_file"
    return 1
  fi

  if [[ ! -f "$diff_file" || ! -r "$diff_file" ]]; then
    log_error "Batch review diff source not readable: $diff_file"
    return 1
  fi

  local tmp_file
  tmp_file=$(create_temp_file "batch_review_prompt")

  if awk -v metadata_file="$metadata_file" -v diff_file="$diff_file" '
    BEGIN {
      metadata_found = 0
      diff_found = 0
    }
    $0 == "__BATCH_REVIEW_METADATA__" {
      metadata_found = 1
      while ((read_status = getline line < metadata_file) > 0) {
        print line
      }
      if (read_status < 0) {
        exit 2
      }
      close(metadata_file)
      next
    }
    $0 == "__BATCH_REVIEW_DIFF__" {
      diff_found = 1
      while ((read_status = getline line < diff_file) > 0) {
        print line
      }
      if (read_status < 0) {
        exit 3
      }
      close(diff_file)
      next
    }
    {
      print
    }
    END {
      if (!metadata_found || !diff_found) {
        exit 1
      }
    }
  ' "$template_file" > "$tmp_file"; then
    mv "$tmp_file" "$output_file"
    return 0
  fi

  /bin/rm -f "$tmp_file" 2>/dev/null || true
  log_error "Failed to render batch review prompt from template: $template_file"
  return 1
}

_run_batch_review_reviewer() {
  local review_prompt_file="$1"
  local review_output="$2"
  local stderr_capture=""
  local stderr_sidecar="${review_output}.stderr.log"
  local stdout_capture=""

  REVIEWER_LAST_OUTPUT_STATUS=""

  if [[ ! -x "$CODEX_WRAPPER_CANONICAL" ]]; then
    log_error "codex-wrapper.sh not found or not executable: $CODEX_WRAPPER_CANONICAL"
    printf '%s\n' "[ERROR] codex-wrapper.sh not found" > "$review_output"
    return 1
  fi

  stderr_capture=$(create_temp_file "batch_review_stderr")
  stdout_capture=$(create_temp_file "batch_review_stdout")
  if ! _reviewer_guard_prompt_file "$review_prompt_file" "reviewer:batch"; then
    printf '%s\n' "[ERROR] model I/O guard blocked batch review prompt" > "$review_output"
    return 1
  fi
  if timeout_run "$CODEX_TIMEOUT" "$CODEX_WRAPPER_CANONICAL" --role reviewer --stdin < "$review_prompt_file" > "$stdout_capture" 2> "$stderr_capture"; then
    _reviewer_finalize_stderr_sidecar "$stderr_capture" "$stderr_sidecar" "Batch review"
    /bin/rm -f "$stderr_capture"
    if _reviewer_promote_validated_stdout "$stdout_capture" "$review_output" "Batch review" "Batch review produced invalid reviewer output format"; then
      return 0
    fi
    return 1
  fi

  local exit_code=$?
  _reviewer_finalize_stderr_sidecar "$stderr_capture" "$stderr_sidecar" "Batch review"
  /bin/rm -f "$stderr_capture"
  if [[ $exit_code -eq 124 ]]; then
    _reviewer_quarantine_raw_stdout "$stdout_capture" "$review_output" "Batch review timed out after ${CODEX_TIMEOUT}s"
  else
    _reviewer_quarantine_raw_stdout "$stdout_capture" "$review_output" "Batch review returned non-zero: $exit_code"
  fi
  return $exit_code
}

run_batch_review() {
  local tmpdir="$1"
  local phase="$2"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)

  log_info "=== Running Batch Review (Phase: $phase) ==="

  local lease_run_id=""
  lease_run_id="batch-review-${phase}-$(generate_uuid)"

  local lease_json=""
  if ! lease_json=$(_review_queue_lease "$lease_run_id"); then
    _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_LEASE_FAILED" "Batch review queue lease failed for phase=$phase"
    return 1
  fi

  if ! jq -e '
    type == "object"
    and (.project_id | type == "string")
    and (.project_id != "agent_base")
    and (.project_id | test("^[A-Za-z0-9_-]{1,64}$"))
    and (.leased_count | type == "number")
    and (.expected_files | type == "array")
  ' <<< "$lease_json" >/dev/null 2>&1; then
    _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_INVALID_LEASE" "Batch review queue lease returned invalid contract"
    return 1
  fi

  local leased_count=0
  leased_count=$(jq -r '.leased_count // 0' <<< "$lease_json")
  if [[ "$leased_count" -eq 0 ]]; then
    log_info "No pending reviews in DB queue"
    return 0
  fi

  if ! jq -e '((.lease_owner // "") | length > 0) and ((.expected_files | length) > 0)' <<< "$lease_json" >/dev/null 2>&1; then
    _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_INVALID_LEASE" "Batch review queue lease omitted lease_owner or expected_files"
    return 1
  fi

  local project_id=""
  project_id=$(jq -r '.project_id // empty' <<< "$lease_json")
  if ! _review_queue_project_id_is_valid "$project_id"; then
    _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_INVALID_LEASE" "Batch review queue lease returned invalid project_id"
    return 1
  fi
  _batch_review_state_write_lease "$phase" "$project_id" "$lease_json" "$lease_run_id"

  local queued_files=""
  queued_files=$(jq -r '.expected_files[]? // empty' <<< "$lease_json")
  local review_output="$tmpdir/${phase}_batch_review_${timestamp}.md"

  local snapshot_file="$tmpdir/${phase}_diff_snapshot_${timestamp}.patch"
  if ! review_create_diff_snapshot "$snapshot_file" "$queued_files"; then
    printf '%s\n' "[SKIPPED] No diff remaining for leased files." > "$review_output"

    local empty_complete_json=""
    local empty_complete_json_file=""
    empty_complete_json_file=$(create_temp_file "queue_complete_json")
    if ! _review_queue_finalize_from_state "$phase" "complete" > "$empty_complete_json_file"; then
      /bin/rm -f "$empty_complete_json_file" 2>/dev/null || true
      if [[ "$REVIEW_QUEUE_LAST_ERROR_KIND" == "lease_lost" ]]; then
        _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_LEASE_LOST" "Batch review lost queue lease ownership before no-diff completion: ${REVIEW_QUEUE_LAST_ERROR:-unknown error}"
      else
        _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_COMPLETE_FAILED" "Batch review queue complete failed without reviewer execution: ${REVIEW_QUEUE_LAST_ERROR:-unknown error}"
      fi
      return 1
    fi
    empty_complete_json="$(cat "$empty_complete_json_file")"
    /bin/rm -f "$empty_complete_json_file" 2>/dev/null || true

    _batch_review_state_transition "$phase" "completed" "" "$empty_complete_json"
    echo "$review_output"
    return 0
  fi

  local review_prompt_file="$tmpdir/${phase}_batch_review_prompt.md"
  local review_metadata_file="$tmpdir/${phase}_batch_review_metadata_${timestamp}.txt"
  local formatted_files
  formatted_files=$(printf '%s\n' "$queued_files" | sed 's/^/  - /')

  {
    printf '%s\n' "- Phase: $phase"
    printf '%s\n' "- Timestamp: $timestamp"
    printf '%s\n' "- Changed files:"
    printf '%s\n' "$formatted_files"
  } > "$review_metadata_file"

  render_batch_review_prompt \
    "$BATCH_REVIEW_TEMPLATE" \
    "$review_metadata_file" \
    "$snapshot_file" \
    "$review_prompt_file" || {
      local render_error=""
      render_error=$(_review_queue_build_error_context "batch review prompt render failed" "$review_output")
      local requeue_json=""
      local requeue_json_file=""
      requeue_json_file=$(create_temp_file "queue_requeue_json")

      if ! _review_queue_finalize_from_state "$phase" "requeue" "$render_error" > "$requeue_json_file"; then
        /bin/rm -f "$requeue_json_file" 2>/dev/null || true
        if [[ "$REVIEW_QUEUE_LAST_ERROR_KIND" == "lease_lost" ]]; then
          _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_LEASE_LOST" "Batch review prompt render failed after partial lease loss: ${REVIEW_QUEUE_LAST_ERROR:-unknown error}"
        else
          _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_REQUEUE_FAILED" "Batch review prompt render failed and queue requeue could not complete: ${REVIEW_QUEUE_LAST_ERROR:-unknown error}"
        fi
        return 1
      fi
      requeue_json="$(cat "$requeue_json_file")"
      /bin/rm -f "$requeue_json_file" 2>/dev/null || true

      printf '%s\n' "[ERROR] Batch review prompt render failed." > "$review_output"
      _batch_review_state_transition "$phase" "requeued" "$render_error" "$requeue_json"
      /bin/rm -f "$review_prompt_file" "$review_metadata_file" 2>/dev/null || true
      echo "$review_output"
      return 0
    }

  log_info "Running Codex batch review (timeout: ${CODEX_TIMEOUT}s)..."

  local review_success=false
  local review_failure_context=""
  local review_verdict=""
  if _run_batch_review_reviewer "$review_prompt_file" "$review_output"; then
    log_info "Batch review completed: $review_output"
    if [[ -s "$review_output" ]]; then
      if ! validate_review_output_format "$review_output"; then
        log_warn "Batch review produced invalid reviewer output format"
        review_failure_context=$(_review_queue_build_error_context "batch review produced invalid reviewer output format" "$review_output")
      elif ! review_verdict=$(_extract_review_report_verdict "$review_output" 2>/dev/null); then
        log_warn "Batch review verdict was missing or invalid"
        review_failure_context=$(_review_queue_build_error_context "batch review verdict was missing or invalid" "$review_output")
      elif [[ "$review_verdict" == "LGTM" ]]; then
        review_success=true
      else
        log_warn "Batch review returned non-LGTM verdict: $review_verdict"
        review_failure_context=$(_review_queue_build_error_context "batch review verdict was $review_verdict" "$review_output")
      fi
    else
      printf '%s\n' "[ERROR] Batch review produced empty output." > "$review_output"
      review_failure_context=$(_review_queue_build_error_context "batch review produced empty output" "$review_output")
    fi
  else
    local ret=$?
    if [[ "$REVIEWER_LAST_OUTPUT_STATUS" == "invalid_format" ]]; then
      log_warn "Batch review produced invalid reviewer output format"
      review_failure_context=$(_review_queue_build_error_context "batch review produced invalid reviewer output format" "$review_output")
    elif [[ "$REVIEWER_LAST_OUTPUT_STATUS" == "empty_output" ]]; then
      log_warn "Batch review produced empty output"
      review_failure_context=$(_review_queue_build_error_context "batch review produced empty output" "$review_output")
    elif [[ $ret -eq 124 ]]; then
      log_warn "Batch review timed out after ${CODEX_TIMEOUT}s"
      review_failure_context=$(_review_queue_build_error_context "batch review timed out after ${CODEX_TIMEOUT}s" "$review_output")
    else
      log_warn "Batch review returned non-zero: $ret"
      review_failure_context=$(_review_queue_build_error_context "batch review returned non-zero (rc=$ret)" "$review_output")
    fi
  fi

  local finalize_json=""
  local finalize_json_file=""
  finalize_json_file=$(create_temp_file "queue_finalize_json")
  if [[ "$review_success" == "true" ]]; then
    if ! _review_queue_finalize_from_state "$phase" "complete" > "$finalize_json_file"; then
      /bin/rm -f "$finalize_json_file" 2>/dev/null || true
      if [[ "$REVIEW_QUEUE_LAST_ERROR_KIND" == "lease_lost" ]]; then
        _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_LEASE_LOST" "Batch review succeeded but lost queue lease ownership during completion: ${REVIEW_QUEUE_LAST_ERROR:-unknown error}"
      else
        _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_COMPLETE_FAILED" "Batch review succeeded but queue complete failed: ${REVIEW_QUEUE_LAST_ERROR:-unknown error}"
      fi
      return 1
    fi
    finalize_json="$(cat "$finalize_json_file")"
    /bin/rm -f "$finalize_json_file" 2>/dev/null || true

    _batch_review_state_transition "$phase" "completed" "" "$finalize_json"
  else
    if ! _review_queue_finalize_from_state "$phase" "requeue" "$review_failure_context" > "$finalize_json_file"; then
      /bin/rm -f "$finalize_json_file" 2>/dev/null || true
      if [[ "$REVIEW_QUEUE_LAST_ERROR_KIND" == "lease_lost" ]]; then
        _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_LEASE_LOST" "Batch review failed after partial lease loss: ${REVIEW_QUEUE_LAST_ERROR:-unknown error}"
      else
        _batch_review_fail_closed "$phase" "BATCH_REVIEW_QUEUE_REQUEUE_FAILED" "Batch review failed and queue requeue could not complete: ${REVIEW_QUEUE_LAST_ERROR:-unknown error}"
      fi
      return 1
    fi
    finalize_json="$(cat "$finalize_json_file")"
    /bin/rm -f "$finalize_json_file" 2>/dev/null || true

    _batch_review_state_transition "$phase" "requeued" "$review_failure_context" "$finalize_json"
  fi

  /bin/rm -f "$review_prompt_file" "$review_metadata_file"

  echo "$review_output"
}
