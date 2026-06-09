#!/usr/bin/env bash
# coder.sh - Coder 実行関数
# エージェント自動化システム用
#
# 依存: utils.sh, state.sh, session.sh が先に読み込まれていること
# 依存: claude CLI, jq

# Coder 設定
CODER_TIMEOUT="${CODER_TIMEOUT:-1800}"  # 30分（デフォルト）
CODER_MAX_PARALLEL="${CODER_MAX_PARALLEL:-1}"  # 最大並列Coder数

# セマンティックコンテキスト連携設定
_CODER_LIB_DIR="${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
_CODER_REPO_ROOT="${REPO_ROOT:-$(cd "$_CODER_LIB_DIR/../../.." && pwd)}"
_CODER_CONTEXT_CAPSULE_SH="${_CODER_LIB_DIR}/context_capsule.sh"
_CODER_CONTEXT_ANALYSIS_SH="${_CODER_LIB_DIR}/context_analysis.sh"
_CODER_MODEL_IO_GUARD="${REV_HARNESS_MODEL_IO_GUARD:-${_CODER_REPO_ROOT}/scripts/rev-harness-model-io-guard.sh}"

_coder_model_io_quarantine_dir() {
  local repo_root=""
  repo_root="$(cd "$_CODER_REPO_ROOT" && pwd -P 2>/dev/null)" || repo_root="$_CODER_REPO_ROOT"
  printf '%s\n' "${repo_root}/.claude/tmp/call-invoke-guard/quarantine"
}

_coder_guard_prompt_file() {
  local prompt_file="$1"
  local label="$2"

  if [[ -x "$_CODER_MODEL_IO_GUARD" ]]; then
    bash "$_CODER_MODEL_IO_GUARD" prompt-budget --file "$prompt_file" --label "$label" \
      --max-bytes "${REV_HARNESS_MODEL_IO_PROMPT_MAX_BYTES:-262144}" \
      --warn-bytes "${REV_HARNESS_MODEL_IO_PROMPT_WARN_BYTES:-196608}" || return 1
  fi
}

_coder_write_sanitized_model_io_stub() {
  local output_file="$1"
  local label="$2"

  {
    printf '[ERROR] model I/O guard blocked unsafe output for %s.\n' "$label"
    printf 'See sanitized guard metadata under .claude/tmp/call-invoke-guard/.\n'
    printf '\n---OUTPUT-END---\n'
  } > "$output_file"
}

_coder_scan_output_file() {
  local output_file="$1"
  local label="$2"

  if [[ -x "$_CODER_MODEL_IO_GUARD" ]]; then
    if ! bash "$_CODER_MODEL_IO_GUARD" scan-output --file "$output_file" --label "$label" --quarantine-dir "$(_coder_model_io_quarantine_dir)"; then
      _coder_write_sanitized_model_io_stub "$output_file" "$label"
      return 1
    fi
  fi
}

# 互換ガード: context_capsule/context_analysis 未配置時は従来動作
if [[ -f "$_CODER_CONTEXT_CAPSULE_SH" ]]; then
  _HAS_CAPSULE=true
else
  _HAS_CAPSULE=false
  log_warn "context_capsule.sh未配置: カプセル注入をスキップ"
fi

if [[ -f "$_CODER_CONTEXT_ANALYSIS_SH" ]]; then
  _HAS_CONTEXT_ANALYSIS=true
else
  _HAS_CONTEXT_ANALYSIS=false
  log_warn "context_analysis.sh未配置: delta注入をスキップ"
fi

# =====================================================
# 動的エージェント起動
# =====================================================

# タスクの複雑さを分析
# Usage: coder_analyze_task_complexity <plan_path>
# Returns: complexity level (stdout): simple, moderate, complex
coder_analyze_task_complexity() {
  local plan_path="$1"

  if [[ -z "$plan_path" || ! -f "$plan_path" ]]; then
    echo "simple"
    return
  fi

  local content
  content=$(cat "$plan_path" 2>/dev/null || true)

  # ヒューリスティック: タスクの複雑さを判定
  local score=0

  # ファイル数の言及があるか
  local file_mentions
  file_mentions=$(echo "$content" | grep -ciE '\.(ts|js|py|go|rs|java|tsx|jsx|vue|sh)' 2>/dev/null | tr -d '\n' || echo 0)
  # 空の場合は0にフォールバック
  [[ -z "$file_mentions" ]] && file_mentions=0
  if [[ $file_mentions -gt 10 ]]; then
    score=$((score + 2))
  elif [[ $file_mentions -gt 5 ]]; then
    score=$((score + 1))
  fi

  # 複数モジュール/パッケージの変更
  if echo "$content" | grep -qiE '(multiple|several|many|各|複数).*(file|module|package|component)'; then
    score=$((score + 2))
  fi

  # リファクタリング/マイグレーション
  if echo "$content" | grep -qiE '(refactor|migration|リファクタ|移行|マイグレーション)'; then
    score=$((score + 2))
  fi

  # テスト作成
  if echo "$content" | grep -qiE '(test|spec|テスト)'; then
    score=$((score + 1))
  fi

  # 結果を返す
  if [[ $score -ge 4 ]]; then
    echo "complex"
  elif [[ $score -ge 2 ]]; then
    echo "moderate"
  else
    echo "simple"
  fi
}

