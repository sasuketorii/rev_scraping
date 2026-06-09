#!/usr/bin/env bash
# HSDI Phase B aggregate acceptance CI.

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
METRICS_FILE="${REPO_ROOT}/.agent/metrics/phase_B_done.jsonl"
VERBOSE=0

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
export REVHARNESS_PARALLEL_QUIESCE="${REVHARNESS_PARALLEL_QUIESCE:-1}"

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
  local name="$2"
  local exit_code="$3"
  local passed="$4"
  printf '{"event":"phase_B_done_step","step":"%s","name":"%s","exit_code":%d,"passed":%s,"ts":"%s"}\n' \
    "$(json_escape "$step")" \
    "$(json_escape "$name")" \
    "$exit_code" \
    "$passed" \
    "$(iso_utc)" >> "${METRICS_FILE}"
}

emit_summary_metric() {
  local passed="$1"
  local failed="$2"
  local exit_code="$3"
  printf '{"event":"phase_B_done","passed":%d,"failed":%d,"exit_code":%d,"ts":"%s"}\n' \
    "$passed" "$failed" "$exit_code" "$(iso_utc)" >> "${METRICS_FILE}"
}

run_substep() {
  if [[ "${VERBOSE}" -eq 1 ]]; then
    "$@"
  else
    "$@" >/dev/null 2>&1
  fi
}

run_step_1() {
  run_substep bash test/unit/test-hook-quiesce-gate.sh
}

run_step_2() {
  run_substep bash -n scripts/ci/check-execplan-topology.sh || return $?
  run_substep bash test/unit/test-execplan-topology.sh
}

run_step_3() {
  run_substep bash -n scripts/safe-dispatch.sh || return $?
  run_substep bash test/unit/test-safe-dispatch.sh
}

run_step_4() {
  run_substep bash -n .claude/hooks/snapshot-pre.sh .claude/hooks/snapshot-post.sh .claude/hooks/snapshot-stop.sh scripts/snapshot-dispatch.sh || return $?
  run_substep bash test/unit/test-snapshot-hooks.sh
}

run_step_5() {
  run_substep python3 -c "import json; json.load(open('.claude/settings.json'))" || return $?
  run_substep bash -n scripts/rev-harness-janitor.sh || return $?
  run_substep bash test/unit/test-janitor-quiesce.sh || return $?
  (
    export REVHARNESS_PARALLEL_QUIESCE=0
    run_substep bash test/unit/test-janitor-bail-gc.sh
  )
}

run_step_6() {
  export REVHARNESS_PARALLEL_QUIESCE=1
  run_substep bash .claude/hooks/agent-graceful-shutdown.sh --self-test || return $?
  run_substep bash test/unit/test-graceful-shutdown-self-test.sh || return $?
  run_substep bash test/unit/test-harness-bg-spawn.sh || return $?
  run_substep bash scripts/ci/check-metric-schemas.sh || return $?
  run_substep grep -q 'wip:' docs/roles/reviewer.md
}

run_step() {
  local index="$1"
  local step_id="$2"
  local name="$3"
  local rc=0

  printf '[step %s/6] %s ... ' "$index" "$name"
  "run_step_${index}"
  rc=$?

  if [[ "$rc" -eq 0 ]]; then
    printf 'PASS\n'
    emit_step_metric "$step_id" "$name" "$rc" "true"
  else
    printf 'FAIL (exit %d)\n' "$rc"
    emit_step_metric "$step_id" "$name" "$rc" "false"
  fi
  return "$rc"
}

passed_count=0
failed_count=0
failing_steps=()

step_ids=("T-B-1" "T-B-2" "T-B-3" "T-B-4" "T-B-5" "phase-A")
step_names=("hook-quiesce" "execplan-topology" "safe-dispatch" "snapshot-hooks" "janitor-quiesce" "phase-A-continuity")

for idx in 1 2 3 4 5 6; do
  pos=$(( idx - 1 ))
  step_id="${step_ids[$pos]}"
  step_name="${step_names[$pos]}"
  run_step "$idx" "$step_id" "$step_name"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
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
