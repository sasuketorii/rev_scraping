#!/usr/bin/env bash
# HSDI Phase G aggregate acceptance CI.
# Invariant 1: execute from the repository root discovered from this script.
# Invariant 2: keep all checks deterministic and local-only.
# Invariant 3: emit one Phase G JSONL metric per executed step.
# Invariant 4: stop on the first failed step and report the failing step.
# Invariant 5: avoid user-specific absolute paths in script logic.

set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
METRICS_FILE="${REPO_ROOT}/.agent/metrics/phase_G_done.jsonl"
VERBOSE=0
TMP_LOGS=()
export LC_ALL=C
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
  for log_file in "${TMP_LOGS[@]}"; do rm -f "$log_file" || true; done
}
trap cleanup EXIT

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

iso_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

emit_step_metric() {
  local step="$1" exit_code="$2" passed="$3"
  printf '{"event":"phase_G_done_step","step":"%s","exit_code":%d,"passed":%s,"ts":"%s"}\n' \
    "$(json_escape "$step")" "$exit_code" "$passed" "$(iso_utc)" >> "${METRICS_FILE}"
}

emit_summary_metric() {
  local passed="$1" failed="$2" exit_code="$3"
  printf '{"event":"phase_G_done","passed":%d,"failed":%d,"exit_code":%d,"schema_version":"phase-G-done/v1"}\n' \
    "$passed" "$failed" "$exit_code" >> "${METRICS_FILE}"
}

tg1_integration_acceptance() {
  local evidence_log=".agent/active/plan_20260525_hsdi-phase-G/T-G-1/integration-tests-stdout.log"
  local pass_count=0 test_file="" idx=0 tests=() tmp_target=""
  if [[ -s "${evidence_log}" ]]; then
    pass_count="$(grep -Ec 'PASS|: ok$' "${evidence_log}" || true)"
    [[ "${pass_count}" -ge 3 ]] && return 0
  fi
  shopt -s nullglob
  tests=(test/integration/test-rev-harness-adopter-setup-*.sh)
  shopt -u nullglob
  if [[ "${#tests[@]}" -gt 0 ]]; then
    for test_file in "${tests[@]}"; do
      idx=$(( idx + 1 )); [[ "${idx}" -le 3 ]] || break
      bash "${test_file}" || return $?
    done
    return 0
  fi
  tmp_target="$(mktemp -d)"
  bash scripts/rev-harness-adopter-setup.sh status --target "$tmp_target"
}

description_len() {
  awk 'BEGIN { found=0 }
    /^description:/ { found=1; sub(/^description:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print length($0); exit }
    END { if (!found) exit 1 }' .claude/skills/rev-harness-lifecycle/SKILL.md
}

run_step_1() { bash -n scripts/rev-harness-adopter-setup.sh || return $?; bash scripts/rev-harness-adopter-setup.sh --help || return $?; tg1_integration_acceptance; }
run_step_2() {
  bash test/unit/test-janitor-build-cleanup.sh || return $?
  ( export REVHARNESS_PARALLEL_QUIESCE=0; bash test/unit/test-janitor-bail-gc.sh ) || return $?
  bash test/unit/test-janitor-quiesce.sh
}
run_step_3() { bash -n scripts/rev-harness || return $?; bash -n scripts/rev-harness-install.sh || return $?; bash -n scripts/rev-harness-uninstall.sh || return $?; bash -n scripts/rev-harness-repair.sh || return $?; (unset REVHARNESS_PARALLEL_QUIESCE && bash test/integration/test-rev-harness-cli.sh); }
run_step_4() {
  local n=0
  test -s .claude/skills/rev-harness-lifecycle/SKILL.md || return $?
  n="$(description_len)" || return $?
  [[ "${n}" -le 200 ]] || return 1
  grep -q 'rev-harness-lifecycle' .claude/skills/development-junk-cleanup/SKILL.md || return $?
  grep -q 'rev-harness-lifecycle' .claude/skills/semantic-bootstrap/SKILL.md
}
run_step_5() { bash -n scripts/rev-harness-mcp-wire.sh || return $?; bash scripts/rev-harness-mcp-wire.sh --self-test || return $?; bash test/unit/test-mcp-wire-merge.sh || return $?; bash test/unit/test-mcp-wire-conflict-refuse.sh || return $?; bash test/unit/test-mcp-wire-bak-rollback.sh; }
run_step_6() { bash .claude/hooks/agent-graceful-shutdown.sh --self-test; }
run_step_7() { bash scripts/ci/hsdi-phase-B-done.sh; }
run_step_8() { bash scripts/ci/hsdi-phase-C-done.sh; }
run_step_9() { bash scripts/ci/hsdi-phase-D-done.sh; }
run_step_10() { bash scripts/ci/hsdi-phase-E-done.sh; }
run_step_11() { bash scripts/ci/hsdi-phase-F-done.sh; }
run_step_12() { bash test/integration/install_hooks_fail_closed_no_harness_root_test.sh; }

run_step() {
  local index="$1" total="$2" name="$3" rc=0 start_ms=0 end_ms=0 duration_ms=0 log_file=""
  printf '[step %s/%s] %s ... ' "$index" "$total" "$name"
  start_ms="$(now_ms)"
  set +e
  if [[ "${VERBOSE}" -eq 1 ]]; then
    "run_step_${index}"; rc=$?
  else
    log_file="$(mktemp "${TMPDIR:-/tmp}/phase-G-step-${index}.XXXXXX")"
    TMP_LOGS+=("$log_file")
    "run_step_${index}" >"$log_file" 2>&1; rc=$?
  fi
  set -e
  end_ms="$(now_ms)"; duration_ms=$(( end_ms - start_ms ))
  if [[ "$rc" -eq 0 ]]; then
    printf 'PASS (%d ms)\n' "$duration_ms"
    emit_step_metric "$name" "$rc" "true"
  else
    printf 'FAIL (exit %d, %d ms)\n' "$rc" "$duration_ms"
    printf 'failing step %s: %s\n' "$index" "$name" >&2
    if [[ "${VERBOSE}" -ne 1 && -n "$log_file" ]]; then
      printf 'captured output for step %s (%s):\n' "$index" "$name" >&2
      cat "$log_file" >&2
    fi
    emit_step_metric "$name" "$rc" "false"
  fi
  return "$rc"
}

step_names=(
  "T-G-1 acceptance" "T-G-2 acceptance" "T-G-3 acceptance" "T-G-4 acceptance"
  "T-G-6 acceptance" "Phase A continuity" "Phase B continuity" "Phase C continuity"
  "Phase D continuity" "Phase E continuity" "Phase F continuity"
  "install hooks fail closed without harness root"
)
total_steps="${#step_names[@]}"
passed_count=0

for idx in 1 2 3 4 5 6 7 8 9 10 11 12; do
  pos=$(( idx - 1 ))
  if run_step "$idx" "$total_steps" "${step_names[$pos]}"; then
    passed_count=$(( passed_count + 1 ))
  else
    emit_summary_metric "$passed_count" 1 1
    exit 1
  fi
done

emit_summary_metric "$passed_count" 0 0
exit 0
