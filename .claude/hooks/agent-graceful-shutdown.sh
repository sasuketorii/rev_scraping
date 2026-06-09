#!/usr/bin/env bash
set +e
set -u
set -o pipefail 2>/dev/null || true

__gsd_script_dir() {
  local src="${BASH_SOURCE[0]}"
  case "$src" in
    */*) (cd "${src%/*}" && pwd -P) ;;
    *) pwd -P ;;
  esac
}

__GSD_SCRIPT_DIR="$(__gsd_script_dir)"
__GSD_REPO_ROOT="$(cd "${__GSD_SCRIPT_DIR}/../.." 2>/dev/null && pwd -P)"
__GSD_METRICS_DIR="${__GSD_REPO_ROOT}/.agent/metrics"
__GSD_TIMEOUT_LOG="${__GSD_METRICS_DIR}/hook_timeout.jsonl"
__GSD_WRAPPER_EVENTS_LOG="${__GSD_METRICS_DIR}/wrapper_events.jsonl"
__GSD_BG_JOBS_DIR="${__GSD_REPO_ROOT}/.agent/runtime/bg_jobs"
__GSD_WATCHDOG_SECONDS="${GSD_WATCHDOG_SECONDS:-30}"
__GSD_REAPER_GRACE_SECONDS="${GSD_REAPER_GRACE_SECONDS:-10}"
__GSD_CURRENT_PHASE="init"
__GSD_PHASE_START_MS=0
__GSD_AGENT_ID="${REVHARNESS_AGENT_ID:-${AGENT_ID:-}}"

__gsd_failopen_trap() {
  local rc="${1:-1}"
  __gsd_emit_timeout_row "${__GSD_CURRENT_PHASE}" "${rc}" 2>/dev/null || true
  exit 0
}
trap '__gsd_failopen_trap $?' ERR

__gsd_now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null && return 0
  fi
  local s
  s="$(date +%s 2>/dev/null || echo 0)"
  echo "$(( s * 1000 ))"
}

__gsd_iso8601_utc() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' 2>/dev/null && return 0
  fi
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z"
}

__gsd_emit_timeout_row() {
  local phase="${1:-unknown}"
  local exit_code="${2:-0}"
  local elapsed_ms=0
  if [[ "${__GSD_PHASE_START_MS}" =~ ^[0-9]+$ ]] && [[ "${__GSD_PHASE_START_MS}" -gt 0 ]]; then
    local now_ms
    now_ms="$(__gsd_now_ms)"
    elapsed_ms=$(( now_ms - __GSD_PHASE_START_MS ))
    [[ "${elapsed_ms}" -lt 0 ]] && elapsed_ms=0
  fi
  local ts
  ts="$(__gsd_iso8601_utc)"
  mkdir -p "${__GSD_METRICS_DIR}" 2>/dev/null || return 0
  local safe_phase="${phase//\"/_}"
  safe_phase="${safe_phase//$'\n'/ }"
  printf '{"ts":"%s","hook":"agent-graceful-shutdown","phase":"%s","elapsed_ms":%d,"exit_code":%d}\n' \
    "${ts}" "${safe_phase}" "${elapsed_ms}" "${exit_code}" \
    >> "${__GSD_TIMEOUT_LOG}" 2>/dev/null || true
  return 0
}

__gsd_phase_begin() { __GSD_CURRENT_PHASE="${1:-unknown}"; __GSD_PHASE_START_MS="$(__gsd_now_ms)"; }
__gsd_phase_end() { __GSD_CURRENT_PHASE="idle"; __GSD_PHASE_START_MS=0; }

__gsd_run_with_watchdog() {
  local phase="${1:-unknown}" fn_name="${2:-:}"
  shift 2 || true
  __gsd_phase_begin "${phase}"
  ( set +e; "${fn_name}" "$@" ) &
  local sub_pid=$! waited=0 rc=0
  while (( waited < __GSD_WATCHDOG_SECONDS )); do
    kill -0 "${sub_pid}" 2>/dev/null || break
    sleep 1 2>/dev/null || true
    waited=$(( waited + 1 ))
  done
  if kill -0 "${sub_pid}" 2>/dev/null; then
    __gsd_emit_timeout_row "${phase}" 124 || true
    kill -TERM "${sub_pid}" 2>/dev/null || true
    sleep 1 2>/dev/null || true
    kill -KILL "${sub_pid}" 2>/dev/null || true
    rc=124
  else
    wait "${sub_pid}" 2>/dev/null
    rc=$?
  fi
  __gsd_phase_end
  return 0
}

gsd_idle_reminder() {
  # GSD_T-21.0-4: idle reminder (implemented).
  # Emits a single stderr line when REVHARNESS_AGENT_START_TS indicates the
  # agent has been running for >= GSD_IDLE_REMINDER_SECONDS (default 300).
  # Rate-limited via .agent/runtime/gsd_last_reminder so the same agent does
  # not get reminded more than once per window. Fail-open: any error -> 0.
  if [[ "${REVHARNESS_PARALLEL_QUIESCE:-0}" == "1" ]]; then
    return 0   # PARALLEL_QUIESCE active; suppress side effect (HSDI Phase B T-B-1)
  fi
  [[ -n "${REVHARNESS_AGENT_START_TS:-}" ]] || return 0
  [[ "${REVHARNESS_AGENT_START_TS}" =~ ^[0-9]+$ ]] || return 0
  local window="${GSD_IDLE_REMINDER_SECONDS:-300}"
  [[ "${window}" =~ ^[0-9]+$ ]] || window=300
  local now_s
  now_s="$(date -u +%s 2>/dev/null || echo 0)"
  [[ "${now_s}" =~ ^[0-9]+$ ]] || return 0
  local elapsed=$(( now_s - REVHARNESS_AGENT_START_TS ))
  (( elapsed >= window )) || return 0
  local rt_dir="${__GSD_REPO_ROOT}/.agent/runtime"
  local marker="${rt_dir}/gsd_last_reminder"
  if [[ -r "${marker}" ]]; then
    local last
    last="$(cat "${marker}" 2>/dev/null || echo 0)"
    [[ "${last}" =~ ^[0-9]+$ ]] || last=0
    if (( now_s - last < window )); then
      return 0
    fi
  fi
  mkdir -p "${rt_dir}" 2>/dev/null || true
  printf '%s' "${now_s}" > "${marker}" 2>/dev/null || true
  printf 'Idle %d min elapsed; please flush progress to .agent/active/<task>/progress.md and continue.\n' \
    $(( elapsed / 60 )) >&2
  return 0
}

gsd_wallclock_hardstop() {
  # GSD_T-21.0-4: wall-clock hardstop (implemented).
  # When REVHARNESS_AGENT_START_TS shows wall-clock elapsed >=
  # GSD_HARDSTOP_SECONDS (default 1800), emit a hook_timeout row and
  # terminate the *current* process group (so the calling subshell does
  # not reach any "POST_HARDSTOP_REACHED" sentinel). Fail-open: any
  # internal error -> 0. No 'token'/'budget'/'allowance'/'quota' wording.
  if [[ "${REVHARNESS_PARALLEL_QUIESCE:-0}" == "1" ]]; then
    return 0   # PARALLEL_QUIESCE active; suppress side effect (HSDI Phase B T-B-1)
  fi
  [[ -n "${REVHARNESS_AGENT_START_TS:-}" ]] || return 0
  [[ "${REVHARNESS_AGENT_START_TS}" =~ ^[0-9]+$ ]] || return 0
  local limit="${GSD_HARDSTOP_SECONDS:-1800}"
  [[ "${limit}" =~ ^[0-9]+$ ]] || limit=1800
  local now_s
  now_s="$(date -u +%s 2>/dev/null || echo 0)"
  [[ "${now_s}" =~ ^[0-9]+$ ]] || return 0
  local elapsed=$(( now_s - REVHARNESS_AGENT_START_TS ))
  (( elapsed >= limit )) || return 0
  __GSD_PHASE_START_MS="$(__gsd_now_ms)"
  __gsd_emit_timeout_row "wallclock_hardstop" 124 || true
  # Terminate the current shell so the caller's post-hardstop code does
  # not run. Use a hard exit; the EXIT-trap wrapper returns 0 to keep
  # fail-open semantics at the OS level.
  exit 0
}
gsd_dirty_exit_stash() {
  # GSD_T-21.0-2: dirty-exit auto-stash.
  # Stage 1: git stash push -u -m "revharness-bail-<task>-<ts>"
  # Stage 2 (fallback): branch revharness-bail/<task>/<ts> with
  #         "wip(bail): <task> graceful checkpoint" commit; path-scoped
  #         cleanup of originally-untracked files (NEVER git clean -fd).
  # Stage 3 (both fail): append phase=stash_failed to hook_timeout.jsonl.
  if [[ "${REVHARNESS_PARALLEL_QUIESCE:-0}" == "1" ]]; then
    return 0   # PARALLEL_QUIESCE active; suppress side effect (HSDI Phase B T-B-1)
  fi
  command -v git >/dev/null 2>&1 || return 0
  local in_tree
  in_tree="$(git rev-parse --is-inside-work-tree 2>/dev/null || echo false)"
  [[ "${in_tree}" == "true" ]] || return 0
  local porcelain
  porcelain="$(git status --porcelain 2>/dev/null || true)"
  [[ -n "${porcelain}" ]] || return 0
  local task="${REVHARNESS_TASK_ID:-unknown}"
  task="${task//[^A-Za-z0-9._-]/_}"
  [[ -n "${task}" ]] || task="unknown"
  local ts=""
  if command -v python3 >/dev/null 2>&1; then
    ts="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))' 2>/dev/null || true)"
  fi
  [[ -n "${ts}" ]] || ts="$(date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || echo 19700101T000000Z)"
  local stash_msg="revharness-bail-${task}-${ts}"
  local branch_name="revharness-bail/${task}/${ts}"
  local commit_msg="wip(bail): ${task} graceful checkpoint"
  local stash_rc=0
  git stash push -u -m "${stash_msg}" >/dev/null 2>&1 || stash_rc=$?
  if [[ "${stash_rc}" -eq 0 ]]; then
    if git stash list 2>/dev/null | grep -Fq "${stash_msg}"; then
      __gsd_record_bail "stash" "${stash_msg}" || true
      return 0
    fi
  fi
  local untracked_paths
  untracked_paths="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
  local prev_ref
  prev_ref="$(git symbolic-ref --short -q HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "")"
  if git checkout -b "${branch_name}" 2>/dev/null; then
    local add_ok=0 commit_ok=0
    git add -A 2>/dev/null && add_ok=1
    if [[ "${add_ok}" -eq 1 ]]; then
      git commit -m "${commit_msg}" 2>/dev/null && commit_ok=1
    fi
    if [[ "${commit_ok}" -eq 1 ]]; then
      [[ -n "${prev_ref}" ]] && git checkout "${prev_ref}" 2>/dev/null || true
      git checkout -- . 2>/dev/null || true
      if [[ -n "${untracked_paths}" ]]; then
        local repo_root
        repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
        if [[ -n "${repo_root}" ]]; then
          local p full
          while IFS= read -r p; do
            [[ -n "${p}" ]] || continue
            case "${p}" in /*|*..*) continue ;; esac
            full="${repo_root}/${p}"
            [[ -f "${full}" || -L "${full}" ]] && rm -f "${full}" 2>/dev/null || true
          done <<<"${untracked_paths}"
        fi
      fi
      __gsd_record_bail "branch" "${branch_name}" || true
      return 0
    fi
    [[ -n "${prev_ref}" ]] && git checkout "${prev_ref}" 2>/dev/null || true
    git branch -D "${branch_name}" 2>/dev/null || true
  fi
  __GSD_PHASE_START_MS="$(__gsd_now_ms)"
  __gsd_emit_timeout_row "stash_failed" 1 || true
  return 0
}

__gsd_record_bail() {
  local kind="${1:-unknown}" ref="${2:-unknown}"
  local ts; ts="$(__gsd_iso8601_utc)"
  mkdir -p "${__GSD_METRICS_DIR}" 2>/dev/null || return 0
  local safe_ref="${ref//\"/_}"; safe_ref="${safe_ref//$'\n'/ }"
  local safe_kind="${kind//\"/_}"
  printf '{"ts":"%s","hook":"agent-graceful-shutdown","phase":"dirty_exit_stash","stash_kind":"%s","ref":"%s"}\n' \
    "${ts}" "${safe_kind}" "${safe_ref}" \
    >> "${__GSD_METRICS_DIR}/silent_bail.jsonl" 2>/dev/null || true
  return 0
}
# GSD_T-21.0-6: silent_bail.jsonl emit body (implemented).
#
# Append exactly one JSONL row to `.agent/metrics/silent_bail.jsonl`
# describing the agent run that just exited. Row schema mirrors
# `test/unit/fixtures/silent_bail_row.json` (finalized by T-21.0-12):
#   {"ts":ISO8601_UTC, "event":"silent_bail", "task_id":<sanitized>,
#    "phase":dirty_exit|wallclock_hardstop|sigterm_received|other,
#    "elapsed_sec":int, "recovery":{"stash_ref":str|null,
#    "bail_branch":str|null, "reaped_pids":int},
#    "agent_family":claude|codex|unknown}
#
# FROZEN mode (golden-fixture parity): when any GSD_GOLDEN_FROZEN_* env
# is set, the matching field is replaced verbatim. Recognized env:
#   GSD_GOLDEN_FROZEN_TS, _TASK_ID, _PHASE, _ELAPSED, _STASH_REF,
#   _BAIL_BRANCH, _REAPED_PIDS, _AGENT_FAMILY.
#
# Invariants:
#   - No "token" or "budget" substring in the emitted row (Opus C2).
#   - Fail-open: any error returns 0; wrapper exit unaffected.
#   - Field order is fixed so `jq -c .` normalization yields byte-equal
#     output to the golden fixture.
gsd_emit_silent_bail() {
  if [[ "${REVHARNESS_PARALLEL_QUIESCE:-0}" == "1" ]]; then
    return 0   # PARALLEL_QUIESCE active; suppress side effect (HSDI Phase B T-B-1)
  fi
  local out_dir="${__GSD_METRICS_DIR}"
  local out_file="${out_dir}/silent_bail.jsonl"
  mkdir -p "${out_dir}" 2>/dev/null || return 0

  local ts
  if [[ -n "${GSD_GOLDEN_FROZEN_TS:-}" ]]; then
    ts="${GSD_GOLDEN_FROZEN_TS}"
  else
    ts="$(__gsd_iso8601_utc)"
  fi

  local task_id
  if [[ -n "${GSD_GOLDEN_FROZEN_TASK_ID:-}" ]]; then
    task_id="${GSD_GOLDEN_FROZEN_TASK_ID}"
  else
    task_id="${REVHARNESS_TASK_ID:-unknown}"
  fi
  task_id="${task_id//[^A-Za-z0-9._-]/_}"
  [[ -n "${task_id}" ]] || task_id="unknown"

  local phase
  if [[ -n "${GSD_GOLDEN_FROZEN_PHASE:-}" ]]; then
    phase="${GSD_GOLDEN_FROZEN_PHASE}"
  else
    phase="${__GSD_BAIL_PHASE:-other}"
  fi
  case "${phase}" in
    dirty_exit|wallclock_hardstop|sigterm_received|other) ;;
    *) phase="other" ;;
  esac

  local elapsed_sec=0
  if [[ -n "${GSD_GOLDEN_FROZEN_ELAPSED:-}" ]]; then
    if [[ "${GSD_GOLDEN_FROZEN_ELAPSED}" =~ ^[0-9]+$ ]]; then
      elapsed_sec="${GSD_GOLDEN_FROZEN_ELAPSED}"
    fi
  elif [[ -n "${REVHARNESS_AGENT_START_TS:-}" ]] && \
       [[ "${REVHARNESS_AGENT_START_TS}" =~ ^[0-9]+$ ]]; then
    local now_s
    now_s="$(date -u +%s 2>/dev/null || echo 0)"
    if [[ "${now_s}" =~ ^[0-9]+$ ]] && \
       [[ "${now_s}" -ge "${REVHARNESS_AGENT_START_TS}" ]]; then
      elapsed_sec=$(( now_s - REVHARNESS_AGENT_START_TS ))
    fi
  fi

  local stash_ref_raw
  if [[ -n "${GSD_GOLDEN_FROZEN_STASH_REF:-}" ]]; then
    stash_ref_raw="${GSD_GOLDEN_FROZEN_STASH_REF}"
  else
    stash_ref_raw="${__GSD_BAIL_STASH_REF:-null}"
  fi
  local stash_ref_json
  if [[ "${stash_ref_raw}" == "null" || -z "${stash_ref_raw}" ]]; then
    stash_ref_json="null"
  else
    local safe_stash="${stash_ref_raw//\\/\\\\}"
    safe_stash="${safe_stash//\"/\\\"}"
    safe_stash="${safe_stash//$'\n'/ }"
    stash_ref_json="\"${safe_stash}\""
  fi

  local bail_branch_raw
  if [[ -n "${GSD_GOLDEN_FROZEN_BAIL_BRANCH:-}" ]]; then
    bail_branch_raw="${GSD_GOLDEN_FROZEN_BAIL_BRANCH}"
  else
    bail_branch_raw="${__GSD_BAIL_BRANCH:-null}"
  fi
  local bail_branch_json
  if [[ "${bail_branch_raw}" == "null" || -z "${bail_branch_raw}" ]]; then
    bail_branch_json="null"
  else
    local safe_branch="${bail_branch_raw//\\/\\\\}"
    safe_branch="${safe_branch//\"/\\\"}"
    safe_branch="${safe_branch//$'\n'/ }"
    bail_branch_json="\"${safe_branch}\""
  fi

  local reaped_pids=0
  if [[ -n "${GSD_GOLDEN_FROZEN_REAPED_PIDS:-}" ]]; then
    if [[ "${GSD_GOLDEN_FROZEN_REAPED_PIDS}" =~ ^[0-9]+$ ]]; then
      reaped_pids="${GSD_GOLDEN_FROZEN_REAPED_PIDS}"
    fi
  elif [[ -n "${__GSD_REAPED_PIDS:-}" ]] && \
       [[ "${__GSD_REAPED_PIDS}" =~ ^[0-9]+$ ]]; then
    reaped_pids="${__GSD_REAPED_PIDS}"
  fi

  local agent_family
  if [[ -n "${GSD_GOLDEN_FROZEN_AGENT_FAMILY:-}" ]]; then
    agent_family="${GSD_GOLDEN_FROZEN_AGENT_FAMILY}"
  else
    agent_family="${REVHARNESS_AGENT_FAMILY:-unknown}"
  fi
  case "${agent_family}" in
    claude|codex|unknown) ;;
    *) agent_family="unknown" ;;
  esac

  local row
  row="$(printf '{"ts":"%s","event":"silent_bail","task_id":"%s","phase":"%s","elapsed_sec":%d,"recovery":{"stash_ref":%s,"bail_branch":%s,"reaped_pids":%d},"agent_family":"%s"}' \
    "${ts}" "${task_id}" "${phase}" "${elapsed_sec}" \
    "${stash_ref_json}" "${bail_branch_json}" "${reaped_pids}" \
    "${agent_family}")"

  # Opus C2 guard: refuse forbidden substrings (token / budget).
  if printf '%s' "${row}" | grep -qiE 'token|budget'; then
    return 0
  fi

  printf '%s\n' "${row}" >> "${out_file}" 2>/dev/null || true
  return 0
}

# GSD_T-21.0-3: bg-job SIGTERM → grace → SIGKILL reaper (implemented).
gsd_bg_job_reaper() {
  if [[ "${REVHARNESS_PARALLEL_QUIESCE:-0}" == "1" ]]; then
    return 0   # PARALLEL_QUIESCE active; suppress side effect (HSDI Phase B T-B-1)
  fi
  (
    set +e
    local target_pgid
    if [[ -n "${GSD_REAPER_TARGET_PGID:-}" && "${GSD_REAPER_TARGET_PGID}" =~ ^[0-9]+$ ]]; then
      target_pgid="${GSD_REAPER_TARGET_PGID}"
    else
      target_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
    fi
    if [[ -z "${target_pgid}" || ! "${target_pgid}" =~ ^[0-9]+$ ]]; then
      __gsd_emit_timeout_row "bg_job_reaper_no_pgid" 1 || true
      return 0
    fi
    local ts
    ts="$(__gsd_iso8601_utc)"
    mkdir -p "${__GSD_METRICS_DIR}" 2>/dev/null || true
    local skip_pids=" $$ ${PPID:-0} ${BASHPID:-0} ${GSD_REAPER_SELF_PID:-0} "
    local seen_pids=" "
    local ps_out=""
    ps_out="$(ps -g "${target_pgid}" -o pid=,pgid=,comm= 2>/dev/null)"
    [[ -z "${ps_out}" ]] && __gsd_emit_timeout_row "bg_job_reaper_ps_empty" 0 || true
    local line pid pgid
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      pid="$(echo "${line}" | awk '{print $1}')"
      pgid="$(echo "${line}" | awk '{print $2}')"
      [[ -z "${pid}" || ! "${pid}" =~ ^[0-9]+$ ]] && continue
      case "${skip_pids}" in *" ${pid} "*) continue ;; esac
      seen_pids+="${pid} "
      local reg_file="${__GSD_BG_JOBS_DIR}/${pid}.json"
      local owner_id=""
      [[ -r "${reg_file}" ]] && owner_id="$(__gsd_read_owner_id "${reg_file}")"
      local class action
      if [[ -n "${owner_id}" ]]; then
        if [[ -n "${__GSD_AGENT_ID}" && "${owner_id}" != "${__GSD_AGENT_ID}" ]]; then
          __gsd_emit_reap_row "${ts}" "${pid}" "${pgid}" "owner_registered" "audit_only" "${owner_id}" || true
          continue
        fi
        class="owner_registered"
      else
        class="orphan_unowned"
      fi
      action="$(__gsd_reap_pid "${pid}")"
      __gsd_emit_reap_row "${ts}" "${pid}" "${pgid}" "${class}" "${action}" "${owner_id}" || true
    done <<< "${ps_out}"

    if [[ -d "${__GSD_BG_JOBS_DIR}" ]]; then
      local rf rf_base reg_pid reg_pgid reg_owner
      shopt -s nullglob 2>/dev/null || true
      for rf in "${__GSD_BG_JOBS_DIR}"/*.json; do
        [[ -e "${rf}" ]] || continue
        rf_base="$(basename "${rf}" .json)"
        [[ "${rf_base}" =~ ^[0-9]+$ ]] || continue
        reg_pid="${rf_base}"
        case "${seen_pids}" in *" ${reg_pid} "*) continue ;; esac
        case "${skip_pids}" in *" ${reg_pid} "*) continue ;; esac
        # Liveness via ps -o pgid= (handles PIDs we lack permission to
        # signal but are still alive — e.g. PID 1). Empty pgid means
        # the PID has exited.
        reg_pgid="$(ps -o pgid= -p "${reg_pid}" 2>/dev/null | tr -d ' ')"
        [[ -z "${reg_pgid}" || ! "${reg_pgid}" =~ ^[0-9]+$ ]] && continue
        reg_owner="$(__gsd_read_owner_id "${rf}")"
        if [[ "${reg_pgid}" == "${target_pgid}" ]]; then
          if [[ -n "${reg_owner}" && ( -z "${__GSD_AGENT_ID}" || "${reg_owner}" == "${__GSD_AGENT_ID}" ) ]]; then
            local act
            act="$(__gsd_reap_pid "${reg_pid}")"
            __gsd_emit_reap_row "${ts}" "${reg_pid}" "${reg_pgid}" "owner_registered" "${act}" "${reg_owner}" || true
          else
            __gsd_emit_reap_row "${ts}" "${reg_pid}" "${reg_pgid}" "owner_registered" "audit_only" "${reg_owner}" || true
          fi
          continue
        fi
        __gsd_emit_reap_row "${ts}" "${reg_pid}" "${reg_pgid}" "foreign_outside_pgid" "audit_only" "${reg_owner}" || true
      done
    fi
    return 0
  ) || true
  return 0
}

__gsd_read_owner_id() {
  local f="${1:-}"
  [[ -z "${f}" || ! -r "${f}" ]] && return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${f}" 2>/dev/null <<'PY' || true
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as fh:
        data = json.load(fh)
    val = data.get('owner_agent_id', '')
    if isinstance(val, str):
        print(val)
except Exception:
    pass
PY
    return 0
  fi
  grep -oE '"owner_agent_id"[[:space:]]*:[[:space:]]*"[^"]*"' "${f}" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*"owner_agent_id"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/' \
    || true
}

__gsd_reap_pid() {
  local pid="${1:-}"
  [[ -z "${pid}" || ! "${pid}" =~ ^[0-9]+$ ]] && { echo "noop"; return 0; }
  kill -0 "${pid}" 2>/dev/null || { echo "noop"; return 0; }
  kill -TERM "${pid}" 2>/dev/null || true
  local grace="${__GSD_REAPER_GRACE_SECONDS}"
  [[ ! "${grace}" =~ ^[0-9]+$ ]] && grace=10
  local waited=0
  while (( waited < grace )); do
    kill -0 "${pid}" 2>/dev/null || { echo "sigterm"; return 0; }
    sleep 1 2>/dev/null || true
    waited=$(( waited + 1 ))
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "${pid}" 2>/dev/null || true
    sleep 1 2>/dev/null || true
    echo "sigkill"
    return 0
  fi
  echo "sigterm"
  return 0
}

__gsd_emit_reap_row() {
  local ts="${1:-}" pid="${2:-0}" pgid="${3:-0}" class="${4:-unknown}" action="${5:-noop}" owner="${6:-}"
  local owner_field
  if [[ -z "${owner}" ]]; then
    owner_field='null'
  else
    local safe_owner="${owner//\"/_}"
    safe_owner="${safe_owner//$'\n'/ }"
    owner_field="\"${safe_owner}\""
  fi
  mkdir -p "${__GSD_METRICS_DIR}" 2>/dev/null || true
  printf '{"ts":"%s","event":"bg_reap","pid":%d,"pgid":%d,"class":"%s","action":"%s","owner_agent_id":%s}\n' \
    "${ts}" "${pid}" "${pgid}" "${class}" "${action}" "${owner_field}" \
    >> "${__GSD_WRAPPER_EVENTS_LOG}" 2>/dev/null || true
  return 0
}

gsd_main() {
  if [[ "${REVHARNESS_PARALLEL_QUIESCE:-0}" == "1" ]]; then
    return 0   # PARALLEL_QUIESCE active; suppress all side effects (HSDI Phase B T-B-1)
  fi
  __gsd_run_with_watchdog "idle_reminder"      gsd_idle_reminder      || true
  __gsd_run_with_watchdog "wallclock_hardstop" gsd_wallclock_hardstop || true
  __gsd_run_with_watchdog "bg_job_reaper"      gsd_bg_job_reaper      || true
  __gsd_run_with_watchdog "dirty_exit_stash"   gsd_dirty_exit_stash   || true
  __gsd_run_with_watchdog "silent_bail_emit"   gsd_emit_silent_bail   || true
  return 0
}

gsd_self_test() {
  local ok=0 fail=0 fn
  for fn in gsd_idle_reminder gsd_wallclock_hardstop gsd_dirty_exit_stash \
            gsd_bg_job_reaper gsd_emit_silent_bail gsd_main \
            __gsd_emit_timeout_row __gsd_run_with_watchdog \
            __gsd_read_owner_id __gsd_reap_pid __gsd_emit_reap_row; do
    if declare -F "${fn}" >/dev/null 2>&1; then
      echo "[self-test] OK  function defined: ${fn}"
      ok=$(( ok + 1 ))
    else
      echo "[self-test] DIAG missing function: ${fn}"
      fail=$(( fail + 1 ))
    fi
  done
  echo "[self-test] summary ok=${ok} diag=${fail}"
  return 0
}

# Dispatch.
# Source-vs-exec guard: only dispatch when EXECUTED, not when SOURCED.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --self-test) gsd_self_test; exit 0 ;;
    --help|-h)
      echo "agent-graceful-shutdown.sh — HSDI Phase A fail-open EXIT-trap hook."
      exit 0 ;;
    *)
      # HSDI Phase A recovery guardrail (R3 §7): when an orchestrator
      # explicitly quiesces parallel agents during a recovery/restore window,
      # skip side-effecting gsd_main (auto-stash, reaper, idle-reminder, etc.).
      # --self-test and --help remain reachable for diagnostics. HSDI Phase B
      # will formalise this gate; this is the interim recovery-window shim.
      if [[ "${REVHARNESS_PARALLEL_QUIESCE:-0}" == "1" ]]; then
        exit 0
      fi
      gsd_main; exit 0 ;;
  esac
fi
