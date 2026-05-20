#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CODEX_WRAPPER="${REPO_ROOT}/scripts/codex-wrapper.sh"
CLAUDE_WRAPPER="${REPO_ROOT}/scripts/claude-wrapper.sh"
OUTBOUND_DENY="${REPO_ROOT}/scripts/_outbound-deny.sh"
PASS=0
FAIL=0

record_pass() {
  printf 'PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

record_fail() {
  printf 'FAIL: %s\n' "$1"
  FAIL=$((FAIL + 1))
}

assert_exit_contains() {
  local name="$1"
  local expected_exit="$2"
  local expected_substring="$3"
  shift 3
  local out=""
  local rc=0

  out=$("$@" 2>&1)
  rc=$?
  if [[ "${rc}" == "${expected_exit}" && "${out}" == *"${expected_substring}"* ]]; then
    record_pass "${name}"
  else
    record_fail "${name} (exit=${rc}, expected=${expected_exit}; missing=${expected_substring}; output=${out})"
  fi
}

assert_exit_not_contains() {
  local name="$1"
  local expected_exit="$2"
  local rejected_substring="$3"
  shift 3
  local out=""
  local rc=0

  out=$("$@" 2>&1)
  rc=$?
  if [[ "${rc}" == "${expected_exit}" && "${out}" != *"${rejected_substring}"* ]]; then
    record_pass "${name}"
  else
    record_fail "${name} (exit=${rc}, expected=${expected_exit}; rejected=${rejected_substring}; output=${out})"
  fi
}

assert_cmd() {
  local name="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    record_pass "${name}"
  else
    record_fail "${name}"
  fi
}

assert_shellcheck() {
  local name="$1"
  local path="$2"

  if ! command -v shellcheck >/dev/null 2>&1; then
    record_fail "${name} (shellcheck not found)"
    return
  fi
  if shellcheck "${path}" >/dev/null 2>&1; then
    record_pass "${name}"
  else
    record_fail "${name}"
  fi
}

# 1. Codex normal path with no test hook.
assert_exit_contains "codex normal dry-run works without parent test hook" 0 "Dry Run: true" \
  "${CODEX_WRAPPER}" --role coder --dry-run

# 2. Codex fail-closed when the test harness reports cursor-agent parent.
assert_exit_contains "codex blocks cursor-agent parent" 1 "BLOCK" \
  env REVHARNESS_TEST_HARNESS=1 REV_HARNESS_PARENT_PROCESS_TEST=cursor-agent \
  "${CODEX_WRAPPER}" --role coder --dry-run

# 3. Codex escape hatch explicitly permits intentional outbound delegation.
assert_exit_contains "codex allow env bypasses cursor-agent parent deny" 0 "Dry Run: true" \
  env REVHARNESS_TEST_HARNESS=1 REV_HARNESS_PARENT_PROCESS_TEST=cursor-agent REV_HARNESS_CURSOR_OUTBOUND_ALLOW=1 \
  "${CODEX_WRAPPER}" --role coder --dry-run

# 4. Claude normal path with no test hook, using --help to avoid real CLI/auth.
assert_exit_contains "claude normal help works without parent test hook" 0 "Usage:" \
  "${CLAUDE_WRAPPER}" --help

# 5. Claude fail-closed when the test harness reports cursor-agent parent.
assert_exit_contains "claude blocks cursor-agent parent" 1 "BLOCK" \
  env REVHARNESS_TEST_HARNESS=1 REV_HARNESS_PARENT_PROCESS_TEST=cursor-agent \
  "${CLAUDE_WRAPPER}" --help

# 6. Claude escape hatch explicitly permits intentional outbound delegation.
assert_exit_contains "claude allow env bypasses cursor-agent parent deny" 0 "Usage:" \
  env REVHARNESS_TEST_HARNESS=1 REV_HARNESS_PARENT_PROCESS_TEST=cursor-agent REV_HARNESS_CURSOR_OUTBOUND_ALLOW=1 \
  "${CLAUDE_WRAPPER}" --help

# 7. Test hook is ignored unless REVHARNESS_TEST_HARNESS=1 is also set.
assert_exit_not_contains "parent test hook ignored outside test harness" 0 "BLOCK" \
  env REV_HARNESS_PARENT_PROCESS_TEST=cursor-agent \
  "${CODEX_WRAPPER}" --role coder --dry-run

# 8. Diagnostic includes wrapper name, BLOCK, and escape-hatch env var.
assert_exit_contains "deny diagnostic includes wrapper name" 1 "[codex-wrapper][outbound-deny]" \
  env REVHARNESS_TEST_HARNESS=1 REV_HARNESS_PARENT_PROCESS_TEST=cursor-agent \
  "${CODEX_WRAPPER}" --role coder --dry-run
assert_exit_contains "deny diagnostic includes escape hatch env" 1 "REV_HARNESS_CURSOR_OUTBOUND_ALLOW" \
  env REVHARNESS_TEST_HARNESS=1 REV_HARNESS_PARENT_PROCESS_TEST=cursor-agent \
  "${CODEX_WRAPPER}" --role coder --dry-run

# 9. Generic agent process name does not match cursor-agent deny pattern.
assert_exit_not_contains "generic agent parent name does not trigger cursor outbound deny" 0 "BLOCK" \
  env REVHARNESS_TEST_HARNESS=1 REV_HARNESS_PARENT_PROCESS_TEST=agent \
  "${CODEX_WRAPPER}" --role coder --dry-run

# 10. Parent lookup unavailable / empty remains advisory allow path.
assert_exit_not_contains "unavailable parent ancestry does not trigger cursor outbound deny" 0 "BLOCK" \
  env REVHARNESS_TEST_HARNESS=1 REV_HARNESS_PARENT_PROCESS_TEST= \
  "${CODEX_WRAPPER}" --role coder --dry-run

# 11. Helper syntax and lint.
assert_cmd "bash -n _outbound-deny" bash -n "${OUTBOUND_DENY}"
assert_shellcheck "shellcheck _outbound-deny" "${OUTBOUND_DENY}"

printf '%s\n' "---"
printf 'Result: %s passed, %s failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == "0" ]]
