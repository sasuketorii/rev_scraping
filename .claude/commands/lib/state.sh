#!/usr/bin/env bash
# state.sh - state.json 操作関数
# エージェント自動化システム用

# 依存: utils.sh が先に読み込まれていること
# 依存: jq コマンド

# jq パス検証（インジェクション防止）
# 許可パターン: .foo, .foo_bar, .foo[0], .foo.bar[1].baz など
# Usage: _validate_jq_path <jq_path>
# Returns: 0 if valid, 1 if invalid
_validate_jq_path() {
  local jq_path="$1"

  # 空文字列は不正
  if [[ -z "$jq_path" ]]; then
    return 1
  fi

  # 許可されるパターン:
  # - 先頭は "." で始まる
  # - 識別子: [a-zA-Z_][a-zA-Z0-9_]*
  # - 配列インデックス: \[[0-9]+\]
  # - これらの組み合わせ
  local pattern='^(\.[a-zA-Z_][a-zA-Z0-9_]*|\[[0-9]+\])+$'
  if [[ "$jq_path" =~ $pattern ]]; then
    return 0
  else
    return 1
  fi
}

# グローバル変数
STATE_FILE=""
STATE_DIR=""
STATE_LOCK_FILE=""
STATE_LOCK_TIMEOUT="${STATE_LOCK_TIMEOUT:-30}"

# state.json スキーマバージョン
readonly STATE_SCHEMA_VERSION="2.0.0"

