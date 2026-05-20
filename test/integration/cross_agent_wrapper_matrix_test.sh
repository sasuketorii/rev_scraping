#!/usr/bin/env bash
# Integration tests for cross-agent wrapper invocation matrix.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
WRAPPER_STDERR_TEST_ROOT="$PROJECT_ROOT/.claude/tmp/cross-agent-wrapper-matrix-stderr.$$"
TEST_TIMEOUT_SECS="${CROSS_AGENT_WRAPPER_MATRIX_TEST_TIMEOUT_SECS:-120}"

cleanup_global() {
  /bin/rm -rf "$WRAPPER_STDERR_TEST_ROOT" 2>/dev/null || true
}
trap cleanup_global EXIT

ALL_TEST_IDS=(X1 X2 X3 X4 X5 X6 X7 X8 X9 X10 X11 X12 X13 X14 X14b X15a X15b X15c X15d X15e X15f X15g X15h)

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 2
  fi
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "ERROR: required file not found: $path" >&2
    exit 2
  fi
}

contains_text() {
  local needle="$1"
  local haystack="$2"
  [[ "$haystack" == *"$needle"* ]]
}

test_description() {
  local id="${1:-}"
  case "$id" in
    X1) echo "codex can call canonical codex wrapper role matrix and fail closed on bad role input plus non-interactive resume" ;;
    X2) echo "codex can call claude wrapper with print, bypassPermissions, and default medium effort" ;;
    X3) echo "claude can call canonical reviewer role, legacy codex shims preserve compatibility, and reviewer shim rejects role escape attempts" ;;
    X4) echo "claude can call claude wrapper with print, bypassPermissions, and default medium effort" ;;
    X5) echo "session helpers keep orchestrated Claude flow non-interactive, fail closed on continuation helpers, cap explicit xhigh opt-in to CLI high, and reject max effort env" ;;
    X6) echo "canonical codex wrapper strips --cd and --add-dir before invoking codex" ;;
    X7) echo "claude wrapper strips equals-form permission bypass flags before invoking claude" ;;
    X8) echo "session helper rejects caller-controlled CLAUDE_WRAPPER overrides" ;;
    X9) echo "session helper routes Codex execution through the canonical codex wrapper instead of a legacy shim" ;;
    X10) echo "reviewer helper rejects caller-controlled CODEX_WRAPPER_CANONICAL overrides" ;;
    X11) echo "claude wrapper rejects repo-external stderr roots" ;;
    X12) echo "codex wrapper fails closed on caller attempts to override model policy and native multi-agent guards" ;;
    X13) echo "codex wrapper subscription-auth preflight rejects OpenAI API-key auth before invoking codex" ;;
    X14) echo "vendored claude-wrapper and codex-wrapper are refused with exit 70 by canonical-path guard" ;;
    X14b) echo "REV_HARNESS_VENDOR_CHECK=warn soft-mode allows vendored wrappers to proceed with warning" ;;
    X15a) echo "codex-job start emits a job id and persists pid/status.json under REV_HARNESS_RUN_DIR" ;;
    X15b) echo "codex-job wait blocks until completion and exposes exit_code/status JSON" ;;
    X15c) echo "codex-job wait returns 124 on timeout while leaving the job running" ;;
    X15d) echo "codex-job start issues unique job ids and gc --ttl 0 removes completed jobs" ;;
    X15e) echo "shim-hits.log records codex-job start entries tagged with the issued job_id" ;;
    X15f) echo "codex-job wait --timeout 0 returns 0 when completed and 124 when still running" ;;
    X15g) echo "codex-job gc --ttl rejects non-numeric, negative, and out-of-range values with exit 64" ;;
    X15h) echo "codex-job status/wait/result reject path-traversal job ids with exit 64" ;;
    *) return 1 ;;
  esac
}

setup_mocks() {
  local tmpdir="$1"
  local mockbin="$tmpdir/mockbin"

  mkdir -p "$mockbin" "$tmpdir/mock-claude-stdin"

  write_lines "$mockbin/codex" \
    '#!/usr/bin/env bash' \
    'printf '"'"'caller=%s|argv=%s\n'"'"' "${SIMULATED_CALLER:-unknown}" "$*" >> "${MOCK_CODEX_LOG:?}"' \
    'cat >/dev/null || true' \
    'printf '"'"'mock-codex-output\n'"'"''
  chmod +x "$mockbin/codex"

  write_lines "$mockbin/claude" \
    '#!/usr/bin/env bash' \
    'stdin_file="$(mktemp "${MOCK_CLAUDE_STDIN_DIR:?}/stdin.XXXXXX")"' \
    'cat > "$stdin_file" || true' \
    'printf '"'"'caller=%s|argv=%s|stdin_file=%s\n'"'"' "${SIMULATED_CALLER:-unknown}" "$*" "$stdin_file" >> "${MOCK_CLAUDE_LOG:?}"' \
    'printf '"'"'Session: mock-session-id\n'"'"' >&2' \
    'printf '"'"'mock-claude-output\n'"'"''
  chmod +x "$mockbin/claude"
}

read_single_line() {
  local file="$1"
  awk 'NR == 1 { print; exit }' "$file"
}

read_nth_line() {
  local file="$1"
  local line_no="$2"
  awk -v line_no="$line_no" 'NR == line_no { print; exit }' "$file"
}

extract_stdin_file() {
  local line="$1"
  printf '%s\n' "${line##*|stdin_file=}"
}

codex_line_has_never_approval() {
  local line="$1"
  contains_text "--ask-for-approval never" "$line" || contains_text "approval_policy=never" "$line"
}

assert_codex_invocation() {
  local caller="$1"
  local effort="$2"
  local search="$3"
  local line="$4"

  contains_text "caller=${caller}" "$line" &&
  contains_text "argv=exec" "$line" &&
  contains_text "--sandbox workspace-write" "$line" &&
  codex_line_has_never_approval "$line" &&
  contains_text "model=gpt-5.5" "$line" &&
  contains_text "model_reasoning_effort=${effort}" "$line" &&
  contains_text "web_search=${search}" "$line"
}

assert_claude_invocation() {
  local caller="$1"
  local effort="$2"
  local line="$3"

  assert_claude_invocation_common "$caller" "$effort" "$line" &&
  contains_text "--model opus" "$line" &&
  contains_text "--session-id " "$line"
}

assert_claude_invocation_common() {
  local caller="$1"
  local effort="$2"
  local line="$3"

  contains_text "caller=${caller}" "$line" &&
  contains_text "--print" "$line" &&
  contains_text "--permission-mode bypassPermissions" "$line" &&
  contains_text "--effort ${effort}" "$line"
}

assert_text_matches() {
  local pattern="$1"
  local file="$2"
  grep -Eq "$pattern" "$file"
}

write_lines() {
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
}

collect_descendants() {
  local parent_pid="$1"
  local child_pid

  while read -r child_pid; do
    [[ -n "$child_pid" ]] || continue
    collect_descendants "$child_pid"
    printf '%s\n' "$child_pid"
  done < <(ps -Ao pid=,ppid= | awk -v parent="$parent_pid" '$2 == parent { print $1 }')
}

kill_process_tree() {
  local root_pid="$1"
  local signal_name="$2"
  local pid
  local pids=()

  while read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(collect_descendants "$root_pid")
  pids+=("$root_pid")

  for pid in "${pids[@]}"; do
    if [[ "$pid" != "$$" ]]; then
      kill "-$signal_name" "$pid" 2>/dev/null || true
    fi
  done
}

diagnose_timeout() {
  local id="$1"
  local root_pid="$2"

  echo "ERROR: $id timed out after ${TEST_TIMEOUT_SECS}s" >&2
  echo "ERROR: process snapshot for $id (root pid $root_pid):" >&2
  ps -Ao pid,ppid,pgid,etime,stat,command |
    awk -v root="$root_pid" '
      NR == 1 { print; next }
      $1 == root || $2 == root || $3 == root || index($0, "cross_agent_wrapper_matrix_test.sh") || index($0, "session_runner") || index($0, "claude-wrapper") || index($0, "mockbin") { print }
    ' >&2
}

