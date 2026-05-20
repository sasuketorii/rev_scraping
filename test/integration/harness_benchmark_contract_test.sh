#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP_ROOT=""
BENCH_TASK_ROOTS=()

cleanup() {
  /bin/rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
  if [[ "${#BENCH_TASK_ROOTS[@]}" -gt 0 ]]; then
    /bin/rm -rf -- "${BENCH_TASK_ROOTS[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || fail "missing file: $path"
}

assert_dir_exists() {
  local path="$1"
  [[ -d "$path" ]] || fail "missing directory: $path"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || fail "missing expected text in $file: $needle"
}

assert_jq() {
  local filter="$1"
  local file="$2"
  jq -e "$filter" "$file" >/dev/null || fail "jq assertion failed for $file: $filter"
}

assert_grep() {
  local pattern="$1"
  local file="$2"
  grep -Eq -- "$pattern" "$file" || fail "pattern not found in $file: $pattern"
}

hash_file() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi

  shasum -a 256 "$path" | awk '{print $1}'
}

assert_line_count() {
  local expected="$1"
  local file="$2"
  local actual=""

  actual="$(wc -l < "$file" | tr -d '[:space:]')"
  [[ "$actual" == "$expected" ]] || fail "unexpected line count for $file (expected=$expected actual=$actual)"
}

track_bench_task_root() {
  local path="$1"
  BENCH_TASK_ROOTS+=("$path")
}

