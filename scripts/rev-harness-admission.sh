#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-admission.sh counter --request <path> --ledger <path> [--json] [--now <timestamp>]
  scripts/rev-harness-admission.sh schema-micro-fix --manifest <path> --ledger <path> [--json] [--now <timestamp>]

Run read-only reviewer-admission preflight checks for Revharness counter governance.
The command emits one JSON object and exits 0 when admission is allowed, 1 when
admission is fail-closed, and 2 for CLI/input-shape errors that prevent a report.
Use --now or REV_HARNESS_ADMISSION_NOW to make budget checks deterministic in tests.
EOF
}

die() {
  printf 'rev-harness-admission: %s\n' "$*" >&2
  exit 2
}

json_read() {
  local file="$1"
  local filter="$2"

  jq -er "$filter" "$file" 2>/dev/null || true
}

json_has() {
  local file="$1"
  local filter="$2"

  jq -e "$filter" "$file" >/dev/null 2>&1
}

add_reason() {
  reasons+=("$1")
}

reasons_json() {
  if [[ "${#reasons[@]}" -eq 0 ]]; then
    printf '[]\n'
  else
    printf '%s\n' "${reasons[@]}" | jq -R . | jq -s -c .
  fi
}

parse_counter() {
  local raw="$1"
  local out_var="$2"

  if [[ "$raw" =~ ^[[:space:]]*([0-9]+)[[:space:]]*/[[:space:]]*([0-9]+) ]]; then
    printf -v "$out_var" '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

is_iso_utc_timestamp() {
  local ts="$1"

  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

iso_to_epoch() {
  local ts="$1"

  if date -u -d "$ts" +%s >/dev/null 2>&1; then
    date -u -d "$ts" +%s
    return 0
  fi

  if date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s >/dev/null 2>&1; then
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s
    return 0
  fi

  return 1
}

counter_raw() {
  local file="$1"
  local key="$2"

  json_read "$file" ".counters.${key} // empty"
}

previous_counter_raw() {
  local file="$1"
  local key="$2"

  json_read "$file" ".previous_counters.${key} // empty"
}

ledger_task_section() {
  local ledger="$1"
  local task_id="$2"

  awk -v task_id="$task_id" '
    $1 == "##" && $2 == task_id && NF == 2 {
      in_section = 1
      found = 1
      print
      next
    }
    /^##[[:space:]]/ && in_section {
      exit
    }
    in_section {
      print
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$ledger"
}

section_contains_line_value() {
  local section="$1"
  local label="$2"
  local value="$3"

  grep -F -- "$label" <<<"$section" | grep -F -- "$value" >/dev/null 2>&1
}

validate_counter_field() {
  local file="$1"
  local ledger_section="$2"
  local key="$3"
  local label="$4"
  local raw=""
  local parsed=""
  local previous=""
  local previous_parsed=""
  local actual=""
  local ceiling=""
  local previous_actual=""
  local previous_ceiling=""
  local prior_task_id=""

  raw="$(counter_raw "$file" "$key")"
  if [[ -z "$raw" ]]; then
    add_reason "missing counter: $label"
    return
  fi

  if ! parse_counter "$raw" parsed; then
    add_reason "invalid counter format for $label: $raw"
    return
  fi

  actual="${parsed%% *}"
  ceiling="${parsed##* }"
  if (( actual > ceiling )); then
    add_reason "counter over ceiling: $label=$raw"
  fi

  if ! section_contains_line_value "$ledger_section" "$label" "$raw"; then
    add_reason "ledger does not carry counter $label=$raw"
  fi

  prior_task_id="$(json_read "$file" '.prior_task_id // empty')"
  previous="$(previous_counter_raw "$file" "$key")"
  if [[ "$prior_task_id" != "" && "$prior_task_id" != "none" && -z "$previous" ]]; then
    add_reason "missing previous counter for carried lineage: $label"
    return
  fi

  if [[ -n "$previous" ]]; then
    if ! parse_counter "$previous" previous_parsed; then
      add_reason "invalid previous counter format for $label: $previous"
      return
    fi
    previous_actual="${previous_parsed%% *}"
    previous_ceiling="${previous_parsed##* }"
    if (( actual < previous_actual )); then
      add_reason "counter reset detected for $label: previous=$previous current=$raw"
    fi
    if (( ceiling != previous_ceiling )); then
      add_reason "counter ceiling changed for $label: previous=$previous current=$raw"
    fi
  fi
}

validate_budget() {
  local file="$1"
  local ledger_section="$2"
  local budget=""
  local status=""
  local parsed=""
  local stall=""
  local wall=""
  local basis=""
  local start=""
  local last_progress=""
  local now_epoch=""
  local start_epoch=""
  local last_progress_epoch=""
  local elapsed_wall_seconds=""
  local elapsed_stall_seconds=""

  budget="$(json_read "$file" '.task_level_stall_or_wall_time_budget // empty')"
  status="$(json_read "$file" '.task_level_stall_or_wall_time_budget_status // empty')"

  if [[ -z "$budget" ]]; then
    add_reason "missing task-level stall-or-wall-time budget"
  else
    parsed="$(
      sed -nE \
        's/^stall<=([0-9]+)m; wall<=([0-9]+)m; basis=([^;]+); start=([^;]+); last-progress=([^;]+)$/\1 \2 \3 \4 \5/p' \
        <<<"$budget"
    )"
    if [[ -z "$parsed" ]]; then
      add_reason "invalid task-level stall-or-wall-time budget format"
    else
      read -r stall wall basis start last_progress <<<"$parsed"
      if ! is_iso_utc_timestamp "$admission_now"; then
        add_reason "invalid admission now timestamp: $admission_now"
      fi
      if (( stall > 60 )); then
        add_reason "stall budget exceeds max auto-loop ceiling: stall<=${stall}m"
      fi
      if (( wall > 480 )); then
        add_reason "wall budget exceeds max auto-loop ceiling: wall<=${wall}m"
      fi
      if [[ "$basis" != "task-lineage-opened-at" && "$basis" != "user-approved-reopen-at" ]]; then
        add_reason "invalid budget basis: $basis"
      fi
      if ! is_iso_utc_timestamp "$start"; then
        add_reason "invalid budget start timestamp: $start"
      fi
      if ! is_iso_utc_timestamp "$last_progress"; then
        add_reason "invalid budget last-progress timestamp: $last_progress"
      fi
      if is_iso_utc_timestamp "$start" \
        && is_iso_utc_timestamp "$last_progress" \
        && is_iso_utc_timestamp "$admission_now"; then
        if ! now_epoch="$(iso_to_epoch "$admission_now")"; then
          add_reason "invalid admission --now timestamp: $admission_now"
        elif ! start_epoch="$(iso_to_epoch "$start")"; then
          add_reason "invalid budget start timestamp: $start"
        elif ! last_progress_epoch="$(iso_to_epoch "$last_progress")"; then
          add_reason "invalid budget last-progress timestamp: $last_progress"
        else
          elapsed_wall_seconds="$((now_epoch - start_epoch))"
          elapsed_stall_seconds="$((now_epoch - last_progress_epoch))"
          if (( elapsed_wall_seconds < 0 )); then
            add_reason "budget start timestamp is in the future relative to now: start=$start now=$admission_now"
          elif (( elapsed_wall_seconds > wall * 60 )); then
            add_reason "stale task-level wall-time budget: elapsed=$((elapsed_wall_seconds / 60))m limit<=${wall}m"
          fi
          if (( elapsed_stall_seconds < 0 )); then
            add_reason "budget last-progress timestamp is in the future relative to now: last-progress=$last_progress now=$admission_now"
          elif (( elapsed_stall_seconds > stall * 60 )); then
            add_reason "stale task-level stall-time budget: elapsed=$((elapsed_stall_seconds / 60))m limit<=${stall}m"
          fi
          if (( last_progress_epoch < start_epoch )); then
            add_reason "budget last-progress timestamp predates start timestamp"
          fi
        fi
      fi
    fi

    if ! section_contains_line_value "$ledger_section" "task-level stall-or-wall-time budget" "$budget"; then
      add_reason "ledger does not carry current task-level budget"
    fi
  fi

  case "$status" in
    within-budget)
      ;;
    exhausted)
      add_reason "task-level stall-or-wall-time budget status is exhausted"
      ;;
    "")
      add_reason "missing task-level stall-or-wall-time budget status"
      ;;
    *)
      add_reason "invalid task-level stall-or-wall-time budget status: $status"
      ;;
  esac

  if [[ -n "$status" ]] && ! section_contains_line_value "$ledger_section" "task-level stall-or-wall-time budget status" "$status"; then
    add_reason "ledger does not carry budget status=$status"
  fi
}

