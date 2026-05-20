#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFLIGHT="$PROJECT_ROOT/scripts/harness-projection-preflight.sh"
PROJECTION_REGISTRY="$PROJECT_ROOT/.agent/registry/orchestration_policy_projection.json"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local haystack="$1"
  local needle="$2"
  grep -Fq -- "$needle" <<<"$haystack"
}

run_preflight() {
  (cd "$PROJECT_ROOT" && bash "$PREFLIGHT" "$@")
}

run_preflight_with_registry() {
  local registry="$1"
  shift
  (cd "$PROJECT_ROOT" && HARNESS_PROJECTION_PREFLIGHT_REGISTRY="$registry" bash "$PREFLIGHT" "$@")
}

assert_preflight_with_registry_fails_without_stdout() {
  local registry="$1"
  local test_name="$2"
  shift 2
  local stdout_file="/tmp/harness-projection-preflight-${test_name}.out"
  local stderr_file="/tmp/harness-projection-preflight-${test_name}.err"

  if run_preflight_with_registry "$registry" "$@" >"$stdout_file" 2>"$stderr_file"; then
    fail "$test_name should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "$test_name should not write stdout"
}

assert_json_field() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual=""

  actual="$(jq -r "$filter" <<<"$json")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected, got $actual"
}

test_validate_passes() {
  local output=""
  output="$(run_preflight --validate)"

  contains "$output" "PASS: projection registry schema" \
    || fail "validate should report schema pass"
}

test_list_statuses_contains_next_statuses() {
  local output=""
  output="$(run_preflight --list-statuses)"

  contains "$output" "pending acceptance" || fail "missing pending acceptance"
  contains "$output" "blocked" || fail "missing blocked"
  contains "$output" "pending review" || fail "missing pending review"
  contains "$output" "pending verification" || fail "missing pending verification"
}

test_list_statuses_json_returns_array() {
  local output=""
  output="$(run_preflight --list-statuses --json)"

  assert_json_field "$output" 'type' "array"
  assert_json_field "$output" 'index("pending acceptance") != null' "true"
  assert_json_field "$output" 'index("blocked") != null' "true"
}

test_status_json_projects_matching_verdicts() {
  local output=""
  output="$(run_preflight --status 'pending acceptance' --json)"

  assert_json_field "$output" '.status' "pending acceptance"
  assert_json_field "$output" '.matching_review_verdicts[0]' "LGTM"
  assert_json_field "$output" '.lgtm_gate_applies' "true"
}

test_status_field_returns_scalar() {
  local output=""
  output="$(run_preflight --status 'pending acceptance' --field lgtm_gate_required_request_target)"

  [[ "$output" == "FINAL" ]] || fail "LGTM gate target should be FINAL"
}

test_unknown_status_fails_closed() {
  if run_preflight --status done --json >/tmp/harness-projection-preflight-unknown-status.out 2>/tmp/harness-projection-preflight-unknown-status.err; then
    fail "unknown status should fail"
  fi
}

test_unknown_field_fails_without_stdout() {
  local stdout_file="/tmp/harness-projection-preflight-unknown-field.out"
  local stderr_file="/tmp/harness-projection-preflight-unknown-field.err"

  if run_preflight --status blocked --field does_not_exist >"$stdout_file" 2>"$stderr_file"; then
    fail "unknown field should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "unknown field should not write stdout"
  contains "$(cat "$stderr_file")" "unknown field for status blocked: does_not_exist" \
    || fail "unknown field should emit explicit error"
}

test_empty_status_fails_without_stdout() {
  local stdout_file="/tmp/harness-projection-preflight-empty-status.out"
  local stderr_file="/tmp/harness-projection-preflight-empty-status.err"

  if run_preflight --status '' --json >"$stdout_file" 2>"$stderr_file"; then
    fail "empty status should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "empty status should not write stdout"
  contains "$(cat "$stderr_file")" "--status cannot be empty" \
    || fail "empty status should emit explicit error"
}

test_empty_field_fails_without_stdout() {
  local stdout_file="/tmp/harness-projection-preflight-empty-field.out"
  local stderr_file="/tmp/harness-projection-preflight-empty-field.err"

  if run_preflight --status blocked --field '' >"$stdout_file" 2>"$stderr_file"; then
    fail "empty field should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "empty field should not write stdout"
  contains "$(cat "$stderr_file")" "--field cannot be empty" \
    || fail "empty field should emit explicit error"
}

