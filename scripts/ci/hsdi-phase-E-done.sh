#!/usr/bin/env bash
# HSDI Phase E aggregate acceptance CI.
# Invariant 1: execute from the repository root discovered from this script.
# Invariant 2: keep all checks deterministic and local-only.
# Invariant 3: emit one Phase E JSONL metric per executed step.
# Invariant 4: stop on the first failed step and report the failing step.
# Invariant 5: avoid user-specific absolute paths in script logic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
METRICS_FILE="${REPO_ROOT}/.agent/metrics/phase_E_done.jsonl"
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

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

emit_step_metric() {
  local step="$1"
  local name="$2"
  local exit_code="$3"
  local duration_ms="$4"
  printf '{"ts":"%s","phase":"E","step":"%s","name":"%s","exit":%d,"duration_ms":%d}\n' \
    "$(iso_utc)" \
    "$(json_escape "$step")" \
    "$(json_escape "$name")" \
    "$exit_code" \
    "$duration_ms" >> "${METRICS_FILE}"
}

emit_success_summary_metric() {
  printf '{"phase":"E","summary":"done","total_steps":8,"failed":0}\n' >> "${METRICS_FILE}"
}

run_step_1() {
  grep -q 'verdict markdown' docs/roles/reviewer.md || return $?
  grep -q 'text-only return' docs/roles/reviewer.md
}

run_step_2() {
  bash -n scripts/dual-lgtm-validate.sh || return $?
  bash scripts/dual-lgtm-validate.sh --self-test || return $?
  bash test/unit/test-dual-lgtm-validate.sh
}

run_step_3() {
  bash -n scripts/state-transition-guard.sh || return $?
  bash scripts/state-transition-guard.sh --self-test || return $?
  bash test/unit/test-state-transition-guard.sh
}

run_step_4() {
  bash test/unit/test-dual-lgtm-gap-emit.sh
}

run_step_5() {
  bash .claude/hooks/agent-graceful-shutdown.sh --self-test
}

run_step_6() {
  bash scripts/ci/hsdi-phase-B-done.sh
}

run_step_7() {
  bash scripts/ci/hsdi-phase-C-done.sh
}

run_step_8() {
  bash scripts/ci/hsdi-phase-D-done.sh
}

run_step() {
  local index="$1"
  local total="$2"
  local name="$3"
  local rc=0
  local start_ms=0
  local end_ms=0
  local duration_ms=0
  local log_file=""

  printf '[step %s/%s] %s ... ' "$index" "$total" "$name"
  start_ms="$(now_ms)"
  set +e
  if [[ "${VERBOSE}" -eq 1 ]]; then
    "run_step_${index}"
    rc=$?
  else
    log_file="$(mktemp "${TMPDIR:-/tmp}/phase-E-step-${index}.XXXXXX")"
    TMP_LOGS+=("$log_file")
    "run_step_${index}" >"$log_file" 2>&1
    rc=$?
  fi
  set -e
  end_ms="$(now_ms)"
  duration_ms=$(( end_ms - start_ms ))

  if [[ "$rc" -eq 0 ]]; then
    printf 'PASS\n'
    emit_step_metric "$index" "$name" "$rc" "$duration_ms"
  else
    printf 'FAIL (exit %d)\n' "$rc"
    printf 'failing step %s: %s\n' "$index" "$name" >&2
    if [[ "${VERBOSE}" -ne 1 && -n "$log_file" ]]; then
      printf 'captured output for step %s (%s):\n' "$index" "$name" >&2
      cat "$log_file" >&2
    fi
    emit_step_metric "$index" "$name" "$rc" "$duration_ms"
  fi
  return "$rc"
}

step_names=(
  "T-E-1pre acceptance"
  "T-E-1 acceptance"
  "T-E-3 acceptance"
  "T-E-4 acceptance"
  "Phase A continuity"
  "Phase B continuity"
  "Phase C continuity"
  "Phase D continuity"
)
total_steps="${#step_names[@]}"

for idx in 1 2 3 4 5 6 7 8; do
  pos=$(( idx - 1 ))
  step_name="${step_names[$pos]}"
  if ! run_step "$idx" "$total_steps" "$step_name"; then
    exit 1
  fi
done

emit_success_summary_metric
exit 0