validate_lineage() {
  local file="$1"
  local ledger_section="$2"
  local task_id=""
  local ledger_entry=""
  local prior_task_id=""
  local materially_same=""
  local reopen_delta_summary=""
  local delta_evidence=""

  task_id="$(json_read "$file" '.task_id // empty')"
  ledger_entry="$(json_read "$file" '.task_lineage_ledger_entry // empty')"
  prior_task_id="$(json_read "$file" '.prior_task_id // empty')"
  materially_same="$(json_read "$file" '.materially_same_change_surface // false')"
  reopen_delta_summary="$(json_read "$file" '.reopen_delta_summary // empty')"
  delta_evidence="$(json_read "$file" '.delta_evidence // empty')"

  if [[ -z "$task_id" ]]; then
    add_reason "missing task_id"
    return
  fi

  if [[ -z "$ledger_entry" || "$ledger_entry" != *" :: $task_id"* ]]; then
    add_reason "task_lineage_ledger_entry does not reference task_id=$task_id"
  fi

  if [[ -z "$ledger_section" ]]; then
    add_reason "missing lineage ledger entry for task_id=$task_id"
  fi

  if [[ -z "$prior_task_id" ]]; then
    add_reason "missing prior_task_id"
  elif [[ "$prior_task_id" != "none" ]]; then
    if ! grep -Fq -- "$prior_task_id" <<<"$ledger_section"; then
      add_reason "target ledger entry does not reference prior_task_id=$prior_task_id"
    fi
    if [[ -z "$reopen_delta_summary" || "$reopen_delta_summary" == "none" ]]; then
      add_reason "missing reopen delta summary for carried lineage"
    fi
    if [[ -z "$delta_evidence" || "$delta_evidence" == "none" ]]; then
      add_reason "missing delta evidence for carried lineage"
    fi
    if ! json_has "$file" '.previous_counters | type == "object"'; then
      add_reason "missing previous_counters for carried lineage monotonicity check"
    fi
  elif [[ "$materially_same" == "true" ]]; then
    add_reason "materially same change surface cannot use prior_task_id=none"
  fi
}

