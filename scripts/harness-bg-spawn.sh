#!/usr/bin/env bash
# scripts/harness-bg-spawn.sh — HSDI Phase A T-21.0-5
#
# Spawn a long-running background job in its OWN process group and write
# a registration record that the gsd_bg_job_reaper (T-21.0-3) can read to
# decide whether the bg job belongs to the current agent.
#
# Contract (read by T-21.0-3 reaper):
#   - Registration file: ${HARNESS_BG_JOBS_DIR}/<pid>.json
#   - Required fields  : pid, pgid, task_id, owner_agent_id, started_ts,
#                        command, started_at_epoch
#   - Atomic write     : write to <pid>.json.tmp, then mv -f to <pid>.json
#   - Process group    : child becomes a session/pgid leader so the reaper
#                        can distinguish foreign_outside_pgid vs
#                        owner_registered solely from ps -o pgid=.
#
# Fail-open: any internal error returns non-zero with a diagnostic but
# does NOT leave a partial registration file behind.
#
# Usage:
#   harness-bg-spawn.sh --task-id <id> --owner <agent_id> -- <command...>
#
# Env overrides:
#   HARNESS_BG_JOBS_DIR    default .agent/runtime/bg_jobs/ under repo root
#   HARNESS_DEFAULT_AGENT_ID
#                          default owner if --owner is omitted; falls back
#                          to REVHARNESS_AGENT_ID, then AGENT_ID, then
#                          "unknown".
set -u
set -o pipefail 2>/dev/null || true

