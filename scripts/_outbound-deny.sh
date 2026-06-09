#!/usr/bin/env bash
# _outbound-deny.sh
#
# Detect whether Codex/Claude wrappers were invoked from a Cursor agent process
# tree. The public assertion exits fail-closed only when a cursor-agent parent
# is detected; process inspection failures leave the normal wrapper path intact.
#
# Public function:
#   rev_harness_assert_no_cursor_parent <wrapper_name>
#
# Environment:
#   REV_HARNESS_CURSOR_OUTBOUND_ALLOW=1  explicit opt-in escape hatch
#   REVHARNESS_TEST_HARNESS=1 and REV_HARNESS_PARENT_PROCESS_TEST=<binary>
#     test-only parent-process override

if [[ -n "${_REV_HARNESS_OUTBOUND_DENY_LOADED:-}" ]]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi
readonly _REV_HARNESS_OUTBOUND_DENY_LOADED=1

_rev_harness_parent_binary() {
  if [[ -n "${REV_HARNESS_PARENT_PROCESS_TEST:-}" && "${REVHARNESS_TEST_HARNESS:-}" == "1" ]]; then
    printf '%s\n' "${REV_HARNESS_PARENT_PROCESS_TEST}"
    return 0
  fi

  local pid="${PPID:-}"
  local depth=0
  local comm=""

  while [[ "${depth}" -lt 16 ]]; do
    [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] || break

    comm="$(ps -o comm= -p "${pid}" 2>/dev/null | tr -d '[:space:]')" || comm=""
    if [[ -n "${comm}" ]]; then
      printf '%s\n' "${comm}"
    fi

    pid="$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d '[:space:]')" || break
    depth=$((depth + 1))
  done
}

rev_harness_assert_no_cursor_parent() {
  local wrapper_name="${1:-unknown-wrapper}"
  local chain=""

  if [[ "${REV_HARNESS_CURSOR_OUTBOUND_ALLOW:-}" == "1" ]]; then
    return 0
  fi

  chain="$(_rev_harness_parent_binary)"
  if printf '%s\n' "${chain}" | grep -qE '(^|/)cursor-agent$'; then
    printf '[%s][outbound-deny] BLOCK: invoked from a cursor-agent process tree.\n' "${wrapper_name}" >&2
    printf '[%s][outbound-deny] Cross-family delegation from Cursor is forbidden.\n' "${wrapper_name}" >&2
    printf '[%s][outbound-deny] If this is intentional, set REV_HARNESS_CURSOR_OUTBOUND_ALLOW=1.\n' "${wrapper_name}" >&2
    exit 1
  fi
}
