#!/usr/bin/env bash
# HSDI Phase H aggregate acceptance CI.
#
# Step 8 statically checks that scripts/state-transition-guard.sh keeps the
# I-12 smoke_evidence_sha256 requirement on validate_joint_transition and the
# --require-lgtm-final operator path.

set -euo pipefail

# Concurrent execution guard (T-H-7 reflection: prevents double-runs racing on state files)
LOCK_FILE=".agent/state/hsdi-phase-H-done.lock"
LOCK_DIR=""
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
release_lock() {
  if [[ -n "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap release_lock EXIT
if command -v flock >/dev/null 2>&1; then
  if ! flock -n 9; then
    echo "ERROR: another hsdi-phase-H-done.sh is running (lock: $LOCK_FILE)" >&2
    exit 2
  fi
else
  LOCK_DIR="${LOCK_FILE}.d"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "ERROR: another hsdi-phase-H-done.sh is running (lock: $LOCK_FILE)" >&2
    exit 2
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
METRICS_FILE="$REPO_ROOT/.agent/metrics/phase_H_done.jsonl"
VERBOSE=0
TMP_LOGS=()
STEP_EXIT_CODES=()
FAILED_STEPS=()

export LC_ALL=C
export REVHARNESS_PARALLEL_QUIESCE="${REVHARNESS_PARALLEL_QUIESCE:-1}"

if [[ "${1:-}" == "--verbose" ]]; then
  VERBOSE=1
  shift
fi
if [[ "$#" -ne 0 ]]; then
  echo "usage: $0 [--verbose]" >&2
  exit 2
fi

cd "$REPO_ROOT" || exit 2
mkdir -p "$(dirname "$METRICS_FILE")"

cleanup() {
  local log_file
  for log_file in "${TMP_LOGS[@]:-}"; do
    rm -f "$log_file" || true
  done
  release_lock
}
trap cleanup EXIT

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

iso_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

emit_step_metric() {
  local step="$1" exit_code="$2" passed="$3" duration_ms="$4"
  printf '{"event":"phase_H_done_step","schema":"phase-H-done/v1","step":"%s","exit_code":%d,"passed":%s,"duration_ms":%d,"ts":"%s"}\n' \
    "$(json_escape "$step")" "$exit_code" "$passed" "$duration_ms" "$(iso_utc)" >>"$METRICS_FILE"
}

emit_summary_metric() {
  local passed="$1" failed="$2" exit_code="$3"
  printf '{"event":"phase_H_done","schema":"phase-H-done/v1","passed":%d,"failed":%d,"exit_code":%d,"ts":"%s"}\n' \
    "$passed" "$failed" "$exit_code" "$(iso_utc)" >>"$METRICS_FILE"
}

run_step_1() { bash test/integration/test-target-root-resolution.sh; }
run_step_2() { bash test/unit/test-state-json-canonical.sh && bash test/unit/test-paths-manifest.sh; }
run_step_3() {
  bash -n scripts/rev-harness || return $?
  ! grep -q 'export REVHARNESS_PARALLEL_QUIESCE=1' scripts/rev-harness || return $?
  (unset REVHARNESS_PARALLEL_QUIESCE && bash test/integration/test-rev-harness-cli.sh)
}
run_step_4() { bash scripts/ci/release-binary-privacy-scan.sh && bash test/unit/test-release-binary-privacy.sh; }
run_step_5() { bash test/unit/test-semantic-mcp-help.sh && bash test/integration/test-mcp-wire-opt-in.sh; }
run_step_6() { bash test/unit/test-phase-done-smoke.sh; }
run_step_7() { bash scripts/ci/phase-done-smoke.sh --phase H; }
run_step_8() {
  local guard="scripts/state-transition-guard.sh" block
  block="$(awk '/^validate_joint_transition\(\)/,/^}/ { print }' "$guard")" || return $?
  [[ -n "$block" ]] || return 1
  grep -q 'smoke_evidence_sha256' <<<"$block" || return 1
  grep -q 'smoke_sha_is_sourced' <<<"$block" || return 1
  grep -q -- '--require-lgtm-final' "$guard" || return 1
}
run_step_9() { bash .claude/hooks/agent-graceful-shutdown.sh --self-test; }
run_step_10() { bash scripts/ci/hsdi-phase-B-done.sh; }
run_step_11() { bash scripts/ci/hsdi-phase-C-done.sh; }
run_step_12() { bash scripts/ci/hsdi-phase-D-done.sh; }
run_step_13() { bash scripts/ci/hsdi-phase-E-done.sh; }
run_step_14() { bash scripts/ci/hsdi-phase-F-done.sh; }
run_step_15() { bash scripts/ci/hsdi-phase-G-done.sh; }
run_step_16() { bash test/integration/pre_commit_hook_guards_fire_test.sh; }

run_step() {
  local index="$1" total="$2" name="$3" start_ms end_ms duration_ms log_file="" rc=0
  printf '[step %s/%s] %s ... ' "$index" "$total" "$name"
  start_ms="$(now_ms)"
  set +e
  if [[ "$VERBOSE" -eq 1 ]]; then
    "run_step_${index}"
    rc=$?
  else
    log_file="$(mktemp "${TMPDIR:-/tmp}/phase-H-step-${index}.XXXXXX")"
    TMP_LOGS+=("$log_file")
    "run_step_${index}" >"$log_file" 2>&1
    rc=$?
  fi
  set -e
  end_ms="$(now_ms)"
  duration_ms=$(( end_ms - start_ms ))
  [[ "$duration_ms" -ge 0 ]] || duration_ms=0
  STEP_EXIT_CODES+=("$rc")
  if [[ "$rc" -eq 0 ]]; then
    printf 'PASS (%d ms)\n' "$duration_ms"
    emit_step_metric "$name" "$rc" "true" "$duration_ms"
  else
    printf 'FAIL (exit %d, %d ms)\n' "$rc" "$duration_ms"
    printf 'failing step %s: %s\n' "$index" "$name" >&2
    if [[ "$VERBOSE" -ne 1 && -n "$log_file" ]]; then
      printf 'captured output for step %s (%s):\n' "$index" "$name" >&2
      cat "$log_file" >&2
    fi
    emit_step_metric "$name" "$rc" "false" "$duration_ms"
    FAILED_STEPS+=("$index:$name")
  fi
}

step_names=(
  "T-H-1 target-root resolution"
  "T-H-2 state-json and paths manifest"
  "T-H-3 facade quiesce regression"
  "T-H-4 binary privacy"
  "T-H-5 semantic help and mcp wire"
  "T-H-6 unit self-test"
  "I-12 phase-done smoke"
  "validate_joint_transition has smoke_evidence_sha256 requirement (static spec check)"
  "Phase A continuity"
  "Phase B continuity"
  "Phase C continuity"
  "Phase D continuity"
  "Phase E continuity"
  "Phase F continuity"
  "Phase G continuity"
  "pre-commit guards fire"
)

total_steps="${#step_names[@]}"
passed_count=0
failed_count=0

for idx in $(seq 1 "$total_steps"); do
  run_step "$idx" "$total_steps" "${step_names[$((idx - 1))]}"
done

for rc in "${STEP_EXIT_CODES[@]}"; do
  if [[ "$rc" -eq 0 ]]; then
    passed_count=$((passed_count + 1))
  else
    failed_count=$((failed_count + 1))
  fi
done

final_rc=0
if [[ "$failed_count" -gt 0 ]]; then
  final_rc=1
  printf 'failing steps: %s\n' "${FAILED_STEPS[*]}" >&2
fi

emit_summary_metric "$passed_count" "$failed_count" "$final_rc"
exit "$final_rc"