run_success_case() {
  local fixture_path="$TMP_ROOT/fixture.txt"
  local task_id="contract-task-$$"
  local slice_id="slice-contract"
  local benchmark_root="$PROJECT_ROOT/.claude/tmp/benchmarks/$task_id/$slice_id"
  local benchmark_dir=""
  local baseline_command='printf "baseline-stderr-noise\n" >&2; cat "$HARNESS_BENCH_FIXTURE" >/dev/null'
  local candidate_command='printf "candidate-stdout-noise\n"; printf "candidate-stderr-noise\n" >&2; wc -c "$HARNESS_BENCH_FIXTURE" >/dev/null'
  local source_policy_sha256=""
  local generated_policy_sha256=""

  track_bench_task_root "$PROJECT_ROOT/.claude/tmp/benchmarks/$task_id"

  printf 'benchmark fixture\n' > "$fixture_path"
  source_policy_sha256="$(hash_file "$PROJECT_ROOT/.agent/registry/model_policy.json")"
  generated_policy_sha256="$(hash_file "$PROJECT_ROOT/.agent/generated/codex_model_policy.runtime.json")"

  bash "$PROJECT_ROOT/scripts/harness-benchmark.sh" \
    --task-id "$task_id" \
    --slice-id "$slice_id" \
    --fixture "$fixture_path" \
    --baseline-command "$baseline_command" \
    --candidate-command "$candidate_command" \
    --runs 2 \
    >"$TMP_ROOT/success.stdout" \
    2>"$TMP_ROOT/success.stderr"

  benchmark_dir="$(find "$benchmark_root/runs" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
  [[ -n "$benchmark_dir" ]] || fail "missing benchmark run directory"
  assert_dir_exists "$benchmark_dir"
  assert_file_exists "$benchmark_dir/artifact-lifecycle-manifest.json"
  assert_file_exists "$benchmark_dir/model-policy-linkage.json"
  assert_file_exists "$benchmark_dir/summary.tsv"
  assert_file_exists "$benchmark_dir/fixture.sha256"
  assert_file_exists "$benchmark_dir/env.txt"
  assert_file_exists "$benchmark_dir/baseline_command.txt"
  assert_file_exists "$benchmark_dir/candidate_command.txt"
  assert_file_exists "$benchmark_dir/wall_ms_baseline_run01.txt"
  assert_file_exists "$benchmark_dir/wall_ms_baseline_run02.txt"
  assert_file_exists "$benchmark_dir/wall_ms_candidate_run01.txt"
  assert_file_exists "$benchmark_dir/wall_ms_candidate_run02.txt"
  assert_file_exists "$benchmark_dir/peak_rss_kb_baseline_run01.txt"
  assert_file_exists "$benchmark_dir/peak_rss_kb_baseline_run02.txt"
  assert_file_exists "$benchmark_dir/peak_rss_kb_candidate_run01.txt"
  assert_file_exists "$benchmark_dir/peak_rss_kb_candidate_run02.txt"

  assert_line_count 5 "$benchmark_dir/summary.tsv"
  assert_file_contains "$benchmark_dir/summary.tsv" $'subject\trun_index\twall_ms\tpeak_rss_kb\tfixture_sha256\tcommand_file'
  assert_grep '^baseline\t01\t[0-9]+\t[0-9]+\t[0-9a-f]{64}\tbaseline_command\.txt$' "$benchmark_dir/summary.tsv"
  assert_grep '^candidate\t02\t[0-9]+\t[0-9]+\t[0-9a-f]{64}\tcandidate_command\.txt$' "$benchmark_dir/summary.tsv"
  assert_grep '^[0-9a-f]{64}[[:space:]]+' "$benchmark_dir/fixture.sha256"
  assert_file_contains "$benchmark_dir/baseline_command.txt" "$baseline_command"
  assert_file_contains "$benchmark_dir/candidate_command.txt" "$candidate_command"
  assert_file_contains "$benchmark_dir/env.txt" "artifact_root=$benchmark_dir"
  assert_file_contains "$benchmark_dir/env.txt" "runs=2"
  assert_grep '^sha256_tool=(shasum|sha256sum)$' "$benchmark_dir/env.txt"
  assert_file_exists "$benchmark_root/latest.json"
  assert_dir_exists "$benchmark_root/baselines"
  assert_jq '.schema_version == "artifact-lifecycle/v1"' "$benchmark_dir/artifact-lifecycle-manifest.json"
  assert_jq '.run_id != "" and .state == "active" and .disposition == "active-evidence"' "$benchmark_dir/artifact-lifecycle-manifest.json"
  assert_jq '.latest_pointer == "comparable-latest" and .safe_delete_class == "never"' "$benchmark_dir/artifact-lifecycle-manifest.json"
  assert_jq '.schema_version == "harness-benchmark/model-policy-linkage/v1"' "$benchmark_dir/model-policy-linkage.json"
  assert_jq ".source_policy_path == \".agent/registry/model_policy.json\" and .source_policy_sha256 == \"$source_policy_sha256\"" "$benchmark_dir/model-policy-linkage.json"
  assert_jq ".generated_policy_path == \".agent/generated/codex_model_policy.runtime.json\" and .generated_policy_sha256 == \"$generated_policy_sha256\"" "$benchmark_dir/model-policy-linkage.json"
  assert_jq ".generated_policy_source_policy_sha256 == \"$source_policy_sha256\"" "$benchmark_dir/model-policy-linkage.json"
  assert_jq '.generated_policy_schema_version == "codex-model-runtime-policy/v1" and .generated_policy_current_model != ""' "$benchmark_dir/model-policy-linkage.json"
  assert_jq '.schema_version == "artifact-lifecycle/latest-pointer/v1"' "$benchmark_root/latest.json"
  assert_file_contains "$TMP_ROOT/success.stdout" "ARTIFACT_ROOT=$benchmark_dir"
}

run_missing_input_case() {
  local missing_fixture="$TMP_ROOT/does-not-exist.txt"
  local task_id="contract-missing-$$"
  local slice_id="slice-missing"
  local benchmark_dir="$PROJECT_ROOT/.claude/tmp/benchmarks/$task_id/$slice_id"

  if bash "$PROJECT_ROOT/scripts/harness-benchmark.sh" \
    --task-id "$task_id" \
    --slice-id "$slice_id" \
    --fixture "$missing_fixture" \
    --baseline-command 'true' \
    --candidate-command 'true' \
    >"$TMP_ROOT/missing.stdout" \
    2>"$TMP_ROOT/missing.stderr"; then
    fail "missing fixture should fail"
  fi

  [[ ! -e "$benchmark_dir" ]] || fail "artifact directory should not be created for missing fixture"
  assert_file_contains "$TMP_ROOT/missing.stderr" "fixture does not exist"
}

