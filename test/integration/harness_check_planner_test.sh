#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLANNER="$PROJECT_ROOT/scripts/harness-check-planner.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local haystack="$1"
  local needle="$2"
  grep -Fq -- "$needle" <<<"$haystack"
}

run_planner() {
  (cd "$PROJECT_ROOT" && bash "$PLANNER" "$@")
}

test_docs_dev_mode_stays_light() {
  local output=""
  output="$(run_planner --mode dev docs/manual/harness-user-guide.md)"

  contains "$output" "git diff --check -- docs/manual/harness-user-guide.md" \
    || fail "docs dev mode should include diff check"
  ! contains "$output" "harness_release_gate.sh" \
    || fail "docs dev mode should not include release gate"
}

test_shell_change_gets_syntax_check() {
  local output=""
  output="$(run_planner --mode dev scripts/harness-check-planner.sh)"

  contains "$output" "bash -n -- scripts/harness-check-planner.sh" \
    || fail "shell change should include bash -n"
}

test_json_change_gets_jq_check() {
  local output=""
  output="$(run_planner --mode dev .agent/registry/harness_operating_modes.json)"

  contains "$output" "jq empty -- .agent/registry/harness_operating_modes.json" \
    || fail "json change should include jq empty"
}

test_projection_registry_gets_schema_preflight() {
  local output=""
  output="$(run_planner --mode dev .agent/registry/orchestration_policy_projection.json)"

  contains "$output" "jq empty -- .agent/registry/orchestration_policy_projection.json" \
    || fail "projection registry change should include jq empty"
  contains "$output" "bash scripts/harness-projection-preflight.sh --validate" \
    || fail "projection registry change should include schema preflight"
}

test_executable_integration_change_gets_self_run() {
  local output=""
  output="$(run_planner --mode review test/integration/harness_release_gate.sh)"

  contains "$output" "bash -n -- test/integration/harness_release_gate.sh" \
    || fail "integration shell change should include bash -n"
  contains "$output" "bash -- test/integration/harness_release_gate.sh" \
    || fail "executable integration change should include self-run command"
}

test_review_mode_adds_review_surface_command() {
  local dev_output=""
  local review_output=""

  dev_output="$(run_planner --mode dev docs/manual/harness-user-guide.md)"
  review_output="$(run_planner --mode review docs/manual/harness-user-guide.md)"

  ! contains "$dev_output" "git diff --stat -- docs/manual/harness-user-guide.md" \
    || fail "dev mode should not include review diff summary"
  contains "$review_output" "git diff --stat -- docs/manual/harness-user-guide.md" \
    || fail "review mode should include review diff summary"
}

test_option_like_paths_are_protected() {
  local output=""
  output="$(run_planner --mode dev -- '--version.sh' '--foo.json')"

  contains "$output" "bash -n -- --version.sh" \
    || fail "option-like shell path should be protected with --"
  contains "$output" "jq empty -- --foo.json" \
    || fail "option-like json path should be protected with --"
}

test_release_mode_includes_release_gate() {
  local output=""
  output="$(run_planner --mode release docs/manual/harness-user-guide.md)"

  contains "$output" "bash test/integration/harness_release_gate.sh" \
    || fail "release mode should include release gate"
}

test_unknown_mode_fails_closed() {
  if run_planner --mode turbo docs/manual/harness-user-guide.md >/tmp/harness-check-planner-unknown.out 2>/tmp/harness-check-planner-unknown.err; then
    fail "unknown mode should fail"
  fi
}

test_docs_dev_mode_stays_light
test_shell_change_gets_syntax_check
test_json_change_gets_jq_check
test_projection_registry_gets_schema_preflight
test_executable_integration_change_gets_self_run
test_review_mode_adds_review_surface_command
test_option_like_paths_are_protected
test_release_mode_includes_release_gate
test_unknown_mode_fails_closed

printf 'PASS: harness_check_planner_test\n'
