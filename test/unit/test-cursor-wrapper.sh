#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="${REPO_ROOT}/scripts/cursor-wrapper.sh"
FAKE_AGENT="${REPO_ROOT}/test/fixtures/fake-cursor/agent"

PASS=0
FAIL=0

cleanup_test_artifacts() {
  /bin/rm -f \
    "${REPO_ROOT}/.ask-readonly-dry-run-test-$$" \
    "${REPO_ROOT}/.ask-readonly-violation-test-$$" \
    "${REPO_ROOT}/.agent-write-test-$$"
  [[ -n "${readonly_violation_file:-}" ]] && /bin/rm -f "${readonly_violation_file}"
  [[ -n "${agent_write_file:-}" ]] && /bin/rm -f "${agent_write_file}"
  [[ -n "${argv_log:-}" ]] && /bin/rm -f "${argv_log}"
  [[ -n "${stderr_capture:-}" ]] && /bin/rm -f "${stderr_capture}"
}
trap cleanup_test_artifacts EXIT

assert_exit_grep() {
  local name="$1"; shift
  local expect_exit="$1"; shift
  local expect_grep="$1"; shift
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  if [[ "${rc}" == "${expect_exit}" ]] && echo "${out}" | grep -q -- "${expect_grep}"; then
    echo "PASS: ${name}"; PASS=$((PASS+1))
  else
    echo "FAIL: ${name} (exit=${rc}, expected=${expect_exit}; output missing substring: ${expect_grep})"
    echo "      ---OUTPUT---"
    echo "${out}" | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

[[ -x "${FAKE_AGENT}" ]] || { echo "FAIL: fake agent not executable at ${FAKE_AGENT}"; exit 1; }
export CURSOR_WRAPPER_AGENT_BIN="${FAKE_AGENT}"

# ---- Role resolution & help ----

# 1. Help renders
assert_exit_grep "help renders" 0 "Usage:" "${WRAPPER}" --help

# 2. Default role is ask
assert_exit_grep "default role ask" 0 "Role: ask" "${WRAPPER}" --dry-run

# 3. ask dry-run
assert_exit_grep "ask dry-run validates" 0 "Status: validated" "${WRAPPER}" --role ask --dry-run

# 4. agent dry-run
assert_exit_grep "agent dry-run validates" 0 "Role: agent" "${WRAPPER}" --role agent --dry-run

# 5. yolo dry-run
assert_exit_grep "yolo dry-run validates" 0 "Role: yolo" "${WRAPPER}" --role yolo --dry-run

# 6. Unknown role rejected
assert_exit_grep "unknown role rejected" 1 "unknown role" "${WRAPPER}" --role unknown --dry-run

# 7. Duplicate --role rejected (Codex amendment)
assert_exit_grep "duplicate --role rejected" 1 "specified more than once" "${WRAPPER}" --role ask --role agent --dry-run

# ---- Metric schema ----

# 8. Exactly 1 metric per invocation
stderr_capture="$(mktemp)"
"${WRAPPER}" --role ask --dry-run >/dev/null 2>"${stderr_capture}"
count=$(grep -c "^REV_HARNESS_DELEGATION_METRIC " "${stderr_capture}" || true)
/bin/rm -f "${stderr_capture}"
if [[ "${count}" == "1" ]]; then echo "PASS: exactly 1 metric per invocation"; PASS=$((PASS+1)); else echo "FAIL: metric count=${count}"; FAIL=$((FAIL+1)); fi

# 9. REV_HARNESS_METRICS_DISABLE=1 suppresses
stderr_capture="$(mktemp)"
REV_HARNESS_METRICS_DISABLE=1 "${WRAPPER}" --role ask --dry-run >/dev/null 2>"${stderr_capture}"
count=$(grep -c "^REV_HARNESS_DELEGATION_METRIC " "${stderr_capture}" || true)
/bin/rm -f "${stderr_capture}"
if [[ "${count}" == "0" ]]; then echo "PASS: REV_HARNESS_METRICS_DISABLE=1 suppresses metric"; PASS=$((PASS+1)); else echo "FAIL: metric should be suppressed (got ${count})"; FAIL=$((FAIL+1)); fi

# 10. Metric JSON schema v1 + vendor + wrapper_role + dry_run
out_metric=$("${WRAPPER}" --role ask --dry-run 2>&1 | grep "^REV_HARNESS_DELEGATION_METRIC " | sed 's/^REV_HARNESS_DELEGATION_METRIC //')
if echo "${out_metric}" | jq -e '.schema_version == 1 and .vendor == "cursor" and .wrapper_role == "cursor-ask" and .dry_run == true and .cursor_mode == "ask"' >/dev/null 2>&1; then
  echo "PASS: ask metric schema (cursor_mode=ask)"; PASS=$((PASS+1))
else
  echo "FAIL: ask metric schema"; echo "      ${out_metric}"; FAIL=$((FAIL+1))
fi

# 11. yolo sets cursor_force_flag=--force
out_metric=$("${WRAPPER}" --role yolo --dry-run 2>&1 | grep "^REV_HARNESS_DELEGATION_METRIC " | sed 's/^REV_HARNESS_DELEGATION_METRIC //')
if echo "${out_metric}" | jq -e '.cursor_force_flag == "--force" and .cursor_mode == "" and .wrapper_role == "cursor-yolo"' >/dev/null 2>&1; then
  echo "PASS: yolo metric (cursor_force_flag=--force, cursor_mode='')"; PASS=$((PASS+1))
else
  echo "FAIL: yolo metric"; echo "      ${out_metric}"; FAIL=$((FAIL+1))
fi

# 12. agent default mode (no --force, no --mode)
out_metric=$("${WRAPPER}" --role agent --dry-run 2>&1 | grep "^REV_HARNESS_DELEGATION_METRIC " | sed 's/^REV_HARNESS_DELEGATION_METRIC //')
if echo "${out_metric}" | jq -e '.cursor_force_flag == "" and .cursor_mode == "" and .wrapper_role == "cursor-agent"' >/dev/null 2>&1; then
  echo "PASS: agent metric (no --force, no --mode = default agent mode)"; PASS=$((PASS+1))
else
  echo "FAIL: agent metric"; echo "      ${out_metric}"; FAIL=$((FAIL+1))
fi

# ---- Real-invocation argv assertions (Codex amendment: verify actual argv) ----

argv_log="$(mktemp)"

# 13. ask role passes --mode ask to agent
FAKE_CURSOR_ARGV_LOG="${argv_log}" "${WRAPPER}" --role ask --stdin >/dev/null 2>&1 <<< "hello"
if grep -q -- "--mode ask" "${argv_log}" && ! grep -q -- "--force" "${argv_log}"; then
  echo "PASS: ask invocation passes --mode ask, no --force"; PASS=$((PASS+1))
else
  echo "FAIL: ask invocation argv"; echo "      argv: $(cat "${argv_log}")"; FAIL=$((FAIL+1))
fi
: >"${argv_log}"

# 14. agent role does NOT pass --mode (default agent mode) and no --force
FAKE_CURSOR_ARGV_LOG="${argv_log}" "${WRAPPER}" --role agent --stdin >/dev/null 2>&1 <<< "hello"
if ! grep -q -- "--mode" "${argv_log}" && ! grep -q -- "--force" "${argv_log}"; then
  echo "PASS: agent invocation has no --mode and no --force (default agent mode)"; PASS=$((PASS+1))
else
  echo "FAIL: agent invocation argv"; echo "      argv: $(cat "${argv_log}")"; FAIL=$((FAIL+1))
fi
: >"${argv_log}"

# 15. yolo role passes --force, no --mode
FAKE_CURSOR_ARGV_LOG="${argv_log}" "${WRAPPER}" --role yolo --stdin >/dev/null 2>&1 <<< "hello"
if grep -q -- "--force" "${argv_log}" && ! grep -q -- "--mode" "${argv_log}"; then
  echo "PASS: yolo invocation passes --force, no --mode"; PASS=$((PASS+1))
else
  echo "FAIL: yolo invocation argv"; echo "      argv: $(cat "${argv_log}")"; FAIL=$((FAIL+1))
fi
: >"${argv_log}"

# 16. -p and --output-format text are always present
FAKE_CURSOR_ARGV_LOG="${argv_log}" "${WRAPPER}" --role ask --stdin >/dev/null 2>&1 <<< "hello"
if grep -q -- "-p" "${argv_log}" && grep -q -- "--output-format text" "${argv_log}"; then
  echo "PASS: -p and --output-format text always passed"; PASS=$((PASS+1))
else
  echo "FAIL: -p / --output-format missing"; echo "      argv: $(cat "${argv_log}")"; FAIL=$((FAIL+1))
fi
: >"${argv_log}"

# 17. Prompt body is forwarded as the trailing positional arg
FAKE_CURSOR_ARGV_LOG="${argv_log}" "${WRAPPER}" --role ask --stdin >/dev/null 2>&1 <<< "unique-test-prompt-string-2026"
if grep -q "unique-test-prompt-string-2026" "${argv_log}"; then
  echo "PASS: stdin prompt forwarded as positional arg to agent"; PASS=$((PASS+1))
else
  echo "FAIL: prompt body not forwarded"; echo "      argv: $(cat "${argv_log}")"; FAIL=$((FAIL+1))
fi

/bin/rm -f "${argv_log}"
argv_log=""

# ---- Process semantics ----

# 18. Real invocation via fake agent succeeds
assert_exit_grep "real fake-agent invocation succeeds" 0 "fake cursor response" "${WRAPPER}" --role ask --stdin <<< "hello"

# 19. Wrapper propagates fake-agent exit code 3
export FAKE_CURSOR_EXIT_CODE=3
out=$("${WRAPPER}" --role ask --stdin <<< "hello" 2>&1)
rc=$?
unset FAKE_CURSOR_EXIT_CODE
if [[ "${rc}" == "3" ]]; then
  echo "PASS: wrapper propagates fake-agent exit code 3"; PASS=$((PASS+1))
else
  echo "FAIL: wrapper exit propagation (rc=${rc}, expected=3)"; FAIL=$((FAIL+1))
fi

# 20. Missing agent binary fail-closed
TMP_HOME="$(mktemp -d)"
out=$(REV_HARNESS_CANONICAL_ROOT="${REPO_ROOT}" HOME="${TMP_HOME}" PATH="/usr/bin:/bin" env -u CURSOR_WRAPPER_AGENT_BIN "${WRAPPER}" --role ask --stdin <<< "hello" 2>&1)
rc=$?
/bin/rm -rf "${TMP_HOME}"
if [[ "${rc}" != "0" ]] && echo "${out}" | grep -q "agent binary not found"; then
  echo "PASS: missing agent binary fail-closed"; PASS=$((PASS+1))
else
  echo "FAIL: missing agent binary fail-closed (rc=${rc})"; echo "      ${out}" | head -3; FAIL=$((FAIL+1))
fi

# 21. --stdin omitted on real invocation rejected
assert_exit_grep "--stdin omitted rejected for real invocation" 1 "--stdin is required" "${WRAPPER}" --role ask

# ---- Signal handling (Codex round 2 amendment) ----

# 22. SIGINT/SIGTERM handler is registered (regression guard)
# Verify the wrapper source registers traps for INT and TERM with forward_signal.
# We don't fire a real signal because subshell signal timing is OS/bash-version
# sensitive; instead we assert the trap contract is wired correctly.
if grep -q "trap 'forward_signal INT'" "${WRAPPER}" \
   && grep -q "trap 'forward_signal TERM'" "${WRAPPER}" \
   && grep -q "exit 130" "${WRAPPER}"; then
  echo "PASS: SIGINT/SIGTERM trap + exit 130 registered in wrapper"; PASS=$((PASS+1))
else
  echo "FAIL: signal trap contract not registered in wrapper"; FAIL=$((FAIL+1))
fi

# 22b. forward_signal forwards to METRICS_CHILD_PID before exit
if grep -q 'kill "-${signal_name}" "${METRICS_CHILD_PID}"' "${WRAPPER}"; then
  echo "PASS: forward_signal kills METRICS_CHILD_PID with received signal"; PASS=$((PASS+1))
else
  echo "FAIL: forward_signal does not propagate signal to child"; FAIL=$((FAIL+1))
fi

# 23. Canonical-guard identity-class smoke (dedicated cursor-wrapper case)
# The detailed identity-class behavior (canonical-dev / managed-adopter / ambiguous-copy
# / invalid) is exercised by test/unit/test-canonical-guard.sh. Here we just smoke-test
# that the wrapper's source of _canonical-guard.sh resolves through the official
# REV_HARNESS_CANONICAL_ROOT for the local checkout, i.e. a clean invocation passes.
out=$(REV_HARNESS_CANONICAL_ROOT="${REPO_ROOT}" "${WRAPPER}" --role ask --dry-run 2>&1)
rc=$?
if [[ "${rc}" == "0" ]] && ! echo "${out}" | grep -q "VENDOR GUARD"; then
  echo "PASS: canonical-guard passes on official root (no VENDOR GUARD warning)"; PASS=$((PASS+1))
else
  echo "FAIL: canonical-guard official-root smoke (rc=${rc})"; echo "      ${out}" | head -3; FAIL=$((FAIL+1))
fi

# ---- Cursor rules visibility telemetry ----

# 25. cursor_rules_files_present is emitted and true for the current repo state
out_metric=$("${WRAPPER}" --role ask --dry-run 2>&1 | grep "^REV_HARNESS_DELEGATION_METRIC " | sed 's/^REV_HARNESS_DELEGATION_METRIC //')
if echo "${out_metric}" | jq -e '.cursor_rules_files_present == true' >/dev/null 2>&1; then
  echo "PASS: cursor_rules_files_present metric emitted true"; PASS=$((PASS+1))
else
  echo "FAIL: cursor_rules_files_present metric"; echo "      ${out_metric}"; FAIL=$((FAIL+1))
fi

# 26. cursor_rules_selfcheck_status is emitted as unimplemented for round 5
out_metric=$("${WRAPPER}" --role ask --dry-run 2>&1 | grep "^REV_HARNESS_DELEGATION_METRIC " | sed 's/^REV_HARNESS_DELEGATION_METRIC //')
if echo "${out_metric}" | jq -e '.cursor_rules_selfcheck_status == "unimplemented"' >/dev/null 2>&1; then
  echo "PASS: cursor_rules_selfcheck_status metric emitted unimplemented"; PASS=$((PASS+1))
else
  echo "FAIL: cursor_rules_selfcheck_status metric"; echo "      ${out_metric}"; FAIL=$((FAIL+1))
fi

# 27. Missing AGENTS.md emits cursor_rules_files_present=false and restores file
agents_md="${REPO_ROOT}/AGENTS.md"
agents_md_backup="$(mktemp "${REPO_ROOT}/AGENTS.md.bak.XXXXXX")"
restore_agents_md() {
  if [[ -f "${agents_md_backup}" && ! -f "${agents_md}" ]]; then
    mv "${agents_md_backup}" "${agents_md}"
  elif [[ -f "${agents_md_backup}" ]]; then
    /bin/rm -f "${agents_md_backup}"
  fi
}
trap restore_agents_md EXIT
mv "${agents_md}" "${agents_md_backup}"
out_metric=$("${WRAPPER}" --role ask --dry-run 2>&1 | grep "^REV_HARNESS_DELEGATION_METRIC " | sed 's/^REV_HARNESS_DELEGATION_METRIC //')
restore_agents_md
trap cleanup_test_artifacts EXIT
if [[ -f "${agents_md}" ]] && echo "${out_metric}" | jq -e '.cursor_rules_files_present == false' >/dev/null 2>&1; then
  echo "PASS: missing AGENTS.md emits cursor_rules_files_present false"; PASS=$((PASS+1))
else
  echo "FAIL: missing AGENTS.md cursor_rules_files_present metric"; echo "      ${out_metric}"; FAIL=$((FAIL+1))
fi

# ---- Ask read-only diff gate ----

# 28. ask role + dry-run skips the diff gate
readonly_violation_file="${REPO_ROOT}/.ask-readonly-dry-run-test-$$"
/bin/rm -f "${readonly_violation_file}"
out=$(FAKE_CURSOR_TOUCH_FILE="${readonly_violation_file}" "${WRAPPER}" --role ask --dry-run 2>&1)
rc=$?
/bin/rm -f "${readonly_violation_file}"
readonly_violation_file=""
if [[ "${rc}" == "0" ]] && ! echo "${out}" | grep -q "ask-readonly-enforce"; then
  echo "PASS: ask dry-run skips read-only diff gate"; PASS=$((PASS+1))
else
  echo "FAIL: ask dry-run read-only diff gate skip (rc=${rc})"; echo "${out}" | sed 's/^/      /'; FAIL=$((FAIL+1))
fi

# 29. ask role blocks if the fake agent writes into the worktree.
# IMPORTANT: the fixture path must NOT match a .gitignore pattern, otherwise
# `git ls-files --others --exclude-standard` (which the ask diff gate uses)
# won't see it and the gate falsely passes. We use a leading-non-dot name to
# stay outside the .ask-readonly-* / .agent-write-test-* ignore patterns.
readonly_violation_file="${REPO_ROOT}/cursor-ask-violation-test-$$"
/bin/rm -f "${readonly_violation_file}"
trap "/bin/rm -f '${readonly_violation_file}'" EXIT
out=$(FAKE_CURSOR_TOUCH_FILE="${readonly_violation_file}" "${WRAPPER}" --role ask --stdin <<< "hello" 2>&1)
rc=$?
/bin/rm -f "${readonly_violation_file}"
trap - EXIT
if [[ "${rc}" == "2" ]] \
   && echo "${out}" | grep -q "ask-readonly-enforce" \
   && echo "${out}" | grep -q "read-only invariant violated" \
   && echo "${out}" | grep -q "$(basename "${readonly_violation_file}")"; then
  echo "PASS: ask role blocks fake-agent workspace write"; PASS=$((PASS+1))
else
  echo "FAIL: ask role write block (rc=${rc})"; echo "${out}" | sed 's/^/      /'; FAIL=$((FAIL+1))
fi
readonly_violation_file=""

# 30. agent role permits the same fake write path without firing the ask gate.
# Same non-dot prefix as #29 so the diff gate can actually see the file.
agent_write_file="${REPO_ROOT}/cursor-agent-write-test-$$"
/bin/rm -f "${agent_write_file}"
trap "/bin/rm -f '${agent_write_file}'" EXIT
out=$(FAKE_CURSOR_TOUCH_FILE="${agent_write_file}" "${WRAPPER}" --role agent --stdin <<< "hello" 2>&1)
rc=$?
/bin/rm -f "${agent_write_file}"
if [[ "${rc}" == "0" ]] && ! echo "${out}" | grep -q "ask-readonly-enforce"; then
  echo "PASS: agent role write does not trigger ask diff gate"; PASS=$((PASS+1))
else
  echo "FAIL: agent role write unexpectedly triggered gate (rc=${rc})"; echo "${out}" | sed 's/^/      /'; FAIL=$((FAIL+1))
fi
agent_write_file=""

echo "---"
echo "Result: ${PASS} passed, ${FAIL} failed"
exit "${FAIL}"
