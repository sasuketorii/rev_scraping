#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER="$PROJECT_ROOT/scripts/harness-block-router.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local haystack="$1"
  local needle="$2"
  grep -Fq -- "$needle" <<<"$haystack"
}

run_router() {
  (cd "$PROJECT_ROOT" && bash "$ROUTER" "$@")
}

assert_json_field() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual=""

  actual="$(jq -r "$filter" <<<"$json")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected, got $actual"
}

test_list_contains_all_block_types() {
  local output=""
  output="$(run_router --list)"

  contains "$output" "code-block" || fail "missing code-block"
  contains "$output" "process-block" || fail "missing process-block"
  contains "$output" "governance-block" || fail "missing governance-block"
  contains "$output" "terminal-block" || fail "missing terminal-block"
}

test_list_json_returns_array() {
  local output=""
  output="$(run_router --list --json)"

  assert_json_field "$output" 'type' "array"
  assert_json_field "$output" 'index("code-block") != null' "true"
  assert_json_field "$output" 'index("terminal-block") != null' "true"
}

test_code_block_routes_to_coder() {
  local output=""
  output="$(run_router --type code-block)"

  contains "$output" "- route owner: coder" || fail "code-block should route to coder"
  contains "$output" "- auto retry allowed: true" || fail "code-block should allow retry"
}

test_process_block_routes_to_orchestrator() {
  local owner=""
  owner="$(run_router --type process-block --field route_owner)"

  [[ "$owner" == "orchestrator" ]] || fail "process-block should route to orchestrator"
}

test_governance_block_requires_user_decision() {
  local output=""
  output="$(run_router --type governance-block --json)"

  assert_json_field "$output" '.requires_user_decision' "true"
  assert_json_field "$output" '.auto_retry_allowed' "false"
}

test_terminal_block_stops_auto_retry() {
  local output=""
  output="$(run_router --type terminal-block --json)"

  assert_json_field "$output" '.route_owner' "user"
  assert_json_field "$output" '.auto_retry_allowed' "false"
}

test_unknown_block_type_fails_closed() {
  if run_router --type mystery-block >/tmp/harness-block-router-unknown.out 2>/tmp/harness-block-router-unknown.err; then
    fail "unknown block type should fail"
  fi
}

test_unknown_field_fails_without_stdout() {
  local stdout_file="/tmp/harness-block-router-unknown-field.out"
  local stderr_file="/tmp/harness-block-router-unknown-field.err"

  if run_router --type governance-block --field does_not_exist >"$stdout_file" 2>"$stderr_file"; then
    fail "unknown field should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "unknown field should not write stdout"
  contains "$(cat "$stderr_file")" "unknown field for block type governance-block: does_not_exist" \
    || fail "unknown field should emit explicit error"
}

test_empty_field_fails_without_stdout() {
  local stdout_file="/tmp/harness-block-router-empty-field.out"
  local stderr_file="/tmp/harness-block-router-empty-field.err"

  if run_router --type code-block --field '' >"$stdout_file" 2>"$stderr_file"; then
    fail "empty field should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "empty field should not write stdout"
  contains "$(cat "$stderr_file")" "--field cannot be empty" \
    || fail "empty field should emit explicit error"
}

test_empty_type_fails_without_stdout() {
  local stdout_file="/tmp/harness-block-router-empty-type.out"
  local stderr_file="/tmp/harness-block-router-empty-type.err"

  if run_router --type '' >"$stdout_file" 2>"$stderr_file"; then
    fail "empty type should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "empty type should not write stdout"
  contains "$(cat "$stderr_file")" "--type cannot be empty" \
    || fail "empty type should emit explicit error"
}

test_list_empty_type_fails_without_stdout() {
  local stdout_file="/tmp/harness-block-router-list-empty-type.out"
  local stderr_file="/tmp/harness-block-router-list-empty-type.err"

  if run_router --list --type '' >"$stdout_file" 2>"$stderr_file"; then
    fail "empty list type should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "empty list type should not write stdout"
  contains "$(cat "$stderr_file")" "--type cannot be empty" \
    || fail "empty list type should emit explicit error"
}

test_list_contains_all_block_types
test_list_json_returns_array
test_code_block_routes_to_coder
test_process_block_routes_to_orchestrator
test_governance_block_requires_user_decision
test_terminal_block_stops_auto_retry
test_unknown_block_type_fails_closed
test_unknown_field_fails_without_stdout
test_empty_field_fails_without_stdout
test_empty_type_fails_without_stdout
test_list_empty_type_fails_without_stdout

printf 'PASS: harness_block_router_test\n'