# 推奨Coder数を取得
# Usage: coder_get_recommended_count <complexity> [max_coders]
# Returns: recommended coder count (stdout)
coder_get_recommended_count() {
  local complexity="$1"
  local max_coders="${2:-$CODER_MAX_PARALLEL}"

  case "$complexity" in
    complex)
      # 複雑なタスク: 最大数を推奨
      echo "$max_coders"
      ;;
    moderate)
      # 中程度: 2つまで
      local count=2
      [[ $count -gt $max_coders ]] && count=$max_coders
      echo "$count"
      ;;
    simple|*)
      # シンプル: 1つ
      echo "1"
      ;;
  esac
}

# 動的エージェント戦略情報をログ出力
# Usage: coder_log_strategy <plan_path> <max_coders>
coder_log_strategy() {
  local plan_path="$1"
  local max_coders="${2:-1}"

  local complexity
  complexity=$(coder_analyze_task_complexity "$plan_path")

  local recommended
  recommended=$(coder_get_recommended_count "$complexity" "$max_coders")

  log_info "Dynamic agent strategy:"
  log_info "  Task complexity: $complexity"
  log_info "  Max coders allowed: $max_coders"
  log_info "  Recommended coders: $recommended"

  echo "$recommended"
}

# plan内の security-sensitive フラグを検出
# Usage: _coder_is_security_sensitive_plan <plan_path>
# Returns: "true" | "false"（stdout）
_coder_is_security_sensitive_plan() {
  local plan_path="$1"

  if [[ -z "$plan_path" || ! -f "$plan_path" ]]; then
    echo "false"
    return 0
  fi

  # 例:
  # - security-sensitive=true
  # - security_sensitive=true
  # - security-sensitive: true
  # - "security_sensitive": true
  if grep -qiE "[\"']?security[-_ ]sensitive[\"']?[[:space:]]*[:=][[:space:]]*[\"']?true[\"']?" "$plan_path"; then
    echo "true"
  else
    echo "false"
  fi
}

# タスク複雑度から Canonical Codex role を選択
# Usage: select_codex_role_by_complexity <plan_path>
# Returns: canonical role name（stdout）
select_codex_role_by_complexity() {
  local plan_path="$1"
  local complexity
  complexity=$(coder_analyze_task_complexity "$plan_path")

  case "$complexity" in
    simple)   echo "standard" ;;
    moderate) echo "coder" ;;
    complex)  echo "coder" ;;   # reviewer は reviewer role に限定
    *)        echo "coder" ;;   # fail-closed: 不明時は安全側へ寄せる
  esac
}

# Canonical Codex role を検証
# Usage: _coder_validate_codex_role <role>
_coder_validate_codex_role() {
  local role="$1"

  case "$role" in
    standard|research|coder|high-coder|reviewer)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Canonical Codex wrapper を絶対パスへ解決
# Usage: _coder_resolve_wrapper_path
# Returns: wrapper absolute path（stdout）
_coder_resolve_wrapper_path() {
  local canonical_dir=""
  local canonical_path=""

  canonical_dir="$(cd "${_CODER_REPO_ROOT}/scripts" && pwd -P 2>/dev/null)" || {
    die "Canonical Codex wrapper directory not found: ${_CODER_REPO_ROOT}/scripts"
    return 1
  }
  canonical_path="${canonical_dir}/codex-wrapper.sh"

  if [[ -n "${CODEX_WRAPPER_CANONICAL:-}" ]]; then
    local candidate_dir=""
    candidate_dir="$(cd "$(dirname "$CODEX_WRAPPER_CANONICAL")" && pwd -P 2>/dev/null)" || {
      die "CODEX_WRAPPER_CANONICAL must resolve to canonical repo path: ${canonical_path}"
      return 1
    }

    local resolved_candidate="${candidate_dir}/$(basename "$CODEX_WRAPPER_CANONICAL")"
    if [[ "$resolved_candidate" != "$canonical_path" ]]; then
      die "CODEX_WRAPPER_CANONICAL must resolve to canonical repo path: ${canonical_path}"
      return 1
    fi

    echo "$canonical_path"
    return 0
  fi

  echo "$canonical_path"
}

# jq 存在確認
_ensure_jq_coder() {
  if ! command -v jq >/dev/null 2>&1; then
    die "jq not found. Please install jq (brew install jq / apt install jq)."
  fi
}

# プロンプトディレクトリを取得
_coder_get_prompt_dir() {
  if [[ -n "$PROMPT_DIR" ]]; then
    echo "$PROMPT_DIR"
    return 0
  fi

  echo "${_CODER_REPO_ROOT}/docs/prompts"
}

