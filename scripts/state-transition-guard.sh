#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_canonical-guard.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_canonical-guard.sh"
rev_harness_assert_canonical_root state-transition-guard

DEFAULT_STATE_FILE=".agent/state/dual_lgtm_state.json"
DEFAULT_ALLOWED="dual_lgtm_pending->dual_lgtm_confirmed,dual_lgtm_pending->dual_lgtm_blocked,dual_lgtm_confirmed->dual_lgtm_confirmed,dual_lgtm_blocked->dual_lgtm_blocked,dual_lgtm_blocked->dual_lgtm_pending,dual_lgtm_pending->dual_lgtm_pending"
DEFAULT_SMOKE_METRICS=".agent/metrics/phase_done_smoke.jsonl"

usage() {
  cat <<'EOF'
Usage:
  scripts/state-transition-guard.sh \
    --plan-id <plan-id> \
    --round <int> \
    --target-state dual_lgtm_pending|dual_lgtm_confirmed|dual_lgtm_blocked \
    [--target-stage provisional|final] \
    [--smoke-evidence-sha256 <hex>] \
    [--state-file .agent/state/dual_lgtm_state.json] \
    [--evidence-paths "opus=path1,codex=path2"] \
    [--reason "<string>"] \
    [--allowed-transitions "<csv>"]
  scripts/state-transition-guard.sh --require-lgtm-final <state-file>
  scripts/state-transition-guard.sh --self-test
  scripts/state-transition-guard.sh --help
EOF
}

die() { printf 'state-transition-guard: %s\n' "$*" >&2; exit 1; }
usage_error() { printf 'state-transition-guard: %s\n' "$*" >&2; usage >&2; exit 2; }

is_state() { case "$1" in dual_lgtm_pending|dual_lgtm_confirmed|dual_lgtm_blocked) return 0 ;; *) return 1 ;; esac; }
is_stage() { case "$1" in provisional|final) return 0 ;; *) return 1 ;; esac; }
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
csv_has_transition() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }

parse_evidence_paths() {
  local raw="$1" old_ifs pair key value
  OPUS_PATH=""; CODEX_PATH=""
  old_ifs="$IFS"; IFS=','
  for pair in $raw; do
    IFS="$old_ifs"; key="${pair%%=*}"; value="${pair#*=}"
    case "$key" in
      opus) OPUS_PATH="$value" ;;
      codex) CODEX_PATH="$value" ;;
      "") ;;
      *) usage_error "unknown evidence key: ${key}" ;;
    esac
    IFS=','
  done
  IFS="$old_ifs"
}