test_empty_args_fail_closed() {
  if run_preflight >/tmp/harness-projection-preflight-empty-args.out 2>/tmp/harness-projection-preflight-empty-args.err; then
    fail "empty args should fail"
  fi
}

test_unsupported_mode_fails_closed() {
  if run_preflight --mode release --validate >/tmp/harness-projection-preflight-mode.out 2>/tmp/harness-projection-preflight-mode.err; then
    fail "unsupported mode should fail"
  fi
}

test_validate_json_fails_without_stdout() {
  local stdout_file="/tmp/harness-projection-preflight-validate-json.out"
  local stderr_file="/tmp/harness-projection-preflight-validate-json.err"

  if run_preflight --validate --json >"$stdout_file" 2>"$stderr_file"; then
    fail "--validate --json should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "--validate --json should not write stdout"
  contains "$(cat "$stderr_file")" "--validate does not support --json" \
    || fail "--validate --json should emit explicit error"
}

test_invalid_json_registry_fails_closed() {
  local tmp_registry="/tmp/harness-projection-preflight-invalid.json"
  printf '{invalid json\n' >"$tmp_registry"

  if run_preflight_with_registry "$tmp_registry" --validate >/tmp/harness-projection-preflight-invalid-json.out 2>/tmp/harness-projection-preflight-invalid-json.err; then
    fail "invalid JSON registry should fail"
  fi
}

test_invalid_schema_registry_fails_closed() {
  local tmp_registry="/tmp/harness-projection-preflight-invalid-schema.json"
  printf '{"reviewer_contract":{}}\n' >"$tmp_registry"

  if run_preflight_with_registry "$tmp_registry" --validate >/tmp/harness-projection-preflight-invalid-schema.out 2>/tmp/harness-projection-preflight-invalid-schema.err; then
    fail "invalid schema registry should fail"
  fi
}

test_swapped_verdict_mapping_fails_closed() {
  local tmp_registry="/tmp/harness-projection-preflight-swapped-mapping.json"
  jq '
    .reviewer_contract.verdict_outgoing_next_status.LGTM = "blocked"
    | .reviewer_contract.verdict_outgoing_next_status.BLOCK = "pending acceptance"
  ' "$PROJECTION_REGISTRY" >"$tmp_registry"

  assert_preflight_with_registry_fails_without_stdout "$tmp_registry" "swapped-mapping" --validate
}

test_shortcut_completed_mapping_fails_closed() {
  local tmp_registry="/tmp/harness-projection-preflight-completed-mapping.json"
  jq '
    .reviewer_contract.accepted_outgoing_next_statuses += ["completed"]
    | .reviewer_contract.verdict_outgoing_next_status.LGTM = "completed"
  ' "$PROJECTION_REGISTRY" >"$tmp_registry"

  assert_preflight_with_registry_fails_without_stdout "$tmp_registry" "completed-mapping" --validate
}

test_forbidden_accepted_status_fails_closed() {
  local tmp_registry="/tmp/harness-projection-preflight-forbidden-status.json"
  jq '.reviewer_contract.accepted_outgoing_next_statuses += ["completed"]' "$PROJECTION_REGISTRY" >"$tmp_registry"

  assert_preflight_with_registry_fails_without_stdout "$tmp_registry" "forbidden-status" --validate
}

test_noncanonical_lgtm_gate_fails_closed() {
  local tmp_registry="/tmp/harness-projection-preflight-lgtm-gate.json"
  jq '.reviewer_contract.lgtm_gate.required_request_target = "INTERMEDIATE"' "$PROJECTION_REGISTRY" >"$tmp_registry"

  assert_preflight_with_registry_fails_without_stdout "$tmp_registry" "lgtm-gate" --validate
}

test_validate_passes
test_list_statuses_contains_next_statuses
test_list_statuses_json_returns_array
test_status_json_projects_matching_verdicts
test_status_field_returns_scalar
test_unknown_status_fails_closed
test_unknown_field_fails_without_stdout
test_empty_status_fails_without_stdout
test_empty_field_fails_without_stdout
test_empty_args_fail_closed
test_unsupported_mode_fails_closed
test_validate_json_fails_without_stdout
test_invalid_json_registry_fails_closed
test_invalid_schema_registry_fails_closed
test_swapped_verdict_mapping_fails_closed
test_shortcut_completed_mapping_fails_closed
test_forbidden_accepted_status_fails_closed
test_noncanonical_lgtm_gate_fails_closed

printf 'PASS: harness_projection_preflight_test\n'