# state.json または plan_path から task_id を導出
_coder_get_task_id() {
  local plan_path="$1"
  local task_id=""

  if [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE:-}" ]]; then
    task_id=$(jq -r '.task.id // empty' "$STATE_FILE" 2>/dev/null || true)
  fi

  if [[ -z "$task_id" ]]; then
    local plan_name
    plan_name="$(basename "$plan_path")"
    plan_name="${plan_name%.*}"
    task_id="$(printf '%s' "$plan_name" | tr -c '[:alnum:]._-' '_')"
    task_id="${task_id##[_-]}"
    task_id="${task_id%%[_-]}"
  fi

  if [[ -z "$task_id" ]]; then
    task_id="task_$(date +%Y%m%d_%H%M%S)"
  fi

  _validate_identifier "$task_id" "task_id"
  echo "$task_id"
}

_coder_resolve_engine() {
  local engine="${1:-${CODER_ENGINE:-codex}}"

  case "$engine" in
    claude|codex)
      printf '%s\n' "$engine"
      ;;
    *)
      die "Unsupported coder engine: ${engine:-<empty>} (allowed: claude|codex)"
      ;;
  esac
}

_coder_engine_label() {
  local engine
  engine=$(_coder_resolve_engine "${1:-}")

  case "$engine" in
    claude) printf 'Claude\n' ;;
    codex) printf 'Codex\n' ;;
  esac
}

_coder_codex_routing_context() {
  local plan_path="$1"

  local complexity
  complexity=$(coder_analyze_task_complexity "$plan_path")

  local security_sensitive
  security_sensitive=$(_coder_is_security_sensitive_plan "$plan_path")

  local codex_role
  codex_role=$(select_codex_role_by_complexity "$plan_path")

  local context_mode="diff"
  if [[ "$security_sensitive" == "true" ]]; then
    codex_role="high-coder"
    context_mode="full"
  fi

  if ! _coder_validate_codex_role "$codex_role"; then
    die "Coder role resolution failed: ${codex_role:-<empty>} (allowed: standard|research|coder|high-coder|reviewer)"
  fi

  local wrapper_path
  wrapper_path=$(_coder_resolve_wrapper_path)
  if [[ ! -x "$wrapper_path" ]]; then
    die "Canonical Codex wrapper not found or not executable: $wrapper_path"
  fi

  local wrapper_label
  wrapper_label=$(basename "$wrapper_path")

  cat <<EOF
engine: codex
wrapper: ${wrapper_label}
role: ${codex_role}
complexity: ${complexity}
security-sensitive: ${security_sensitive}
context-mode: ${context_mode}
EOF

  if [[ "$security_sensitive" == "true" ]]; then
    printf '%s\n' "Security-sensitive task detected. Use full-context analysis; do not rely on diff-only reasoning."
  fi
}

_coder_run_codex_prompt() {
  local plan_path="$1"
  local prompt="$2"
  local output_file="$3"

  local routing_context
  routing_context=$(_coder_codex_routing_context "$plan_path")

  local codex_role
  codex_role=$(printf '%s\n' "$routing_context" | awk -F': ' '$1 == "role" { print $2; exit }')
  local wrapper_label
  wrapper_label=$(printf '%s\n' "$routing_context" | awk -F': ' '$1 == "wrapper" { print $2; exit }')
  local wrapper_path
  wrapper_path=$(_coder_resolve_wrapper_path)

  log_info "Coder routing (${wrapper_label}):"
  while IFS= read -r routing_line; do
    [[ -n "$routing_line" ]] || continue
    log_info "  $routing_line"
  done <<< "$routing_context"

  local prompt_file
  prompt_file=$(create_temp_file "coder_prompt")
  if [[ -z "$prompt_file" ]]; then
    die "_coder_run_codex_prompt: failed to create temp prompt file"
  fi
  if ! printf '%s' "$prompt" > "$prompt_file"; then
    /bin/rm -f "$prompt_file" 2>/dev/null || true
    die "_coder_run_codex_prompt: failed to write prompt file"
  fi
  if ! _coder_guard_prompt_file "$prompt_file" "coder:$codex_role"; then
    /bin/rm -f "$prompt_file" 2>/dev/null || true
    log_error "Coder prompt budget guard blocked launch (engine: codex, role: $codex_role)"
    return 1
  fi

  local start_epoch
  start_epoch=$(date +%s)

  local run_exit=0
  if "$wrapper_path" --role "$codex_role" --stdin < "$prompt_file" > "$output_file" 2>&1; then
    log_info "Coder execution completed (engine: codex, role: $codex_role, wrapper: $wrapper_label)"
  else
    run_exit=$?
    /bin/rm -f "$prompt_file" 2>/dev/null || true
    if [[ -f "$output_file" ]]; then
      _coder_scan_output_file "$output_file" "coder:$codex_role" || true
    fi
    log_error "Coder execution failed (engine: codex, role: $codex_role, wrapper: $wrapper_label, exit: $run_exit)"
    return "$run_exit"
  fi

  /bin/rm -f "$prompt_file" 2>/dev/null || true

  if ! _coder_scan_output_file "$output_file" "coder:$codex_role"; then
    log_error "Coder output marker guard blocked promotion (engine: codex, role: $codex_role)"
    return 1
  fi

  local session_id
  session_id=$(get_latest_codex_session "$start_epoch" 2>/dev/null || true)

  if [[ -n "$session_id" ]]; then
    log_info "Coder session: $session_id"
    log_info "Coder output: $output_file"
  else
    log_warn "Session ID not captured, but output may still be valid"
  fi

  echo "$session_id"
}