sha256_for() {
  local path="$1"
  [[ -n "$path" && -f "$path" ]] || { printf ''; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$path" | awk '{print $1}'; else shasum -a 256 "$path" | awk '{print $1}'; fi
}

read_current_state() {
  local state_file="$1"
  [[ -f "$state_file" ]] || { printf 'dual_lgtm_pending'; return 0; }
  jq -er '.state // "dual_lgtm_pending"' "$state_file" 2>/dev/null || die "failed to read current state from ${state_file}"
}

read_current_stage() {
  local state_file="$1"
  [[ -f "$state_file" ]] || { printf 'provisional'; return 0; }
  jq -er '.lgtm_stage // "provisional"' "$state_file" 2>/dev/null || die "failed to read lgtm_stage from ${state_file}"
}

smoke_metric_file() {
  printf '%s\n' "${REV_HARNESS_PHASE_DONE_SMOKE_METRICS:-$DEFAULT_SMOKE_METRICS}"
}

smoke_sha_is_sourced() {
  local sha="$1" metrics
  metrics="$(smoke_metric_file)"
  [[ -f "$metrics" ]] || return 1
  jq -e --arg sha "$sha" '
    select(type == "object")
    | select(.event == "summary")
    | select((.exit_code // 1) == 0)
    | select(.smoke_evidence_sha256 == $sha)
  ' "$metrics" >/dev/null 2>&1
}

validate_joint_transition() {
  local current="$1" current_stage="$2" target_state="$3" target_stage="$4" smoke_sha="$5"

  if [[ "$current_stage" == "final" && "$target_stage" == "provisional" ]]; then
    printf 'state-transition-guard: I-12 violation: final lgtm_stage cannot regress to provisional\n' >&2
    exit 1
  fi

  if [[ "$current_stage" == "final" && "$target_stage" == "final" ]]; then
    return 0
  fi

  if [[ "$current" == "dual_lgtm_confirmed" && "$current_stage" == "provisional" && "$target_state" == "dual_lgtm_confirmed" && "$target_stage" == "final" ]]; then
    is_sha256 "$smoke_sha" || { printf 'state-transition-guard: I-12 violation: --smoke-evidence-sha256 must be a sha256 hex\n' >&2; exit 1; }
    smoke_sha_is_sourced "$smoke_sha" || { printf 'state-transition-guard: I-12 violation: smoke_evidence_sha256 is not sourced from phase_done_smoke summary\n' >&2; exit 1; }
    return 0
  fi

  if [[ "$target_stage" == "final" ]]; then
    printf 'state-transition-guard: I-12 violation: lgtm_stage=final requires confirmed/provisional -> confirmed/final with smoke evidence\n' >&2
    exit 1
  fi

  return 0
}

write_state_atomic() {
  local state_file="$1" plan_id="$2" round="$3" target_state="$4" target_stage="$5" reason="$6"
  local opus_path="$7" codex_path="$8" opus_sha="$9" codex_sha="${10}" smoke_sha="${11}"
  local dir base tmp transitioned_at
  dir="$(dirname "$state_file")"; base="$(basename "$state_file")"
  mkdir -p "$dir"; tmp="${dir}/${base}.tmp.$$.${RANDOM:-0}"
  transitioned_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  trap '/bin/rm -f "${tmp:-}"' EXIT
  jq -n --arg plan_id "$plan_id" --argjson round "$round" \
    --arg state "$target_state" --arg lgtm_stage "$target_stage" \
    --arg transitioned_at "$transitioned_at" --arg transition_reason "$reason" \
    --arg opus_path "$opus_path" --arg codex_path "$codex_path" \
    --arg opus_sha "$opus_sha" --arg codex_sha "$codex_sha" \
    --arg smoke_sha "$smoke_sha" \
    '{
      plan_id:$plan_id,
      round:$round,
      state:$state,
      lgtm_stage:$lgtm_stage,
      transitioned_at:$transitioned_at,
      transition_reason:$transition_reason,
      evidence_paths:{opus:$opus_path,codex:$codex_path},
      sha256:{opus:$opus_sha,codex:$codex_sha}
    }
    | if $smoke_sha == "" then . else .smoke_evidence_sha256 = $smoke_sha end' >"$tmp"
  mv -f "$tmp" "$state_file"
  trap - EXIT
}

run_require_lgtm_final() {
  local state_file="$1" stage
  [[ -n "$state_file" ]] || usage_error "--require-lgtm-final requires a state file"
  [[ -f "$state_file" ]] || die "state file not found: ${state_file}"
  stage="$(read_current_stage "$state_file")"
  if [[ "$stage" != "final" ]]; then
    printf 'state-transition-guard: I-12 violation: lgtm_stage must be final for phase_advance (got %s)\n' "$stage" >&2
    exit 1
  fi
}

run_transition() {
  local plan_id="" round="" target_state="" target_stage="" state_file="$DEFAULT_STATE_FILE"
  local evidence_paths="" reason="" allowed="$DEFAULT_ALLOWED" smoke_sha=""
  local current current_stage transition opus_sha codex_sha
  OPUS_PATH=""; CODEX_PATH=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --plan-id) [[ "$#" -ge 2 ]] || usage_error "--plan-id requires a value"; plan_id="$2"; shift 2 ;;
      --round) [[ "$#" -ge 2 ]] || usage_error "--round requires a value"; round="$2"; shift 2 ;;
      --target-state) [[ "$#" -ge 2 ]] || usage_error "--target-state requires a value"; target_state="$2"; shift 2 ;;
      --target-stage) [[ "$#" -ge 2 ]] || usage_error "--target-stage requires a value"; target_stage="$2"; shift 2 ;;
      --smoke-evidence-sha256) [[ "$#" -ge 2 ]] || usage_error "--smoke-evidence-sha256 requires a value"; smoke_sha="$2"; shift 2 ;;
      --state-file) [[ "$#" -ge 2 ]] || usage_error "--state-file requires a value"; state_file="$2"; shift 2 ;;
      --evidence-paths) [[ "$#" -ge 2 ]] || usage_error "--evidence-paths requires a value"; evidence_paths="$2"; shift 2 ;;
      --reason) [[ "$#" -ge 2 ]] || usage_error "--reason requires a value"; reason="$2"; shift 2 ;;
      --allowed-transitions) [[ "$#" -ge 2 ]] || usage_error "--allowed-transitions requires a value"; allowed="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --self-test) self_test; exit 0 ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done
  [[ -n "$plan_id" ]] || usage_error "--plan-id is required"
  [[ -n "$round" ]] || usage_error "--round is required"
  is_int "$round" || usage_error "--round must be a non-negative integer"
  [[ -n "$target_state" ]] || usage_error "--target-state is required"
  is_state "$target_state" || usage_error "invalid target state: ${target_state}"
  parse_evidence_paths "$evidence_paths"
  current="$(read_current_state "$state_file")"
  current_stage="$(read_current_stage "$state_file")"
  is_state "$current" || die "invalid current state in ${state_file}: ${current}"
  is_stage "$current_stage" || die "invalid lgtm_stage in ${state_file}: ${current_stage}"
  [[ -n "$target_stage" ]] || target_stage="$current_stage"
  is_stage "$target_stage" || usage_error "invalid target stage: ${target_stage}"
  transition="${current}->${target_state}"
  if ! csv_has_transition "$allowed" "$transition"; then
    printf 'state-transition-guard: forbidden transition %s -> %s (reason: %s)\n' "$current" "$target_state" "${reason:-not allowed by transition table}" >&2
    exit 1
  fi
  validate_joint_transition "$current" "$current_stage" "$target_state" "$target_stage" "$smoke_sha"
  opus_sha="$(sha256_for "$OPUS_PATH")"; codex_sha="$(sha256_for "$CODEX_PATH")"
  write_state_atomic "$state_file" "$plan_id" "$round" "$target_state" "$target_stage" "$reason" "$OPUS_PATH" "$CODEX_PATH" "$opus_sha" "$codex_sha" "$smoke_sha"
  printf 'state-transition-guard: transitioned %s/%s -> %s/%s (%s)\n' "$current" "$current_stage" "$target_state" "$target_stage" "$state_file" >&2
}