dispatch_test_with_timeout() {
  local id="$1"
  local timeout_secs="$TEST_TIMEOUT_SECS"
  local pid elapsed=0 status=0

  if [[ -z "$timeout_secs" || ! "$timeout_secs" =~ ^[0-9]+$ || "$timeout_secs" -eq 0 ]]; then
    dispatch_test "$id"
    return $?
  fi

  (
    dispatch_test "$id"
  ) &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed" -ge "$timeout_secs" ]]; then
      diagnose_timeout "$id" "$pid"
      kill_process_tree "$pid" TERM
      sleep 1
      if kill -0 "$pid" 2>/dev/null; then
        kill_process_tree "$pid" KILL
      fi
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$pid"
  status=$?
  return "$status"
}

test_x1_codex_to_codex() {
  (
    set -u -o pipefail
    local tmpdir mockbin out line1 line2 line3 line4 line_count failed=0 resume_stderr resume_eq_stderr

    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    mockbin="$tmpdir/mockbin"
    out="$tmpdir/out.txt"
    : > "$tmpdir/codex.log"
    : > "$tmpdir/claude.log"

    if ! SIMULATED_CALLER=codex \
      AGENT_ROLE= \
      CODEX_WRAPPER_ROLE= \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --stdin > "$out" <<< "x1 default"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    if ! SIMULATED_CALLER=codex \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role research --stdin >> "$out" <<< "x1 research"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    if ! SIMULATED_CALLER=codex \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role coder --stdin >> "$out" <<< "x1 coder"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    if ! SIMULATED_CALLER=codex \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role high-coder --stdin >> "$out" <<< "x1 high-coder"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    if SIMULATED_CALLER=codex \
      AGENT_ROLE= \
      CODEX_WRAPPER_ROLE= \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role nope --stdin >> "$out" <<< "x1 invalid-role"; then
      failed=1
    fi

    resume_stderr="$tmpdir/resume.stderr"
    if SIMULATED_CALLER=codex \
      AGENT_ROLE= \
      CODEX_WRAPPER_ROLE= \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role coder --resume abcd1234 "x1 resume" \
        > /dev/null 2> "$resume_stderr"; then
      failed=1
    fi

    resume_eq_stderr="$tmpdir/resume-eq.stderr"
    if SIMULATED_CALLER=codex \
      AGENT_ROLE= \
      CODEX_WRAPPER_ROLE= \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role coder --resume=abcd1234 "x1 resume eq" \
        > /dev/null 2> "$resume_eq_stderr"; then
      failed=1
    fi

    line1="$(read_nth_line "$tmpdir/codex.log" 1)"
    line2="$(read_nth_line "$tmpdir/codex.log" 2)"
    line3="$(read_nth_line "$tmpdir/codex.log" 3)"
    line4="$(read_nth_line "$tmpdir/codex.log" 4)"
    line_count="$(wc -l < "$tmpdir/codex.log" | tr -d '[:space:]')"

    [[ -s "$out" ]] || failed=1
    [[ "$line_count" -eq 4 ]] || failed=1
    contains_text "manual-only" "$(cat "$resume_stderr")" || failed=1
    contains_text "manual-only" "$(cat "$resume_eq_stderr")" || failed=1
    assert_codex_invocation "codex" "medium" "cached" "$line1" || failed=1
    assert_codex_invocation "codex" "high" "live" "$line2" || failed=1
    assert_codex_invocation "codex" "medium" "cached" "$line3" || failed=1
    assert_codex_invocation "codex" "high" "cached" "$line4" || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

# NEGATIVE TEST: Codex top-level→Claude (claude-wrapper.sh) must be blocked.
# As of 2026-06-15 Agent SDK billing separation, this cross-family direction
# is excluded from the default flow. This test asserts that calling claude-wrapper.sh
# from a Codex top-level context emits the deprecation warning (PR-A shim behavior).
# See: docs/agent-sdk-policy.md, docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md
test_x2_codex_to_claude() {
  (
    set -u -o pipefail
    local tmpdir mockbin out stderr_file shim_log failed=0

    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    mockbin="$tmpdir/mockbin"
    out="$tmpdir/out.txt"
    stderr_file="$tmpdir/wrapper.stderr"
    shim_log="$tmpdir/shim-hits.log"
    : > "$tmpdir/codex.log"
    : > "$tmpdir/claude.log"

    # Passthrough is allowed (exit 0) but a DEPRECATED warning must be emitted
    # to stderr and a shim-hits.log entry must be recorded.
    SIMULATED_CALLER=codex \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
      CLAUDE_WRAPPER_STDERR_ROOT="$WRAPPER_STDERR_TEST_ROOT/x2" \
      REV_HARNESS_SHIM_HITS_LOG="$shim_log" \
      HOME="$tmpdir/home" \
      REV_HARNESS_CANONICAL_ROOT="$PROJECT_ROOT" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" --output "$out" "x2 prompt" \
        2> "$stderr_file" || true

    contains_text "DEPRECATED" "$(cat "$stderr_file")" || failed=1
    # shim-hits log: either REV_HARNESS_SHIM_HITS_LOG path or HOME/.rev_harness/shim-hits.log
    if [[ ! -s "$shim_log" && ! -s "$tmpdir/home/.rev_harness/shim-hits.log" ]]; then
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x3_claude_to_codex() {
  (
    set -u -o pipefail
    local tmpdir mockbin out line1 line2 line3 line4 line_count failed=0

    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    mockbin="$tmpdir/mockbin"
    out="$tmpdir/out.txt"
    : > "$tmpdir/codex.log"
    : > "$tmpdir/claude.log"

    if ! SIMULATED_CALLER=claude \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role reviewer --stdin > "$out" <<< "x3 canonical reviewer"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    if ! SIMULATED_CALLER=claude \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper-medium.sh" --stdin >> "$out" <<< "x3 shim medium"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    if ! SIMULATED_CALLER=claude \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper-high.sh" --stdin >> "$out" <<< "x3 shim high"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    if ! SIMULATED_CALLER=claude \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper-xhigh.sh" --stdin >> "$out" <<< "x3 shim xhigh"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    if SIMULATED_CALLER=claude \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper-xhigh.sh" --role coder --stdin >> "$out" <<< "x3 shim escape"; then
      failed=1
    fi

    line1="$(read_nth_line "$tmpdir/codex.log" 1)"
    line2="$(read_nth_line "$tmpdir/codex.log" 2)"
    line3="$(read_nth_line "$tmpdir/codex.log" 3)"
    line4="$(read_nth_line "$tmpdir/codex.log" 4)"
    line_count="$(wc -l < "$tmpdir/codex.log" | tr -d '[:space:]')"

    [[ -s "$out" ]] || failed=1
    [[ "$line_count" -eq 4 ]] || failed=1
    assert_codex_invocation "claude" "xhigh" "cached" "$line1" || failed=1
    assert_codex_invocation "claude" "medium" "cached" "$line2" || failed=1
    assert_codex_invocation "claude" "high" "cached" "$line3" || failed=1
    assert_codex_invocation "claude" "xhigh" "cached" "$line4" || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x4_claude_to_claude() {
  (
    set -u -o pipefail
    local tmpdir mockbin out line stdin_file failed=0

    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    mockbin="$tmpdir/mockbin"
    out="$tmpdir/out.txt"
    : > "$tmpdir/codex.log"
    : > "$tmpdir/claude.log"

    if ! SIMULATED_CALLER=claude \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
      CLAUDE_WRAPPER_STDERR_ROOT="$WRAPPER_STDERR_TEST_ROOT/x4" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" --output "$out" "x4 prompt"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    line="$(read_single_line "$tmpdir/claude.log")"
    stdin_file="$(extract_stdin_file "$line")"

    [[ -s "$out" ]] || failed=1
    [[ -f "$out.stderr-pointer.txt" ]] || failed=1
    [[ ! -e "${out%.*}.stderr.log" ]] || failed=1
    contains_text "stderr/" "$(cat "$out.stderr-pointer.txt")" || failed=1
    assert_claude_invocation "claude" "medium" "$line" || failed=1
    [[ -f "$stdin_file" ]] || failed=1
    contains_text "[外部委譲モード]" "$(cat "$stdin_file")" || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x5_session_helpers_use_wrapper() {
  (
    set -u -o pipefail
    local tmpdir mockbin runner stdout stderr line1 line2 line3 line4 failed=0 line_count=0 mode_count=0
    local stdin1 stdin2 stdin3 stdin4

    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    mockbin="$tmpdir/mockbin"
    runner="$tmpdir/session_runner.sh"
    stdout="$tmpdir/session.stdout"
    stderr="$tmpdir/session.stderr"
    : > "$tmpdir/codex.log"
    : > "$tmpdir/claude.log"

    write_lines "$runner" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      'PROJECT_ROOT="$1"' \
      'TMPDIR_RUN="$2"' \
      'STDERR_ROOT="$3"' \
      'export TMPDIR="$TMPDIR_RUN"' \
      'export CLAUDE_WRAPPER_STDERR_ROOT="$STDERR_ROOT"' \
      'unset CLAUDE_CODE_EFFORT_LEVEL_DEFAULT' \
      'unset CLAUDE_CODE_EFFORT_LEVEL' \
      'unset CLAUDE_THINKING_BUDGET' \
      '' \
      'source "$PROJECT_ROOT/.claude/commands/lib/utils.sh"' \
      'source "$PROJECT_ROOT/.claude/commands/lib/state.sh"' \
      'source "$PROJECT_ROOT/.claude/commands/lib/timeout.sh"' \
      'source "$PROJECT_ROOT/.claude/commands/lib/session.sh"' \
      '' \
      'sid1="$(session_start '"'"'start prompt'"'"' "$TMPDIR_RUN/start.txt")"' \
      'if session_resume '"'"'abcd1234'"'"' '"'"'resume prompt'"'"' "$TMPDIR_RUN/resume.txt"; then' \
      '  exit 91' \
      'fi' \
      'export CLAUDE_CODE_EFFORT_LEVEL="xhigh"' \
      'if session_fork '"'"'abcd1234'"'"' '"'"'fork prompt'"'"' "$TMPDIR_RUN/fork-blocked.txt" > "$TMPDIR_RUN/fork.stdout"; then' \
      '  exit 92' \
      'fi' \
      'sid2="$(session_start '"'"'xhigh prompt'"'"' "$TMPDIR_RUN/xhigh.txt")"' \
      'export CLAUDE_CODE_EFFORT_LEVEL="max"' \
      'sid3="$(session_start '"'"'max prompt'"'"' "$TMPDIR_RUN/max.txt")"' \
      'unset CLAUDE_CODE_EFFORT_LEVEL' \
      'session_run_with_timeout 5 '"'"'new'"'"' '"'"'timeout new'"'"' "$TMPDIR_RUN/timeout-new.txt"' \
      'if session_run_with_timeout 5 '"'"'abcd1234'"'"' '"'"'timeout resume'"'"' "$TMPDIR_RUN/timeout-resume.txt"; then' \
      '  exit 93' \
      'fi' \
      '' \
      'printf '"'"'sid1=%s\n'"'"' "$sid1"' \
      'printf '"'"'sid2=%s\n'"'"' "$sid2"' \
      'printf '"'"'sid3=%s\n'"'"' "$sid3"'
    chmod +x "$runner"

    if ! SIMULATED_CALLER=session \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
      PATH="$mockbin:$PATH" \
      bash "$runner" "$PROJECT_ROOT" "$tmpdir" "$WRAPPER_STDERR_TEST_ROOT/x5" > "$stdout" 2> "$stderr"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    line_count="$(wc -l < "$tmpdir/claude.log" | tr -d '[:space:]')"
    line1="$(read_nth_line "$tmpdir/claude.log" 1)"
    line2="$(read_nth_line "$tmpdir/claude.log" 2)"
    line3="$(read_nth_line "$tmpdir/claude.log" 3)"
    line4="$(read_nth_line "$tmpdir/claude.log" 4)"
    stdin1="$(extract_stdin_file "$line1")"
    stdin2="$(extract_stdin_file "$line2")"
    stdin3="$(extract_stdin_file "$line3")"
    stdin4="$(extract_stdin_file "$line4")"
    mode_count="$(grep -c 'Mode: orchestrator-full' "$stderr" || true)"

    [[ "$line_count" -eq 4 ]] || failed=1
    [[ "$mode_count" -eq 4 ]] || failed=1
    assert_text_matches '^sid1=[a-z0-9-]+$' "$stdout" || failed=1
    assert_text_matches '^sid2=[a-z0-9-]+$' "$stdout" || failed=1
    assert_text_matches '^sid3=[a-z0-9-]+$' "$stdout" || failed=1
    assert_claude_invocation "session" "medium" "$line1" || failed=1
    assert_claude_invocation "session" "high" "$line2" || failed=1
    contains_text "Effort: xhigh (Claude CLI: high)" "$(cat "$stderr")" || failed=1
    assert_claude_invocation "session" "medium" "$line3" || failed=1
    ! contains_text "--effort max" "$line3" || failed=1
    contains_text "Invalid CLAUDE_CODE_EFFORT_LEVEL: max (must be low|medium|high|xhigh). Using default: medium" "$(cat "$stderr")" || failed=1
    assert_claude_invocation "session" "medium" "$line4" || failed=1
    ! contains_text "--resume " "$line1" || failed=1
    ! contains_text "--resume " "$line2" || failed=1
    ! contains_text "--resume " "$line3" || failed=1
    ! contains_text "--resume " "$line4" || failed=1
    ! contains_text "--fork-session" "$line1" || failed=1
    ! contains_text "--fork-session" "$line2" || failed=1
    ! contains_text "--fork-session" "$line3" || failed=1
    ! contains_text "--fork-session" "$line4" || failed=1
    contains_text "interactive session continuation is disabled" "$(cat "$stderr")" || failed=1
    [[ ! -s "$tmpdir/resume.txt" ]] || failed=1
    [[ ! -s "$tmpdir/fork-blocked.txt" ]] || failed=1
    [[ ! -s "$tmpdir/timeout-resume.txt" ]] || failed=1
    ! contains_text "[外部委譲モード]" "$(cat "$stdin1")" || failed=1
    ! contains_text "[外部委譲モード]" "$(cat "$stdin2")" || failed=1
    ! contains_text "[外部委譲モード]" "$(cat "$stdin3")" || failed=1
    ! contains_text "[外部委譲モード]" "$(cat "$stdin4")" || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x6_codex_wrapper_strips_location_escape_flags() {
  (
    set -u -o pipefail
    local tmpdir mockbin out line1 line2 line_count failed=0

    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    mockbin="$tmpdir/mockbin"
    out="$tmpdir/out.txt"
    : > "$tmpdir/codex.log"
    : > "$tmpdir/claude.log"

    if ! SIMULATED_CALLER=codex \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role coder --cd "$tmpdir" --stdin > "$out" <<< "x6 cd"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    if ! SIMULATED_CALLER=codex \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role coder --add-dir "$tmpdir" --stdin >> "$out" <<< "x6 add-dir"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    line1="$(read_nth_line "$tmpdir/codex.log" 1)"
    line2="$(read_nth_line "$tmpdir/codex.log" 2)"
    line_count="$(wc -l < "$tmpdir/codex.log" | tr -d '[:space:]')"

    [[ "$line_count" -eq 2 ]] || failed=1
    [[ -s "$out" ]] || failed=1
    assert_codex_invocation "codex" "medium" "cached" "$line1" || failed=1
    assert_codex_invocation "codex" "medium" "cached" "$line2" || failed=1
    ! contains_text "--cd " "$line1" || failed=1
    ! contains_text "--cd=" "$line1" || failed=1
    ! contains_text "--add-dir " "$line1" || failed=1
    ! contains_text "--add-dir=" "$line1" || failed=1
    ! contains_text "--cd " "$line2" || failed=1
    ! contains_text "--cd=" "$line2" || failed=1
    ! contains_text "--add-dir " "$line2" || failed=1
    ! contains_text "--add-dir=" "$line2" || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

# NEGATIVE TEST: Codex top-level→Claude (claude-wrapper.sh) must be blocked.
# As of 2026-06-15 Agent SDK billing separation, this cross-family direction
# is excluded from the default flow. This test asserts that calling claude-wrapper.sh
# from a Codex top-level context emits the deprecation warning (PR-A shim behavior).
# See: docs/agent-sdk-policy.md, docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md
test_x7_claude_wrapper_strips_equals_form_bypass_flags() {
  (
    set -u -o pipefail
    local tmpdir mockbin stderr_file shim_log failed=0

    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    mockbin="$tmpdir/mockbin"
    stderr_file="$tmpdir/wrapper.stderr"
    shim_log="$tmpdir/shim-hits.log"
    : > "$tmpdir/codex.log"
    : > "$tmpdir/claude.log"
    : > "$stderr_file"

    # Each invocation: passthrough may succeed but DEPRECATED warning expected.
    SIMULATED_CALLER=codex \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
      CLAUDE_WRAPPER_STDERR_ROOT="$WRAPPER_STDERR_TEST_ROOT/x7" \
      REV_HARNESS_SHIM_HITS_LOG="$shim_log" \
      HOME="$tmpdir/home" \
      REV_HARNESS_CANONICAL_ROOT="$PROJECT_ROOT" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" --output "$tmpdir/out1.txt" --permission-mode=bypassPermissions "x7 permission same" \
        2>> "$stderr_file" || true

    SIMULATED_CALLER=codex \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
      CLAUDE_WRAPPER_STDERR_ROOT="$WRAPPER_STDERR_TEST_ROOT/x7" \
      REV_HARNESS_SHIM_HITS_LOG="$shim_log" \
      HOME="$tmpdir/home" \
      REV_HARNESS_CANONICAL_ROOT="$PROJECT_ROOT" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" --output "$tmpdir/out2.txt" --dangerously-skip-permissions=true "x7 skip" \
        2>> "$stderr_file" || true

    contains_text "DEPRECATED" "$(cat "$stderr_file")" || failed=1
    if [[ ! -s "$shim_log" && ! -s "$tmpdir/home/.rev_harness/shim-hits.log" ]]; then
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x8_session_helper_rejects_claude_wrapper_env_override() {
  (
    set -u -o pipefail
    local tmpdir fake_root runner stdout line1 line_count failed=0

    tmpdir="$(mktemp -d)"
    fake_root="$tmpdir/fake_root"
    runner="$tmpdir/session_runner.sh"
    stdout="$tmpdir/session.stdout"

    mkdir -p "$fake_root/.claude/commands/lib" "$fake_root/scripts"
    /bin/cp "$PROJECT_ROOT/.claude/commands/lib/session.sh" "$fake_root/.claude/commands/lib/session.sh"

    write_lines "$fake_root/scripts/claude-wrapper.sh" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      'printf '"'"'wrapper=canonical-claude|argv=%s\n'"'"' "$*" >> "${SESSION_HELPER_LOG:?}"' \
      '' \
      'output=""' \
      'while [[ $# -gt 0 ]]; do' \
      '  case "$1" in' \
      '    --output)' \
      '      output="$2"' \
      '      shift 2' \
      '      ;;' \
      '    *)' \
      '      shift' \
      '      ;;' \
      '  esac' \
      'done' \
      '' \
      '[[ -n "$output" ]]' \
      'printf '"'"'canonical-claude-output\n'"'"' > "$output"'
    chmod +x "$fake_root/scripts/claude-wrapper.sh"

    write_lines "$fake_root/scripts/escape-claude-wrapper.sh" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      'printf '"'"'wrapper=escape-claude|argv=%s\n'"'"' "$*" >> "${SESSION_HELPER_LOG:?}"' \
      'exit 98'
    chmod +x "$fake_root/scripts/escape-claude-wrapper.sh"

    write_lines "$runner" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      'PROJECT_ROOT="$1"' \
      'FAKE_ROOT="$2"' \
      'TMPDIR_RUN="$3"' \
      '' \
      'export TMPDIR="$TMPDIR_RUN"' \
      'export SESSION_HELPER_LOG="$TMPDIR_RUN/session-helper.log"' \
      '' \
      'source "$PROJECT_ROOT/.claude/commands/lib/utils.sh"' \
      'source "$FAKE_ROOT/.claude/commands/lib/session.sh"' \
      '' \
      'export CLAUDE_WRAPPER="$FAKE_ROOT/scripts/escape-claude-wrapper.sh"' \
      '' \
      'sid="$(session_start '"'"'start prompt'"'"' "$TMPDIR_RUN/session.txt")"' \
      'printf '"'"'sid=%s\n'"'"' "$sid"'
    chmod +x "$runner"

    if bash "$runner" "$PROJECT_ROOT" "$fake_root" "$tmpdir" > "$stdout"; then
      failed=1
    fi

    if [[ -f "$tmpdir/session-helper.log" ]]; then
      line_count="$(wc -l < "$tmpdir/session-helper.log" | tr -d '[:space:]')"
      line1="$(read_single_line "$tmpdir/session-helper.log")"
    else
      line_count="0"
      line1=""
    fi

    [[ "$line_count" -eq 0 ]] || failed=1
    [[ -z "$line1" ]] || failed=1
    [[ ! -s "$stdout" ]] || failed=1
    [[ ! -s "$tmpdir/session.txt" ]] || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x9_session_helper_uses_canonical_codex_wrapper() {
  (
    set -u -o pipefail
    local tmpdir fake_root runner stdout line1 line_count failed=0

    tmpdir="$(mktemp -d)"
    fake_root="$tmpdir/fake_root"
    runner="$tmpdir/codex_session_runner.sh"
    stdout="$tmpdir/codex_session.stdout"

    mkdir -p "$fake_root/.claude/commands/lib" "$fake_root/scripts"
    /bin/cp "$PROJECT_ROOT/.claude/commands/lib/session.sh" "$fake_root/.claude/commands/lib/session.sh"

    write_lines "$fake_root/scripts/codex-wrapper.sh" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      'printf '"'"'wrapper=canonical-codex|argv=%s\n'"'"' "$*" >> "${SESSION_HELPER_LOG:?}"' \
      'cat >/dev/null || true' \
      'printf '"'"'canonical-codex-output\n'"'"''
    chmod +x "$fake_root/scripts/codex-wrapper.sh"

    write_lines "$fake_root/scripts/codex-wrapper-high.sh" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      'printf '"'"'wrapper=legacy-codex-shim|argv=%s\n'"'"' "$*" >> "${SESSION_HELPER_LOG:?}"' \
      'exit 97'
    chmod +x "$fake_root/scripts/codex-wrapper-high.sh"

    write_lines "$runner" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      'PROJECT_ROOT="$1"' \
      'FAKE_ROOT="$2"' \
      'TMPDIR_RUN="$3"' \
      '' \
      'export TMPDIR="$TMPDIR_RUN"' \
      'export SESSION_HELPER_LOG="$TMPDIR_RUN/session-helper.log"' \
      '' \
      'source "$PROJECT_ROOT/.claude/commands/lib/utils.sh"' \
      'source "$PROJECT_ROOT/.claude/commands/lib/timeout.sh"' \
      'source "$FAKE_ROOT/.claude/commands/lib/session.sh"' \
      '' \
      'get_latest_codex_session() {' \
      '  echo "codex-session-id"' \
      '}' \
      '' \
      'prompt_file="$TMPDIR_RUN/prompt.txt"' \
      'printf '"'"'codex prompt\n'"'"' > "$prompt_file"' \
      '' \
      'sid="$(codex_session_start "$prompt_file" "$TMPDIR_RUN/codex.txt" 5)"' \
      'printf '"'"'sid=%s\n'"'"' "$sid"'
    chmod +x "$runner"

    if ! bash "$runner" "$PROJECT_ROOT" "$fake_root" "$tmpdir" > "$stdout"; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    line_count="$(wc -l < "$tmpdir/session-helper.log" | tr -d '[:space:]')"
    line1="$(read_single_line "$tmpdir/session-helper.log")"

    [[ "$line_count" -eq 1 ]] || failed=1
    contains_text "wrapper=canonical-codex" "$line1" || failed=1
    assert_text_matches '^sid=codex-session-id$' "$stdout" || failed=1
    assert_text_matches '^canonical-codex-output$' "$tmpdir/codex.txt" || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x10_reviewer_helper_rejects_codex_wrapper_env_override() {
  (
    set -u -o pipefail
    local tmpdir fake_root runner stdout line1 line_count failed=0

    tmpdir="$(mktemp -d)"
    fake_root="$tmpdir/fake_root"
    runner="$tmpdir/reviewer_runner.sh"
    stdout="$tmpdir/reviewer.stdout"

    mkdir -p "$fake_root/.claude/commands/lib" "$fake_root/scripts"
    /bin/cp "$PROJECT_ROOT/.claude/commands/lib/reviewer.sh" "$fake_root/.claude/commands/lib/reviewer.sh"

    write_lines "$fake_root/scripts/codex-wrapper.sh" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      'printf '"'"'wrapper=canonical-reviewer|argv=%s\n'"'"' "$*" >> "${REVIEWER_HELPER_LOG:?}"' \
      'cat >/dev/null || true' \
      'printf '"'"'canonical-reviewer-output\n'"'"''
    chmod +x "$fake_root/scripts/codex-wrapper.sh"

    write_lines "$fake_root/scripts/escape-codex-wrapper.sh" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      'printf '"'"'wrapper=escape-reviewer|argv=%s\n'"'"' "$*" >> "${REVIEWER_HELPER_LOG:?}"' \
      'exit 96'
    chmod +x "$fake_root/scripts/escape-codex-wrapper.sh"

    write_lines "$runner" \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      'PROJECT_ROOT="$1"' \
      'FAKE_ROOT="$2"' \
      'TMPDIR_RUN="$3"' \
      '' \
      'export TMPDIR="$TMPDIR_RUN"' \
      'export REVIEWER_HELPER_LOG="$TMPDIR_RUN/reviewer-helper.log"' \
      '' \
      'source "$PROJECT_ROOT/.claude/commands/lib/utils.sh"' \
      'source "$FAKE_ROOT/.claude/commands/lib/reviewer.sh"' \
      '' \
      'coder_output="$TMPDIR_RUN/coder-output.md"' \
      'printf '"'"'coder output\n'"'"' > "$coder_output"' \
      '' \
      'export CODEX_WRAPPER_CANONICAL="$FAKE_ROOT/scripts/escape-codex-wrapper.sh"' \
      '' \
      'reviewer_run_single safety "$coder_output" "$TMPDIR_RUN/review.txt" 5'
    chmod +x "$runner"

    if bash "$runner" "$PROJECT_ROOT" "$fake_root" "$tmpdir" > "$stdout"; then
      failed=1
    fi

    if [[ -f "$tmpdir/reviewer-helper.log" ]]; then
      line_count="$(wc -l < "$tmpdir/reviewer-helper.log" | tr -d '[:space:]')"
      line1="$(read_single_line "$tmpdir/reviewer-helper.log")"
    else
      line_count="0"
      line1=""
    fi

    [[ "$line_count" -eq 0 ]] || failed=1
    [[ -z "$line1" ]] || failed=1
    [[ ! -s "$stdout" ]] || failed=1
    [[ ! -s "$tmpdir/review.txt" ]] || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

# NEGATIVE TEST: Codex top-level→Claude (claude-wrapper.sh) must be blocked.
# As of 2026-06-15 Agent SDK billing separation, this cross-family direction
# is excluded from the default flow. This test asserts that calling claude-wrapper.sh
# from a Codex top-level context emits the deprecation warning (PR-A shim behavior).
# See: docs/agent-sdk-policy.md, docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md
test_x11_claude_wrapper_rejects_external_stderr_root() {
  (
    set -u -o pipefail
    local tmpdir mockbin out stderr_text shim_log failed=0

    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    mockbin="$tmpdir/mockbin"
    out="$tmpdir/out.txt"
    shim_log="$tmpdir/shim-hits.log"
    : > "$tmpdir/codex.log"
    : > "$tmpdir/claude.log"

    SIMULATED_CALLER=codex \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      MOCK_CLAUDE_STDIN_DIR="$tmpdir/mock-claude-stdin" \
      CLAUDE_WRAPPER_STDERR_ROOT="$WRAPPER_STDERR_TEST_ROOT/x11" \
      REV_HARNESS_SHIM_HITS_LOG="$shim_log" \
      HOME="$tmpdir/home" \
      REV_HARNESS_CANONICAL_ROOT="$PROJECT_ROOT" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/claude-wrapper.sh" --output "$out" "x11 prompt" \
        > "$tmpdir/stdout.txt" 2> "$tmpdir/stderr.txt" || true

    stderr_text="$(cat "$tmpdir/stderr.txt")"
    contains_text "DEPRECATED" "$stderr_text" || failed=1
    if [[ ! -s "$shim_log" && ! -s "$tmpdir/home/.rev_harness/shim-hits.log" ]]; then
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x12_codex_wrapper_rejects_model_policy_overrides() {
  (
    set -u -o pipefail
    local tmpdir mockbin out failed=0 line_count=0
    local override_args=(
      "--enable multi_agent_v2"
      "--disable multi_agent"
      "-c features.multi_agent_v2=true"
      "-c agents.max_threads=2"
      "-c model=gpt-5.4" # example_forbidden_model negative override
      "-c model_reasoning_effort=low"
    )
    local args_string

    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    mockbin="$tmpdir/mockbin"
    out="$tmpdir/out.txt"
    : > "$tmpdir/codex.log"
    : > "$tmpdir/claude.log"

    for args_string in "${override_args[@]}"; do
      # shellcheck disable=SC2086
      if SIMULATED_CALLER=codex \
        MOCK_CODEX_LOG="$tmpdir/codex.log" \
        MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
        PATH="$mockbin:$PATH" \
        bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role coder $args_string --stdin \
          >> "$out" 2>> "$tmpdir/stderr.log" <<< "x12 override"; then
        failed=1
      fi
    done

    line_count="$(wc -l < "$tmpdir/codex.log" | tr -d '[:space:]')"
    [[ "$line_count" -eq 0 ]] || failed=1
    contains_text "Blocked override attempt" "$(cat "$tmpdir/stderr.log")" || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x13_codex_wrapper_rejects_api_key_auth() {
  (
    set -u -o pipefail
    local tmpdir mockbin out stderr_text failed=0 line_count=0

    tmpdir="$(mktemp -d)"
    setup_mocks "$tmpdir"
    mockbin="$tmpdir/mockbin"
    out="$tmpdir/out.txt"
    : > "$tmpdir/codex.log"
    : > "$tmpdir/claude.log"

    if OPENAI_API_KEY="test-openai-key" \
      CODEX_API_KEY="" \
      SIMULATED_CALLER=codex \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role coder --stdin \
        >> "$out" 2> "$tmpdir/openai.stderr" <<< "x13 openai key"; then
      failed=1
    fi

    if OPENAI_API_KEY="" \
      CODEX_API_KEY="test-codex-key" \
      SIMULATED_CALLER=codex \
      MOCK_CODEX_LOG="$tmpdir/codex.log" \
      MOCK_CLAUDE_LOG="$tmpdir/claude.log" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role coder --stdin \
        >> "$out" 2> "$tmpdir/codex.stderr" <<< "x13 codex key"; then
      failed=1
    fi

    line_count="$(wc -l < "$tmpdir/codex.log" | tr -d '[:space:]')"
    stderr_text="$(cat "$tmpdir/openai.stderr" "$tmpdir/codex.stderr")"
    [[ "$line_count" -eq 0 ]] || failed=1
    contains_text "OPENAI_API_KEY is set" "$stderr_text" || failed=1
    contains_text "CODEX_API_KEY is set" "$stderr_text" || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x14_vendored_wrappers_refused() {
  (
    set -u -o pipefail
    local tmpdir vendor_root claude_stderr codex_stderr claude_status codex_status failed=0

    tmpdir="$(mktemp -d)"
    vendor_root="$tmpdir/vendor_root"
    mkdir -p "$vendor_root"

    # canonical scripts/ ツリー一式を vendor 先にコピー (_canonical-guard.sh,
    # _shim-log.sh, claude-wrapper.sh, codex-wrapper.sh 等を含む)
    /bin/cp -R "$PROJECT_ROOT/scripts" "$vendor_root/scripts"

    claude_stderr="$tmpdir/claude.stderr"
    codex_stderr="$tmpdir/codex.stderr"

    # canonical root を別の存在しない (またはここの vendor_root と一致しない)
    # 場所に固定して、vendor 検出を強制する。
    set +e
    REV_HARNESS_CANONICAL_ROOT="$PROJECT_ROOT" \
      bash "$vendor_root/scripts/claude-wrapper.sh" --help \
        > /dev/null 2> "$claude_stderr"
    claude_status=$?

    REV_HARNESS_CANONICAL_ROOT="$PROJECT_ROOT" \
      bash "$vendor_root/scripts/codex-wrapper.sh" --help \
        > /dev/null 2> "$codex_stderr" < /dev/null
    codex_status=$?
    set -e

    [[ "$claude_status" -eq 70 ]] || failed=1
    contains_text "VENDOR GUARD" "$(cat "$claude_stderr")" || failed=1
    [[ "$codex_status" -eq 70 ]] || failed=1
    contains_text "VENDOR GUARD" "$(cat "$codex_stderr")" || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x14b_vendor_guard_warn_soft_mode() {
  (
    set -u -o pipefail
    local tmpdir vendor_root claude_stderr codex_stderr claude_status codex_status failed=0

    tmpdir="$(mktemp -d)"
    vendor_root="$tmpdir/vendor_root"
    mkdir -p "$vendor_root"

    /bin/cp -R "$PROJECT_ROOT/scripts" "$vendor_root/scripts"

    claude_stderr="$tmpdir/claude.stderr"
    codex_stderr="$tmpdir/codex.stderr"

    # soft mode: guard 自体は exit 70 せずに warning を出して通過する。
    # guard 通過後の wrapper 本体の振る舞い (CLI 不在等で非0終了) は
    # この test のスコープ外。stderr の WARNING marker のみ assert する。
    set +e
    REV_HARNESS_CANONICAL_ROOT="$PROJECT_ROOT" \
      REV_HARNESS_VENDOR_CHECK=warn \
      bash "$vendor_root/scripts/claude-wrapper.sh" --help \
        > /dev/null 2> "$claude_stderr"
    claude_status=$?

    REV_HARNESS_CANONICAL_ROOT="$PROJECT_ROOT" \
      REV_HARNESS_VENDOR_CHECK=warn \
      bash "$vendor_root/scripts/codex-wrapper.sh" --help \
        > /dev/null 2> "$codex_stderr" < /dev/null
    codex_status=$?
    set -e

    # guard で exit 70 されていないこと (= soft mode で通過していること)
    [[ "$claude_status" -ne 70 ]] || failed=1
    [[ "$codex_status" -ne 70 ]] || failed=1
    contains_text "soft-mode active" "$(cat "$claude_stderr")" || failed=1
    contains_text "soft-mode active" "$(cat "$codex_stderr")" || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

# ---------------------------------------------------------------------------
# X15a-d: scripts/codex-job.sh background job manager contract.
#
# These tests exercise codex-job.sh's CLI surface using a mockbin codex stub
# so that no real codex CLI is invoked. Each test isolates REV_HARNESS_RUN_DIR
# under its own mktemp directory so that concurrent jobs and gc do not leak.
#
# Expected codex-job.sh CLI:
#   start [--role <role>] [--timeout <sec>] <prompt>    -> stdout: <job-id>, exit 0
#   status <job-id>                                     -> stdout: status.json
#   wait <job-id> [--timeout <sec>]                     -> blocks until exit_code
#   result <job-id> [--field <name>]                    -> stdout: status JSON
#   gc [--ttl <days>]                                   -> remove TTL-expired jobs
# Jobs live at $REV_HARNESS_RUN_DIR/jobs/<id>/{cmd,pid,log,exit_code,status.json}.
# Exit codes: 0 success / 1 generic error / 64 usage / 70 internal / 124 timeout.
# ---------------------------------------------------------------------------

codex_job_setup_fast_stub() {
  # Writes a mockbin/codex stub that exits 0 immediately after echoing output.
  local mockbin="$1"
  mkdir -p "$mockbin"
  write_lines "$mockbin/codex" \
    '#!/usr/bin/env bash' \
    'printf '"'"'mock-codex-output\n'"'"'' \
    'exit 0'
  chmod +x "$mockbin/codex"
}

codex_job_setup_slow_stub() {
  # Writes a mockbin/codex stub that sleeps long enough to exceed wait timeouts.
  local mockbin="$1"
  mkdir -p "$mockbin"
  write_lines "$mockbin/codex" \
    '#!/usr/bin/env bash' \
    'sleep 30' \
    'exit 0'
  chmod +x "$mockbin/codex"
}

test_x15a_codex_job_start_status() {
  (
    set -u -o pipefail
    local tmpdir mockbin run_dir job_id status_out failed=0

    if [[ ! -x "$PROJECT_ROOT/scripts/codex-job.sh" ]]; then
      echo "X15a: scripts/codex-job.sh missing or not executable (expected to be provided by parallel work)" >&2
      return 1
    fi

    tmpdir="$(mktemp -d)"
    mockbin="$tmpdir/mockbin"
    run_dir="$tmpdir/run"
    mkdir -p "$run_dir"
    codex_job_setup_fast_stub "$mockbin"

    job_id="$(REV_HARNESS_RUN_DIR="$run_dir" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" start --role reviewer "Reply with: OK" \
      2>"$tmpdir/start.stderr")" || failed=1

    # job_id must be a single non-empty token (16+ chars typical, alnum/-_ allowed).
    if [[ -z "$job_id" ]]; then
      failed=1
    elif [[ ! "$job_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
      failed=1
    fi

    [[ -d "$run_dir/jobs/$job_id" ]] || failed=1
    [[ -s "$run_dir/jobs/$job_id/pid" ]] || failed=1
    [[ -s "$run_dir/jobs/$job_id/status.json" ]] || failed=1

    # status sub-command must return JSON-ish output containing state/role markers.
    status_out="$(REV_HARNESS_RUN_DIR="$run_dir" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" status "$job_id" 2>/dev/null)" || failed=1
    contains_text "\"state\"" "$status_out" || failed=1
    contains_text "reviewer" "$status_out" || failed=1
    contains_text "\"started_at\"" "$status_out" || failed=1

    # Best-effort: wait for completion so we do not leak the background process.
    REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" wait "$job_id" --timeout 10 >/dev/null 2>&1 || true

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x15b_codex_job_wait_completed() {
  (
    set -u -o pipefail
    local tmpdir mockbin run_dir job_id wait_out wait_status failed=0

    if [[ ! -x "$PROJECT_ROOT/scripts/codex-job.sh" ]]; then
      echo "X15b: scripts/codex-job.sh missing or not executable" >&2
      return 1
    fi

    tmpdir="$(mktemp -d)"
    mockbin="$tmpdir/mockbin"
    run_dir="$tmpdir/run"
    mkdir -p "$run_dir"
    codex_job_setup_fast_stub "$mockbin"

    job_id="$(REV_HARNESS_RUN_DIR="$run_dir" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" start "fast job" 2>/dev/null)" || failed=1

    [[ -n "$job_id" ]] || { /bin/rm -rf "$tmpdir"; return 1; }

    set +e
    wait_out="$(REV_HARNESS_RUN_DIR="$run_dir" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" wait "$job_id" --timeout 10 2>/dev/null)"
    wait_status=$?
    set -e

    [[ "$wait_status" -eq 0 ]] || failed=1
    contains_text "\"state\"" "$wait_out" || failed=1
    contains_text "completed" "$wait_out" || failed=1
    contains_text "\"exit_code\"" "$wait_out" || failed=1
    [[ -s "$run_dir/jobs/$job_id/exit_code" ]] || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x15c_codex_job_wait_timeout() {
  (
    set -u -o pipefail
    local tmpdir mockbin run_dir job_id wait_out wait_status pid failed=0

    if [[ ! -x "$PROJECT_ROOT/scripts/codex-job.sh" ]]; then
      echo "X15c: scripts/codex-job.sh missing or not executable" >&2
      return 1
    fi

    tmpdir="$(mktemp -d)"
    mockbin="$tmpdir/mockbin"
    run_dir="$tmpdir/run"
    mkdir -p "$run_dir"
    codex_job_setup_slow_stub "$mockbin"

    job_id="$(REV_HARNESS_RUN_DIR="$run_dir" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" start "slow job" 2>/dev/null)" || failed=1

    [[ -n "$job_id" ]] || { /bin/rm -rf "$tmpdir"; return 1; }

    set +e
    wait_out="$(REV_HARNESS_RUN_DIR="$run_dir" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" wait "$job_id" --timeout 2 2>/dev/null)"
    wait_status=$?
    set -e

    [[ "$wait_status" -eq 124 ]] || failed=1
    contains_text "\"state\"" "$wait_out" || failed=1
    contains_text "running" "$wait_out" || failed=1
    [[ ! -s "$run_dir/jobs/$job_id/exit_code" ]] || failed=1

    # Cleanup: kill the still-running background job tree to avoid leaking sleep stubs.
    if [[ -s "$run_dir/jobs/$job_id/pid" ]]; then
      pid="$(read_single_line "$run_dir/jobs/$job_id/pid")"
      if [[ -n "$pid" ]]; then
        kill_process_tree "$pid" TERM 2>/dev/null || true
        sleep 1
        kill_process_tree "$pid" KILL 2>/dev/null || true
      fi
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x15d_codex_job_gc_and_unique_ids() {
  (
    set -u -o pipefail
    local tmpdir mockbin run_dir id1 id2 id3 unique_count remaining failed=0

    if [[ ! -x "$PROJECT_ROOT/scripts/codex-job.sh" ]]; then
      echo "X15d: scripts/codex-job.sh missing or not executable" >&2
      return 1
    fi

    tmpdir="$(mktemp -d)"
    mockbin="$tmpdir/mockbin"
    run_dir="$tmpdir/run"
    mkdir -p "$run_dir"
    codex_job_setup_fast_stub "$mockbin"

    # Fire three start calls back-to-back; codex-job.sh start must return promptly.
    id1="$(REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" start "job-a" 2>/dev/null)" || failed=1
    id2="$(REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" start "job-b" 2>/dev/null)" || failed=1
    id3="$(REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" start "job-c" 2>/dev/null)" || failed=1

    [[ -n "$id1" && -n "$id2" && -n "$id3" ]] || failed=1

    unique_count="$(printf '%s\n%s\n%s\n' "$id1" "$id2" "$id3" | sort -u | wc -l | tr -d '[:space:]')"
    [[ "$unique_count" -eq 3 ]] || failed=1

    # Wait for all three jobs to finish before invoking gc.
    REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" wait "$id1" --timeout 10 >/dev/null 2>&1 || failed=1
    REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" wait "$id2" --timeout 10 >/dev/null 2>&1 || failed=1
    REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" wait "$id3" --timeout 10 >/dev/null 2>&1 || failed=1

    REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" gc --ttl 0 >/dev/null 2>&1 || failed=1

    # After gc --ttl 0 there must be no surviving job directories.
    if [[ -d "$run_dir/jobs" ]]; then
      remaining="$(find "$run_dir/jobs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
      [[ "$remaining" -eq 0 ]] || failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x15e_codex_job_shim_log_job_id() {
  (
    set -u -o pipefail
    local tmpdir mockbin run_dir shim_log job_id match_line failed=0

    if [[ ! -x "$PROJECT_ROOT/scripts/codex-job.sh" ]]; then
      echo "X15e: scripts/codex-job.sh missing or not executable" >&2
      return 1
    fi

    tmpdir="$(mktemp -d)"
    mockbin="$tmpdir/mockbin"
    run_dir="$tmpdir/run"
    shim_log="$tmpdir/shim-hits.log"
    mkdir -p "$run_dir" "$tmpdir/home"
    codex_job_setup_fast_stub "$mockbin"

    job_id="$(REV_HARNESS_RUN_DIR="$run_dir" \
      REV_HARNESS_SHIM_HITS_LOG="$shim_log" \
      REV_HARNESS_CANONICAL_ROOT="$PROJECT_ROOT" \
      HOME="$tmpdir/home" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" start --role reviewer "x15e prompt" \
      2>/dev/null)" || failed=1

    [[ -n "$job_id" ]] || { /bin/rm -rf "$tmpdir"; return 1; }

    # 完了まで待ってバックグラウンドを残さない
    REV_HARNESS_RUN_DIR="$run_dir" \
      REV_HARNESS_SHIM_HITS_LOG="$shim_log" \
      REV_HARNESS_CANONICAL_ROOT="$PROJECT_ROOT" \
      HOME="$tmpdir/home" \
      PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" wait "$job_id" --timeout 10 \
        >/dev/null 2>&1 || true

    # shim-hits.log は REV_HARNESS_SHIM_HITS_LOG 指定パス、または HOME 下に
    # 出力されているはず。
    local effective_log=""
    if [[ -s "$shim_log" ]]; then
      effective_log="$shim_log"
    elif [[ -s "$tmpdir/home/.rev_harness/shim-hits.log" ]]; then
      effective_log="$tmpdir/home/.rev_harness/shim-hits.log"
    fi
    if [[ -z "$effective_log" ]]; then
      /bin/rm -rf "$tmpdir"
      return 1
    fi

    # codex-job-start かつ当該 job_id を持つ行が存在することを確認
    match_line="$(grep -F "\"rewrite_target\":\"codex-job-start\"" "$effective_log" \
      | grep -F "\"job_id\":\"${job_id}\"" | head -n 1)"
    [[ -n "$match_line" ]] || failed=1

    # 一致行が有効な JSON であること (python3 で parse、なければ jq)
    if [[ -n "$match_line" ]]; then
      if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$match_line" \
          | python3 -c 'import sys,json; json.loads(sys.stdin.read())' \
          >/dev/null 2>&1 || failed=1
      elif command -v jq >/dev/null 2>&1; then
        printf '%s' "$match_line" | jq -e . >/dev/null 2>&1 || failed=1
      fi
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x15f_codex_job_wait_timeout_zero() {
  (
    set -u -o pipefail
    local tmpdir mockbin run_dir job_id wait_status pid failed=0

    if [[ ! -x "$PROJECT_ROOT/scripts/codex-job.sh" ]]; then
      echo "X15f: scripts/codex-job.sh missing or not executable" >&2
      return 1
    fi

    tmpdir="$(mktemp -d)"
    mockbin="$tmpdir/mockbin"
    run_dir="$tmpdir/run"
    mkdir -p "$run_dir"

    # Case 1: still-running job -> --timeout 0 must return 124 immediately.
    codex_job_setup_slow_stub "$mockbin"
    job_id="$(REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" start "slow" 2>/dev/null)" || failed=1
    [[ -n "$job_id" ]] || { /bin/rm -rf "$tmpdir"; return 1; }

    set +e
    REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" wait "$job_id" --timeout 0 >/dev/null 2>&1
    wait_status=$?
    set -e
    [[ "$wait_status" -eq 124 ]] || failed=1

    # Cleanup slow background job.
    if [[ -s "$run_dir/jobs/$job_id/pid" ]]; then
      pid="$(read_single_line "$run_dir/jobs/$job_id/pid")"
      if [[ -n "$pid" ]]; then
        kill_process_tree "$pid" TERM 2>/dev/null || true
        sleep 1
        kill_process_tree "$pid" KILL 2>/dev/null || true
      fi
    fi

    # Case 2: completed job -> --timeout 0 must return the job's exit code (0).
    /bin/rm -rf "$run_dir"
    mkdir -p "$run_dir"
    codex_job_setup_fast_stub "$mockbin"
    job_id="$(REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" start "fast" 2>/dev/null)" || failed=1
    [[ -n "$job_id" ]] || { /bin/rm -rf "$tmpdir"; return 1; }

    # Wait synchronously so the job is fully completed.
    REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" wait "$job_id" --timeout 10 >/dev/null 2>&1 || true

    set +e
    REV_HARNESS_RUN_DIR="$run_dir" PATH="$mockbin:$PATH" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" wait "$job_id" --timeout 0 >/dev/null 2>&1
    wait_status=$?
    set -e
    [[ "$wait_status" -eq 0 ]] || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x15g_codex_job_gc_ttl_validation() {
  (
    set -u -o pipefail
    local tmpdir run_dir rc failed=0

    if [[ ! -x "$PROJECT_ROOT/scripts/codex-job.sh" ]]; then
      echo "X15g: scripts/codex-job.sh missing or not executable" >&2
      return 1
    fi

    tmpdir="$(mktemp -d)"
    run_dir="$tmpdir/run"
    mkdir -p "$run_dir"

    # Non-numeric -> 64
    set +e
    REV_HARNESS_RUN_DIR="$run_dir" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" gc --ttl abc >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 64 ]] || failed=1

    # Negative -> 64 (regex rejects leading '-')
    set +e
    REV_HARNESS_RUN_DIR="$run_dir" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" gc --ttl -1 >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 64 ]] || failed=1

    # Out-of-range (>365) -> 64
    set +e
    REV_HARNESS_RUN_DIR="$run_dir" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" gc --ttl 99999 >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 64 ]] || failed=1

    # Sanity: a valid TTL still succeeds.
    set +e
    REV_HARNESS_RUN_DIR="$run_dir" \
      bash "$PROJECT_ROOT/scripts/codex-job.sh" gc --ttl 7 >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]] || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_x15h_codex_job_path_traversal_rejected() {
  (
    set -u -o pipefail
    local tmpdir run_dir rc failed=0

    if [[ ! -x "$PROJECT_ROOT/scripts/codex-job.sh" ]]; then
      echo "X15h: scripts/codex-job.sh missing or not executable" >&2
      return 1
    fi

    tmpdir="$(mktemp -d)"
    run_dir="$tmpdir/run"
    mkdir -p "$run_dir"

    # Each of these job-ids must be refused with exit 64 by status/wait/result.
    local bad_ids=( '../../etc/passwd' '..' '/' 'foo/bar' 'UPPERCASE' 'short' '../sibling' )
    local sub bad
    for sub in status wait result; do
      for bad in "${bad_ids[@]}"; do
        set +e
        REV_HARNESS_RUN_DIR="$run_dir" \
          bash "$PROJECT_ROOT/scripts/codex-job.sh" "$sub" "$bad" >/dev/null 2>&1
        rc=$?
        set -e
        if [[ "$rc" -ne 64 ]]; then
          echo "X15h: ${sub} ${bad} -> rc=${rc} (expected 64)" >&2
          failed=1
        fi
      done
    done

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

dispatch_test() {
  local id="$1"
  case "$id" in
    X1) test_x1_codex_to_codex ;;
    X2) test_x2_codex_to_claude ;;
    X3) test_x3_claude_to_codex ;;
    X4) test_x4_claude_to_claude ;;
    X5) test_x5_session_helpers_use_wrapper ;;
    X6) test_x6_codex_wrapper_strips_location_escape_flags ;;
    X7) test_x7_claude_wrapper_strips_equals_form_bypass_flags ;;
    X8) test_x8_session_helper_rejects_claude_wrapper_env_override ;;
    X9) test_x9_session_helper_uses_canonical_codex_wrapper ;;
    X10) test_x10_reviewer_helper_rejects_codex_wrapper_env_override ;;
    X11) test_x11_claude_wrapper_rejects_external_stderr_root ;;
    X12) test_x12_codex_wrapper_rejects_model_policy_overrides ;;
    X13) test_x13_codex_wrapper_rejects_api_key_auth ;;
    X14) test_x14_vendored_wrappers_refused ;;
    X14b) test_x14b_vendor_guard_warn_soft_mode ;;
    X15a) test_x15a_codex_job_start_status ;;
    X15b) test_x15b_codex_job_wait_completed ;;
    X15c) test_x15c_codex_job_wait_timeout ;;
    X15d) test_x15d_codex_job_gc_and_unique_ids ;;
    X15e) test_x15e_codex_job_shim_log_job_id ;;
    X15f) test_x15f_codex_job_wait_timeout_zero ;;
    X15g) test_x15g_codex_job_gc_ttl_validation ;;
    X15h) test_x15h_codex_job_path_traversal_rejected ;;
    *) return 2 ;;
  esac
}

run_test() {
  local id="$1"
  local description=""

  description="$(test_description "$id")" || description="(unknown)"
  echo "[TEST] $id - $description"

  if dispatch_test_with_timeout "$id"; then
    echo "PASS: $id"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $id"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

list_tests() {
  local id
  for id in "${ALL_TEST_IDS[@]}"; do
    echo "$id - $(test_description "$id")"
  done
}

main() {
  require_cmd awk
  require_cmd bash
  require_cmd mktemp

  require_file "$PROJECT_ROOT/scripts/codex-wrapper.sh"
  require_file "$PROJECT_ROOT/scripts/codex-wrapper-medium.sh"
  require_file "$PROJECT_ROOT/scripts/codex-wrapper-high.sh"
  require_file "$PROJECT_ROOT/scripts/codex-wrapper-xhigh.sh"
  require_file "$PROJECT_ROOT/scripts/claude-wrapper.sh"

  local selected_tests=()
  if [[ "$#" -eq 0 ]]; then
    selected_tests=("${ALL_TEST_IDS[@]}")
  elif [[ "$#" -eq 1 && "$1" == "--list" ]]; then
    list_tests
    exit 0
  else
    local id
    for id in "$@"; do
      if ! test_description "$id" >/dev/null 2>&1; then
        echo "ERROR: unknown test id: $id" >&2
        echo "Use --list to show available test ids." >&2
        exit 2
      fi
      selected_tests+=("$id")
    done
  fi

  local id
  for id in "${selected_tests[@]}"; do
    run_test "$id"
    echo
  done

  echo "RESULT: pass=$PASS_COUNT fail=$FAIL_COUNT"
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