_coder_run_claude_prompt() {
  local prompt="$1"
  local output_file="$2"

  log_info "Coder routing (Claude session runtime):"
  log_info "  engine: claude"
  log_info "  runtime: session_start"

  local session_id
  session_id=$(session_start "$prompt" "$output_file")
  if [[ -n "$session_id" ]]; then
    log_info "Coder session: $session_id"
    log_info "Coder output: $output_file"
  fi

  echo "$session_id"
}

# RV-0: reviewerテンプレート必須チェック（fail-closed）
_coder_require_reviewer_templates() {
  local prompt_dir="$1"
  local required=(
    "reviewer_safety.md"
    "reviewer_perf.md"
    "reviewer_consistency.md"
  )
  local missing=()
  local file=""
  for file in "${required[@]}"; do
    if [[ ! -f "$prompt_dir/$file" ]]; then
      missing+=("$prompt_dir/$file")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    local joined
    joined=$(IFS=', '; echo "${missing[*]}")
    die "Phase 3 blocked (RV-0): reviewer templates missing: $joined"
  fi
}

# 文字数上限でテキストを丸める（過大コンテキスト防止）
_coder_truncate_text() {
  local text="${1:-}"
  local max_chars="${2:-2600}"

  if ! [[ "$max_chars" =~ ^[0-9]+$ ]] || [[ "$max_chars" -le 0 ]]; then
    max_chars=2600
  fi

  if [[ ${#text} -le "$max_chars" ]]; then
    printf '%s' "$text"
    return 0
  fi

  local keep=$((max_chars - 80))
  if [[ "$keep" -lt 0 ]]; then
    keep=0
  fi
  printf '%s\n[truncated: context budget exceeded]' "${text:0:$keep}"
}

# capsule_build を関数優先で呼び出し、未ロード時はサブプロセスで実行
_coder_call_capsule_build() {
  local task_id="$1"
  local phase="$2"
  local budget="${3:-220}"

  if [[ "$(type -t capsule_build 2>/dev/null || true)" == "function" ]]; then
    capsule_build "$task_id" "$phase" --budget "$budget"
    return $?
  fi

  if [[ -f "$_CODER_CONTEXT_CAPSULE_SH" ]]; then
    bash "$_CODER_CONTEXT_CAPSULE_SH" build "$task_id" "$phase" --budget "$budget"
    return $?
  fi

  return 1
}

# select_window を関数優先で呼び出し、未ロード時はサブプロセスで実行
_coder_call_select_window() {
  local role="${1:-coder}"
  local base_ref="${2:-HEAD~1}"
  local head_ref="${3:-HEAD}"
  local explicit_extra_windows="${4:-0}"

  if [[ "$(type -t select_window 2>/dev/null || true)" == "function" ]]; then
    select_window "$role" "$base_ref" "$head_ref" "$explicit_extra_windows"
    return $?
  fi

  if [[ -f "$_CODER_CONTEXT_CAPSULE_SH" ]]; then
    bash -c 'set -euo pipefail; source "$1"; select_window "$2" "$3" "$4" "$5"' \
      _ "$_CODER_CONTEXT_CAPSULE_SH" "$role" "$base_ref" "$head_ref" "$explicit_extra_windows"
    return $?
  fi

  return 1
}

# delta サブコマンド呼び出し（未実装時は非0終了）
_coder_call_context_delta() {
  local base_ref="${1:-HEAD~1}"
  local head_ref="${2:-HEAD}"

  if [[ -f "$_CODER_CONTEXT_ANALYSIS_SH" ]]; then
    bash "$_CODER_CONTEXT_ANALYSIS_SH" delta "$base_ref" "$head_ref"
    return $?
  fi

  return 1
}

# diff-impact 呼び出し（関数優先、未ロード時はCLI）
_coder_call_context_diff_impact() {
  local base_ref="${1:-HEAD~1}"
  local head_ref="${2:-HEAD}"

  if [[ "$(type -t context_diff_impact 2>/dev/null || true)" == "function" ]]; then
    context_diff_impact "$base_ref" "$head_ref"
    return $?
  fi

  if [[ -f "$_CODER_CONTEXT_ANALYSIS_SH" ]]; then
    bash "$_CODER_CONTEXT_ANALYSIS_SH" diff-impact "$base_ref" "$head_ref"
    return $?
  fi

  return 1
}

_coder_summarize_capsule_json() {
  local capsule_json="$1"
  jq -r '
    (.capsule // "") as $capsule
    | (.constraints // []) as $constraints
    | (.hints // []) as $hints
    | if ($capsule | length) == 0 then
        ""
      else
        "# Semantic Capsule\n"
        + $capsule
        + (if ($constraints | length) > 0 then "\nconstraints=" + ($constraints | join("; ")) else "" end)
        + (if ($hints | length) > 0 then "\nhints=" + ($hints | join("; ")) else "" end)
      end
  ' <<< "$capsule_json" 2>/dev/null || true
}

_coder_summarize_windows_json() {
  local windows_json="$1"
  local preview_lines="${2:-12}"

  if ! [[ "$preview_lines" =~ ^[0-9]+$ ]] || [[ "$preview_lines" -le 0 ]]; then
    preview_lines=12
  fi

  jq -r --argjson preview_lines "$preview_lines" '
    (.windows // []) as $windows
    | if ($windows | length) == 0 then
        ""
      else
        (
          "# Window Selection\n"
          + "algorithm=" + (.selection_algorithm // "unknown")
          + "; tree_sitter_used=" + ((.tree_sitter_used // false) | tostring)
          + "; windows=" + (($windows | length) | tostring)
          + "\n"
          + (
              $windows[:3]
              | to_entries
              | map(
                  "[" + ((.key + 1) | tostring) + "] "
                  + (.value.path // "unknown")
                  + " lines=" + ((.value.start // 0) | tostring) + "-" + ((.value.end // 0) | tostring)
                  + " reason=" + (.value.reason // "n/a")
                )
              | join("\n")
            )
        )
        + (
            ($windows[0].snippet // "") as $snippet
            | if ($snippet | length) > 0 then
                "\n\n# Primary Window Preview\n"
                + (
                    $snippet
                    | split("\n")
                    | .[:$preview_lines]
                    | join("\n")
                  )
              else
                ""
              end
          )
      end
  ' <<< "$windows_json" 2>/dev/null || true
}

_coder_build_capsule_window_context() {
  local plan_path="$1"
  local phase="$2"
  local context_budget="${CODER_CONTEXT_CHAR_BUDGET:-2600}"
  local task_id=""
  local capsule_section=""
  local window_section=""
  local composed=""

  if [[ "$_HAS_CAPSULE" != "true" ]]; then
    return 0
  fi

  task_id=$(_coder_get_task_id "$plan_path")

  local capsule_json=""
  capsule_json=$(_coder_call_capsule_build "$task_id" "$phase" "${CODER_CAPSULE_BUDGET:-220}" 2>/dev/null || true)
  if [[ -n "$capsule_json" ]] && jq -e . >/dev/null 2>&1 <<< "$capsule_json"; then
    capsule_section=$(_coder_summarize_capsule_json "$capsule_json")
  else
    log_warn "capsule_build失敗または非JSON応答: カプセル注入をスキップ"
  fi

  local windows_json=""
  windows_json=$(_coder_call_select_window "coder" "${CODER_WINDOW_BASE_REF:-HEAD~1}" "${CODER_WINDOW_HEAD_REF:-HEAD}" "${CODER_WINDOW_EXTRA_WINDOWS:-0}" 2>/dev/null || true)
  if [[ -n "$windows_json" ]] && jq -e . >/dev/null 2>&1 <<< "$windows_json"; then
    window_section=$(_coder_summarize_windows_json "$windows_json" "${CODER_WINDOW_PREVIEW_LINES:-12}")
  else
    log_warn "select_window失敗または非JSON応答: 窓注入をスキップ"
  fi

  if [[ -n "$capsule_section" || -n "$window_section" ]]; then
    composed="# Semantic Context"
    if [[ -n "$capsule_section" ]]; then
      composed+=$'\n'"$capsule_section"
    fi
    if [[ -n "$window_section" ]]; then
      composed+=$'\n\n'"$window_section"
    fi
    _coder_truncate_text "$composed" "$context_budget"
  fi
}

_coder_summarize_diff_json() {
  local diff_json="$1"
  jq -r '
    (.changed_files // []) as $files
    | (.changed_symbols // []) as $changed
    | (.impacted_symbols // []) as $impacted
    | "changed_files=" + (($files | length) | tostring)
      + "; changed_symbols=" + (($changed | length) | tostring)
      + "; impacted_symbols=" + (($impacted | length) | tostring)
      + "\nfiles=" + (if ($files | length) > 0 then ($files[:8] | join(", ")) else "none" end)
      + "\nchanged=" + (
          if ($changed | length) > 0 then
            (
              $changed[:8]
              | map(
                  if type == "string" then
                    .
                  else
                    (.logical_id // .name // ((.file // "?") + ":" + ((.line // 0) | tostring)))
                  end
                )
              | join(", ")
            )
          else
            "none"
          end
        )
      + "\nimpacted=" + (
          if ($impacted | length) > 0 then
            (
              $impacted[:8]
              | map(
                  if type == "string" then
                    .
                  else
                    (.logical_id // .ref_name // ((.file // "?") + ":" + ((.line // 0) | tostring)))
                  end
                )
              | join(", ")
            )
          else
            "none"
          end
        )
  ' <<< "$diff_json" 2>/dev/null || true
}

_coder_build_delta_context() {
  local base_ref="${1:-HEAD~1}"
  local head_ref="${2:-HEAD}"
  local delta_json=""
  local summary=""
  local block=""

  if [[ "$_HAS_CONTEXT_ANALYSIS" != "true" ]]; then
    return 0
  fi

  # 優先: context_analysis.sh delta（未実装環境では自動フォールバック）
  delta_json=$(_coder_call_context_delta "$base_ref" "$head_ref" 2>/dev/null || true)

  if [[ -z "$delta_json" ]] || ! jq -e . >/dev/null 2>&1 <<< "$delta_json"; then
    delta_json=$(_coder_call_context_diff_impact "$base_ref" "$head_ref" 2>/dev/null || true)
  fi

  if [[ -z "$delta_json" ]] || ! jq -e . >/dev/null 2>&1 <<< "$delta_json"; then
    log_warn "delta注入失敗: context_analysis delta/context_diff_impact を取得できませんでした"
    return 0
  fi

  summary=$(_coder_summarize_diff_json "$delta_json")
  if [[ -z "$summary" ]]; then
    return 0
  fi

  block="# Delta Context"$'\n'
  block+="mode=diff_only;base_ref=${base_ref};head_ref=${head_ref}"$'\n'
  block+="$summary"
  _coder_truncate_text "$block" "${CODER_DELTA_CONTEXT_CHAR_BUDGET:-1600}"
}

# プロンプトディレクトリ（呼び出し元で設定されていなければデフォルト）
PROMPT_DIR="${PROMPT_DIR:-}"

# プロンプト構築
# Usage: coder_build_prompt <plan_path> <phase> [extra_context]
# Returns: 構築されたプロンプト（stdoutに出力）
coder_build_prompt() {
  local plan_path="$1"
  local phase="$2"
  local extra_context="${3:-}"

  if [[ -z "$plan_path" ]]; then
    die "coder_build_prompt: plan_path is required"
  fi

  if [[ ! -f "$plan_path" ]]; then
    die "coder_build_prompt: plan file not found: $plan_path"
  fi

  if [[ -z "$phase" ]]; then
    die "coder_build_prompt: phase is required"
  fi

  # フェーズ名を検証（セキュリティ）
  _validate_identifier "$phase" "phase"

  # プロンプトディレクトリを決定
  local prompt_dir
  prompt_dir=$(_coder_get_prompt_dir)

  # RV-0: reviewerテンプレート必須（未配置なら fail-closed）
  _coder_require_reviewer_templates "$prompt_dir"

  # フェーズ別プロンプト
  local prompt_file="$prompt_dir/coder_phase_${phase}.md"
  if [[ ! -f "$prompt_file" ]]; then
    # フォールバック: impl プロンプト
    prompt_file="$prompt_dir/coder_phase_impl.md"
  fi

  local phase_prompt=""
  if [[ -f "$prompt_file" ]]; then
    phase_prompt=$(cat "$prompt_file")
  else
    log_warn "No phase prompt found, using minimal instructions"
    phase_prompt="Execute the ${phase} phase according to the plan."
  fi

  # カプセル + 250行窓注入（互換ガード付き）
  local semantic_context=""
  semantic_context=$(_coder_build_capsule_window_context "$plan_path" "$phase")

  # プロンプト構築（ヒアドキュメント内の $(...) 展開を防ぐため、変数は別途追記）
  {
    cat <<'EOF'
# Plan
EOF
    cat "$plan_path"
    cat <<'EOF'

# Phase Instructions
EOF
    printf '%s\n' "$phase_prompt"
    cat <<'EOF'

# Reference Policy (M-REG-03)
- 既存実装・既存仕様は参照情報です。追従を強制しません。
- 代替案を採用して構いません。採用時は理由・影響・移行要否を簡潔に記述してください。

# Context
EOF
    printf 'Current phase: %s\n' "$phase"
    if [[ -n "$semantic_context" ]]; then
      printf '\n%s\n' "$semantic_context"
    fi
    if [[ -n "$extra_context" ]]; then
      printf '\n# Additional Context\n%s\n' "$extra_context"
    fi
    cat <<'EOF'

# Output Format
- 変更差分とテスト結果を Markdown で出力
- 末尾に `---OUTPUT-END---` を付ける
EOF
  }
}

# Coder 実行（新規セッション）
# Usage: coder_run <plan_path> <phase> <output_file> [extra_context] [engine]
# Returns: session_id（stdoutに出力）、実行結果は output_file に保存
coder_run() {
  local plan_path="$1"
  local phase="$2"
  local output_file="$3"
  local extra_context="${4:-}"
  local engine
  engine=$(_coder_resolve_engine "${5:-}")

  if [[ -z "$output_file" ]]; then
    die "coder_run: output_file is required"
  fi

  local routing_context=""
  routing_context+="# Model Routing"$'\n'
  routing_context+="engine: ${engine}"
  if [[ "$engine" == "codex" ]]; then
    routing_context+=$'\n'"$(_coder_codex_routing_context "$plan_path")"
  else
    routing_context+=$'\n'"runtime: session_start"
  fi

  local merged_extra_context="$routing_context"
  if [[ -n "$extra_context" ]]; then
    merged_extra_context="${extra_context}"$'\n\n'"${routing_context}"
  fi

  # プロンプト構築
  local prompt
  prompt=$(coder_build_prompt "$plan_path" "$phase" "$merged_extra_context")

  if [[ "$engine" == "codex" ]]; then
    _coder_run_codex_prompt "$plan_path" "$prompt" "$output_file"
  else
    _coder_run_claude_prompt "$prompt" "$output_file"
  fi
}

# Coder 修正実行
# Usage: coder_run_fix <plan_path> <phase> <reviews_file> <iteration> <output_file> [session_id] [fix_until] [engine]
# Returns: session_id（stdoutに出力）
# fix_until: high | medium | low | all（デフォルト: all）
coder_run_fix() {
  local plan_path="$1"
  local phase="$2"
  local reviews_file="$3"
  local iteration="$4"
  local output_file="$5"
  local session_id="${6:-}"
  local fix_until="${7:-all}"
  local engine
  engine=$(_coder_resolve_engine "${8:-}")

  if [[ -z "$reviews_file" || ! -f "$reviews_file" ]]; then
    die "coder_run_fix: reviews_file not found: $reviews_file"
  fi

  if [[ -z "$output_file" ]]; then
    die "coder_run_fix: output_file is required"
  fi

  local prompt_dir
  prompt_dir=$(_coder_get_prompt_dir)
  _coder_require_reviewer_templates "$prompt_dir"

  log_info "Running Coder fix iteration $iteration for phase: $phase"

  # fix_until に基づいた動的メッセージ
  local fix_message
  case "$fix_until" in
    high)
      fix_message="[High] 重大度の指摘を必ず解消してください。"
      ;;
    medium)
      fix_message="[High] と [Medium] 重大度の指摘を必ず解消してください。"
      ;;
    low|all|*)
      fix_message="[High]、[Medium]、[Low] すべての指摘を解消してください。"
      ;;
  esac

  local delta_context=""
  if [[ "$iteration" =~ ^[0-9]+$ ]] && [[ "$iteration" -ge 1 ]]; then
    delta_context=$(_coder_build_delta_context "${CODER_DELTA_BASE_REF:-HEAD~1}" "${CODER_DELTA_HEAD_REF:-HEAD}")
  fi

  # 修正プロンプト構築（ヒアドキュメント内の $(...) 展開を防ぐため、変数は別途追記）
  local fix_prompt
  fix_prompt=$({
    printf '# Review Feedback (Iteration %s)\n' "$iteration"
    printf '%s\n\n' "$fix_message"
    cat "$reviews_file"
    cat <<'EOF'

# Original Plan
EOF
    cat "$plan_path"
    if [[ -n "$delta_context" ]]; then
      printf '\n%s\n' "$delta_context"
    fi
    cat <<'EOF'

# Instructions
- 上記の重大度に応じた指摘を解消する
- 既存実装は参照情報として扱い、必要なら代替案を採用してよい
- 変更差分とテスト結果を Markdown で出力
- 末尾に `---OUTPUT-END---` を付ける

---OUTPUT-END---
EOF
  })

  local new_session_id=""

  if [[ "$engine" == "codex" ]]; then
    if [[ -n "$session_id" ]]; then
      log_warn "Codex coder engine does not support continue/fork for fix iterations in orchestrator mode; starting a new Codex run"
    fi
    fix_prompt="# Model Routing"$'\n'"engine: codex"$'\n'"mode: fix"$'\n\n'"${fix_prompt}"
    new_session_id=$(_coder_run_codex_prompt "$plan_path" "$fix_prompt" "$output_file")
  else
    if [[ -n "$session_id" ]] && _validate_session_id "$session_id"; then
      log_info "Non-interactive invariant: starting a fresh Claude coder session instead of resuming $session_id"
    fi
    new_session_id=$(session_start "$fix_prompt" "$output_file")
  fi

  if [[ -n "$new_session_id" ]]; then
    log_info "Fix session: $new_session_id"
  fi

  echo "$new_session_id"
}

# Coder セッション継続
# Usage: coder_resume <session_id> <prompt> <output_file> [engine]
# Returns: 0 on success, 1 on failure
coder_resume() {
  local session_id="$1"
  local prompt="$2"
  local output_file="$3"
  local engine
  engine=$(_coder_resolve_engine "${4:-claude}")

  if [[ -z "$session_id" ]]; then
    die "coder_resume: session_id is required"
  fi

  if [[ -z "$prompt" ]]; then
    die "coder_resume: prompt is required"
  fi

  if [[ -z "$output_file" ]]; then
    die "coder_resume: output_file is required"
  fi

  if [[ "$engine" == "codex" ]]; then
    log_warn "Codex coder engine does not support session resume in orchestrator mode"
    return 1
  fi

  log_error "Coder session resume is disabled by the non-interactive invariant; start a fresh Claude session instead"
  return 1
}

# Coder セッション分岐
# Usage: coder_fork <parent_session_id> <prompt> <output_file> [engine]
# Returns: new_session_id（stdoutに出力）
coder_fork() {
  local parent_session_id="$1"
  local prompt="$2"
  local output_file="$3"
  local engine
  engine=$(_coder_resolve_engine "${4:-claude}")

  if [[ -z "$parent_session_id" ]]; then
    die "coder_fork: parent_session_id is required"
  fi

  if [[ -z "$prompt" ]]; then
    die "coder_fork: prompt is required"
  fi

  if [[ -z "$output_file" ]]; then
    die "coder_fork: output_file is required"
  fi

  if [[ "$engine" == "codex" ]]; then
    log_warn "Codex coder engine does not support session fork in orchestrator mode"
    return 1
  fi

  log_error "Coder session fork is disabled by the non-interactive invariant; start a fresh Claude session instead"
  return 1
}

# Coder 実行（タイムアウト付き）
# Usage: coder_run_with_timeout <timeout_secs> <plan_path> <phase> <output_file> [session_id]
# Returns: 0 on success, 124 on timeout, other on error
coder_run_with_timeout() {
  local timeout_secs="$1"
  local plan_path="$2"
  local phase="$3"
  local output_file="$4"
  local session_id="${5:-}"

  log_info "Running Coder with timeout: ${timeout_secs}s"

  # プロンプト構築
  local prompt
  prompt=$(coder_build_prompt "$plan_path" "$phase")

  # セッション実行（タイムアウト付き）
  if [[ -n "$session_id" && "$session_id" != "new" ]]; then
    log_info "Non-interactive invariant: ignoring prior session $session_id and starting a fresh Claude session"
    session_id="new"
  fi

  if session_run_with_timeout "$timeout_secs" "$session_id" "$prompt" "$output_file"; then
    log_info "Coder completed within timeout"
    return 0
  else
    local ret=$?
    if [[ $ret -eq 124 ]]; then
      log_warn "Coder timed out after ${timeout_secs}s"
    else
      log_warn "Coder returned error: $ret"
    fi
    return $ret
  fi
}

# Coder 出力検証
# Usage: coder_validate_output <output_file>
# Returns: 0 if valid (contains OUTPUT-END marker), 1 if incomplete
coder_validate_output() {
  local output_file="$1"

  if [[ ! -f "$output_file" ]]; then
    log_warn "Output file not found: $output_file"
    return 1
  fi

  if [[ ! -s "$output_file" ]]; then
    log_warn "Output file is empty: $output_file"
    return 1
  fi

  # OUTPUT-END マーカーを確認
  if grep -q '\-\-\-OUTPUT-END\-\-\-' "$output_file"; then
    log_debug "Output validated: $output_file"
    return 0
  else
    log_warn "Output missing ---OUTPUT-END--- marker: $output_file"
    return 1
  fi
}

# state.json にCoder情報を記録
# Usage: coder_record_to_state <phase> <session_id> <output_file> [engine] [parent_session_id]
coder_record_to_state() {
  local phase="$1"
  local session_id="$2"
  local output_file="$3"
  local engine
  engine=$(_coder_resolve_engine "${4:-}")
  local parent_session_id="${5:-}"

  # jq 依存チェック
  _ensure_jq_coder

  if [[ -z "$phase" ]]; then
    log_warn "coder_record_to_state: phase is empty"
    return 1
  fi

  local phase_idx
  phase_idx=$(state_find_phase "$phase")

  if [[ "$phase_idx" == "-1" ]]; then
    log_warn "Phase not found in state: $phase"
    return 1
  fi

  # coder 情報を更新
  local coder_obj
  coder_obj=$(jq -n \
    --arg out "$output_file" \
    --arg eng "$engine" \
    '{
      output_file: $out,
      engine: $eng
    }')

  state_set ".phases[$phase_idx].coder" "$coder_obj"

  # セッションも記録（session_id がある場合）
  if [[ -n "$session_id" ]]; then
    local iteration
    iteration=$(state_get ".phases[$phase_idx].iteration")
    [[ -z "$iteration" || "$iteration" == "null" ]] && iteration=0
    state_record_session "$session_id" "$phase" "$iteration" "$engine" "$parent_session_id"
  fi

  state_save
  log_debug "Coder info recorded to state for phase: $phase"
}

# 最新の Coder 出力ファイルを取得
# Usage: coder_get_latest_output <phase> <tmpdir>
# Returns: output_file path（stdoutに出力）
coder_get_latest_output() {
  local phase="$1"
  local tmpdir="$2"

  if [[ -z "$tmpdir" || ! -d "$tmpdir" ]]; then
    return 1
  fi

  # フェーズ名検証
  _validate_identifier "$phase" "phase"

  # 最新の修正ファイルを探す（fix3, fix2, fix1 の順）
  local i
  for i in 10 9 8 7 6 5 4 3 2 1; do
    local fix_file="$tmpdir/${phase}_coder_fix${i}.md"
    if [[ -f "$fix_file" ]]; then
      echo "$fix_file"
      return 0
    fi
  done

  # 修正ファイルがなければオリジナル
  local original="$tmpdir/${phase}_coder.md"
  if [[ -f "$original" ]]; then
    echo "$original"
    return 0
  fi

  return 1
}
