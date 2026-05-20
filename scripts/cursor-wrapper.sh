#!/usr/bin/env bash
#
# cursor-wrapper.sh - Canonical Cursor CLI wrapper (round 2)
#
# 目的:
#   Cursor CLI (binary: `agent`) を RevHarness の role 契約で運用する。
#   Cursor の **公式 mode 用語** (ask / agent / --force) に align し、
#   role 名は false advertising を避ける。
#
# 公式 Cursor docs (cursor.com/docs/cli/reference/parameters) に基づく:
#   `agent -p` (default agent mode) は **write/shell 含む全ツールにアクセス可能**。
#   true read-only にしたい場合は `--mode ask` を強制する必要がある。
#   `--force/--yolo` は file-write gate ではなく command 自動承認 (shell command の auto-approval)。
#
# 使用方法:
#   cat prompt.md | ./scripts/cursor-wrapper.sh --role ask --stdin   # 真の read-only
#   cat prompt.md | ./scripts/cursor-wrapper.sh --role agent --stdin # write 可、command は個別承認
#   cat prompt.md | ./scripts/cursor-wrapper.sh --role yolo --stdin  # write 可 + command auto-approval
#   ./scripts/cursor-wrapper.sh --role ask --dry-run
#
# Roles:
#   ask   (default): --mode ask を強制。Cursor 公式が唯一保証する read-only 経路。
#   agent:           Cursor default agent mode。write 可能。command は Cursor 側で個別承認。
#   yolo:            agent + --force。command auto-approval まで含む。明示 opt-in 専用。
#
# Fail-closed:
#   - agent binary 不在
#   - 未知 role
#   - duplicate --role
#   - --stdin 不在の non-dry-run invocation
#   - vendoring 検出 (_canonical-guard.sh)
#
set -euo pipefail

readonly DEFAULT_ROLE="ask"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/_canonical-guard.sh
source "${SCRIPT_DIR}/_canonical-guard.sh"
rev_harness_assert_canonical_root cursor-wrapper

LOG_PREFIX="${CURSOR_WRAPPER_LOG_PREFIX:-cursor-wrapper}"
WRAPPER_HELP=false
DRY_RUN=false
STDIN_FLAG=false
ROLE_SEEN=false
RESOLVED_ROLE=""
ROLE_SOURCE=""
CURSOR_MODE=""        # "ask" or "" (default = agent mode)
CURSOR_FORCE=false
CURSOR_OUTPUT_FORMAT="text"
METRICS_ACTIVE=false
METRICS_EMITTED=false
METRICS_STDERR_CAPTURE=""
METRICS_STARTED_MS=""
METRICS_TIMESTAMP=""
METRICS_DELEGATION_ID=""
METRICS_CHILD_PID=""
METRICS_EXITING_FROM_SIGNAL=false
RULES_FILES_PRESENT=false
RULES_SELFCHECK_STATUS="unimplemented"
ASK_PRE_TRACKED=""
ASK_PRE_UNTRACKED=""

log_info()  { echo "[${LOG_PREFIX}] $*" >&2; }
log_error() { echo "[${LOG_PREFIX}][ERROR] $*" >&2; }

fail() {
  log_error "$*"
  exit 1
}

now_ms() {
  if [[ -n "${CURSOR_WRAPPER_FAKE_NOW_MS:-}" ]]; then
    echo "${CURSOR_WRAPPER_FAKE_NOW_MS}"
  else
    perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null \
      || python3 -c 'import time; print(int(time.time()*1000))'
  fi
}

generate_delegation_id() {
  if [[ -n "${CURSOR_WRAPPER_FAKE_DELEGATION_ID:-}" ]]; then
    echo "${CURSOR_WRAPPER_FAKE_DELEGATION_ID}"
  else
    if command -v uuidgen >/dev/null 2>&1; then
      uuidgen | tr 'A-Z' 'a-z'
    else
      python3 -c 'import uuid; print(uuid.uuid4())'
    fi
  fi
}

ask_git_snapshot_tracked() {
  command -v git >/dev/null 2>&1 || { echo "NA"; return 0; }
  git -C "${PROJECT_ROOT}" status --porcelain=v1 2>/dev/null || echo "NA"
}

