#!/usr/bin/env bash
# orchestration_packet.sh - auto_orchestrate packet preflight helper
#
# This file is sourced by auto_orchestrate.sh after utils/state globals are set.
# It owns orchestration packet extraction, path validation, baseline snapshot
# preflight, and policy bundle validation for coder-launch packets.

_orchestration_packet_model_io_guard_path() {
  local repo_root="${REPO_ROOT:-}"
  if [[ -z "$repo_root" ]]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  fi
  printf '%s\n' "${REV_HARNESS_MODEL_IO_GUARD:-${repo_root}/scripts/rev-harness-model-io-guard.sh}"
}

_orchestration_packet_guard_prompt_file() {
  local prompt_file="$1"
  local label="$2"
  local guard_path=""

  guard_path="$(_orchestration_packet_model_io_guard_path)"
  if [[ -x "$guard_path" ]]; then
    bash "$guard_path" prompt-budget --file "$prompt_file" --label "$label" \
      --max-bytes "${REV_HARNESS_MODEL_IO_PROMPT_MAX_BYTES:-262144}" \
      --warn-bytes "${REV_HARNESS_MODEL_IO_PROMPT_WARN_BYTES:-196608}" || return 1
  fi
}

_baseline_freeze_script_is_available() {
  local canonical_baseline_lib=""

  canonical_baseline_lib="$(cd "$(dirname "$BASELINE_FREEZE_LIB")" && pwd -P)/$(basename "$BASELINE_FREEZE_LIB")" || {
    baseline_freeze_unavailable_reason="failed to resolve canonical baseline freeze path: $BASELINE_FREEZE_LIB"
    return 1
  }

  if [[ ! -r "$canonical_baseline_lib" ]]; then
    baseline_freeze_unavailable_reason="missing or unreadable: $canonical_baseline_lib"
    return 1
  fi

  if [[ ! -x "$canonical_baseline_lib" ]]; then
    baseline_freeze_unavailable_reason="not executable: $canonical_baseline_lib"
    return 1
  fi

  baseline_freeze_unavailable_reason=""
  return 0
}

_orchestration_packet_block() {
  local phase="$1"
  local message="$2"

  state_set_error "ORCHESTRATION_PACKET_BLOCK" "$message" "$phase"
  state_save
  die "$message"
}

_orchestration_packet_task_id_from_plan() {
  local plan_path="$1"

  sed -n -E 's/^- task (id|lineage):[^`]*`([^`]+)`.*/\2/p' "$plan_path" | head -n 1
}

_orchestration_packet_backticked_value() {
  local line="${1:-}"

  printf '%s\n' "$line" | sed -n -E 's/^[^`]*`([^`]+)`.*/\1/p' | head -n 1
}

