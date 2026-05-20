#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/codex-wrapper.sh"
COLLECTOR="$REPO_ROOT/scripts/collect-delegation-metrics.sh"
DELTA="$REPO_ROOT/scripts/compute-completion-delta.sh"
FAKE_CODEX_DIR="$REPO_ROOT/test/fixtures/fake-codex"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-delegation-metrics.XXXXXX")"
PASS=0
FAIL=0

trap '/bin/rm -rf "$TMP_ROOT"' EXIT

pass() {
  printf 'PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name (expected=$expected actual=$actual)"
  fi
}

assert_jq() {
  local name="$1"
  local file="$2"
  local expr="$3"
  if jq -e "$expr" "$file" >/dev/null 2>&1; then
    pass "$name"
  else
    fail "$name"
    jq -c . "$file" >&2 2>/dev/null || true
  fi
}

run_wrapper_capture() {
  local name="$1"
  shift
  local stdout="$TMP_ROOT/$name.stdout"
  local stderr="$TMP_ROOT/$name.stderr"
  local rc_file="$TMP_ROOT/$name.rc"

  unset OPENAI_API_KEY CODEX_API_KEY
  PATH="$FAKE_CODEX_DIR:$PATH" "$@" >"$stdout" 2>"$stderr"
  printf '%s\n' "$?" > "$rc_file"
}

metric_payload_file() {
  local stderr_file="$1"
  local output_file="$2"
  sed -n 's/^REV_HARNESS_DELEGATION_METRIC //p' "$stderr_file" > "$output_file"
}

assert_single_metric() {
  local name="$1"
  local stderr_file="$2"
  local count=""
  count="$(grep -c '^REV_HARNESS_DELEGATION_METRIC ' "$stderr_file" || true)"
  assert_eq "$name metric count" "1" "$count"
}

assert_no_metric() {
  local name="$1"
  local stderr_file="$2"
  local count=""
  count="$(grep -c '^REV_HARNESS_DELEGATION_METRIC ' "$stderr_file" || true)"
  assert_eq "$name metric suppressed" "0" "$count"
}

run_wrapper_capture success "$WRAPPER" --role coder --stdin < /dev/null
success_stderr="$TMP_ROOT/success.stderr"
success_json="$TMP_ROOT/success.metric.json"
metric_payload_file "$success_stderr" "$success_json"
assert_single_metric "success" "$success_stderr"
assert_jq "success metric JSON parses" "$success_json" '.schema_version == 1'
assert_jq "success delegation_id UUID-shaped" "$success_json" '.delegation_id | test("^[0-9a-fA-F-]{36}$")'
assert_jq "success tokens integer" "$success_json" '(.tokens_in | type == "number") and (.tokens_out | type == "number") and (.total_tokens | type == "number")'
assert_jq "success duration positive" "$success_json" '(.duration_ms | type == "number") and (.duration_ms >= 1)'
assert_jq "success exit code matches" "$success_json" '.exit_code == 0'
assert_jq "success no specialty" "$success_json" '.specialty == null and .canonical_role == null and .manifest_hash == null and .specialty_status == "none"'

FAKE_CODEX_NO_TOKENS=1 run_wrapper_capture no_tokens "$WRAPPER" --role coder --stdin < /dev/null
no_tokens_stderr="$TMP_ROOT/no_tokens.stderr"
no_tokens_json="$TMP_ROOT/no_tokens.metric.json"
metric_payload_file "$no_tokens_stderr" "$no_tokens_json"
assert_single_metric "no token run" "$no_tokens_stderr"
assert_jq "tokens null when absent" "$no_tokens_json" '.tokens_in == null and .tokens_out == null and .total_tokens == null'

FAKE_CODEX_EXIT_CODE=7 run_wrapper_capture exit_7 "$WRAPPER" --role coder --stdin < /dev/null
exit_7_stderr="$TMP_ROOT/exit_7.stderr"
exit_7_json="$TMP_ROOT/exit_7.metric.json"
exit_7_rc="$(cat "$TMP_ROOT/exit_7.rc")"
metric_payload_file "$exit_7_stderr" "$exit_7_json"
assert_single_metric "nonzero run" "$exit_7_stderr"
assert_eq "wrapper returned fake codex exit" "7" "$exit_7_rc"
assert_jq "nonzero metric exit code matches" "$exit_7_json" '.exit_code == 7'

run_wrapper_capture specialty "$WRAPPER" --role coder --specialty refactor-safety-analyst --stdin < /dev/null
specialty_stderr="$TMP_ROOT/specialty.stderr"
specialty_json="$TMP_ROOT/specialty.metric.json"
metric_payload_file "$specialty_stderr" "$specialty_json"
assert_single_metric "specialty run" "$specialty_stderr"
assert_jq "specialty fields populated" "$specialty_json" '.specialty == "refactor-safety-analyst" and .canonical_role == "coder" and (.manifest_hash | type == "string" and length > 0) and .specialty_status == "validated"'

run_wrapper_capture invalid_specialty "$WRAPPER" --role coder --specialty FOO_BAR --dry-run
invalid_stderr="$TMP_ROOT/invalid_specialty.stderr"
invalid_json="$TMP_ROOT/invalid_specialty.metric.json"
invalid_rc="$(cat "$TMP_ROOT/invalid_specialty.rc")"
metric_payload_file "$invalid_stderr" "$invalid_json"
assert_single_metric "invalid specialty" "$invalid_stderr"
assert_eq "invalid specialty exits one" "1" "$invalid_rc"
assert_jq "invalid specialty fail-closed" "$invalid_json" '.specialty == null and .specialty_status == "fail-closed" and .exit_code == 1'

run_wrapper_capture dry_run "$WRAPPER" --role coder --dry-run
dry_run_stderr="$TMP_ROOT/dry_run.stderr"
dry_run_json="$TMP_ROOT/dry_run.metric.json"
metric_payload_file "$dry_run_stderr" "$dry_run_json"
assert_single_metric "dry-run" "$dry_run_stderr"
assert_jq "dry-run metric" "$dry_run_json" '.dry_run == true and .exit_code == 0 and .tokens_in == null'

REV_HARNESS_METRICS_DISABLE=1 run_wrapper_capture disabled "$WRAPPER" --role coder --stdin < /dev/null
assert_no_metric "disabled" "$TMP_ROOT/disabled.stderr"

collection="$TMP_ROOT/collection.json"
"$COLLECTOR" \
  --session-id unit-session \
  --inputs "$success_stderr" "$no_tokens_stderr" "$dry_run_stderr" \
  --output "$collection"
assert_jq "collector sample count" "$collection" '.sample_count == 3'
assert_jq "collector median skips nulls" "$collection" '.aggregates.median.tokens_in == 1234'
assert_jq "collector duration aggregate present" "$collection" '.aggregates.median.duration_ms != null and .aggregates.p75.duration_ms != null and .aggregates.total.duration_ms != null'

delta="$TMP_ROOT/delta.json"
"$DELTA" --baseline "$collection" --post "$collection" --output "$delta"
assert_jq "delta baseline ratio" "$delta" '.deltas.tokens_in_median_ratio == 1'

printf '%s\n' '---'
printf 'Result: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