ask_git_snapshot_untracked() {
  command -v git >/dev/null 2>&1 || { echo "NA"; return 0; }
  git -C "${PROJECT_ROOT}" ls-files --others --exclude-standard 2>/dev/null || echo "NA"
}

capture_ask_readonly_pre_snapshot() {
  [[ "${RESOLVED_ROLE}" == "ask" ]] || return 0
  [[ "${DRY_RUN}" != "true" ]] || return 0

  ASK_PRE_TRACKED="$(ask_git_snapshot_tracked)"
  ASK_PRE_UNTRACKED="$(ask_git_snapshot_untracked)"
  if [[ "${ASK_PRE_TRACKED}" == "NA" || "${ASK_PRE_UNTRACKED}" == "NA" ]]; then
    log_info "[ask-readonly-enforce] advisory: git snapshot unavailable before invocation; enforcement will be skipped"
  fi
}

enforce_ask_readonly_post_snapshot() {
  [[ "${RESOLVED_ROLE}" == "ask" ]] || return 0
  [[ "${DRY_RUN}" != "true" ]] || return 0

  local post_tracked post_untracked
  post_tracked="$(ask_git_snapshot_tracked)"
  post_untracked="$(ask_git_snapshot_untracked)"

  if [[ "${ASK_PRE_TRACKED}" == "NA" || "${ASK_PRE_UNTRACKED}" == "NA" \
     || "${post_tracked}" == "NA" || "${post_untracked}" == "NA" ]]; then
    log_info "[ask-readonly-enforce] advisory: git snapshot unavailable; enforcement skipped"
    return 0
  fi

  if [[ "${post_tracked}" != "${ASK_PRE_TRACKED}" || "${post_untracked}" != "${ASK_PRE_UNTRACKED}" ]]; then
    log_error "[ask-readonly-enforce] BLOCK: --role ask produced workspace changes (read-only invariant violated)"
    log_error "[ask-readonly-enforce] tracked diff:"
    diff <(echo "${ASK_PRE_TRACKED}") <(echo "${post_tracked}") >&2 || true
    log_error "[ask-readonly-enforce] untracked diff:"
    diff <(echo "${ASK_PRE_UNTRACKED}") <(echo "${post_untracked}") >&2 || true
    return 2
  fi

  return 0
}

init_metrics_context() {
  [[ -n "${METRICS_STARTED_MS}" ]] && return 0
  METRICS_STARTED_MS="$(now_ms)"
  METRICS_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  METRICS_DELEGATION_ID="$(generate_delegation_id)"
}

preflight_rules_check() {
  local agents_md_present=false
  local critical_rule_present=false

  [[ -f "${PROJECT_ROOT}/AGENTS.md" ]] && agents_md_present=true
  [[ -f "${PROJECT_ROOT}/.cursor/rules/revharness-critical.mdc" ]] && critical_rule_present=true

  if [[ "${agents_md_present}" == "true" && "${critical_rule_present}" == "true" ]]; then
    RULES_FILES_PRESENT=true
  else
    RULES_FILES_PRESENT=false
    log_info "warning: rules files not present (AGENTS.md=${agents_md_present}, critical.mdc=${critical_rule_present})"
  fi
}