_state_normalize_plan_path() {
  local plan_path="${1:-}"
  local abs_path=""
  local abs_dir=""
  local repo_root=""

  [[ -n "$plan_path" ]] || return 1

  abs_dir="$(cd "$(dirname "$plan_path")" && pwd -P)" || return 1
  abs_path="${abs_dir}/$(basename "$plan_path")"
  repo_root="$(git -C "$abs_dir" rev-parse --show-toplevel 2>/dev/null || true)"

  if [[ -n "$repo_root" ]]; then
    repo_root="$(cd "$repo_root" && pwd -P)" || return 1
    case "$abs_path" in
      "$repo_root"/*)
        printf '%s\n' "${abs_path#"$repo_root"/}"
        return 0
        ;;
    esac
  fi

  printf '%s\n' "$abs_path"
}

_state_resolve_plan_path() {
  local plan_path="${1:-}"
  local repo_root="${2:-${REPO_ROOT:-}}"
  local candidate_path=""
  local abs_dir=""

  [[ -n "$plan_path" ]] || return 1

  if [[ "$plan_path" == /* ]]; then
    candidate_path="$plan_path"
  elif [[ -n "$repo_root" ]]; then
    repo_root="$(cd "$repo_root" && pwd -P)" || return 1
    candidate_path="${repo_root}/${plan_path}"
  else
    candidate_path="$plan_path"
  fi

  abs_dir="$(cd "$(dirname "$candidate_path")" && pwd -P)" || return 1
  printf '%s\n' "${abs_dir}/$(basename "$candidate_path")"
}

_state_resolve_coder_engine() {
  local engine="${1:-}"

  if [[ -z "$engine" && -n "${STATE_FILE:-}" && -f "${STATE_FILE:-}" ]]; then
    engine=$(jq -r '.assignments.coder_engine // empty' "$STATE_FILE" 2>/dev/null || true)
  fi

  if [[ -z "$engine" ]]; then
    engine="codex"
  fi

  case "$engine" in
    claude|codex)
      printf '%s\n' "$engine"
      ;;
    *)
      die "Unsupported coder engine in state: ${engine:-<empty>} (allowed: claude|codex)"
      ;;
  esac
}

state_phase_has_engine_metadata() {
  local phase="${1:-}"

  if [[ -z "$STATE_FILE" ]]; then
    die "State not initialized."
  fi

  jq -e --arg p "$phase" '
    (.sessions.coder_sessions // [])
    | any(
        .phase == $p
        and ((.engine // null) | type) == "string"
        and (.engine == "claude" or .engine == "codex")
      )
  ' "$STATE_FILE" >/dev/null
}

state_phase_has_invalid_engine_metadata() {
  local phase="${1:-}"

  if [[ -z "$STATE_FILE" ]]; then
    die "State not initialized."
  fi

  jq -e --arg p "$phase" '
    (.sessions.coder_sessions // [])
    | any(
        .phase == $p
        and (.engine // null) != null
        and (
          ((.engine | type) != "string")
          or (
            (.engine | type) == "string"
            and (.engine | length) > 0
            and (.engine != "claude" and .engine != "codex")
          )
        )
      )
  ' "$STATE_FILE" >/dev/null
}

state_get_last_legacy_session() {
  local phase="${1:-}"

  if [[ -z "$STATE_FILE" ]]; then
    die "State not initialized."
  fi

  jq -r --arg p "$phase" '
    (.sessions.coder_sessions // [])
    | map(
        select(
          .phase == $p
          and (
            if (.engine // null) == null then
              true
            else
              ((.engine | type) == "string" and (.engine | length) == 0)
            end
          )
        )
      )
    | last
    | .session_id // empty
  ' "$STATE_FILE"
}

# ロック取得ヘルパー（内部用）
_state_lock() {
  if [[ -z "$STATE_LOCK_FILE" ]]; then
    return 0  # ロックファイルが設定されていない場合はスキップ
  fi
  lock_acquire "$STATE_LOCK_FILE" "$STATE_LOCK_TIMEOUT"
}

# ロック解放ヘルパー（内部用）
_state_unlock() {
  if [[ -z "$STATE_LOCK_FILE" ]]; then
    return 0
  fi
  lock_release "$STATE_LOCK_FILE"
}

_state_live_scrub_filter() {
  printf '%s\n' '
def walk(f):
  . as $in
  | if type == "object" then
      reduce keys_unsorted[] as $key
        ({}; .[$key] = ($in[$key] | walk(f)))
      | f
    elif type == "array" then
      map(walk(f))
      | f
    else
      f
    end;

def contract_coder_sessions:
  (
    if (.sessions | type) == "object" then
      .sessions.coder_sessions
    else
      []
    end
  )
  | if type == "array" then
      map(
        select(
          type == "object"
          and (.session_id // null) != null
          and (.session_id | type) == "string"
          and (.session_id | length) > 0
        )
        | {
            session_id: .session_id,
            phase: (.phase // null),
            iteration: (.iteration // null),
            created_at: (.created_at // null)
          }
        + (
            if (.engine // null) != null then
              { engine: .engine }
            else
              {}
            end
          )
        + (
            if (.parent_session_id // null) != null then
              { parent_session_id: .parent_session_id }
            else
              {}
            end
          )
      )
    else
      []
    end;

. as $root
| walk(
    if type == "object" then
      del(
        .reviews,
        .fixes,
        .review,
        .reviewers,
        .reviewer,
        .review_file,
        .review_files,
        .review_output,
        .review_outputs,
        .reviewer_output,
        .reviewer_outputs,
        .review_session,
        .review_sessions,
        .reviewer_session,
        .reviewer_sessions,
        .review_trace,
        .reviewer_trace,
        .review_payload,
        .reviewer_payload,
        .session_id,
        .session_ids,
        .parent_session_id,
        .last_session_id,
        .last_reviewer_session_id
      )
    else
      .
    end
  )
| .phases = (
  ($root.phases // []) as $root_phases
  | (.phases // []) as $scrubbed_phases
  | if ($scrubbed_phases | type) == "array" then
      [
        range(0; ($scrubbed_phases | length)) as $idx
        | ($scrubbed_phases[$idx]) as $phase
        | if ($phase | type) == "object" then
            $phase
          else
            empty
          end
      ]
    else
      []
    end
)
| .sessions = {
    coder_sessions: ($root | contract_coder_sessions)
  }
'
}

_state_scrub_live_state_locked() {
  local tmp_file
  tmp_file=$(create_temp_file "state_scrub")

  if ! jq -f <(_state_live_scrub_filter) "$STATE_FILE" > "$tmp_file"; then
    /bin/rm -f "$tmp_file"
    return 1
  fi

  if ! mv "$tmp_file" "$STATE_FILE"; then
    /bin/rm -f "$tmp_file"
    return 1
  fi

  return 0
}

_state_scrub_live_state() {
  if [[ -z "$STATE_FILE" ]]; then
    die "State not initialized."
  fi

  _state_lock || die "Failed to acquire state lock"
  if ! _state_scrub_live_state_locked; then
    _state_unlock
    die "Failed to scrub live state file"
  fi
  _state_unlock
}

# 新規 state.json 生成
# Usage: state_init <plan_path> <task_name> [output_dir]
state_init() {
  local plan_path="$1"
  local task_name="$2"
  local output_dir="${3:-}"
  local normalized_plan_path=""

  ensure_cmd jq
  normalized_plan_path=$(_state_normalize_plan_path "$plan_path") || die "state_init: failed to normalize plan_path: $plan_path"

  # 出力ディレクトリ決定
  if [[ -z "$output_dir" ]]; then
    # スクリプトの場所から .claude/tmp/<task_name> を計算
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    output_dir="$(dirname "$script_dir")/tmp/${task_name}"
  fi

  ensure_dir "$output_dir"

  STATE_DIR="$output_dir"
  STATE_FILE="${output_dir}/state.json"
  STATE_LOCK_FILE="${output_dir}/.state.lock"

  local task_id
  task_id=$(generate_uuid)
  local now
  now=$(get_timestamp)

  # 初期 state.json 生成（jqで安全にJSON生成）
  jq -n \
    --arg version "$STATE_SCHEMA_VERSION" \
    --arg task_id "$task_id" \
    --arg task_name "$task_name" \
    --arg plan_path "$normalized_plan_path" \
    --arg now "$now" \
    '{
      version: $version,
      task: {
        id: $task_id,
        name: $task_name,
        plan_path: $plan_path,
        contract_id: null,
        contract_path: null
      },
      status: "pending",
      current_phase: null,
      assignments: {},
      phases: [],
      quality_gate: {
        level: null,
        status: "pending"
      },
      sessions: {
        coder_sessions: []
      },
      timeouts: {
        codex_secs: 7200,
        claude_secs: 1800
      },
      created_at: $now,
      updated_at: $now,
      error: null
    }' > "$STATE_FILE"

  _state_scrub_live_state
  log_info "State initialized: $STATE_FILE"
  echo "$STATE_FILE"
}

# state.json 読み込み
# Usage: state_load <state_file>
state_load() {
  local state_file="$1"

  ensure_cmd jq
  ensure_file "$state_file"

  STATE_FILE="$state_file"
  STATE_DIR="$(dirname "$state_file")"
  STATE_LOCK_FILE="${STATE_DIR}/.state.lock"

  # スキーマバージョンチェック
  local version
  version=$(jq -r '.version // "unknown"' "$STATE_FILE")

  if [[ "$version" != "$STATE_SCHEMA_VERSION" ]]; then
    log_warn "State schema version mismatch: $version (expected: $STATE_SCHEMA_VERSION)"
  fi

  _state_scrub_live_state
  log_debug "State loaded: $STATE_FILE"
  return 0
}

# state.json 保存（updated_at を更新）
state_save() {
  if [[ -z "$STATE_FILE" ]]; then
    die "State not initialized. Call state_init or state_load first."
  fi

  _state_lock || die "Failed to acquire state lock"
  # Note: bash 3.x互換のため trap RETURN ではなく明示的にunlock

  local now
  now=$(get_timestamp)

  # updated_at を更新
  local tmp_file
  tmp_file=$(create_temp_file "state")
  jq --arg ts "$now" '.updated_at = $ts' "$STATE_FILE" > "$tmp_file"
  if ! mv "$tmp_file" "$STATE_FILE"; then
    /bin/rm -f "$tmp_file"
    _state_unlock
    die "Failed to save state file"
  fi

  if ! _state_scrub_live_state_locked; then
    _state_unlock
    die "Failed to scrub state file during save"
  fi

  _state_unlock
  log_debug "State saved: $STATE_FILE"
}

# coder_engine を assignments に保存
# Usage: state_set_coder_engine <claude|codex>
state_set_coder_engine() {
  local engine
  engine=$(_state_resolve_coder_engine "${1:-}")
  state_set '.assignments.coder_engine' "\"$engine\""
}

# task contract の path を保存
# Usage: state_set_contract_path <contract_path>
state_set_contract_path() {
  local contract_path="${1:-}"

  [[ -n "$contract_path" ]] || die "state_set_contract_path: contract_path is required"
  state_set '.task.contract_path' "\"$contract_path\""
}

# task contract の id を保存
# Usage: state_set_contract_id <contract_id>
state_set_contract_id() {
  local contract_id="${1:-}"

  [[ -n "$contract_id" ]] || die "state_set_contract_id: contract_id is required"
  state_set '.task.contract_id' "\"$contract_id\""
}

# task contract の path を取得
# Usage: state_get_contract_path
state_get_contract_path() {
  local contract_path=""

  contract_path=$(state_get '.task.contract_path')
  if [[ -n "$contract_path" ]]; then
    printf '%s\n' "$contract_path"
    return 0
  fi

  state_get '.task.contract.path'
}

# task contract の id を取得
# Usage: state_get_contract_id
state_get_contract_id() {
  local contract_id=""

  contract_id=$(state_get '.task.contract_id')
  if [[ -n "$contract_id" ]]; then
    printf '%s\n' "$contract_id"
    return 0
  fi

  state_get '.task.contract.id'
}

# task plan の path を解決
# Usage: state_resolve_plan_path [plan_path] [repo_root]
state_resolve_plan_path() {
  local plan_path="${1:-}"
  local repo_root="${2:-${REPO_ROOT:-}}"

  if [[ -z "$plan_path" ]]; then
    plan_path=$(state_get '.task.plan_path')
  fi

  _state_resolve_plan_path "$plan_path" "$repo_root"
}

# task contract の path/id を保存
# Usage: state_set_task_contract <contract_id> <contract_path>
state_set_task_contract() {
  local contract_id="${1:-}"
  local contract_path="${2:-}"

  [[ -n "$contract_id" ]] || die "state_set_task_contract: contract_id is required"
  [[ -n "$contract_path" ]] || die "state_set_task_contract: contract_path is required"

  state_set_contract_id "$contract_id"
  state_set_contract_path "$contract_path"
}

# 値取得
# Usage: state_get <jq_path>
# Example: state_get '.status'
# Example: state_get '.phases[0].name'
state_get() {
  local jq_path="$1"

  if [[ -z "$STATE_FILE" ]]; then
    die "State not initialized."
  fi

  # セキュリティ: jq パス検証（state_set/state_append と同様）
  if ! _validate_jq_path "$jq_path"; then
    die "Invalid jq path: $jq_path (allowed: .identifier, [index], combinations)"
  fi

  jq -r "$jq_path // empty" "$STATE_FILE"
}

# 値設定
# Usage: state_set <jq_path> <value>
# Example: state_set '.status' '"running"'
# Example: state_set '.phases[0].iteration' '2'
state_set() {
  local jq_path="$1"
  local value="$2"

  if [[ -z "$STATE_FILE" ]]; then
    die "State not initialized."
  fi

  # jq パスインジェクション防止
  if ! _validate_jq_path "$jq_path"; then
    die "Invalid jq path: $jq_path (allowed: .identifier, [index], combinations)"
  fi

  _state_lock || die "Failed to acquire state lock"
  # Note: bash 3.x互換のため trap RETURN ではなく明示的にunlock

  local tmp_file
  tmp_file=$(create_temp_file "state")

  # 値が JSON として有効かチェック
  # セキュリティ: 常に --argjson/--arg を使用してインジェクションを防止
  local jq_exit=0
  if echo "$value" | jq -e . >/dev/null 2>&1; then
    # JSON値として設定（--argjson で安全に渡す）
    jq --argjson v "$value" "${jq_path} = \$v" "$STATE_FILE" > "$tmp_file" || jq_exit=$?
  else
    # 文字列として設定（--arg で安全に渡す）
    jq --arg v "$value" "${jq_path} = \$v" "$STATE_FILE" > "$tmp_file" || jq_exit=$?
  fi

  # jq 失敗時は一時ファイルを削除してエラー
  if [[ $jq_exit -ne 0 ]]; then
    /bin/rm -f "$tmp_file"
    _state_unlock
    die "Failed to update state: jq error at $jq_path"
  fi

  if ! mv "$tmp_file" "$STATE_FILE"; then
    /bin/rm -f "$tmp_file"
    _state_unlock
    die "Failed to update state file"
  fi

  if ! _state_scrub_live_state_locked; then
    _state_unlock
    die "Failed to scrub state file after update"
  fi
  _state_unlock
  log_debug "State set: $jq_path = $value"
}

# 配列に追加
# Usage: state_append <jq_array_path> <json_object>
# Example: state_append '.phases' '{"name":"test","status":"pending"}'
state_append() {
  local jq_path="$1"
  local json_obj="$2"

  if [[ -z "$STATE_FILE" ]]; then
    die "State not initialized."
  fi

  # jq パスインジェクション防止
  if ! _validate_jq_path "$jq_path"; then
    die "Invalid jq path: $jq_path (allowed: .identifier, [index], combinations)"
  fi

  # JSON妥当性チェック（インジェクション防止）
  if ! echo "$json_obj" | jq -e . >/dev/null 2>&1; then
    die "Invalid JSON object: $json_obj"
  fi

  _state_lock || die "Failed to acquire state lock"
  # Note: bash 3.x互換のため trap RETURN ではなく明示的にunlock

  local tmp_file
  tmp_file=$(create_temp_file "state")

  # --argjson で安全にJSONオブジェクトを渡す
  local jq_exit=0
  jq --argjson obj "$json_obj" "${jq_path} += [\$obj]" "$STATE_FILE" > "$tmp_file" || jq_exit=$?

  # jq 失敗時は一時ファイルを削除してエラー
  if [[ $jq_exit -ne 0 ]]; then
    /bin/rm -f "$tmp_file"
    _state_unlock
    die "Failed to append to state: jq error at $jq_path"
  fi

  if ! mv "$tmp_file" "$STATE_FILE"; then
    /bin/rm -f "$tmp_file"
    _state_unlock
    die "Failed to update state file"
  fi

  if ! _state_scrub_live_state_locked; then
    _state_unlock
    die "Failed to scrub state file after append"
  fi
  _state_unlock

  log_debug "State appended to $jq_path"
}

# フェーズのインデックスを取得
# Usage: state_find_phase <phase_name>
# Returns: index (0-based) or -1 if not found
state_find_phase() {
  local phase_name="$1"

  if [[ -z "$STATE_FILE" ]]; then
    die "State not initialized."
  fi

  local index
  index=$(jq --arg name "$phase_name" '
    .phases | to_entries | map(select(.value.name == $name)) | .[0].key // -1
  ' "$STATE_FILE")

  echo "$index"
}

# フェーズを追加または更新
# Usage: state_upsert_phase <phase_name> <max_iterations>
state_upsert_phase() {
  local phase_name="$1"
  local max_iterations="${2:-5}"

  local index
  index=$(state_find_phase "$phase_name")

  if [[ "$index" == "-1" ]]; then
    # 新規追加（jqで安全にJSON生成）
    local phase_obj
    phase_obj=$(jq -n \
      --arg name "$phase_name" \
      --argjson max_iter "$max_iterations" \
      '{
        name: $name,
        status: "pending",
        iteration: 0,
        max_iterations: $max_iter,
        coder: null,
        started_at: null,
        completed_at: null
      }')
    state_append '.phases' "$phase_obj"
    log_info "Phase added: $phase_name"
  else
    log_debug "Phase already exists: $phase_name (index: $index)"
  fi
}

# フェーズの状態を更新
# Usage: state_set_phase_status <phase_name> <status>
state_set_phase_status() {
  local phase_name="$1"
  local status="$2"

  local index
  index=$(state_find_phase "$phase_name")

  if [[ "$index" == "-1" ]]; then
    die "Phase not found: $phase_name"
  fi

  state_set '.current_phase' "\"$phase_name\""
  state_set ".phases[$index].status" "\"$status\""

  # started_at / completed_at を自動設定
  local now
  now=$(get_timestamp)

  case "$status" in
    running|review|fixing)
      local started_at
      started_at=$(state_get ".phases[$index].started_at")
      if [[ -z "$started_at" || "$started_at" == "null" ]]; then
        state_set ".phases[$index].started_at" "\"$now\""
      fi
      ;;
    completed|failed|timeout|escalated)  # escalated を追加
      state_set ".phases[$index].completed_at" "\"$now\""
      ;;
  esac
}

# セッション情報を記録
# Usage: state_record_session <session_id> <phase> <iteration> [engine] [parent_id]
state_record_session() {
  local session_id="$1"
  local phase="$2"
  local iteration="$3"
  local engine="${4:-}"
  local parent_id="${5:-}"
  local now
  now=$(get_timestamp)
  engine=$(_state_resolve_coder_engine "$engine")

  # jqで安全にJSON生成
  local session_obj
  if [[ -z "$parent_id" ]]; then
    session_obj=$(jq -n \
      --arg sid "$session_id" \
      --arg p "$phase" \
      --argjson iter "$iteration" \
      --arg eng "$engine" \
      --arg ts "$now" \
      '{
        session_id: $sid,
        phase: $p,
        iteration: $iter,
        engine: $eng,
        created_at: $ts
      }')
  else
    session_obj=$(jq -n \
      --arg sid "$session_id" \
      --arg p "$phase" \
      --argjson iter "$iteration" \
      --arg eng "$engine" \
      --arg parent "$parent_id" \
      --arg ts "$now" \
      '{
        session_id: $sid,
        phase: $p,
        iteration: $iter,
        engine: (if ($eng | length) > 0 then $eng else null end),
        parent_session_id: $parent,
        created_at: $ts
      }')
  fi

  state_append '.sessions.coder_sessions' "$session_obj"
  log_debug "Session recorded: $session_id"
}

# 最後のセッションIDを取得
# Usage: state_get_last_session [phase] [engine]
state_get_last_session() {
  local phase="${1:-}"
  local engine="${2:-}"

  if [[ -z "$STATE_FILE" ]]; then
    die "State not initialized."
  fi

  if [[ -n "$phase" && -n "$engine" ]]; then
    jq -r --arg p "$phase" --arg e "$engine" '
      (.sessions.coder_sessions // [])
      | map(select(.phase == $p and (.engine // empty) == $e))
      | last
      | .session_id // empty
    ' "$STATE_FILE"
  elif [[ -n "$phase" ]]; then
    jq -r --arg p "$phase" '
      (.sessions.coder_sessions // []) | map(select(.phase == $p)) | last | .session_id // empty
    ' "$STATE_FILE"
  elif [[ -n "$engine" ]]; then
    jq -r --arg e "$engine" '
      (.sessions.coder_sessions // [])
      | map(select((.engine // empty) == $e))
      | last
      | .session_id // empty
    ' "$STATE_FILE"
  else
    jq -r '(.sessions.coder_sessions // []) | last | .session_id // empty' "$STATE_FILE"
  fi
}

# エラー情報を記録
# Usage: state_set_error <code> <message> [phase]
state_set_error() {
  local code="$1"
  local message="$2"
  local phase="${3:-}"

  local now
  now=$(get_timestamp)

  # jqで安全にJSON生成
  local error_obj
  if [[ -n "$phase" ]]; then
    error_obj=$(jq -n \
      --arg c "$code" \
      --arg m "$message" \
      --arg p "$phase" \
      --arg ts "$now" \
      '{
        code: $c,
        message: $m,
        phase: $p,
        timestamp: $ts
      }')
  else
    error_obj=$(jq -n \
      --arg c "$code" \
      --arg m "$message" \
      --arg ts "$now" \
      '{
        code: $c,
        message: $m,
        timestamp: $ts
      }')
  fi

  state_set '.error' "$error_obj"
  log_error "Error recorded: [$code] $message"
}

# エラーをクリア
state_clear_error() {
  state_set '.error' 'null'
}

# 状態のサマリーを表示
state_show_summary() {
  if [[ -z "$STATE_FILE" ]]; then
    die "State not initialized."
  fi

  echo "=== State Summary ==="
  echo "File: $STATE_FILE"
  echo ""
  jq -r '
    "Task: \(.task.name) (\(.task.id))",
    "Status: \(.status)",
    "Current Phase: \(.current_phase // "none")",
    "Coder Engine: \(.assignments.coder_engine // "not set")",
    "Created: \(.created_at)",
    "Updated: \(.updated_at)",
    "",
    "Phases:",
    (.phases[] | "  - \(.name): \(.status) (iteration: \(.iteration)/\(.max_iterations))"),
    "",
    "Quality Gate: \(.quality_gate.status) (level: \(.quality_gate.level // "not set"))",
    "",
    if .error then "Error: [\(.error.code)] \(.error.message)" else "" end
  ' "$STATE_FILE"
}

# Reviewer session persistence intentionally removed from live state.json.