run_missing_command_case() {
  local fixture_path="$TMP_ROOT/fixture-missing-command.txt"
  local task_id="contract-missing-command-$$"
  local slice_id="slice-missing-command"
  local benchmark_dir="$PROJECT_ROOT/.claude/tmp/benchmarks/$task_id/$slice_id"

  printf 'fixture\n' > "$fixture_path"

  if bash "$PROJECT_ROOT/scripts/harness-benchmark.sh" \
    --task-id "$task_id" \
    --slice-id "$slice_id" \
    --fixture "$fixture_path" \
    --candidate-command 'true' \
    >"$TMP_ROOT/missing-command.stdout" \
    2>"$TMP_ROOT/missing-command.stderr"; then
    fail "missing baseline command should fail"
  fi

  [[ ! -e "$benchmark_dir" ]] || fail "artifact directory should not be created when baseline command is missing"
  assert_file_contains "$TMP_ROOT/missing-command.stderr" "missing required argument: --baseline-command"
}

run_non_empty_artifact_root_case() {
  local fixture_path="$TMP_ROOT/fixture-existing-root.txt"
  local task_id="contract-existing-root-$$"
  local slice_id="slice-existing-root"
  local benchmark_dir="$PROJECT_ROOT/.claude/tmp/benchmarks/$task_id/$slice_id/runs/existing-run"
  local sentinel_file="$benchmark_dir/sentinel.txt"

  mkdir -p "$benchmark_dir"
  printf 'keep\n' > "$sentinel_file"
  printf 'fixture\n' > "$fixture_path"
  track_bench_task_root "$PROJECT_ROOT/.claude/tmp/benchmarks/$task_id"

  if HARNESS_BENCH_RUN_ID="existing-run" bash "$PROJECT_ROOT/scripts/harness-benchmark.sh" \
    --task-id "$task_id" \
    --slice-id "$slice_id" \
    --fixture "$fixture_path" \
    --baseline-command 'true' \
    --candidate-command 'true' \
    >"$TMP_ROOT/existing-root.stdout" \
    2>"$TMP_ROOT/existing-root.stderr"; then
    fail "non-empty artifact root should fail"
  fi

  assert_file_exists "$sentinel_file"
  assert_file_contains "$TMP_ROOT/existing-root.stderr" "artifact root already exists and is non-empty"
}

run_id_validation_case() {
  local fixture_path="$TMP_ROOT/fixture-invalid-id.txt"
  local task_id=""
  local slice_id="slice-valid"

  printf 'fixture\n' > "$fixture_path"

  for task_id in "." ".." "bad/id" "bad\\id"; do
    if bash "$PROJECT_ROOT/scripts/harness-benchmark.sh" \
      --task-id "$task_id" \
      --slice-id "$slice_id" \
      --fixture "$fixture_path" \
      --baseline-command 'true' \
      --candidate-command 'true' \
      >"$TMP_ROOT/invalid-id.stdout" \
      2>"$TMP_ROOT/invalid-id.stderr"; then
      fail "invalid task id should fail: $task_id"
    fi
    assert_file_contains "$TMP_ROOT/invalid-id.stderr" "invalid --task-id"
  done

  if HARNESS_BENCH_RUN_ID=".." bash "$PROJECT_ROOT/scripts/harness-benchmark.sh" \
    --task-id "contract-invalid-run-$$" \
    --slice-id "$slice_id" \
    --fixture "$fixture_path" \
    --baseline-command 'true' \
    --candidate-command 'true' \
    >"$TMP_ROOT/invalid-run-id.stdout" \
    2>"$TMP_ROOT/invalid-run-id.stderr"; then
    fail "invalid HARNESS_BENCH_RUN_ID should fail"
  fi
  assert_file_contains "$TMP_ROOT/invalid-run-id.stderr" "invalid HARNESS_BENCH_RUN_ID"
}

