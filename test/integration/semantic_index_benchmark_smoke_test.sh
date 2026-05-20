#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TASK_ID="task-20260424-semantic-index-control-plane-hardening"
SLICE_ID="slice-e-semantic-index-benchmark-smoke"
FIXTURE_PATH="test/fixtures/semantic_index_benchmark_smoke"
MANAGED_ROOT="$PROJECT_ROOT/.claude/tmp/benchmarks/$TASK_ID/$SLICE_ID"
BASELINE_COMMAND='node scripts/semantic-mcp-server/scripts/benchmark-query-runner.mjs --fixture "$HARNESS_BENCH_FIXTURE" --mode partial'
CANDIDATE_COMMAND='node scripts/semantic-mcp-server/scripts/benchmark-query-runner.mjs --fixture "$HARNESS_BENCH_FIXTURE" --mode exact'

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || fail "missing expected text in $file: $needle"
}

benchmark_output=""
ARTIFACT_ROOT=""

benchmark_output="$(
  cd "$PROJECT_ROOT"
  bash scripts/harness-benchmark.sh \
    --task-id "$TASK_ID" \
    --slice-id "$SLICE_ID" \
    --fixture "$FIXTURE_PATH" \
    --baseline-command "$BASELINE_COMMAND" \
    --candidate-command "$CANDIDATE_COMMAND" \
    --runs 3
)"
printf '%s\n' "$benchmark_output"

ARTIFACT_ROOT="$(printf '%s\n' "$benchmark_output" | awk -F= '$1 == "ARTIFACT_ROOT" { print $2; exit }')"
[[ -n "$ARTIFACT_ROOT" ]] || fail "missing ARTIFACT_ROOT in harness-benchmark output"

[[ -d "$ARTIFACT_ROOT" ]] || fail "missing artifact root: $ARTIFACT_ROOT"
[[ "$ARTIFACT_ROOT" == "$MANAGED_ROOT"/runs/* ]] || fail "artifact root is outside managed run root: $ARTIFACT_ROOT"
[[ -f "$ARTIFACT_ROOT/summary.tsv" ]] || fail "missing summary.tsv"
[[ -f "$ARTIFACT_ROOT/fixture.sha256" ]] || fail "missing fixture.sha256"
[[ -f "$ARTIFACT_ROOT/baseline_command.txt" ]] || fail "missing baseline command artifact"
[[ -f "$ARTIFACT_ROOT/candidate_command.txt" ]] || fail "missing candidate command artifact"
[[ -f "$ARTIFACT_ROOT/artifact-lifecycle-manifest.json" ]] || fail "missing artifact lifecycle manifest"
[[ -f "$MANAGED_ROOT/latest.json" ]] || fail "missing latest pointer"
assert_file_contains "$ARTIFACT_ROOT/baseline_command.txt" "$BASELINE_COMMAND"
assert_file_contains "$ARTIFACT_ROOT/candidate_command.txt" "$CANDIDATE_COMMAND"
assert_file_contains "$ARTIFACT_ROOT/env.txt" "fixture=dir:$PROJECT_ROOT/$FIXTURE_PATH"
assert_file_contains "$ARTIFACT_ROOT/env.txt" "runs=3"

(
  cd "$PROJECT_ROOT"
  HARNESS_BENCH_COMPARE_FIXTURE="$FIXTURE_PATH" \
    HARNESS_BENCH_COMPARE_OUT="$ARTIFACT_ROOT/query_path_comparison.json" \
    bash -lc 'node scripts/semantic-mcp-server/scripts/benchmark-query-runner.mjs --fixture "$HARNESS_BENCH_COMPARE_FIXTURE" --mode compare > "$HARNESS_BENCH_COMPARE_OUT"'
)

node -e '
  const fs = require("node:fs");
  const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (payload.mode !== "compare") throw new Error("missing compare mode");
  if (payload.same_dataset !== true) throw new Error("same dataset proof missing");
  if (payload.dataset_cardinality !== 3) throw new Error("unexpected dataset cardinality");
  if (payload.result_cardinality_match !== true) throw new Error("query cardinality mismatch");
  if (payload.partial.total !== 1 || payload.exact.total !== 1) throw new Error("unexpected query totals");
' "$ARTIFACT_ROOT/query_path_comparison.json"

printf 'PASS: semantic_index_benchmark_smoke_test\n'
