#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_ROOT=""
TASK_ID="policy-linkage-task-$$"
SLICE_ID="slice-policy-linkage"
GENERATED_POLICY_PATH="$PROJECT_ROOT/.agent/generated/codex_model_policy.runtime.json"
GENERATED_POLICY_BACKUP=""

cleanup() {
  if [[ -n "${GENERATED_POLICY_BACKUP:-}" && -f "$GENERATED_POLICY_BACKUP" ]]; then
    cp "$GENERATED_POLICY_BACKUP" "$GENERATED_POLICY_PATH" 2>/dev/null || true
  fi
  /bin/rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
  /bin/rm -rf -- "$PROJECT_ROOT/.claude/tmp/benchmarks/$TASK_ID" 2>/dev/null || true
  /bin/rm -rf -- "$PROJECT_ROOT/.claude/tmp/benchmarks/$TASK_ID-drift-digest" 2>/dev/null || true
  /bin/rm -rf -- "$PROJECT_ROOT/.claude/tmp/benchmarks/$TASK_ID-drift-path" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

hash_file() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi

  shasum -a 256 "$path" | awk '{print $1}'
}

assert_jq() {
  local filter="$1"
  local file="$2"
  jq -e "$filter" "$file" >/dev/null || fail "jq assertion failed for $file: $filter"
}

restore_generated_policy() {
  [[ -n "${GENERATED_POLICY_BACKUP:-}" && -f "$GENERATED_POLICY_BACKUP" ]] \
    || fail "missing generated policy backup"
  cp "$GENERATED_POLICY_BACKUP" "$GENERATED_POLICY_PATH"
}

write_stale_generated_source_digest() {
  local tmp_path="$TMP_ROOT/generated-policy-stale-digest.json"

  jq --arg stale_digest "0000000000000000000000000000000000000000000000000000000000000000" \
    '.source_policy_sha256 = $stale_digest' \
    "$GENERATED_POLICY_PATH" > "$tmp_path"
  mv "$tmp_path" "$GENERATED_POLICY_PATH"
}

write_stale_generated_source_path() {
  local tmp_path="$TMP_ROOT/generated-policy-stale-path.json"

  jq --arg stale_path ".agent/registry/stale_model_policy.json" \
    '.source_policy_path = $stale_path' \
    "$GENERATED_POLICY_PATH" > "$tmp_path"
  mv "$tmp_path" "$GENERATED_POLICY_PATH"
}

run_success_case() {
  local fixture_path=""
  local benchmark_output=""
  local artifact_root=""
  local linkage_path=""
  local source_policy_sha256=""
  local generated_policy_sha256=""

  fixture_path="$TMP_ROOT/fixture.txt"
  printf 'policy linkage fixture\n' > "$fixture_path"

  source_policy_sha256="$(hash_file "$PROJECT_ROOT/.agent/registry/model_policy.json")"
  generated_policy_sha256="$(hash_file "$PROJECT_ROOT/.agent/generated/codex_model_policy.runtime.json")"

  benchmark_output="$(
    cd "$PROJECT_ROOT"
    bash scripts/harness-benchmark.sh \
      --task-id "$TASK_ID" \
      --slice-id "$SLICE_ID" \
      --fixture "$fixture_path" \
      --baseline-command 'true' \
      --candidate-command 'true' \
      --runs 1
  )"

  artifact_root="$(printf '%s\n' "$benchmark_output" | awk -F= '$1 == "ARTIFACT_ROOT" { print $2; exit }')"
  [[ -n "$artifact_root" ]] || fail "missing ARTIFACT_ROOT"
  [[ -d "$artifact_root" ]] || fail "missing artifact root: $artifact_root"

  linkage_path="$artifact_root/model-policy-linkage.json"
  [[ -f "$linkage_path" ]] || fail "missing model-policy-linkage.json"

  assert_jq '.schema_version == "harness-benchmark/model-policy-linkage/v1"' "$linkage_path"
  assert_jq '.producer == "scripts/harness-benchmark.sh"' "$linkage_path"
  assert_jq ".task_id == \"$TASK_ID\" and .slice_id == \"$SLICE_ID\"" "$linkage_path"
  assert_jq '.source_policy_path == ".agent/registry/model_policy.json" and .source_policy_digest_algorithm == "sha256"' "$linkage_path"
  assert_jq ".source_policy_sha256 == \"$source_policy_sha256\"" "$linkage_path"
  assert_jq '.generated_policy_path == ".agent/generated/codex_model_policy.runtime.json" and .generated_policy_digest_algorithm == "sha256"' "$linkage_path"
  assert_jq ".generated_policy_sha256 == \"$generated_policy_sha256\"" "$linkage_path"
  assert_jq ".generated_policy_source_policy_sha256 == \"$source_policy_sha256\"" "$linkage_path"
  assert_jq '.generated_policy_schema_version == "codex-model-runtime-policy/v1"' "$linkage_path"
  assert_jq '.generated_policy_current_model != "" and .generated_policy_stable_default_model != "" and .generated_policy_minimum_allowed_model != ""' "$linkage_path"
}

run_drift_failure_case() {
  local label="$1"
  local expected_error="$2"
  local fixture_path="$TMP_ROOT/fixture-drift-$label.txt"
  local task_id="$TASK_ID-drift-$label"
  local slice_id="$SLICE_ID-drift-$label"
  local benchmark_task_root="$PROJECT_ROOT/.claude/tmp/benchmarks/$task_id"

  /bin/rm -rf -- "$benchmark_task_root"
  printf 'policy linkage drift fixture\n' > "$fixture_path"

  if HARNESS_BENCH_RUN_ID="drift-$label-run" \
    bash "$PROJECT_ROOT/scripts/harness-benchmark.sh" \
      --task-id "$task_id" \
      --slice-id "$slice_id" \
      --fixture "$fixture_path" \
      --baseline-command 'true' \
      --candidate-command 'true' \
      --runs 1 \
      >"$TMP_ROOT/drift-$label.stdout" \
      2>"$TMP_ROOT/drift-$label.stderr"; then
    fail "stale generated policy should fail: $label"
  fi

  [[ ! -e "$benchmark_task_root" ]] || fail "partial benchmark artifact root should not remain for drift: $benchmark_task_root"
  grep -Fq -- "$expected_error" "$TMP_ROOT/drift-$label.stderr" \
    || fail "missing expected drift error for $label: $expected_error"
}

main() {
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/harness-benchmark-policy-linkage.XXXXXX")"
  GENERATED_POLICY_BACKUP="$TMP_ROOT/codex_model_policy.runtime.json.backup"
  cp "$GENERATED_POLICY_PATH" "$GENERATED_POLICY_BACKUP"

  run_success_case

  restore_generated_policy
  write_stale_generated_source_digest
  run_drift_failure_case "digest" "generated model policy source digest drift"

  restore_generated_policy
  write_stale_generated_source_path
  run_drift_failure_case "path" "generated model policy source path drift"

  restore_generated_policy
  printf 'PASS: harness_benchmark_policy_linkage_test\n'
}

main "$@"
