#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLASSIFIER="$PROJECT_ROOT/scripts/harness-governance-classifier.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_classifier() {
  (cd "$PROJECT_ROOT" && bash "$CLASSIFIER" "$@")
}

assert_classifier() {
  local expected="$1"
  shift
  local actual=""

  actual="$(run_classifier --json -- "$@" | jq -r '.classifier')"
  [[ "$actual" == "$expected" ]] || fail "expected $expected for $*, got $actual"
}

test_docs_reference_is_light() {
  assert_classifier light docs/official-docs-links.md
}

test_unclassified_defaults_standard() {
  assert_classifier standard unknown.surface
}

test_script_is_standard() {
  assert_classifier standard scripts/harness-check-planner.sh
}

test_integration_is_standard() {
  assert_classifier standard test/integration/harness_check_planner_test.sh
}

test_wrapper_is_heavy() {
  assert_classifier heavy scripts/codex-wrapper.sh
}

test_dot_prefixed_wrapper_is_heavy() {
  assert_classifier heavy ./scripts/codex-wrapper.sh
}

test_absolute_wrapper_is_heavy() {
  assert_classifier heavy "$PROJECT_ROOT/scripts/codex-wrapper.sh"
}

test_double_slash_absolute_wrapper_is_heavy() {
  assert_classifier heavy "$PROJECT_ROOT//scripts/codex-wrapper.sh"
}

test_parent_alias_wrapper_is_heavy() {
  assert_classifier heavy "../$(basename "$PROJECT_ROOT")/scripts/codex-wrapper.sh"
}

test_acceptance_truth_is_heavy() {
  assert_classifier heavy docs/manual/verification-truth-matrix.md
}

test_codex_config_is_heavy() {
  assert_classifier heavy .codex/config.toml
}

test_task_lineage_ledger_is_heavy() {
  assert_classifier heavy .agent/active/sow/task-lineage-ledger.md
}

test_dot_prefixed_task_lineage_ledger_is_heavy() {
  assert_classifier heavy ./.agent/active/sow/task-lineage-ledger.md
}

test_absolute_task_lineage_ledger_is_heavy() {
  assert_classifier heavy "$PROJECT_ROOT/.agent/active/sow/task-lineage-ledger.md"
}

test_double_slash_absolute_task_lineage_ledger_is_heavy() {
  assert_classifier heavy "$PROJECT_ROOT//.agent/active/sow/task-lineage-ledger.md"
}

test_embedded_dot_task_lineage_ledger_is_heavy() {
  assert_classifier heavy .agent/active/sow/./task-lineage-ledger.md
}

test_embedded_dotdot_task_lineage_ledger_is_heavy() {
  assert_classifier heavy .agent/active/sow/../sow/task-lineage-ledger.md
}

test_parent_alias_task_lineage_ledger_is_heavy() {
  assert_classifier heavy "../$(basename "$PROJECT_ROOT")/.agent/active/sow/task-lineage-ledger.md"
}

test_root_external_markdown_does_not_use_light_fallback() {
  assert_classifier standard ../outside.md
}

test_active_plan_is_standard() {
  assert_classifier standard .agent/active/plan_20260506_worldclass_harness_operating_model.md
}

test_mixed_paths_choose_heaviest() {
  assert_classifier heavy docs/official-docs-links.md scripts/codex-wrapper.sh
}

test_json_shape() {
  run_classifier --json -- docs/official-docs-links.md \
    | jq -e '.advisory_only == true and (.reasons | length) >= 1 and .operating_mode == "dev"' >/dev/null \
    || fail "json shape should expose advisory mode, reasons, and operating mode"
}

test_docs_reference_is_light
test_unclassified_defaults_standard
test_script_is_standard
test_integration_is_standard
test_wrapper_is_heavy
test_dot_prefixed_wrapper_is_heavy
test_absolute_wrapper_is_heavy
test_double_slash_absolute_wrapper_is_heavy
test_parent_alias_wrapper_is_heavy
test_acceptance_truth_is_heavy
test_codex_config_is_heavy
test_task_lineage_ledger_is_heavy
test_dot_prefixed_task_lineage_ledger_is_heavy
test_absolute_task_lineage_ledger_is_heavy
test_double_slash_absolute_task_lineage_ledger_is_heavy
test_embedded_dot_task_lineage_ledger_is_heavy
test_embedded_dotdot_task_lineage_ledger_is_heavy
test_parent_alias_task_lineage_ledger_is_heavy
test_root_external_markdown_does_not_use_light_fallback
test_active_plan_is_standard
test_mixed_paths_choose_heaviest
test_json_shape

printf 'PASS: harness_governance_classifier_test\n'