print_help() {
  cat <<'EOF'
Usage:
  cursor-wrapper.sh --role <ask|agent|yolo> [--stdin] [--dry-run]

Roles (aligned to Cursor official mode terminology):
  ask   (default)  --mode ask を強制。Cursor 公式が唯一保証する read-only 経路。
                   ファイル書き込み・shell 実行はしない。repo Q&A / 調査 / proposal 出し向け。
  agent            Cursor default agent mode (`agent -p`)。write/shell 含む全ツールアクセス。
                   個別 command は Cursor 側で承認 prompt が出る (非 --force)。
  yolo             agent + --force。command auto-approval (危険、明示 opt-in)。
                   CI / 自動化向け。

Flags:
  --stdin         stdin から prompt を読む (cursor agent には -p で渡す)
  --dry-run       実 cursor を呼ばず、role 解決と metric 出力だけ行う
  --help          このヘルプを表示

Environment:
  REV_HARNESS_METRICS_DISABLE=1   delegation metric JSONL を抑制
  CURSOR_WRAPPER_AGENT_BIN=path   agent binary path を明示 (test/fixture 用)

Safety notes (per https://cursor.com/docs/cli/reference/parameters):
  * `agent -p` (default mode) は write/shell tool に full access。
  * `--force/--yolo` は file-write の gate ではなく command auto-approval。
  * 真の read-only にしたい場合は --mode ask (role=ask) を使うこと。
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        [[ $# -ge 2 ]] || fail "--role requires a value"
        if [[ "${ROLE_SEEN}" == "true" ]]; then
          fail "--role specified more than once (role escape rejected)"
        fi
        ROLE_SEEN=true
        RESOLVED_ROLE="$2"
        ROLE_SOURCE="cli-flag"
        shift 2
        ;;
      --stdin)
        STDIN_FLAG=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --help|-h)
        WRAPPER_HELP=true
        shift
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
}

resolve_role() {
  if [[ -z "${RESOLVED_ROLE}" ]]; then
    RESOLVED_ROLE="${DEFAULT_ROLE}"
    ROLE_SOURCE="default"
  fi
  case "${RESOLVED_ROLE}" in
    ask)
      CURSOR_MODE="ask"
      CURSOR_FORCE=false
      ;;
    agent)
      CURSOR_MODE=""
      CURSOR_FORCE=false
      ;;
    yolo)
      CURSOR_MODE=""
      CURSOR_FORCE=true
      ;;
    *)
      fail "unknown role: ${RESOLVED_ROLE} (allowed: ask | agent | yolo)"
      ;;
  esac
}

resolve_agent_binary() {
  local bin
  if [[ -n "${CURSOR_WRAPPER_AGENT_BIN:-}" ]]; then
    bin="${CURSOR_WRAPPER_AGENT_BIN}"
    [[ -x "${bin}" ]] || fail "CURSOR_WRAPPER_AGENT_BIN not executable: ${bin}"
    echo "${bin}"
    return 0
  fi
  for candidate in "${HOME}/.local/bin/agent" "/usr/local/bin/agent"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  if command -v agent >/dev/null 2>&1; then
    command -v agent
    return 0
  fi
  fail "cursor agent binary not found (searched: \$HOME/.local/bin/agent, /usr/local/bin/agent, PATH). Install: curl https://cursor.com/install -fsS | bash"
}

emit_delegation_metric() {
  local exit_code="$1"
  local stderr_file="${2:-}"
  local completed_ms duration_ms

  [[ "${REV_HARNESS_METRICS_DISABLE:-}" == "1" ]] && return 0
  [[ "${METRICS_ACTIVE}" == "true" ]] || return 0
  [[ "${METRICS_EMITTED}" == "false" ]] || return 0
  METRICS_EMITTED=true

  init_metrics_context
  completed_ms="$(now_ms)"
  duration_ms=$((completed_ms - METRICS_STARTED_MS))
  [[ "${duration_ms}" -gt 0 ]] || duration_ms=1

  local wrapper_role_label
  wrapper_role_label="cursor-${RESOLVED_ROLE}"

  local cursor_force_emit
  if [[ "${CURSOR_FORCE}" == "true" ]]; then
    cursor_force_emit="--force"
  else
    cursor_force_emit=""
  fi

  jq -cn \
    --argjson schema_version 1 \
    --arg delegation_id "${METRICS_DELEGATION_ID}" \
    --arg timestamp "${METRICS_TIMESTAMP}" \
    --arg wrapper_role "${wrapper_role_label}" \
    --arg vendor "cursor" \
    --argjson exit_code "${exit_code}" \
    --argjson duration_ms "${duration_ms}" \
    --argjson dry_run "${DRY_RUN}" \
    --argjson cursor_rules_files_present "${RULES_FILES_PRESENT}" \
    --arg cursor_rules_selfcheck_status "${RULES_SELFCHECK_STATUS}" \
    --arg cursor_force "${cursor_force_emit}" \
    --arg cursor_mode "${CURSOR_MODE}" \
    '{
      schema_version: $schema_version,
      delegation_id: $delegation_id,
      timestamp: $timestamp,
      wrapper_role: $wrapper_role,
      vendor: $vendor,
      specialty: null,
      canonical_role: null,
      manifest_hash: null,
      exit_code: $exit_code,
      duration_ms: $duration_ms,
      tokens_in: null,
      tokens_out: null,
      total_tokens: null,
      dry_run: $dry_run,
      specialty_status: "none",
      cursor_force_flag: $cursor_force,
      cursor_mode: $cursor_mode,
      cursor_rules_files_present: $cursor_rules_files_present,
      cursor_rules_selfcheck_status: $cursor_rules_selfcheck_status
    }' | sed 's/^/REV_HARNESS_DELEGATION_METRIC /' >&2
}