seed_state() {
  mkdir -p "$(dirname "$1")"
  jq -n --arg state "$2" --arg stage "${3:-provisional}" \
    '{plan_id:"self-test",round:0,state:$state,lgtm_stage:$stage,transitioned_at:"1970-01-01T00:00:00Z",transition_reason:"seed",evidence_paths:{opus:"",codex:""},sha256:{opus:"",codex:""}}' >"$1"
}

emit_smoke_summary_fixture() {
  local metrics="$1" sha="$2"
  mkdir -p "$(dirname "$metrics")"
  printf '{"event":"summary","phase":"self-test","total_steps":1,"passed_count":1,"failed_count":0,"exit_code":0,"smoke_evidence_sha256":"%s"}\n' "$sha" >"$metrics"
}

self_test_case() {
  local root="$1" current="$2" target="$3" expect="$4" dir state_file out rc
  dir="${root}/${current}_to_${target}"; state_file="${dir}/state.json"
  mkdir -p "$dir"; [[ "$current" == "missing" ]] || seed_state "$state_file" "$current"
  set +e
  out="$(bash "${BASH_SOURCE[0]}" --plan-id self-test --round 1 --target-state "$target" --state-file "$state_file" --reason "self-test ${current} -> ${target}" 2>&1)"
  rc=$?
  set -e
  if [[ "$expect" == "0" && "$rc" -eq 0 ]]; then return 0; fi
  if [[ "$expect" != "0" && "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'forbidden transition'; then return 0; fi
  printf 'self-test: FAIL %s -> %s rc=%s output=%s\n' "$current" "$target" "$rc" "$out" >&2
  return 1
}

self_test_stage_case() {
  local root="$1" name="$2" current_state="$3" current_stage="$4" target_state="$5" target_stage="$6" expect="$7"
  local dir state_file out rc metrics sha args=()
  dir="${root}/stage-${name}"; state_file="${dir}/state.json"; metrics="${dir}/phase_done_smoke.jsonl"
  mkdir -p "$dir"; seed_state "$state_file" "$current_state" "$current_stage"
  sha="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  if [[ "$target_stage" == "final" ]]; then
    emit_smoke_summary_fixture "$metrics" "$sha"
    args+=(--smoke-evidence-sha256 "$sha")
  fi
  set +e
  out="$(REV_HARNESS_PHASE_DONE_SMOKE_METRICS="$metrics" bash "${BASH_SOURCE[0]}" --plan-id self-test --round 1 --target-state "$target_state" --target-stage "$target_stage" --state-file "$state_file" --reason "stage ${name}" "${args[@]}" 2>&1)"
  rc=$?
  set -e
  if [[ "$expect" == "0" && "$rc" -eq 0 ]]; then return 0; fi
  if [[ "$expect" != "0" && "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -Eq 'I-12 violation|forbidden transition'; then return 0; fi
  printf 'self-test: FAIL stage %s rc=%s output=%s\n' "$name" "$rc" "$out" >&2
  return 1
}

self_test_require_final_case() {
  local root="$1" name="$2" stage="$3" expect="$4" state_file out rc
  state_file="${root}/require-${name}.json"
  seed_state "$state_file" "dual_lgtm_confirmed" "$stage"
  set +e
  out="$(bash "${BASH_SOURCE[0]}" --require-lgtm-final "$state_file" 2>&1)"
  rc=$?
  set -e
  if [[ "$expect" == "0" && "$rc" -eq 0 ]]; then return 0; fi
  if [[ "$expect" != "0" && "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'I-12 violation'; then return 0; fi
  printf 'self-test: FAIL require-final %s rc=%s output=%s\n' "$name" "$rc" "$out" >&2
  return 1
}

self_test() {
  local root t
  root="$(mktemp -d)"
  trap '/bin/rm -rf "${root:-}"' EXIT
  for t in \
    'missing dual_lgtm_pending 0' \
    'dual_lgtm_pending dual_lgtm_confirmed 0' \
    'dual_lgtm_pending dual_lgtm_blocked 0' \
    'dual_lgtm_confirmed dual_lgtm_confirmed 0' \
    'dual_lgtm_blocked dual_lgtm_blocked 0' \
    'dual_lgtm_blocked dual_lgtm_pending 0' \
    'dual_lgtm_confirmed dual_lgtm_blocked 1' \
    'dual_lgtm_confirmed dual_lgtm_pending 1' \
    'dual_lgtm_blocked dual_lgtm_confirmed 1'
  do
    # shellcheck disable=SC2086
    self_test_case "$root" $t
  done

  self_test_stage_case "$root" "pending-prov-stays-prov" "dual_lgtm_pending" "provisional" "dual_lgtm_confirmed" "provisional" 0
  self_test_stage_case "$root" "confirmed-prov-to-final" "dual_lgtm_confirmed" "provisional" "dual_lgtm_confirmed" "final" 0
  self_test_stage_case "$root" "final-to-provisional-regression" "dual_lgtm_confirmed" "final" "dual_lgtm_confirmed" "provisional" 1
  self_test_stage_case "$root" "final-idempotent" "dual_lgtm_confirmed" "final" "dual_lgtm_confirmed" "final" 0
  self_test_require_final_case "$root" "phase-advance-final" "final" 0
  self_test_require_final_case "$root" "phase-advance-provisional" "provisional" 1

  trap - EXIT
  /bin/rm -rf "$root"
  printf 'self-test: OK\n'
}

main() {
  case "${1:-}" in
    -h|--help|"") usage ;;
    --self-test) self_test ;;
    --require-lgtm-final)
      shift
      [[ "$#" -eq 1 ]] || usage_error "--require-lgtm-final requires exactly one state file"
      run_require_lgtm_final "$1"
      ;;
    *) run_transition "$@" ;;
  esac
}

main "$@"