validate_reviewer_counter_projection() {
  local file="$1"
  local proposed_event=""
  local raw=""
  local parsed=""
  local actual=""
  local ceiling=""
  local projected=""

  proposed_event="$(json_read "$file" '.proposed_event // "reviewer_request"')"
  case "$proposed_event" in
    reviewer_request|schema_micro_fix_spot_check)
      raw="$(counter_raw "$file" "cumulative_reviewer_requests_for_task")"
      if parse_counter "$raw" parsed; then
        actual="${parsed%% *}"
        ceiling="${parsed##* }"
        projected="$((actual + 1))"
        if (( projected > ceiling )); then
          add_reason "projected reviewer request would exceed cumulative reviewer requests for task: ${projected}/${ceiling}"
        fi
      fi
      ;;
    preflight_only)
      ;;
    *)
      add_reason "invalid proposed_event: $proposed_event"
      ;;
  esac
}

validate_common_admission() {
  local file="$1"
  local ledger="$2"
  local task_id=""
  local ledger_section=""

  [[ -r "$file" ]] || die "missing JSON input: $file"
  [[ -r "$ledger" ]] || die "missing ledger: $ledger"
  jq empty "$file" >/dev/null || die "invalid JSON input: $file"

  task_id="$(json_read "$file" '.task_id // empty')"
  if [[ -n "$task_id" ]]; then
    ledger_section="$(ledger_task_section "$ledger" "$task_id" || true)"
  fi

  validate_lineage "$file" "$ledger_section"
  validate_counter_field "$file" "$ledger_section" "re_slice_count_for_task" "re-slice count for task"
  validate_counter_field "$file" "$ledger_section" "cumulative_reviewer_requests_for_task" "cumulative reviewer requests for task"
  validate_counter_field "$file" "$ledger_section" "cumulative_late_same_class_findings_for_task" "cumulative late same-class findings for task"
  validate_counter_field "$file" "$ledger_section" "cumulative_closure_resets_for_task" "cumulative closure resets for task"
  validate_budget "$file" "$ledger_section"
  validate_reviewer_counter_projection "$file"
}

