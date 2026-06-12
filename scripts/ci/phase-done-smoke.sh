#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
HARNESS_ROOT="${REV_HARNESS_SMOKE_HARNESS_ROOT:-$REPO_ROOT}"
METRICS_FILE="${REV_HARNESS_SMOKE_METRICS_FILE:-$REPO_ROOT/.agent/metrics/phase_done_smoke.jsonl}"
PHASE="H"
KEEP_SANDBOX=0
TMP_ROOT="${REV_HARNESS_SMOKE_TMPDIR:-/tmp}"
SMOKE_SKIP_HEAVY="${REV_HARNESS_SMOKE_SKIP_HEAVY:-1}"
SANDBOX=""
STEP_ROWS=()
STEP_NAMES=()
STEP_CODES=()
STEP_PASSED=()
FAILED_STEPS=()

usage() {
  cat <<'EOF'
Usage:
  scripts/ci/phase-done-smoke.sh [--phase <H|G|F|...>] [--keep-sandbox]

Runs the I-12 phase-done smoke against a fresh adopter sandbox and appends
phase-done-smoke/v1 JSONL metrics.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --phase) [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }; PHASE="$2"; shift 2 ;;
    --keep-sandbox) KEEP_SANDBOX=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ ! "$PHASE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
  printf 'phase-done-smoke: invalid phase: %s\n' "$PHASE" >&2
  exit 2
fi

redact_text() {
  sed -E -e "s#${HOME%/}/#~/#g" -e 's#/Users/[^/[:space:]]+/#~/#g' -e 's#/home/[^/[:space:]]+/#~/#g'
}

redact_value() {
  printf '%s' "$1" | redact_text
}

