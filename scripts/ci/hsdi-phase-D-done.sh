#!/usr/bin/env bash
# HSDI Phase D aggregate acceptance CI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
METRICS_FILE="${REPO_ROOT}/.agent/metrics/phase_D_done.jsonl"
VERBOSE=0
TMP_LOGS=()

export REVHARNESS_PARALLEL_QUIESCE=1

if [[ "${1:-}" == "--verbose" ]]; then
  VERBOSE=1
  shift
fi
if [[ "$#" -ne 0 ]]; then
  echo "usage: $0 [--verbose]" >&2
  exit 2
fi

cd "${REPO_ROOT}" || exit 2
mkdir -p "$(dirname "${METRICS_FILE}")"

cleanup() {
  local log_file=""
  for log_file in "${TMP_LOGS[@]}"; do
    rm -f "$log_file" || true
  done
}
trap cleanup EXIT

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

iso_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

emit_step_metric() {
  local step="$1"
  local exit_code="$2"
  local passed="$3"
  printf '{"event":"phase_D_done_step","step":"%s","exit_code":%d,"passed":%s,"ts":"%s"}\n' \
    "$(json_escape "$step")" \
    "$exit_code" \
    "$passed" \
    "$(iso_utc)" >> "${METRICS_FILE}"
}

emit_summary_metric() {
  local passed="$1"
  local failed="$2"
  local exit_code="$3"
  printf '{"event":"phase_D_done","passed":%d,"failed":%d,"exit_code":%d,"ts":"%s"}\n' \
    "$passed" "$failed" "$exit_code" "$(iso_utc)" >> "${METRICS_FILE}"
}

run_step_1() {
  bash -n .claude/hooks/path-leak-advise.sh || return $?
  bash .claude/hooks/path-leak-advise.sh --self-test
}

run_step_2() {
  python3 -c "import json; json.load(open('.claude/settings.json'))" || return $?
  jq -r '.hooks.PostToolUse[].hooks[].command' .claude/settings.json | grep -q 'path-leak-advise.sh' || return $?
  bash test/unit/test-settings-path-leak-wire.sh
}

run_step_3() {
  grep -q 'tail -f' docs/roles/coder.md || return $?
  grep -q 'wip:' docs/roles/reviewer.md || return $?
  grep -q 'PARALLEL_QUIESCE' docs/roles/orchestrator.md
}

run_step_4() {
  test -s test/golden/path-leak/patterns.md || return $?
  test -s test/golden/path-leak/positive.txt || return $?
  test -s test/golden/path-leak/negative.txt
}

run_step_5() {
  bash test/unit/test-path-leak-advise.sh
}

run_step_6() {
  bash .claude/hooks/agent-graceful-shutdown.sh --self-test
}

run_step_7() {
  bash scripts/ci/hsdi-phase-B-done.sh
}

run_step_8() {
  bash scripts/ci/hsdi-phase-C-done.sh
}

run_step() {
  local index="$1"
  local total="$2"
  local step_id="$3"
  local name="$4"
  local rc=0
  local log_file=""

  printf '[step %s/%s] %s ... ' "$index" "$total" "$name"
  set +e
  if [[ "${VERBOSE}" -eq 1 ]]; then
    "run_step_${index}"
    rc=$?
  else
    log_file="$(mktemp "${TMPDIR:-/tmp}/phase-D-${step_id}.XXXXXX")"
    TMP_LOGS+=("$log_file")
    "run_step_${index}" >"$log_file" 2>&1
    rc=$?
  fi
  set -e

  if [[ "$rc" -eq 0 ]]; then
    printf 'PASS\n'
    emit_step_metric "$step_id" "$rc" "true"
  else
    printf 'FAIL (exit %d)\n' "$rc"
    printf 'failing step: %s\n' "$step_id" >&2
    if [[ "${VERBOSE}" -ne 1 && -n "$log_file" ]]; then
      printf 'captured output for %s:\n' "$step_id" >&2
      cat "$log_file" >&2
    fi
    emit_step_metric "$step_id" "$rc" "false"
  fi
  return "$rc"
}

passed_count=0
failed_count=0
failing_steps=()

step_ids=("T-D-1a" "T-D-1b" "T-D-2" "T-D-3" "T-D-4" "phase-A-self-test" "phase-B" "phase-C")
step_names=("path-leak-advise-self-test" "settings-path-leak-wire" "docs-role-updates" "golden-path-leak-corpus" "path-leak-advise-unit" "graceful-shutdown-self-test" "phase-B-continuity" "phase-C-continuity")
total_steps="${#step_ids[@]}"

for idx in 1 2 3 4 5 6 7 8; do
  pos=$(( idx - 1 ))
  step_id="${step_ids[$pos]}"
  step_name="${step_names[$pos]}"
  if run_step "$idx" "$total_steps" "$step_id" "$step_name"; then
    passed_count=$(( passed_count + 1 ))
  else
    failed_count=$(( failed_count + 1 ))
    failing_steps+=("$step_id")
  fi
done

final_rc=0
if [[ "$failed_count" -gt 0 ]]; then
  final_rc=1
  printf 'failing steps: %s\n' "${failing_steps[*]}" >&2
fi

emit_summary_metric "$passed_count" "$failed_count" "$final_rc"
exit "$final_rc"