validate_counter_request_shape() {
  local file="$1"
  local target=""
  local status=""
  local worker_outcome=""

  target="$(json_read "$file" '.review_request_target // empty')"
  status="$(json_read "$file" '.incoming_request_status // empty')"
  worker_outcome="$(json_read "$file" '.worker_outcome // empty')"

  [[ "$target" == "INTERMEDIATE" || "$target" == "FINAL" ]] \
    || add_reason "review_request_target must be INTERMEDIATE or FINAL"
  [[ "$status" == "pending review" || "$status" == "pending final review" ]] \
    || add_reason "incoming_request_status must be pending review or pending final review"
  [[ "$worker_outcome" == "DIFF" || "$worker_outcome" == "NO-CHANGE" ]] \
    || add_reason "worker_outcome must be DIFF or NO-CHANGE for reviewer intake"
}

path_is_schema_micro_fix_allowed() {
  local path="$1"

  case "$path" in
    scripts/*|test/*|src/*|apps/*|packages/*|services/*|.claude/commands/*|.claude/hooks/*)
      return 1
      ;;
    docs/*|.agent_rules/*.md|.agent/PROJECT_CONTEXT.md|README.md|AGENTS.md|CLAUDE.md|.agent/registry/*.json|.agent/templates/*.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

path_is_repo_relative_safe() {
  local path="$1"

  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != *"//"* ]] || return 1
  [[ "$path" != */ ]] || return 1
  [[ "$path" != *"\\"* ]] || return 1
  [[ ! "$path" =~ [[:cntrl:]] ]] || return 1

  case "$path" in
    .|..|./*|../*|*/./*|*/..|*/../*)
      return 1
      ;;
  esac

  return 0
}

validate_schema_micro_fix() {
  local file="$1"
  local target=""
  local spot_check=""
  local change_class=""
  local claim=""
  local changed_file=""
  local changed_file_json=""

  change_class="$(json_read "$file" '.change_class // empty')"
  target="$(json_read "$file" '.review_request_target // empty')"
  spot_check="$(json_read "$file" '.spot_check_required // false')"

  [[ "$change_class" == "schema-micro-fix" ]] \
    || add_reason "change_class must be schema-micro-fix"
  [[ "$target" == "INTERMEDIATE" ]] \
    || add_reason "schema-micro-fix admission must route to INTERMEDIATE"
  [[ "$spot_check" == "true" ]] \
    || add_reason "schema-micro-fix admission requires reviewer spot-check"

  for claim in acceptance completed lgtm reviewer_waived counter_reset; do
    if ! json_has "$file" ".claims.${claim} == false"; then
      add_reason "schema-micro-fix must explicitly set claims.${claim}=false"
    fi
  done

  if ! json_has "$file" '.changed_files | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)'; then
    add_reason "changed_files must be a non-empty string array"
    return
  fi

  while IFS= read -r changed_file_json; do
    changed_file="$(jq -r . <<<"$changed_file_json")"
    if ! path_is_repo_relative_safe "$changed_file"; then
      add_reason "schema-micro-fix changed file is not a safe repo-relative path"
    elif ! path_is_schema_micro_fix_allowed "$changed_file"; then
      add_reason "schema-micro-fix changed file is outside doc/schema/lint-only surface: $changed_file"
    fi
  done < <(jq -c '.changed_files[]' "$file")
}

emit_result() {
  local admission_type="$1"
  local file="$2"
  local reasons_out=""
  local allowed="false"
  local status="BLOCK"
  local review_intake_allowed="false"
  local task_id=""
  local target=""
  local proposed_event=""
  local counter_raw_value=""
  local counter_parsed=""
  local projected_reviewer_requests="null"

  reasons_out="$(reasons_json)"
  if [[ "${#reasons[@]}" -eq 0 ]]; then
    allowed="true"
    status="ADMIT"
    review_intake_allowed="true"
  fi

  task_id="$(json_read "$file" '.task_id // ""')"
  target="$(json_read "$file" '.review_request_target // ""')"
  proposed_event="$(json_read "$file" '.proposed_event // "reviewer_request"')"
  counter_raw_value="$(counter_raw "$file" "cumulative_reviewer_requests_for_task")"
  if parse_counter "$counter_raw_value" counter_parsed; then
    local actual="${counter_parsed%% *}"
    local ceiling="${counter_parsed##* }"
    if [[ "$proposed_event" == "reviewer_request" || "$proposed_event" == "schema_micro_fix_spot_check" ]]; then
      projected_reviewer_requests="\"$((actual + 1))/${ceiling}\""
    else
      projected_reviewer_requests="\"${actual}/${ceiling}\""
    fi
  fi

  jq -cn \
    --arg schema_version "rev-harness-admission-result/v1" \
    --arg admission_type "$admission_type" \
    --arg task_id "$task_id" \
    --arg review_request_target "$target" \
    --arg status "$status" \
    --arg proposed_event "$proposed_event" \
    --argjson allowed "$allowed" \
    --argjson review_intake_allowed "$review_intake_allowed" \
    --argjson fail_closed_reasons "$reasons_out" \
    --argjson projected_reviewer_requests "$projected_reviewer_requests" \
    '{
      schema_version: $schema_version,
      admission_type: $admission_type,
      task_id: $task_id,
      status: $status,
      allowed: $allowed,
      review_intake_allowed: $review_intake_allowed,
      review_request_target: $review_request_target,
      proposed_event: $proposed_event,
      projected_cumulative_reviewer_requests_for_task: $projected_reviewer_requests,
      fail_closed_reasons: $fail_closed_reasons,
      non_claims: {
        acceptance: false,
        completed: false,
        lgtm: false,
        reviewer_waived: false,
        counter_reset: false
      }
    }'

  [[ "${#reasons[@]}" -eq 0 ]]
}

cmd="${1:-}"
shift || true

input_file=""
ledger_file=""
admission_now="${REV_HARNESS_ADMISSION_NOW:-}"
reasons=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --request|--manifest)
      [[ "$#" -ge 2 ]] || die "$1 requires a value"
      input_file="$2"
      shift 2
      ;;
    --ledger)
      [[ "$#" -ge 2 ]] || die "--ledger requires a value"
      ledger_file="$2"
      shift 2
      ;;
    --json)
      shift
      ;;
    --now)
      [[ "$#" -ge 2 ]] || die "--now requires a value"
      admission_now="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -z "$admission_now" ]]; then
  admission_now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

case "$cmd" in
  counter)
    [[ -n "$input_file" ]] || die "counter requires --request"
    [[ -n "$ledger_file" ]] || die "counter requires --ledger"
    validate_common_admission "$input_file" "$ledger_file"
    validate_counter_request_shape "$input_file"
    emit_result "counter" "$input_file"
    ;;
  schema-micro-fix)
    [[ -n "$input_file" ]] || die "schema-micro-fix requires --manifest"
    [[ -n "$ledger_file" ]] || die "schema-micro-fix requires --ledger"
    validate_common_admission "$input_file" "$ledger_file"
    validate_schema_micro_fix "$input_file"
    emit_result "schema-micro-fix" "$input_file"
    ;;
  ""|help)
    usage
    ;;
  *)
    usage >&2
    die "unknown command: $cmd"
    ;;
esac