run_stale_latest_manifest_case() {
  local fixture_path="$TMP_ROOT/fixture-stale-latest.txt"
  local task_id="contract-stale-latest-$$"
  local slice_id="slice-stale-latest"
  local benchmark_root="$PROJECT_ROOT/.claude/tmp/benchmarks/$task_id/$slice_id"
  local first_manifest="$benchmark_root/runs/20200101T000000Z_111/artifact-lifecycle-manifest.json"
  local second_manifest="$benchmark_root/runs/20200101T000001Z_222/artifact-lifecycle-manifest.json"

  track_bench_task_root "$PROJECT_ROOT/.claude/tmp/benchmarks/$task_id"
  printf 'same fixture\n' > "$fixture_path"

  HARNESS_BENCH_RUN_ID="20200101T000000Z_111" bash "$PROJECT_ROOT/scripts/harness-benchmark.sh" \
    --task-id "$task_id" \
    --slice-id "$slice_id" \
    --fixture "$fixture_path" \
    --baseline-command 'true' \
    --candidate-command 'true' \
    --runs 1 >/dev/null

  HARNESS_BENCH_RUN_ID="20200101T000001Z_222" bash "$PROJECT_ROOT/scripts/harness-benchmark.sh" \
    --task-id "$task_id" \
    --slice-id "$slice_id" \
    --fixture "$fixture_path" \
    --baseline-command 'true' \
    --candidate-command 'true' \
    --runs 1 >/dev/null

  assert_file_exists "$first_manifest"
  assert_file_exists "$second_manifest"
  assert_jq '.state == "superseded" and .latest_pointer == "none" and .pinned_baseline == "none"' "$first_manifest"
  assert_jq '.superseded_by == "20200101T000001Z_222" and .run_disposable == "YES" and .safe_delete_class == "archived-managed-run"' "$first_manifest"
  assert_jq '.state == "active" and .latest_pointer == "comparable-latest" and .safe_delete_class == "never"' "$second_manifest"
}

run_symlinked_pointer_manifest_escape_case() {
  local fixture_path="$TMP_ROOT/fixture-symlink-escape.txt"
  local task_id="contract-symlink-escape-$$"
  local slice_id="slice-symlink-escape"
  local benchmark_root="$PROJECT_ROOT/.claude/tmp/benchmarks/$task_id/$slice_id"
  local attack_root="$TMP_ROOT/attacker-manifest-root"
  local pointer_path="$benchmark_root/latest.json"
  local before_state=""
  local after_state=""

  track_bench_task_root "$PROJECT_ROOT/.claude/tmp/benchmarks/$task_id"
  printf 'fixture\n' > "$fixture_path"
  mkdir -p "$benchmark_root/runs" "$attack_root"
  ln -s "$attack_root" "$benchmark_root/runs/evil-run"
  jq -n \
    --arg schema_version "artifact-lifecycle/v1" \
    --arg state "active" \
    --arg latest_pointer "comparable-latest" \
    --arg pinned_baseline "none" \
    --arg run_disposable "NO" \
    --arg safe_delete_class "never" \
    '{schema_version: $schema_version, state: $state, latest_pointer: $latest_pointer, pinned_baseline: $pinned_baseline, run_disposable: $run_disposable, safe_delete_class: $safe_delete_class}' \
    > "$attack_root/artifact-lifecycle-manifest.json"
  before_state="$(jq -c '{state, latest_pointer, pinned_baseline, run_disposable, safe_delete_class}' "$attack_root/artifact-lifecycle-manifest.json")"
  jq -n \
    --arg schema_version "artifact-lifecycle/latest-pointer/v1" \
    --arg manifest_path "${benchmark_root#"$PROJECT_ROOT"/}/runs/evil-run/artifact-lifecycle-manifest.json" \
    '{schema_version: $schema_version, manifest_path: $manifest_path}' \
    > "$pointer_path"

  if HARNESS_BENCH_RUN_ID="20200101T000002Z_333" bash "$PROJECT_ROOT/scripts/harness-benchmark.sh" \
    --task-id "$task_id" \
    --slice-id "$slice_id" \
    --fixture "$fixture_path" \
    --baseline-command 'true' \
    --candidate-command 'true' \
    --runs 1 \
    >"$TMP_ROOT/symlink-escape.stdout" \
    2>"$TMP_ROOT/symlink-escape.stderr"; then
    fail "symlinked latest pointer should fail closed"
  fi

  assert_file_contains "$TMP_ROOT/symlink-escape.stderr" "invalid lifecycle pointer manifest path"
  after_state="$(jq -c '{state, latest_pointer, pinned_baseline, run_disposable, safe_delete_class}' "$attack_root/artifact-lifecycle-manifest.json")"
  [[ "$after_state" == "$before_state" ]] || fail "external symlink target manifest should not be mutated"
}

main() {
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/harness-benchmark-contract.XXXXXX")"

  run_success_case
  run_missing_input_case
  run_missing_command_case
  run_non_empty_artifact_root_case
  run_id_validation_case
  run_stale_latest_manifest_case
  run_symlinked_pointer_manifest_escape_case

  printf 'PASS: harness_benchmark_contract_test\n'
}

main "$@"