log() {
  printf '[phase-done-smoke] %s\n' "$(redact_value "$*")" >&2
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

json_escape_arg() {
  jq -Rn --arg value "$1" '$value'
}

resolve_rev_harness_bin() {
  if [[ -n "${REV_HARNESS_BIN:-}" ]]; then
    printf '%s\n' "$REV_HARNESS_BIN"
  elif command -v rev-harness >/dev/null 2>&1; then
    command -v rev-harness
  else
    printf '%s\n' "$REPO_ROOT/scripts/rev-harness"
  fi
}

resolve_doctor_bin() {
  if [[ -n "${REV_HARNESS_DOCTOR_BIN:-}" ]]; then
    printf '%s\n' "$REV_HARNESS_DOCTOR_BIN"
  elif command -v harness-doctor >/dev/null 2>&1; then
    command -v harness-doctor
  else
    printf '%s\n' "$REPO_ROOT/scripts/harness-doctor.sh"
  fi
}

run_cmd_path() {
  local cmd="$1"; shift
  if [[ "$cmd" == */*.sh || "$cmd" == */rev-harness ]]; then
    bash "$cmd" "$@"
  else
    "$cmd" "$@"
  fi
}

REV_HARNESS_CMD="$(resolve_rev_harness_bin)"
DOCTOR_CMD="$(resolve_doctor_bin)"
PRIVACY_SCAN_CMD="${REV_HARNESS_PRIVACY_SCAN:-$REPO_ROOT/scripts/ci/shipped-artifact-privacy-scan.sh}"
CORE_BINARY_PATH="${REV_HARNESS_SMOKE_CORE_BINARY:-$REPO_ROOT/harness-rust/target/release/agent-core}"

cleanup() {
  if [[ "$KEEP_SANDBOX" -eq 0 && -n "${SANDBOX:-}" ]]; then
    /bin/rm -rf "$SANDBOX" 2>/dev/null || true
  elif [[ "$KEEP_SANDBOX" -eq 1 && -n "${SANDBOX:-}" ]]; then
    log "kept sandbox: $SANDBOX"
  fi
}
trap cleanup EXIT

mk_sandbox() {
  local ts
  ts="$(date -u '+%Y%m%dT%H%M%SZ')"
  mkdir -p "$TMP_ROOT"
  SANDBOX="$(mktemp -d "$TMP_ROOT/phase-done-smoke-${PHASE}-${ts}.XXXXXX")"
  log "sandbox: $SANDBOX"
}

populate_sample() {
  mkdir -p "$SANDBOX/src" "$SANDBOX/python_sample"
  printf '[package]\nname = "phase-done-smoke-sample"\nversion = "0.1.0"\nedition = "2021"\n\n[lib]\npath = "src/lib.rs"\n' >"$SANDBOX/Cargo.toml"
  printf 'pub fn sample() -> u32 { 42 }\n' >"$SANDBOX/src/lib.rs"
  printf '[project]\nname = "phase-done-smoke-sample"\nversion = "0.1.0"\nrequires-python = ">=3.10"\n' >"$SANDBOX/pyproject.toml"
  printf 'def sample() -> int:\n    return 42\n' >"$SANDBOX/python_sample/sample.py"
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email phase-done-smoke@example.invalid
  git -C "$SANDBOX" config user.name phase-done-smoke
  git -C "$SANDBOX" add Cargo.toml pyproject.toml src/lib.rs python_sample/sample.py
  git -C "$SANDBOX" commit -q -m "initial sample"
}

project_id() {
  sed -n '1p' "$SANDBOX/.shared/project_id" 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//'
}

step_create_sandbox() {
  mk_sandbox
  populate_sample
}

step_install() {
  (cd "$HARNESS_ROOT" && REV_HARNESS_SMOKE_SKIP_HEAVY="$SMOKE_SKIP_HEAVY" run_cmd_path "$REV_HARNESS_CMD" install --target "$SANDBOX")
}

step_identity() {
  local pid
  [[ -f "$SANDBOX/.shared/project_id" ]] || return 1
  pid="$(project_id)"
  [[ "$pid" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 1
  [[ "$pid" != revharness-* ]] || return 1
}

step_core_binary_help() {
  if [[ ! -x "$CORE_BINARY_PATH" ]]; then
    (cd "$REPO_ROOT/harness-rust" && cargo build --release -p agent-core --no-default-features >/dev/null)
  fi
  [[ -x "$CORE_BINARY_PATH" ]] || return 1
  "$CORE_BINARY_PATH" --help >/dev/null 2>&1
}

step_privacy_scan() {
  run_cmd_path "$PRIVACY_SCAN_CMD" --manifest "$REPO_ROOT/docs/SHIPPED_ARTIFACTS.md"
}

step_state_json() {
  local state="$SANDBOX/.rev-harness-state/state.json"
  [[ -f "$state" ]] || return 1
  jq -e '.schema == "rev-harness-state/v1" and .phase == "done" and .current_phase == "done"' "$state" >/dev/null
}

step_paths_json() {
  local state="$SANDBOX/.rev-harness-state/state.json"
  local paths="$SANDBOX/.rev-harness-state/paths.json"
  local pid addon_enabled
  [[ -f "$state" ]] || return 1
  pid="$(project_id)"
  [[ "$pid" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 1
  jq -e --arg pid "$pid" '
    .schema == "rev-harness-state/v1"
    and .phase == .current_phase
    and ((.semantic_addon_enabled | type) == "boolean" or .semantic_addon_enabled == null)
    and ((has("project_id") | not) or .project_id == $pid)
    and (has("semantic_db") | not)
    and (has("rust_db") | not)
    and (has("node_db") | not)
  ' "$state" >/dev/null || return 1
  addon_enabled="$(jq -r '.semantic_addon_enabled // false' "$state")"
  if [[ "$addon_enabled" != true && ! -f "$paths" ]]; then
    return 0
  fi
  [[ -f "$paths" ]] || return 1
  jq -e --arg pid "$pid" '
    .schema == "rev-harness-paths/v1"
    and .project_id == $pid
    and .backend == "rust"
    and ((.semantic_db | type) == "null" or (.semantic_db | type == "string"))
    and ((.rust_db | type) == "null" or (.rust_db | type == "string"))
    and (.node_db | not)
  ' "$paths" >/dev/null
}

step_hooks() {
  [[ -f "$SANDBOX/.git/hooks/pre-commit" ]]
}

step_doctor() {
  (cd "$SANDBOX" && PROJECT_ROOT="$SANDBOX" run_cmd_path "$DOCTOR_CMD" --quick >/dev/null)
}

step_status() {
  local out
  out="$(cd "$HARNESS_ROOT" && run_cmd_path "$REV_HARNESS_CMD" status --target "$SANDBOX" 2>&1)"
  printf '%s\n' "$out" | grep -q 'phase: done'
}

step_clean() {
  local out rc
  set +e
  if [[ "$REV_HARNESS_CMD" == */*.sh || "$REV_HARNESS_CMD" == */rev-harness ]]; then
    out="$(cd "$HARNESS_ROOT" && env -u REVHARNESS_PARALLEL_QUIESCE bash "$REV_HARNESS_CMD" clean --target "$SANDBOX" --dry-run 2>&1)"
  else
    out="$(cd "$HARNESS_ROOT" && env -u REVHARNESS_PARALLEL_QUIESCE "$REV_HARNESS_CMD" clean --target "$SANDBOX" --dry-run 2>&1)"
  fi
  rc=$?
  if printf '%s\n' "$out" | grep -q 'skip: PARALLEL_QUIESCE active'; then
    return 1
  fi
  [[ "$rc" -eq 0 ]]
}

step_self_install_guard() {
  local rc
  set +e
  (cd "$HARNESS_ROOT" && run_cmd_path "$REV_HARNESS_CMD" install >/dev/null 2>&1)
  rc=$?
  [[ "$rc" -eq 72 ]]
}

emit_step_metric() {
  local step="$1" exit_code="$2" passed="$3" base sha row
  base="$(jq -nc \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg event "step" \
    --arg step "$step" \
    --arg phase "$PHASE" \
    --argjson exit_code "$exit_code" \
    --argjson passed "$passed" \
    '{schema:"phase-done-smoke/v1",ts:$ts,event:$event,step:$step,exit_code:$exit_code,passed:$passed,phase:$phase}')"
  sha="$(sha256_text "$base")"
  row="$(jq -c --arg sha "$sha" '. + {smoke_evidence_sha256:$sha}' <<<"$base")"
  mkdir -p "$(dirname "$METRICS_FILE")"
  printf '%s\n' "$row" >>"$METRICS_FILE"
  STEP_ROWS+=("$row")
}

emit_summary_metric() {
  local exit_code="$1" total="$2" passed="$3" failed="$4" base sha row
  base="$(jq -nc \
    --arg event "summary" \
    --arg phase "$PHASE" \
    --argjson total_steps "$total" \
    --argjson passed_count "$passed" \
    --argjson failed_count "$failed" \
    --argjson exit_code "$exit_code" \
    '{schema:"phase-done-smoke/v1",event:$event,phase:$phase,total_steps:$total_steps,passed_count:$passed_count,failed_count:$failed_count,exit_code:$exit_code}')"
  sha="$(sha256_text "$base")"
  row="$(jq -c --arg sha "$sha" '. + {smoke_evidence_sha256:$sha}' <<<"$base")"
  mkdir -p "$(dirname "$METRICS_FILE")"
  printf '%s\n' "$row" >>"$METRICS_FILE"
  STEP_ROWS+=("$row")
}

run_step() {
  local name="$1" fn="$2" out rc passed log_file
  STEP_NAMES+=("$name")
  log "step start: $name"
  log_file="$(mktemp "${TMPDIR:-/tmp}/phase-done-smoke-step.XXXXXX")"
  set +e
  "$fn" >"$log_file" 2>&1
  rc=$?
  out="$(cat "$log_file")"
  rm -f "$log_file"
  if [[ "$rc" -eq 0 ]]; then
    passed=true
    log "step pass: $name"
  else
    passed=false
    FAILED_STEPS+=("$name")
    log "step fail: $name exit=$rc"
    if [[ -n "$out" ]]; then printf '%s\n' "$out" | redact_text >&2; fi
  fi
  STEP_CODES+=("$rc")
  STEP_PASSED+=("$passed")
  emit_step_metric "$name" "$rc" "$passed"
  set -e
  return 0
}

main() {
  local total passed failed final_rc
  run_step "sandbox" step_create_sandbox
  run_step "install" step_install
  run_step "identity" step_identity
  run_step "core_binary_help" step_core_binary_help
  run_step "shipped_artifact_privacy_scan" step_privacy_scan
  run_step "state_json" step_state_json
  run_step "paths_json" step_paths_json
  run_step "hooks" step_hooks
  run_step "doctor" step_doctor
  run_step "status" step_status
  run_step "clean" step_clean
  run_step "self_install_guard" step_self_install_guard

  total="${#STEP_NAMES[@]}"
  failed="${#FAILED_STEPS[@]}"
  passed=$(( total - failed ))
  final_rc=0
  [[ "$failed" -eq 0 ]] || final_rc=1
  emit_summary_metric "$final_rc" "$total" "$passed" "$failed"
  if [[ "$failed" -gt 0 ]]; then
    printf 'phase-done-smoke: failed steps: %s\n' "${FAILED_STEPS[*]}" >&2
  fi
  exit "$final_rc"
}

main "$@"