_orchestration_packet_extract_single_tuple_json() {
  local plan_path="$1"
  local tuples_file=""
  local packet_tuple_blocks=0
  local complete_tuple_blocks=0
  local task_id=""
  local slice_id=""
  local sow_path=""
  local coder_prompt=""
  local reviewer_prompt=""
  local coder_output_stub=""
  local reviewer_output_stub=""
  local evidence_destination=""
  local line=""
  local incomplete_missing_fields=""
  local has_incomplete_tuple=false

  _emit_packet_tuple() {
    local field_count=0
    local missing_fields=()

    [[ -n "$slice_id" ]] && field_count=$((field_count + 1)) || missing_fields+=("slice id")
    [[ -n "$sow_path" ]] && field_count=$((field_count + 1)) || missing_fields+=("SOW")
    [[ -n "$coder_prompt" ]] && field_count=$((field_count + 1)) || missing_fields+=("coder prompt")
    [[ -n "$reviewer_prompt" ]] && field_count=$((field_count + 1)) || missing_fields+=("reviewer prompt")
    [[ -n "$coder_output_stub" ]] && field_count=$((field_count + 1)) || missing_fields+=("coder output stub")
    [[ -n "$reviewer_output_stub" ]] && field_count=$((field_count + 1)) || missing_fields+=("reviewer output stub")
    [[ -n "$evidence_destination" ]] && field_count=$((field_count + 1)) || missing_fields+=("evidence destination")

    if [[ "$field_count" -eq 0 ]]; then
      slice_id=""
      sow_path=""
      coder_prompt=""
      reviewer_prompt=""
      coder_output_stub=""
      reviewer_output_stub=""
      evidence_destination=""
      return 0
    fi

    packet_tuple_blocks=$((packet_tuple_blocks + 1))

    if [[ "$field_count" -eq 7 ]]; then
      complete_tuple_blocks=$((complete_tuple_blocks + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$slice_id" \
        "$sow_path" \
        "$coder_prompt" \
        "$reviewer_prompt" \
        "$coder_output_stub" \
        "$reviewer_output_stub" \
        "$evidence_destination" >> "$tuples_file"
    else
      has_incomplete_tuple=true
      incomplete_missing_fields="$(IFS=', '; printf '%s' "${missing_fields[*]}")"
    fi

    slice_id=""
    sow_path=""
    coder_prompt=""
    reviewer_prompt=""
    coder_output_stub=""
    reviewer_output_stub=""
    evidence_destination=""
  }

  orchestration_packet_preflight_skip_reason=""
  task_id="$(_orchestration_packet_task_id_from_plan "$plan_path" || true)"
  tuples_file="$(create_temp_file orchestration_packet_tuples)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "### "*)
        _emit_packet_tuple
        ;;
      "- slice id:"*)
        slice_id="$(_orchestration_packet_backticked_value "$line")"
        ;;
      "- SOW:"*)
        sow_path="$(_orchestration_packet_backticked_value "$line")"
        ;;
      "- coder prompt:"*)
        coder_prompt="$(_orchestration_packet_backticked_value "$line")"
        ;;
      "- reviewer prompt:"*)
        reviewer_prompt="$(_orchestration_packet_backticked_value "$line")"
        ;;
      "- coder output stub:"*)
        coder_output_stub="$(_orchestration_packet_backticked_value "$line")"
        ;;
      "- reviewer output stub:"*)
        reviewer_output_stub="$(_orchestration_packet_backticked_value "$line")"
        ;;
      "- evidence destination:"*)
        evidence_destination="$(_orchestration_packet_backticked_value "$line")"
        ;;
    esac
  done < "$plan_path"

  _emit_packet_tuple
  unset -f _emit_packet_tuple

  if [[ "$packet_tuple_blocks" -eq 0 ]]; then
    orchestration_packet_preflight_skip_reason="no packet tuple declared in plan"
    /bin/rm -f "$tuples_file" 2>/dev/null || true
    printf '%s\n' "$orchestration_packet_preflight_skip_reason" >&2
    return 1
  fi

  if [[ "$packet_tuple_blocks" -gt 1 ]]; then
    orchestration_packet_preflight_skip_reason="multiple packet tuples declared in plan"
    if [[ "$has_incomplete_tuple" == "true" ]]; then
      orchestration_packet_preflight_skip_reason="${orchestration_packet_preflight_skip_reason}; at least one tuple is incomplete"
    fi
    /bin/rm -f "$tuples_file" 2>/dev/null || true
    printf '%s\n' "$orchestration_packet_preflight_skip_reason" >&2
    return 2
  fi

  if [[ "$complete_tuple_blocks" -ne 1 ]]; then
    orchestration_packet_preflight_skip_reason="packet tuple declared but required fields are missing"
    if [[ -n "$incomplete_missing_fields" ]]; then
      orchestration_packet_preflight_skip_reason="${orchestration_packet_preflight_skip_reason}: $incomplete_missing_fields"
    fi
    /bin/rm -f "$tuples_file" 2>/dev/null || true
    printf '%s\n' "$orchestration_packet_preflight_skip_reason" >&2
    return 3
  fi

  IFS=$'\t' read -r \
    slice_id \
    sow_path \
    coder_prompt \
    reviewer_prompt \
    coder_output_stub \
    reviewer_output_stub \
    evidence_destination < "$tuples_file"
  /bin/rm -f "$tuples_file" 2>/dev/null || true

  if [[ -z "$task_id" ]]; then
    orchestration_packet_preflight_skip_reason="packet tuple declared but canonical task id or task lineage is missing in plan"
    printf '%s\n' "$orchestration_packet_preflight_skip_reason" >&2
    return 3
  fi

  jq -n \
    --arg task_id "$task_id" \
    --arg slice_id "$slice_id" \
    --arg sow_path "$sow_path" \
    --arg coder_prompt "$coder_prompt" \
    --arg reviewer_prompt "$reviewer_prompt" \
    --arg coder_output_stub "$coder_output_stub" \
    --arg reviewer_output_stub "$reviewer_output_stub" \
    --arg evidence_destination "$evidence_destination" \
    '{
      task_id: $task_id,
      slice_id: $slice_id,
      sow_path: $sow_path,
      coder_prompt: $coder_prompt,
      reviewer_prompt: $reviewer_prompt,
      coder_output_stub: $coder_output_stub,
      reviewer_output_stub: $reviewer_output_stub,
      evidence_destination: $evidence_destination
    }'
}

