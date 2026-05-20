#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_ROOT=""
TASK_ROOT=""

cleanup() {
  /bin/rm -rf "${TMP_ROOT:-}" "${TASK_ROOT:-}" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "missing file: $path"
}

assert_jq() {
  local filter="$1"
  local file="$2"
  jq -e "$filter" "$file" >/dev/null || fail "jq assertion failed for $file: $filter"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/harness-runtime-baseline-test.XXXXXX")"
TASK_ID="runtime-baseline-contract-$$"
SLICE_ID="slice-contract"
TASK_ROOT="$PROJECT_ROOT/.claude/tmp/runtime-baselines/$TASK_ID"

output="$(
  cd "$PROJECT_ROOT"
  HARNESS_RUNTIME_BASELINE_RUN_ID="20260503T000000Z_test" \
    bash scripts/harness-runtime-baseline.sh \
      --task-id "$TASK_ID" \
      --slice-id "$SLICE_ID" \
      --count-cargo \
      --step 'orchestration_probe|printf "orchestration\n" >/dev/null' \
      --step 'semantic_probe|printf "semantic\n" >/dev/null' \
      --step 'background_probe|sleep 5 &' \
      --step 'index_cargo_probe|cargo --version >/dev/null 2>&1 || true'
)"
printf '%s\n' "$output"

artifact_root="$(printf '%s\n' "$output" | awk -F= '$1 == "ARTIFACT_ROOT" { print $2; exit }')"
baseline_json="$(printf '%s\n' "$output" | awk -F= '$1 == "BASELINE_JSON" { print $2; exit }')"

[[ -n "$artifact_root" ]] || fail "missing ARTIFACT_ROOT"
[[ -n "$baseline_json" ]] || fail "missing BASELINE_JSON"
assert_file "$artifact_root/summary.tsv"
assert_file "$artifact_root/env.txt"
assert_file "$artifact_root/artifact-lifecycle-manifest.json"
assert_file "$baseline_json"
assert_file "$TASK_ROOT/$SLICE_ID/latest.json"

header="$(sed -n '1p' "$artifact_root/summary.tsv")"
[[ "$header" == $'slug\tstatus\twall_ms\tpeak_rss_kb\tcpu_ms\tmax_process_count\tcargo_invocations' ]] \
  || fail "unexpected summary header: $header"
[[ "$(wc -l < "$artifact_root/summary.tsv" | tr -d '[:space:]')" == "5" ]] \
  || fail "expected four measured rows plus header"

assert_jq '.schema_version == "harness-runtime-baseline/v1"' "$baseline_json"
assert_jq '.status == "PASS" and .step_count == 4' "$baseline_json"
assert_jq '(.total_wall_ms | type == "number") and (.total_cpu_ms | type == "number")' "$baseline_json"
assert_jq '(.peak_rss_kb_max | type == "number") and (.max_process_count_max | type == "number")' "$baseline_json"
assert_jq '.cargo_invocations_total >= 1' "$baseline_json"
assert_jq '.steps[] | select(.slug == "index_cargo_probe" and .cargo_invocations >= 1)' "$baseline_json"
assert_file "$artifact_root/background_probe/residual_process_count.txt"
assert_file "$artifact_root/background_probe/residual_cleanup_attempted.txt"
assert_file "$artifact_root/background_probe/residual_term_signal_status.txt"
background_residual_count="$(sed -n '1p' "$artifact_root/background_probe/residual_process_count.txt")"
[[ "$background_residual_count" =~ ^[0-9]+$ ]] \
  || fail "expected numeric background probe residual process evidence"
[[ "$(sed -n '1p' "$artifact_root/background_probe/residual_cleanup_attempted.txt")" == "YES" ]] \
  || fail "expected background probe residual cleanup attempt evidence"
[[ "$(sed -n '1p' "$artifact_root/background_probe/residual_term_signal_status.txt")" == "0" ]] \
  || fail "expected background probe residual TERM signal evidence"
assert_jq '.schema_version == "artifact-lifecycle/v1" and .safe_delete_class == "never"' "$artifact_root/artifact-lifecycle-manifest.json"
assert_jq '.schema_version == "artifact-lifecycle/latest-pointer/v1"' "$TASK_ROOT/$SLICE_ID/latest.json"

hidden_ps_bin="$TMP_ROOT/hidden-ps-bin"
mkdir -p "$hidden_ps_bin"
cat > "$hidden_ps_bin/ps" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$hidden_ps_bin/ps"

hidden_output="$(
  cd "$PROJECT_ROOT"
  PATH="$hidden_ps_bin:$PATH" \
  HARNESS_RUNTIME_BASELINE_RUN_ID="20260503T000001Z_hidden_ps_test" \
    bash scripts/harness-runtime-baseline.sh \
      --task-id "$TASK_ID" \
      --slice-id "$SLICE_ID" \
      --step 'hidden_ps_background_probe|sleep 5 &'
)"
printf '%s\n' "$hidden_output"
hidden_artifact_root="$(printf '%s\n' "$hidden_output" | awk -F= '$1 == "ARTIFACT_ROOT" { print $2; exit }')"
[[ -n "$hidden_artifact_root" ]] || fail "missing hidden ARTIFACT_ROOT"
assert_file "$hidden_artifact_root/hidden_ps_background_probe/residual_process_count.txt"
assert_file "$hidden_artifact_root/hidden_ps_background_probe/residual_term_signal_status.txt"
[[ "$(sed -n '1p' "$hidden_artifact_root/hidden_ps_background_probe/residual_process_count.txt")" == "0" ]] \
  || fail "expected hidden ps residual count to be zero"
[[ "$(sed -n '1p' "$hidden_artifact_root/hidden_ps_background_probe/residual_term_signal_status.txt")" == "0" ]] \
  || fail "expected hidden ps TERM signal to still be attempted successfully"

printf 'PASS: harness_runtime_baseline_test\n'