__hbs_script_dir() {
  local src="${BASH_SOURCE[0]}"
  case "$src" in
    */*) (cd "${src%/*}" && pwd -P) ;;
    *) pwd -P ;;
  esac
}
__HBS_SCRIPT_DIR="$(__hbs_script_dir)"
__HBS_REPO_ROOT="$(cd "${__HBS_SCRIPT_DIR}/.." 2>/dev/null && pwd -P)"

__hbs_usage() {
  cat <<'USAGE'
harness-bg-spawn.sh — spawn a bg job and register it for the graceful-shutdown reaper.

Usage:
  scripts/harness-bg-spawn.sh --task-id <id> --owner <agent_id> -- <command...>

Options:
  --task-id <id>     Task identifier to stamp into the registration file.
  --owner   <id>     Owning agent identifier (stamped as owner_agent_id).
                     If omitted, HARNESS_DEFAULT_AGENT_ID / REVHARNESS_AGENT_ID
                     / AGENT_ID / "unknown" is used in that order.
  -h, --help         Show this help.

Environment:
  HARNESS_BG_JOBS_DIR        Registration directory (default
                             <repo>/.agent/runtime/bg_jobs).
  HARNESS_DEFAULT_AGENT_ID   Default owner_agent_id when --owner is absent.

Output:
  Prints the spawned PID on stdout as a single line. Caller may capture it
  with $(scripts/harness-bg-spawn.sh ...).

Registration JSON (<pid>.json) schema:
  pid, pgid, task_id, owner_agent_id, started_ts, command, started_at_epoch
USAGE
}

__hbs_err() { printf 'harness-bg-spawn: %s\n' "$*" >&2; }

# --- argument parsing ---
TASK_ID=""
OWNER_ID=""
CMD_ARGS=()
seen_dashdash=0
while [[ $# -gt 0 ]]; do
  if [[ "${seen_dashdash}" -eq 1 ]]; then
    CMD_ARGS+=("$1"); shift; continue
  fi
  case "$1" in
    --task-id)
      [[ $# -ge 2 ]] || { __hbs_err "--task-id needs a value"; exit 2; }
      TASK_ID="$2"; shift 2 ;;
    --task-id=*) TASK_ID="${1#*=}"; shift ;;
    --owner)
      [[ $# -ge 2 ]] || { __hbs_err "--owner needs a value"; exit 2; }
      OWNER_ID="$2"; shift 2 ;;
    --owner=*) OWNER_ID="${1#*=}"; shift ;;
    -h|--help) __hbs_usage; exit 0 ;;
    --) seen_dashdash=1; shift ;;
    *)
      __hbs_err "unknown argument: $1 (did you forget '--' before the command?)"
      exit 2 ;;
  esac
done

if [[ -z "${TASK_ID}" ]]; then
  __hbs_err "--task-id is required"; exit 2
fi
if [[ -z "${OWNER_ID}" ]]; then
  OWNER_ID="${HARNESS_DEFAULT_AGENT_ID:-${REVHARNESS_AGENT_ID:-${AGENT_ID:-unknown}}}"
fi
if [[ ${#CMD_ARGS[@]} -eq 0 ]]; then
  __hbs_err "no command supplied after '--'"
  exit 2
fi

# Sanitize identifiers (matches gsd hook sanitizer).
__hbs_sanitize() {
  local v="${1:-}"
  v="${v//[^A-Za-z0-9._\/-]/_}"
  [[ -n "${v}" ]] || v="unknown"
  printf '%s' "${v}"
}
TASK_ID="$(__hbs_sanitize "${TASK_ID}")"
OWNER_ID="$(__hbs_sanitize "${OWNER_ID}")"

BG_DIR="${HARNESS_BG_JOBS_DIR:-${__HBS_REPO_ROOT}/.agent/runtime/bg_jobs}"
if ! mkdir -p "${BG_DIR}" 2>/dev/null; then
  __hbs_err "cannot create registration dir: ${BG_DIR}"
  exit 3
fi

# --- pick a setsid mechanism (macOS lacks /usr/bin/setsid) ---
__hbs_have_python3=0
command -v python3 >/dev/null 2>&1 && __hbs_have_python3=1
__hbs_have_perl=0
command -v perl >/dev/null 2>&1 && __hbs_have_perl=1
__hbs_have_setsid=0
command -v setsid >/dev/null 2>&1 && __hbs_have_setsid=1

if [[ "${__hbs_have_python3}" -eq 0 && "${__hbs_have_perl}" -eq 0 && "${__hbs_have_setsid}" -eq 0 ]]; then
  __hbs_err "need python3, perl, or setsid for process-group isolation"
  exit 4
fi

# Build a sentinel marker file the spawner can write its pid+pgid into
# without racing the foreground stdout channel. This avoids relying on
# the child's first stdout byte to find PID — robust under nohup.
HBS_TMP_PIDFILE="$(mktemp -t harness-bg-spawn-pidXXXXXX 2>/dev/null || mktemp "${TMPDIR:-/tmp}/harness-bg-spawn-pidXXXXXX")"
trap 'rm -f "${HBS_TMP_PIDFILE}" 2>/dev/null || true' EXIT

# Quote command argv for inclusion in the JSON "command" field.
# We do NOT eval the joined string; only used as descriptive metadata.
__hbs_join_cmd() {
  local out="" a
  for a in "$@"; do
    if [[ -z "${out}" ]]; then
      out="${a}"
    else
      out+=" ${a}"
    fi
  done
  printf '%s' "${out}"
}
CMD_JOINED="$(__hbs_join_cmd "${CMD_ARGS[@]}")"

# JSON-string-escape helper for the command field.
__hbs_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '%s' "${s}"
}

# --- spawn the child in its own session/pgid ---
# Strategy: launch a tiny supervisor in its own session. The supervisor
# writes its own PID/PGID to HBS_TMP_PIDFILE, closes stdio, then execs
# the user command. The parent reads pid+pgid back from the pidfile.
#
# IMPORTANT: the supervisor is the actual PID we register. exec replaces
# its image with the user command, so registration PID == running PID.

PIDFILE="${HBS_TMP_PIDFILE}"
export __HBS_CHILD_PIDFILE="${PIDFILE}"

if [[ "${__hbs_have_python3}" -eq 1 ]]; then
  # Python supervisor: setsid + write pidfile + exec.
  nohup python3 - "${PIDFILE}" "${CMD_ARGS[@]}" >/dev/null 2>&1 <<'PY' &
import os, sys
pidfile = sys.argv[1]
argv = sys.argv[2:]
try:
    os.setsid()
except OSError:
    pass
pid = os.getpid()
try:
    pgid = os.getpgid(0)
except OSError:
    pgid = pid
try:
    tmp = pidfile + ".w"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("%d %d\n" % (pid, pgid))
    os.replace(tmp, pidfile)
except OSError:
    sys.exit(7)
# Detach stdio so parent shell's pipeline does not wait on us.
for fd in (0, 1, 2):
    try:
        nullfd = os.open(os.devnull, os.O_RDWR)
        os.dup2(nullfd, fd)
        if nullfd > 2:
            os.close(nullfd)
    except OSError:
        pass
try:
    os.execvp(argv[0], argv)
except OSError as e:
    sys.stderr.write("exec failed: %s\n" % e)
    sys.exit(127)
PY
elif [[ "${__hbs_have_perl}" -eq 1 ]]; then
  nohup perl - "${PIDFILE}" "${CMD_ARGS[@]}" >/dev/null 2>&1 <<'PL' &
use strict; use warnings; use POSIX ();
my $pidfile = shift @ARGV;
POSIX::setsid();
my $pid = $$;
my $pgid = POSIX::getpgrp();
open(my $fh, '>', "$pidfile.w") or exit(7);
print $fh "$pid $pgid\n";
close($fh);
rename("$pidfile.w", $pidfile) or exit(7);
open(STDIN, '<', '/dev/null');
open(STDOUT, '>', '/dev/null');
open(STDERR, '>', '/dev/null');
exec { $ARGV[0] } @ARGV;
exit(127);
PL
else
  # setsid fallback (Linux). Child writes its pid+pgid then execs.
  nohup setsid bash -c '
    printf "%d %d\n" "$$" "$(ps -o pgid= -p $$ | tr -d " ")" > "$1.w" \
      && mv -f "$1.w" "$1"
    shift
    exec "$@"
  ' _ "${PIDFILE}" "${CMD_ARGS[@]}" >/dev/null 2>&1 &
fi
# The shell-level $! is the immediate background pid — but with python3 /
# perl as the supervisor, that IS the supervisor pid (which becomes the
# user command after exec). We re-confirm via the pidfile to be sure.
SHELL_BG_PID=$!

# --- wait for pidfile to be populated ---
__hbs_wait_pidfile() {
  local f="$1" max_iters="${2:-200}" i=0
  while (( i < max_iters )); do
    if [[ -s "${f}" ]]; then
      return 0
    fi
    # 25 ms via python3 if available, else 1 s coarse fallback.
    if [[ "${__hbs_have_python3}" -eq 1 ]]; then
      python3 -c 'import time;time.sleep(0.025)' 2>/dev/null || sleep 1
    else
      sleep 1
    fi
    i=$(( i + 1 ))
  done
  return 1
}

if ! __hbs_wait_pidfile "${PIDFILE}" 200; then
  __hbs_err "child supervisor did not report pid/pgid within timeout"
  # best-effort cleanup of the orphan supervisor
  [[ -n "${SHELL_BG_PID:-}" ]] && kill -KILL "${SHELL_BG_PID}" 2>/dev/null || true
  exit 5
fi

read -r CHILD_PID CHILD_PGID < "${PIDFILE}" || true
if [[ -z "${CHILD_PID:-}" || ! "${CHILD_PID}" =~ ^[0-9]+$ ]]; then
  __hbs_err "could not parse child pid from supervisor"
  exit 5
fi
if [[ -z "${CHILD_PGID:-}" || ! "${CHILD_PGID}" =~ ^[0-9]+$ ]]; then
  # Re-derive via ps as a last-resort.
  CHILD_PGID="$(ps -o pgid= -p "${CHILD_PID}" 2>/dev/null | tr -d ' ')"
fi
if [[ -z "${CHILD_PGID:-}" || ! "${CHILD_PGID}" =~ ^[0-9]+$ ]]; then
  __hbs_err "could not resolve pgid for pid=${CHILD_PID}"
  exit 5
fi

# --- emit registration JSON atomically ---
STARTED_TS=""
if command -v python3 >/dev/null 2>&1; then
  STARTED_TS="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' 2>/dev/null || true)"
fi
[[ -n "${STARTED_TS}" ]] || STARTED_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo 1970-01-01T00:00:00Z)"
STARTED_EPOCH="$(date -u +%s 2>/dev/null || echo 0)"
[[ "${STARTED_EPOCH}" =~ ^[0-9]+$ ]] || STARTED_EPOCH=0

REG_FILE="${BG_DIR}/${CHILD_PID}.json"
REG_TMP="${REG_FILE}.tmp.$$"
CMD_ESCAPED="$(__hbs_json_escape "${CMD_JOINED}")"
TASK_ESCAPED="$(__hbs_json_escape "${TASK_ID}")"
OWNER_ESCAPED="$(__hbs_json_escape "${OWNER_ID}")"
TS_ESCAPED="$(__hbs_json_escape "${STARTED_TS}")"

# Schema-pinned field order; no extra fields.
if ! printf '{"pid":%d,"pgid":%d,"task_id":"%s","owner_agent_id":"%s","started_ts":"%s","command":"%s","started_at_epoch":%d}\n' \
  "${CHILD_PID}" "${CHILD_PGID}" "${TASK_ESCAPED}" "${OWNER_ESCAPED}" \
  "${TS_ESCAPED}" "${CMD_ESCAPED}" "${STARTED_EPOCH}" \
  > "${REG_TMP}" 2>/dev/null; then
  __hbs_err "failed to write registration tmp file"
  rm -f "${REG_TMP}" 2>/dev/null || true
  exit 6
fi
if ! mv -f "${REG_TMP}" "${REG_FILE}" 2>/dev/null; then
  __hbs_err "failed to atomically rename registration file"
  rm -f "${REG_TMP}" 2>/dev/null || true
  exit 6
fi

# Emit the spawned PID to stdout as the documented contract.
printf '%s\n' "${CHILD_PID}"
exit 0