_orchestration_packet_validate_repo_relative_path() {
  local rel_path="${1:-}"

  [[ -n "$rel_path" ]] || return 1

  case "$rel_path" in
    /*)
      return 1
      ;;
    .|..)
      return 1
      ;;
  esac

  if [[ "$rel_path" =~ (^|/)\.\.(/|$) ]]; then
    return 1
  fi

  if [[ "$rel_path" == *$'\n'* || "$rel_path" == *$'\r'* ]]; then
    return 1
  fi

  return 0
}

_orchestration_packet_repo_abs_path() {
  local rel_path="${1:-}"

  _orchestration_packet_validate_repo_relative_path "$rel_path" || return 1
  printf '%s/%s\n' "$REPO_ROOT" "${rel_path#./}"
}

_prepare_orchestration_packet_for_coder_launch() {
  local tmpdir="$1"
  local phase="$2"
  local plan="$3"
  local packet_json=""
  local tuple_status=0
  local task_lineage_id=""
  local slice_id=""
  local sow_rel=""
  local coder_prompt_rel=""
  local reviewer_prompt_rel=""
  local coder_stub_rel=""
  local reviewer_stub_rel=""
  local evidence_destination_rel=""
  local sow_abs=""
  local ledger_abs=""
  local coder_prompt_abs=""
  local reviewer_prompt_abs=""
  local coder_stub_abs=""
  local reviewer_stub_abs=""
  local evidence_destination_abs=""
  local baseline_snapshot_abs=""
  local bundle_abs=""
  local error_file=""
  local error_text=""
  local message=""
  local packet_extract_error_file=""
  local packet_extract_reason=""

  packet_extract_error_file="$(create_temp_file orchestration_packet_extract_error)"
  if packet_json="$(_orchestration_packet_extract_single_tuple_json "$plan" 2> "$packet_extract_error_file")"; then
    /bin/rm -f "$packet_extract_error_file" 2>/dev/null || true
    :
  else
    tuple_status=$?
    packet_extract_reason="$(cat "$packet_extract_error_file" 2>/dev/null || true)"
    /bin/rm -f "$packet_extract_error_file" 2>/dev/null || true
    case "$tuple_status" in
      1|2)
        log_info "Orchestration packet preflight skipped: ${packet_extract_reason:-packet tuple is not applicable to this plan}"
        return 0
        ;;
      3)
        _orchestration_packet_block "$phase" \
          "Orchestration packet preflight failed closed: ${packet_extract_reason:-packet tuple is malformed}"
        ;;
      *)
        _orchestration_packet_block "$phase" \
          "Orchestration packet preflight failed closed before packet extraction."
        ;;
    esac
  fi

  if [[ ! -x "$ORCHESTRATION_PACKET_VALIDATOR_SCRIPT" ]]; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight validator unavailable. missing or not executable: $ORCHESTRATION_PACKET_VALIDATOR_SCRIPT"
  fi

  if ! _baseline_freeze_script_is_available; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight baseline primitive unavailable. ${baseline_freeze_unavailable_reason:-}"
  fi

  task_lineage_id="$(jq -r '.task_id' <<< "$packet_json")"
  slice_id="$(jq -r '.slice_id' <<< "$packet_json")"
  sow_rel="$(jq -r '.sow_path' <<< "$packet_json")"
  coder_prompt_rel="$(jq -r '.coder_prompt' <<< "$packet_json")"
  reviewer_prompt_rel="$(jq -r '.reviewer_prompt' <<< "$packet_json")"
  coder_stub_rel="$(jq -r '.coder_output_stub' <<< "$packet_json")"
  reviewer_stub_rel="$(jq -r '.reviewer_output_stub' <<< "$packet_json")"
  evidence_destination_rel="$(jq -r '.evidence_destination' <<< "$packet_json")"

  if ! sow_abs="$(_orchestration_packet_repo_abs_path "$sow_rel")"; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight failed closed: invalid SOW path in plan packet tuple."
  fi
  if ! coder_prompt_abs="$(_orchestration_packet_repo_abs_path "$coder_prompt_rel")"; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight failed closed: invalid coder prompt path in plan packet tuple."
  fi
  if ! reviewer_prompt_abs="$(_orchestration_packet_repo_abs_path "$reviewer_prompt_rel")"; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight failed closed: invalid reviewer prompt path in plan packet tuple."
  fi
  if ! coder_stub_abs="$(_orchestration_packet_repo_abs_path "$coder_stub_rel")"; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight failed closed: invalid coder output stub path in plan packet tuple."
  fi
  if ! reviewer_stub_abs="$(_orchestration_packet_repo_abs_path "$reviewer_stub_rel")"; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight failed closed: invalid reviewer output stub path in plan packet tuple."
  fi
  if ! evidence_destination_abs="$(_orchestration_packet_repo_abs_path "$evidence_destination_rel")"; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight failed closed: invalid evidence destination path in plan packet tuple."
  fi

  if ! _orchestration_packet_guard_prompt_file "$coder_prompt_abs" "orchestration_packet:coder_prompt"; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight failed closed: coder prompt exceeds model I/O guard budget."
  fi
  if ! _orchestration_packet_guard_prompt_file "$reviewer_prompt_abs" "orchestration_packet:reviewer_prompt"; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight failed closed: reviewer prompt exceeds model I/O guard budget."
  fi

  ledger_abs="$REPO_ROOT/.agent/active/sow/task-lineage-ledger.md"
  baseline_snapshot_abs="$evidence_destination_abs/baseline_freeze.txt"
  bundle_abs="$tmpdir/orchestration-policy.bundle.json"

  if [[ -e "$coder_stub_abs" && -s "$coder_stub_abs" ]]; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight failed closed: coder output stub must be empty before coder launch. See: $coder_stub_rel"
  fi
  if [[ -e "$reviewer_stub_abs" && -s "$reviewer_stub_abs" ]]; then
    _orchestration_packet_block "$phase" \
      "Orchestration packet preflight failed closed: reviewer output stub must be empty before coder launch. See: $reviewer_stub_rel"
  fi

  ensure_dir "$(dirname "$coder_stub_abs")"
  ensure_dir "$(dirname "$reviewer_stub_abs")"
  ensure_dir "$evidence_destination_abs"

  : > "$coder_stub_abs" || _orchestration_packet_block "$phase" \
    "Orchestration packet preflight failed closed: could not pre-touch coder output stub. See: $coder_stub_rel"
  : > "$reviewer_stub_abs" || _orchestration_packet_block "$phase" \
    "Orchestration packet preflight failed closed: could not pre-touch reviewer output stub. See: $reviewer_stub_rel"

  error_file="$(create_temp_file orchestration_packet_preflight_error)"
  if ! bash "$BASELINE_FREEZE_LIB" snapshot "$evidence_destination_abs" > /dev/null 2> "$error_file"; then
    error_text="$(cat "$error_file" 2>/dev/null || true)"
    /bin/rm -f "$error_file" 2>/dev/null || true
    message="Orchestration packet preflight baseline snapshot failed closed."
    if [[ -n "$error_text" ]]; then
      message="${message} ${error_text}"
    fi
    _orchestration_packet_block "$phase" "$message"
  fi
  /bin/rm -f "$error_file" 2>/dev/null || true

  error_file="$(create_temp_file orchestration_packet_preflight_error)"
  if ! bash "$ORCHESTRATION_PACKET_VALIDATOR_SCRIPT" compile \
    --output "$bundle_abs" \
    --manifest .agent/registry/policy_sources.json > /dev/null 2> "$error_file"; then
    error_text="$(cat "$error_file" 2>/dev/null || true)"
    /bin/rm -f "$error_file" 2>/dev/null || true
    message="Orchestration packet preflight bundle compile failed closed."
    if [[ -n "$error_text" ]]; then
      message="${message} ${error_text}"
    fi
    _orchestration_packet_block "$phase" "$message"
  fi
  /bin/rm -f "$error_file" 2>/dev/null || true

  error_file="$(create_temp_file orchestration_packet_preflight_error)"
  if ! bash "$ORCHESTRATION_PACKET_VALIDATOR_SCRIPT" validate \
    --bundle "$bundle_abs" \
    --plan "$plan" \
    --sow "$sow_abs" \
    --ledger "$ledger_abs" \
    --coder-prompt "$coder_prompt_abs" \
    --reviewer-prompt "$reviewer_prompt_abs" \
    --coder-output-stub "$coder_stub_abs" \
    --reviewer-output-stub "$reviewer_stub_abs" \
    --baseline-freeze "$baseline_snapshot_abs" \
    --task-id "$task_lineage_id" \
    --expected-active-slice "$slice_id" > /dev/null 2> "$error_file"; then
    error_text="$(cat "$error_file" 2>/dev/null || true)"
    /bin/rm -f "$error_file" 2>/dev/null || true
    message="Orchestration packet preflight validation failed closed."
    if [[ -n "$error_text" ]]; then
      message="${message} ${error_text}"
    fi
    _orchestration_packet_block "$phase" "$message"
  fi
  /bin/rm -f "$error_file" 2>/dev/null || true

  log_info "Orchestration packet preflight passed: slice=$slice_id task=$task_lineage_id bundle=$(basename "$bundle_abs")"
}
