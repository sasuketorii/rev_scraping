#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADMISSION="$PROJECT_ROOT/scripts/rev-harness-admission.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-admission-test.XXXXXX")"
DEFAULT_ADMISSION_NOW="2026-04-30T00:10:00Z"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  /bin/rm -rf "$TMP_ROOT"
}

trap cleanup EXIT

run_admission() {
  (cd "$PROJECT_ROOT" && REV_HARNESS_ADMISSION_NOW="${REV_HARNESS_ADMISSION_NOW:-$DEFAULT_ADMISSION_NOW}" bash "$ADMISSION" "$@")
}

assert_json_field() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual=""

  actual="$(jq -r "$filter" <<<"$json")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected, got $actual"
}

assert_failure_json() {
  local stdout_file="$1"
  local filter="$2"
  local expected="$3"

  jq empty "$stdout_file" >/dev/null || fail "failure output should be JSON"
  assert_json_field "$(<"$stdout_file")" '.status' "BLOCK"
  assert_json_field "$(<"$stdout_file")" '.allowed' "false"
  assert_json_field "$(<"$stdout_file")" "$filter" "$expected"
}

write_ledger() {
  local path="$1"
  local task_id="$2"
  local prior_task_id="$3"
  local re_slice="$4"
  local reviewer_requests="$5"
  local late_findings="$6"
  local closure_resets="$7"
  local budget_status="$8"
  local budget="${9:-stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-30T00:00:00Z; last-progress=2026-04-30T00:05:00Z}"

  cat >"$path" <<EOF
# Task Lineage Ledger Fixture

## $task_id

- task id: \`$task_id\`
- prior task id: \`$prior_task_id\`
- reopen delta summary: \`n/a\`
- delta evidence: \`n/a\`
- re-slice count for task: \`$re_slice\`
- cumulative reviewer requests for task: \`$reviewer_requests\`
- cumulative late same-class findings for task: \`$late_findings\`
- cumulative closure resets for task: \`$closure_resets\`
- task-level stall-or-wall-time budget: \`$budget\`
- task-level stall-or-wall-time budget status: \`$budget_status\`
EOF
}

write_counter_request() {
  local path="$1"
  local task_id="$2"
  local prior_task_id="$3"
  local reviewer_requests="$4"
  local budget_status="$5"
  local budget="${6:-stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-30T00:00:00Z; last-progress=2026-04-30T00:05:00Z}"

  cat >"$path" <<EOF
{
  "schema_version": "rev-harness-admission-request/v1",
  "task_id": "$task_id",
  "task_lineage_ledger_entry": "fixture-ledger.md :: $task_id",
  "prior_task_id": "$prior_task_id",
  "materially_same_change_surface": false,
  "review_request_target": "INTERMEDIATE",
  "incoming_request_status": "pending review",
  "worker_outcome": "DIFF",
  "proposed_event": "reviewer_request",
  "counters": {
    "re_slice_count_for_task": "0/2",
    "cumulative_reviewer_requests_for_task": "$reviewer_requests",
    "cumulative_late_same_class_findings_for_task": "0/2",
    "cumulative_closure_resets_for_task": "0/2"
  },
  "task_level_stall_or_wall_time_budget": "$budget",
  "task_level_stall_or_wall_time_budget_status": "$budget_status"
}
EOF
}

write_schema_micro_manifest() {
  local path="$1"
  local task_id="$2"
  local reviewer_requests="$3"

  cat >"$path" <<EOF
{
  "schema_version": "rev-harness-schema-micro-fix-admission/v1",
  "task_id": "$task_id",
  "task_lineage_ledger_entry": "fixture-ledger.md :: $task_id",
  "prior_task_id": "none",
  "materially_same_change_surface": false,
  "review_request_target": "INTERMEDIATE",
  "spot_check_required": true,
  "proposed_event": "schema_micro_fix_spot_check",
  "change_class": "schema-micro-fix",
  "changed_files": [
    "docs/manual/verification-truth-matrix.md",
    ".agent/registry/example_schema.json"
  ],
  "claims": {
    "acceptance": false,
    "completed": false,
    "lgtm": false,
    "reviewer_waived": false,
    "counter_reset": false
  },
  "counters": {
    "re_slice_count_for_task": "0/2",
    "cumulative_reviewer_requests_for_task": "$reviewer_requests",
    "cumulative_late_same_class_findings_for_task": "0/2",
    "cumulative_closure_resets_for_task": "0/2"
  },
  "task_level_stall_or_wall_time_budget": "stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-30T00:00:00Z; last-progress=2026-04-30T00:05:00Z",
  "task_level_stall_or_wall_time_budget_status": "within-budget"
}
EOF
}

test_counter_admission_passes_with_projected_request() {
  local ledger="$TMP_ROOT/counter-pass-ledger.md"
  local request="$TMP_ROOT/counter-pass.json"
  local output=""

  write_ledger "$ledger" "task-pass" "none" "0/2" "5/6" "0/2" "0/2" "within-budget"
  write_counter_request "$request" "task-pass" "none" "5/6" "within-budget"

  output="$(run_admission counter --request "$request" --ledger "$ledger" --json)"

  assert_json_field "$output" '.schema_version' "rev-harness-admission-result/v1"
  assert_json_field "$output" '.status' "ADMIT"
  assert_json_field "$output" '.review_intake_allowed' "true"
  assert_json_field "$output" '.projected_cumulative_reviewer_requests_for_task' "6/6"
  assert_json_field "$output" '.non_claims.completed' "false"
}

test_counter_admission_fails_missing_lineage_with_json() {
  local ledger="$TMP_ROOT/counter-missing-ledger.md"
  local request="$TMP_ROOT/counter-missing.json"
  local stdout_file="$TMP_ROOT/counter-missing.out"
  local stderr_file="$TMP_ROOT/counter-missing.err"

  write_ledger "$ledger" "task-other" "none" "0/2" "1/6" "0/2" "0/2" "within-budget"
  write_counter_request "$request" "task-missing" "none" "1/6" "within-budget"

  if run_admission counter --request "$request" --ledger "$ledger" --json >"$stdout_file" 2>"$stderr_file"; then
    fail "missing lineage should fail closed"
  fi

  [[ ! -s "$stderr_file" ]] || fail "missing lineage report should not need stderr"
  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("missing lineage ledger entry"))' "true"
}

test_counter_admission_fails_current_over_ceiling() {
  local ledger="$TMP_ROOT/counter-over-ledger.md"
  local request="$TMP_ROOT/counter-over.json"
  local stdout_file="$TMP_ROOT/counter-over.out"

  write_ledger "$ledger" "task-over" "none" "0/2" "7/6 (BLOCK)" "0/2" "0/2" "within-budget"
  write_counter_request "$request" "task-over" "none" "7/6 (BLOCK)" "within-budget"

  if run_admission counter --request "$request" --ledger "$ledger" --json >"$stdout_file"; then
    fail "over-ceiling counter should fail closed"
  fi

  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("counter over ceiling"))' "true"
}

test_counter_admission_fails_projected_seventh_request() {
  local ledger="$TMP_ROOT/counter-projected-ledger.md"
  local request="$TMP_ROOT/counter-projected.json"
  local stdout_file="$TMP_ROOT/counter-projected.out"

  write_ledger "$ledger" "task-projected" "none" "0/2" "6/6" "0/2" "0/2" "within-budget"
  write_counter_request "$request" "task-projected" "none" "6/6" "within-budget"

  if run_admission counter --request "$request" --ledger "$ledger" --json >"$stdout_file"; then
    fail "projected seventh reviewer request should fail closed"
  fi

  assert_failure_json "$stdout_file" '.projected_cumulative_reviewer_requests_for_task' "7/6"
  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("projected reviewer request"))' "true"
}

test_counter_admission_fails_exhausted_budget() {
  local ledger="$TMP_ROOT/counter-budget-ledger.md"
  local request="$TMP_ROOT/counter-budget.json"
  local stdout_file="$TMP_ROOT/counter-budget.out"

  write_ledger "$ledger" "task-budget" "none" "0/2" "1/6" "0/2" "0/2" "exhausted"
  write_counter_request "$request" "task-budget" "none" "1/6" "exhausted"

  if run_admission counter --request "$request" --ledger "$ledger" --json >"$stdout_file"; then
    fail "exhausted budget should fail closed"
  fi

  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("budget status is exhausted"))' "true"
}

test_counter_admission_fails_stale_within_budget_self_assertion() {
  local ledger="$TMP_ROOT/counter-stale-budget-ledger.md"
  local request="$TMP_ROOT/counter-stale-budget.json"
  local stdout_file="$TMP_ROOT/counter-stale-budget.out"

  write_ledger "$ledger" "task-stale-budget" "none" "0/2" "1/6" "0/2" "0/2" "within-budget"
  write_counter_request "$request" "task-stale-budget" "none" "1/6" "within-budget"

  if run_admission counter --request "$request" --ledger "$ledger" --json --now "2026-04-30T05:00:01Z" >"$stdout_file"; then
    fail "stale within-budget self-assertion should fail closed"
  fi

  assert_failure_json "$stdout_file" '.task_id' "task-stale-budget"
  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("stale task-level wall-time budget"))' "true"
  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("stale task-level stall-time budget"))' "true"
}

test_counter_admission_passes_budget_max_auto_loop_ceiling() {
  local ledger="$TMP_ROOT/counter-budget-max-ledger.md"
  local request="$TMP_ROOT/counter-budget-max.json"
  local output=""
  local budget="stall<=60m; wall<=480m; basis=task-lineage-opened-at; start=2026-04-30T00:00:00Z; last-progress=2026-04-30T00:05:00Z"

  write_ledger "$ledger" "task-budget-max" "none" "0/2" "1/6" "0/2" "0/2" "within-budget" "$budget"
  write_counter_request "$request" "task-budget-max" "none" "1/6" "within-budget" "$budget"

  output="$(run_admission counter --request "$request" --ledger "$ledger" --json)"

  assert_json_field "$output" '.status' "ADMIT"
  assert_json_field "$output" '.allowed' "true"
}

test_counter_admission_fails_budget_above_max_auto_loop_ceiling() {
  local ledger="$TMP_ROOT/counter-budget-over-ledger.md"
  local request="$TMP_ROOT/counter-budget-over.json"
  local stdout_file="$TMP_ROOT/counter-budget-over.out"
  local budget="stall<=61m; wall<=481m; basis=task-lineage-opened-at; start=2026-04-30T00:00:00Z; last-progress=2026-04-30T00:05:00Z"

  write_ledger "$ledger" "task-budget-over" "none" "0/2" "1/6" "0/2" "0/2" "within-budget" "$budget"
  write_counter_request "$request" "task-budget-over" "none" "1/6" "within-budget" "$budget"

  if run_admission counter --request "$request" --ledger "$ledger" --json >"$stdout_file"; then
    fail "budget above max auto-loop ceiling should fail closed"
  fi

  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("stall budget exceeds max auto-loop ceiling: stall<=61m"))' "true"
  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("wall budget exceeds max auto-loop ceiling: wall<=481m"))' "true"
}

test_counter_admission_fails_relabel_reset_escape() {
  local ledger="$TMP_ROOT/counter-relabel-ledger.md"
  local request="$TMP_ROOT/counter-relabel.json"
  local stdout_file="$TMP_ROOT/counter-relabel.out"

  write_ledger "$ledger" "task-relabel" "none" "0/2" "1/6" "0/2" "0/2" "within-budget"
  write_counter_request "$request" "task-relabel" "none" "1/6" "within-budget"
  jq '.materially_same_change_surface = true' "$request" >"$request.tmp"
  mv "$request.tmp" "$request"

  if run_admission counter --request "$request" --ledger "$ledger" --json >"$stdout_file"; then
    fail "materially same relabel with prior_task_id none should fail closed"
  fi

  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("materially same change surface"))' "true"
}

test_counter_admission_fails_non_monotonic_carried_lineage() {
  local ledger="$TMP_ROOT/counter-reset-ledger.md"
  local request="$TMP_ROOT/counter-reset.json"
  local stdout_file="$TMP_ROOT/counter-reset.out"

  write_ledger "$ledger" "task-reset" "task-before" "0/2" "1/6" "0/2" "0/2" "within-budget"
  write_counter_request "$request" "task-reset" "task-before" "1/6" "within-budget"
  jq '
    .reopen_delta_summary = "narrowed scope"
    | .delta_evidence = "fixture"
    | .previous_counters = {
      "re_slice_count_for_task": "0/2",
      "cumulative_reviewer_requests_for_task": "2/6",
      "cumulative_late_same_class_findings_for_task": "0/2",
      "cumulative_closure_resets_for_task": "0/2"
    }
  ' "$request" >"$request.tmp"
  mv "$request.tmp" "$request"

  if run_admission counter --request "$request" --ledger "$ledger" --json >"$stdout_file"; then
    fail "non-monotonic carried counter should fail closed"
  fi

  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("counter reset detected"))' "true"
}

test_counter_admission_rejects_cross_task_counter_spoof() {
  local ledger="$TMP_ROOT/counter-cross-task-ledger.md"
  local request="$TMP_ROOT/counter-cross-task.json"
  local stdout_file="$TMP_ROOT/counter-cross-task.out"

  cat >"$ledger" <<'EOF'
# Task Lineage Ledger Fixture

## task-cross-target

- task id: `task-cross-target`
- prior task id: `none`
- re-slice count for task: `0/2`
- cumulative reviewer requests for task: `3/6`
- cumulative late same-class findings for task: `0/2`
- cumulative closure resets for task: `0/2`
- task-level stall-or-wall-time budget: `stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-30T00:00:00Z; last-progress=2026-04-30T00:05:00Z`
- task-level stall-or-wall-time budget status: `within-budget`

## task-cross-spoof

- task id: `task-cross-spoof`
- prior task id: `none`
- re-slice count for task: `0/2`
- cumulative reviewer requests for task: `5/6`
- cumulative late same-class findings for task: `0/2`
- cumulative closure resets for task: `0/2`
- task-level stall-or-wall-time budget: `stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-30T00:00:00Z; last-progress=2026-04-30T00:05:00Z`
- task-level stall-or-wall-time budget status: `within-budget`
EOF
  write_counter_request "$request" "task-cross-target" "none" "5/6" "within-budget"

  if run_admission counter --request "$request" --ledger "$ledger" --json >"$stdout_file"; then
    fail "cross-task counter evidence should fail closed"
  fi

  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("ledger does not carry counter cumulative reviewer requests for task=5/6"))' "true"
}

test_counter_admission_fails_missing_carried_previous_counter() {
  local ledger="$TMP_ROOT/counter-missing-previous-ledger.md"
  local request="$TMP_ROOT/counter-missing-previous.json"
  local stdout_file="$TMP_ROOT/counter-missing-previous.out"

  write_ledger "$ledger" "task-missing-previous" "task-before" "0/2" "1/6" "0/2" "0/2" "within-budget"
  write_counter_request "$request" "task-missing-previous" "task-before" "1/6" "within-budget"
  jq '
    .reopen_delta_summary = "narrowed scope"
    | .delta_evidence = "fixture"
    | .previous_counters = {
      "re_slice_count_for_task": "0/2",
      "cumulative_reviewer_requests_for_task": "1/6",
      "cumulative_late_same_class_findings_for_task": "0/2"
    }
  ' "$request" >"$request.tmp"
  mv "$request.tmp" "$request"

  if run_admission counter --request "$request" --ledger "$ledger" --json >"$stdout_file"; then
    fail "missing carried previous counter should fail closed"
  fi

  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("missing previous counter for carried lineage: cumulative closure resets for task"))' "true"
}

test_schema_micro_fix_admission_passes_without_acceptance_claims() {
  local ledger="$TMP_ROOT/micro-pass-ledger.md"
  local manifest="$TMP_ROOT/micro-pass.json"
  local output=""

  write_ledger "$ledger" "task-micro" "none" "0/2" "4/6" "0/2" "0/2" "within-budget"
  write_schema_micro_manifest "$manifest" "task-micro" "4/6"

  output="$(run_admission schema-micro-fix --manifest "$manifest" --ledger "$ledger" --json)"

  assert_json_field "$output" '.status' "ADMIT"
  assert_json_field "$output" '.admission_type' "schema-micro-fix"
  assert_json_field "$output" '.review_request_target' "INTERMEDIATE"
  assert_json_field "$output" '.projected_cumulative_reviewer_requests_for_task' "5/6"
  assert_json_field "$output" '.non_claims.reviewer_waived' "false"
  assert_json_field "$output" '.non_claims.counter_reset' "false"
}

test_schema_micro_fix_fails_waiver_or_acceptance_claim() {
  local ledger="$TMP_ROOT/micro-claim-ledger.md"
  local manifest="$TMP_ROOT/micro-claim.json"
  local stdout_file="$TMP_ROOT/micro-claim.out"

  write_ledger "$ledger" "task-micro-claim" "none" "0/2" "1/6" "0/2" "0/2" "within-budget"
  write_schema_micro_manifest "$manifest" "task-micro-claim" "1/6"
  jq '.claims.acceptance = true | .claims.reviewer_waived = true' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  if run_admission schema-micro-fix --manifest "$manifest" --ledger "$ledger" --json >"$stdout_file"; then
    fail "schema micro-fix acceptance/waiver claim should fail closed"
  fi

  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("claims.acceptance=false"))' "true"
  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("claims.reviewer_waived=false"))' "true"
}

test_schema_micro_fix_rejects_runtime_surface() {
  local ledger="$TMP_ROOT/micro-runtime-ledger.md"
  local manifest="$TMP_ROOT/micro-runtime.json"
  local stdout_file="$TMP_ROOT/micro-runtime.out"

  write_ledger "$ledger" "task-micro-runtime" "none" "0/2" "1/6" "0/2" "0/2" "within-budget"
  write_schema_micro_manifest "$manifest" "task-micro-runtime" "1/6"
  jq '.changed_files += ["scripts/runtime-change.json"]' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  if run_admission schema-micro-fix --manifest "$manifest" --ledger "$ledger" --json >"$stdout_file"; then
    fail "schema micro-fix runtime surface should fail closed"
  fi

  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("outside doc/schema/lint-only"))' "true"
}

test_schema_micro_fix_rejects_traversal_changed_file() {
  local ledger="$TMP_ROOT/micro-traversal-ledger.md"
  local manifest="$TMP_ROOT/micro-traversal.json"
  local stdout_file="$TMP_ROOT/micro-traversal.out"

  write_ledger "$ledger" "task-micro-traversal" "none" "0/2" "1/6" "0/2" "0/2" "within-budget"
  write_schema_micro_manifest "$manifest" "task-micro-traversal" "1/6"
  jq '.changed_files += ["docs/../scripts/runtime-change.sh"]' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  if run_admission schema-micro-fix --manifest "$manifest" --ledger "$ledger" --json >"$stdout_file"; then
    fail "schema micro-fix traversal changed file should fail closed"
  fi

  assert_failure_json "$stdout_file" '.fail_closed_reasons | any(contains("not a safe repo-relative path"))' "true"
}

test_counter_admission_passes_with_projected_request
test_counter_admission_fails_missing_lineage_with_json
test_counter_admission_fails_current_over_ceiling
test_counter_admission_fails_projected_seventh_request
test_counter_admission_fails_exhausted_budget
test_counter_admission_fails_stale_within_budget_self_assertion
test_counter_admission_passes_budget_max_auto_loop_ceiling
test_counter_admission_fails_budget_above_max_auto_loop_ceiling
test_counter_admission_fails_relabel_reset_escape
test_counter_admission_fails_non_monotonic_carried_lineage
test_counter_admission_rejects_cross_task_counter_spoof
test_counter_admission_fails_missing_carried_previous_counter
test_schema_micro_fix_admission_passes_without_acceptance_claims
test_schema_micro_fix_fails_waiver_or_acceptance_claim
test_schema_micro_fix_rejects_runtime_surface
test_schema_micro_fix_rejects_traversal_changed_file

printf 'PASS: rev_harness_admission_test\n'