cleanup_metrics_capture() {
  if [[ -n "${METRICS_STDERR_CAPTURE}" && -f "${METRICS_STDERR_CAPTURE}" ]]; then
    /bin/rm -f "${METRICS_STDERR_CAPTURE}"
  fi
}

on_exit() {
  local exit_code=$?
  emit_delegation_metric "${exit_code}" "${METRICS_STDERR_CAPTURE:-}"
  cleanup_metrics_capture
}
trap on_exit EXIT

forward_signal() {
  local signal_name="$1"
  METRICS_EXITING_FROM_SIGNAL=true
  if [[ -n "${METRICS_CHILD_PID}" ]] && kill -0 "${METRICS_CHILD_PID}" 2>/dev/null; then
    kill "-${signal_name}" "${METRICS_CHILD_PID}" 2>/dev/null || true
    wait "${METRICS_CHILD_PID}" 2>/dev/null || true
  fi
  emit_delegation_metric 130 "${METRICS_STDERR_CAPTURE:-}"
  cleanup_metrics_capture
  exit 130
}
trap 'forward_signal INT'  INT
trap 'forward_signal TERM' TERM

main() {
  parse_args "$@"

  if [[ "${WRAPPER_HELP}" == "true" ]]; then
    print_help
    exit 0
  fi

  preflight_rules_check
  resolve_role
  METRICS_ACTIVE=true
  init_metrics_context

  log_info "Role: ${RESOLVED_ROLE} (source: ${ROLE_SOURCE})"
  log_info "Mode: ${CURSOR_MODE:-agent(default)} / Force: ${CURSOR_FORCE} / DryRun: ${DRY_RUN}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "Status: validated (dry-run, agent not invoked)"
    exit 0
  fi

  local agent_bin
  agent_bin="$(resolve_agent_binary)"
  log_info "Agent: ${agent_bin}"

  local -a agent_args=("-p" "--output-format" "${CURSOR_OUTPUT_FORMAT}")
  if [[ -n "${CURSOR_MODE}" ]]; then
    agent_args+=("--mode" "${CURSOR_MODE}")
  fi
  if [[ "${CURSOR_FORCE}" == "true" ]]; then
    agent_args+=("--force")
  fi

  local prompt
  if [[ "${STDIN_FLAG}" == "true" ]]; then
    prompt="$(cat -)"
  else
    fail "--stdin is required (argv-prompt mode not supported by this wrapper)"
  fi

  capture_ask_readonly_pre_snapshot

  METRICS_STDERR_CAPTURE="$(mktemp "${TMPDIR:-/tmp}/cursor-wrapper-stderr.XXXXXX")"
  set +e
  "${agent_bin}" "${agent_args[@]}" "${prompt}" 2> "${METRICS_STDERR_CAPTURE}" &
  METRICS_CHILD_PID=$!
  wait "${METRICS_CHILD_PID}"
  local status=$?
  set -e

  if ! enforce_ask_readonly_post_snapshot; then
    status=2
  fi

  if [[ -s "${METRICS_STDERR_CAPTURE}" ]]; then
    cat "${METRICS_STDERR_CAPTURE}" >&2
  fi

  exit "${status}"
}

main "$@"
