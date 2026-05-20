#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP_ROOT=""

cleanup() {
  rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || fail "missing expected text in $file: $needle"
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  if [[ -f "$file" ]] && grep -Fq -- "$needle" "$file"; then
    fail "unexpected text found in $file: $needle"
  fi
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || fail "missing file: $path"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$expected" == "$actual" ]] || fail "$message (expected=$expected actual=$actual)"
}

assert_jq_equals() {
  local file="$1"
  local query="$2"
  local expected="$3"
  local actual
  actual=$(jq -r "$query" "$file")
  assert_equals "$expected" "$actual" "jq assertion failed: $query"
}

assert_jq_empty() {
  local file="$1"
  local query="$2"
  local actual
  actual=$(jq -r "$query // empty" "$file")
  [[ -z "$actual" ]] || fail "jq assertion failed: $query should be empty (actual=$actual)"
}

line_count() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo 0
    return 0
  fi

  wc -l < "$file" | tr -d '[:space:]'
}

normalize_path() {
  printf '%s\n' "$1" | sed 's#//*#/#g'
}

last_line() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 1
  fi

  awk 'NF { line = $0 } END { if (line != "") print line }' "$file"
}

state_file_for_plan() {
  local repo="$1"
  local plan_path="$2"
  local task
  task="$(basename "$plan_path")"
  task="${task%.*}"
  printf '%s/.claude/tmp/%s/state.json\n' "$repo" "$task"
}

strip_engine_metadata_from_state() {
  local state_file="$1"
  local tmp_file

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/coder_engine_state.XXXXXX")"
  jq '
    del(.assignments.coder_engine)
    | (.phases |= map(
        if (.coder // null) != null then
          .coder |= del(.engine)
        else
          .
        end
      ))
    | (.sessions.coder_sessions |= map(del(.engine)))
  ' "$state_file" > "$tmp_file"
  mv "$tmp_file" "$state_file"
}

set_assignment_coder_engine() {
  local state_file="$1"
  local engine="$2"
  local tmp_file

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/coder_engine_assignment.XXXXXX")"
  jq --arg engine "$engine" '.assignments.coder_engine = $engine' "$state_file" > "$tmp_file"
  mv "$tmp_file" "$state_file"
}

set_first_session_engine_to_boolean_true() {
  local state_file="$1"
  local tmp_file

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/coder_engine_session.XXXXXX")"
  jq '
    del(.assignments.coder_engine)
    | (.phases |= map(
        if (.coder // null) != null then
          .coder |= del(.engine)
        else
          .
        end
      ))
    | (.sessions.coder_sessions[0].engine = true)
  ' "$state_file" > "$tmp_file"
  mv "$tmp_file" "$state_file"
}

set_first_session_engine_to_invalid_string() {
  local state_file="$1"
  local tmp_file

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/coder_engine_session.XXXXXX")"
  jq '
    del(.assignments.coder_engine)
    | (.phases |= map(
        if (.coder // null) != null then
          .coder |= del(.engine)
        else
          .
        end
      ))
    | (.sessions.coder_sessions[0].engine = "broken")
  ' "$state_file" > "$tmp_file"
  mv "$tmp_file" "$state_file"
}

expected_codex_role_for_plan() {
  local repo="$1"
  local plan_path="$2"

  (
    set -euo pipefail
    REPO_ROOT="$repo"
    LIB_DIR="$repo/.claude/commands/lib"
    PROMPT_DIR="$repo/docs/prompts"
    # shellcheck source=/dev/null
    source "$repo/.claude/commands/lib/utils.sh"
    # shellcheck source=/dev/null
    source "$repo/.claude/commands/lib/coder.sh"
    select_codex_role_by_complexity "$plan_path"
  )
}

remove_latest_coder_output() {
  local repo="$1"
  /bin/rm -f "$repo/.claude/tmp/plan/impl_coder.md"
}

disable_codex_session_capture() {
  local repo="$1"
  cat >> "$repo/.claude/commands/lib/session.sh" <<'EOF'
get_latest_codex_session() {
  return 0
}
EOF
}

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s' "$*" > "$path"
}

setup_fake_repo() {
  local repo="$1"

  mkdir -p \
    "$repo/.claude/commands/lib" \
    "$repo/.claude/tmp" \
    "$repo/.shared" \
    "$repo/docs/prompts" \
    "$repo/scripts"

  /bin/cp "$PROJECT_ROOT/.claude/commands/auto_orchestrate.sh" "$repo/.claude/commands/auto_orchestrate.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/coder.sh" "$repo/.claude/commands/lib/coder.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/state.sh" "$repo/.claude/commands/lib/state.sh"
  # auto_orchestrate now blocks before coder selection if task_contract.sh is absent.
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/task_contract.sh" "$repo/.claude/commands/lib/task_contract.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/utils.sh" "$repo/.claude/commands/lib/utils.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/timeout.sh" "$repo/.claude/commands/lib/timeout.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/orchestration_packet.sh" "$repo/.claude/commands/lib/orchestration_packet.sh"

  write_file "$repo/.claude/commands/lib/session.sh" '#!/usr/bin/env bash
set -euo pipefail

SESSION_TIMEOUT="${SESSION_TIMEOUT:-1800}"

_stub_counter_file() {
  local prefix="$1"
  printf "%s/%s.count\n" "${SESSION_COUNTER_DIR:?}" "$prefix"
}

_stub_next_session_id() {
  local prefix="$1"
  local count_file
  local count=0

  mkdir -p "${SESSION_COUNTER_DIR:?}"
  count_file=$(_stub_counter_file "$prefix")
  if [[ -f "$count_file" ]]; then
    count=$(cat "$count_file")
  fi

  count=$((count + 1))
  printf "%s" "$count" > "$count_file"
  printf "%s-session-%03d\n" "$prefix" "$count"
}

_stub_trace() {
  printf "%s\n" "$*" >> "${SESSION_HELPER_TRACE:?}"
}

_stub_write_output() {
  local output_file="${1:-}"
  local label="${2:-stub output}"
  if [[ -n "$output_file" ]]; then
    printf "# %s\n\n---OUTPUT-END---\n" "$label" > "$output_file"
  fi
}

_validate_session_id() {
  [[ -n "${1:-}" ]]
}

session_start() {
  local prompt="$1"
  local output_file="${2:-}"
  local session_id
  session_id=$(_stub_next_session_id "claude")
  _stub_write_output "$output_file" "claude session start"
  _stub_trace "start:${session_id}"
  printf "%s\n" "$session_id"
}

session_resume() {
  local session_id="$1"
  local prompt="$2"
  local output_file="${3:-}"
  _stub_write_output "$output_file" "claude session resume"
  _stub_trace "resume:${session_id}"
  return 0
}

session_fork() {
  local parent_session_id="$1"
  local prompt="$2"
  local output_file="${3:-}"
  local session_id
  session_id=$(_stub_next_session_id "claude")
  _stub_write_output "$output_file" "claude session fork"
  _stub_trace "fork:${parent_session_id}->${session_id}"
  printf "%s\n" "$session_id"
}

session_run_with_timeout() {
  local timeout_secs="$1"
  local session_id="$2"
  local prompt="$3"
  local output_file="${4:-}"

  if [[ -z "$session_id" || "$session_id" == "new" ]]; then
    session_start "$prompt" "$output_file" >/dev/null
  else
    session_resume "$session_id" "$prompt" "$output_file"
  fi
}

get_latest_codex_session() {
  local after_epoch="${1:-0}"
  local session_id
  session_id=$(_stub_next_session_id "codex")
  _stub_trace "codex-latest:${session_id}"
  printf "%s\n" "$session_id"
}
'

  write_file "$repo/.claude/commands/lib/reviewer.sh" '#!/usr/bin/env bash
set -euo pipefail

reviewer_run_all() {
  return 1
}

reviewer_record_to_state() {
  :
}

show_issue_counts() {
  :
}
'

  write_file "$repo/.claude/commands/lib/context_analysis.sh" '#!/usr/bin/env bash
set -euo pipefail

context_update() {
  printf "{\"status\":\"ok\"}\n"
}

context_detect_deletions() {
  printf "{\"deleted_paths\":[],\"removed_symbols\":[],\"move_candidates\":[]}\n"
}

preflight_check() {
  printf "{\"verdict\":\"PASS\",\"conflicts\":[]}\n"
}

context_delta() {
  printf "{\"delta\":\"ok\"}\n"
}

context_diff_impact() {
  printf "{\"impact\":\"ok\"}\n"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  command="${1:-}"
  shift || true
  case "$command" in
    update) context_update "$@" ;;
    detect-deletions) context_detect_deletions "$@" ;;
    delta) context_delta "$@" ;;
    diff-impact) context_diff_impact "$@" ;;
    *) preflight_check "$@" ;;
  esac
fi
'

  write_file "$repo/.claude/commands/lib/context_capsule.sh" '#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "build" ]]; then
  printf "{\"capsule\":\"\",\"constraints\":[],\"hints\":[]}\n"
  exit 0
fi

exit 1
'

  write_file "$repo/scripts/codex-wrapper.sh" '#!/usr/bin/env bash
set -euo pipefail

printf "%s\n" "$*" >> "${CODEX_WRAPPER_TRACE:?}"
cat >/dev/null || true
printf "# codex wrapper output\n\n---OUTPUT-END---\n"
'

  write_file "$repo/scripts/resolve-semantic-project-id.sh" '#!/usr/bin/env bash
set -euo pipefail

repo_root=""
mode=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      repo_root="${2:-}"
      shift 2
      ;;
    --print)
      mode="print"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

[[ "$mode" == "print" ]] || exit 1
[[ -n "$repo_root" ]] || exit 1
cat "$repo_root/.shared/project_id"
'

  write_file "$repo/docs/prompts/reviewer_batch.md" '# reviewer batch template
'
  write_file "$repo/docs/prompts/reviewer_safety.md" '# reviewer safety
'
  write_file "$repo/docs/prompts/reviewer_perf.md" '# reviewer perf
'
  write_file "$repo/docs/prompts/reviewer_consistency.md" '# reviewer consistency
'
  write_file "$repo/docs/prompts/coder_phase_impl.md" '# coder impl
Implement the requested change.
'
  write_file "$repo/plan.md" '# ExecPlan: Coder Engine Truth
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- bash test/integration/coder_engine_truth_test.sh

## Completion Boundary
- keep coder engine truth behavior deterministic
'
  write_file "$repo/.shared/project_id" 'coder-engine-truth
'

  chmod +x \
    "$repo/.claude/commands/auto_orchestrate.sh" \
    "$repo/.claude/commands/lib/session.sh" \
    "$repo/.claude/commands/lib/reviewer.sh" \
    "$repo/.claude/commands/lib/context_analysis.sh" \
    "$repo/.claude/commands/lib/context_capsule.sh" \
    "$repo/scripts/codex-wrapper.sh" \
    "$repo/scripts/resolve-semantic-project-id.sh"

  (
    cd "$repo"
    git init -q
  )

  : > "$repo/.claude/tmp/session.trace"
  : > "$repo/.claude/tmp/codex-wrapper.trace"
}

run_auto() {
  local repo="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3

  (
    cd "$repo"
    CODEX_WRAPPER_TRACE="$repo/.claude/tmp/codex-wrapper.trace" \
    SESSION_HELPER_TRACE="$repo/.claude/tmp/session.trace" \
    SESSION_COUNTER_DIR="$repo/.claude/tmp/session-counters" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$repo/.claude/commands/auto_orchestrate.sh" "$@"
  ) >"$stdout_file" 2>"$stderr_file"
}

run_fix_iteration_direct() {
  local repo="$1"
  local review_file="$2"
  local stdout_file="$3"
  local stderr_file="$4"

  (
    cd "$repo"
    # shellcheck source=/dev/null
    source "$repo/.claude/commands/auto_orchestrate.sh"

    PLAN="$repo/plan.md"
    PHASE="impl"
    FIX_UNTIL="all"
    CODER_ENGINE="codex"
    SESSION_ID=""

    state_init "$PLAN" "plan" "$repo/.claude/tmp/plan"
    state_upsert_phase "$PHASE" 5
    persist_coder_engine_assignment "$CODER_ENGINE"
    state_set '.status' '"running"'
    state_set_phase_status "$PHASE" "fixing"
    state_save

    run_fix_iteration "$repo/.claude/tmp/plan" "$PHASE" "$PLAN" "$review_file" 1
  ) >"$stdout_file" 2>"$stderr_file"
}

test_explicit_codex_truth() {
  local repo="$TMP_ROOT/codex"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local state_file
  local expected_role
  local contract_rel_path
  local contract_abs_path
  local state_contract_id
  local artifact_contract_id
  local state_task_id
  local contract_task_id

  setup_fake_repo "$repo"
  run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine codex

  state_file=$(state_file_for_plan "$repo" "$repo/plan.md")
  expected_role=$(expected_codex_role_for_plan "$repo" "$repo/plan.md")
  contract_rel_path="$(jq -r '.task.contract_path' "$state_file")"
  contract_abs_path="$repo/$contract_rel_path"
  assert_equals '.claude/tmp/plan/task-contract.json' "$contract_rel_path" "state should persist the emitted contract path"
  assert_file_exists "$contract_abs_path"
  state_contract_id="$(jq -r '.task.contract_id' "$state_file")"
  artifact_contract_id="$(jq -r '.contract_id' "$contract_abs_path")"
  state_task_id="$(jq -r '.task.id' "$state_file")"
  contract_task_id="$(jq -r '.task_id' "$contract_abs_path")"

  assert_file_contains "$stderr_file" 'Running Coder (Codex) for phase: impl'
  assert_file_contains "$repo/.claude/tmp/codex-wrapper.trace" "--role ${expected_role} --stdin"
  assert_file_contains "$repo/.claude/tmp/session.trace" 'codex-latest:codex-session-001'
  assert_equals "1" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" "unexpected codex wrapper call count"
  assert_jq_equals "$state_file" '.assignments.coder_engine' 'codex'
  assert_jq_equals "$state_file" '.phases[0].coder.engine' 'codex'
  assert_jq_empty "$state_file" '.phases[0].coder.session_id'
  assert_jq_equals "$state_file" '.sessions.coder_sessions[0].engine' 'codex'
  assert_jq_equals "$state_file" '.sessions.coder_sessions[0].session_id' 'codex-session-001'
  assert_equals "$state_contract_id" "$artifact_contract_id" "state contract_id should match emitted artifact"
  assert_equals "$state_task_id" "$contract_task_id" "runtime contract task_id should follow state.task.id"
  assert_jq_equals "$contract_abs_path" '.artifact_destination' "$contract_rel_path"
}

test_security_sensitive_codex_uses_high_cached_lane() {
  local repo="$TMP_ROOT/codex-security-sensitive"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"

  setup_fake_repo "$repo"
  cat >> "$repo/plan.md" <<'EOF'

security-sensitive=true
EOF

  run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine codex

  assert_file_contains "$stderr_file" 'security-sensitive: true'
  assert_file_contains "$stderr_file" 'context-mode: full'
  assert_file_contains "$stderr_file" 'Security-sensitive task detected. Use full-context analysis; do not rely on diff-only reasoning.'
  assert_file_contains "$repo/.claude/tmp/codex-wrapper.trace" '--role high-coder --stdin'
  assert_equals "1" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" "unexpected codex wrapper call count"
}

test_codex_coder_rejects_wrapper_env_escape() {
  local repo="$TMP_ROOT/codex-wrapper-env-escape"
  local escape_wrapper="$repo/escape-codex-wrapper.sh"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"

  setup_fake_repo "$repo"
  write_file "$escape_wrapper" '#!/usr/bin/env bash
set -euo pipefail
printf "escape-wrapper\n" >> "${CODEX_WRAPPER_TRACE:?}"
'
  chmod +x "$escape_wrapper"

  if (
    cd "$repo"
    REPO_ROOT="$repo"
    LIB_DIR="$repo/.claude/commands/lib"
    PROMPT_DIR="$repo/docs/prompts"
    CODEX_WRAPPER_CANONICAL="$escape_wrapper"
    CODEX_WRAPPER_TRACE="$repo/.claude/tmp/codex-wrapper.trace"
    PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    export REPO_ROOT LIB_DIR PROMPT_DIR CODEX_WRAPPER_CANONICAL CODEX_WRAPPER_TRACE PATH
    # shellcheck source=/dev/null
    source "$repo/.claude/commands/lib/utils.sh"
    # shellcheck source=/dev/null
    source "$repo/.claude/commands/lib/coder.sh"
    coder_run "$repo/plan.md" impl "$repo/.claude/tmp/env_escape_output.md" "" codex
  ) >"$stdout_file" 2>"$stderr_file"; then
    fail "coder should reject CODEX_WRAPPER_CANONICAL outside the repo-local canonical wrapper"
  fi

  assert_file_contains "$stderr_file" 'CODEX_WRAPPER_CANONICAL must resolve to canonical repo path'
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" "escape wrapper must not run"
}

test_explicit_claude_truth() {
  local repo="$TMP_ROOT/claude"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local state_file

  setup_fake_repo "$repo"
  run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine claude

  state_file=$(state_file_for_plan "$repo" "$repo/plan.md")

  assert_file_contains "$stderr_file" 'Running Coder (Claude) for phase: impl'
  assert_file_contains "$repo/.claude/tmp/session.trace" 'start:claude-session-001'
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" "codex wrapper should not run for claude engine"
  assert_jq_equals "$state_file" '.assignments.coder_engine' 'claude'
  assert_jq_equals "$state_file" '.phases[0].coder.engine' 'claude'
  assert_jq_empty "$state_file" '.phases[0].coder.session_id'
  assert_jq_equals "$state_file" '.sessions.coder_sessions[0].engine' 'claude'
  assert_jq_equals "$state_file" '.sessions.coder_sessions[0].session_id' 'claude-session-001'
}

test_resume_state_rejects_fork_flag() {
  local repo="$TMP_ROOT/codex-fork-blocked"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local resume_stdout="$repo/resume.stdout"
  local resume_stderr="$repo/resume.stderr"
  local state_file

  setup_fake_repo "$repo"
  run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine codex

  state_file=$(state_file_for_plan "$repo" "$repo/plan.md")
  remove_latest_coder_output "$repo"

  if run_auto "$repo" "$resume_stdout" "$resume_stderr" \
    --resume "$state_file" \
    --run-coder \
    --fork-session; then
    fail "fork-session should fail closed in orchestrated flow"
  fi

  assert_file_contains "$resume_stderr" 'Non-interactive invariant: --continue-session/--fork-session are disabled in orchestrated flow'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'fork:'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'resume:'
  assert_equals "1" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" "fork-session rejection should not start a second codex run"
}

test_codex_run_records_phase_output_without_session_id() {
  local repo="$TMP_ROOT/codex-no-session"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local state_file
  local expected_output_file
  local actual_output_file

  setup_fake_repo "$repo"
  disable_codex_session_capture "$repo"

  run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine codex

  state_file=$(state_file_for_plan "$repo" "$repo/plan.md")
  expected_output_file=$(normalize_path "$repo/.claude/tmp/plan/impl_coder.md")
  actual_output_file=$(normalize_path "$(jq -r '.phases[0].coder.output_file' "$state_file")")

  assert_file_contains "$stderr_file" 'Coder session ID was not captured; recorded phase output and engine without session linkage'
  assert_jq_equals "$state_file" '.assignments.coder_engine' 'codex'
  assert_jq_equals "$state_file" '.phases[0].coder.engine' 'codex'
  assert_equals "$expected_output_file" "$actual_output_file" "phase coder output file should still be recorded without session linkage"
  assert_jq_equals "$state_file" '.sessions.coder_sessions | length' '0'
}

test_codex_fix_records_phase_output_without_session_id() {
  local repo="$TMP_ROOT/codex-fix-no-session"
  local review_file="$repo/reviews.md"
  local stdout_file="$repo/fix.stdout"
  local stderr_file="$repo/fix.stderr"
  local state_file
  local expected_output_file
  local actual_output_file

  setup_fake_repo "$repo"
  disable_codex_session_capture "$repo"
  write_file "$review_file" '# Code Review Report

## Findings
- None.
'

  run_fix_iteration_direct "$repo" "$review_file" "$stdout_file" "$stderr_file"

  state_file="$repo/.claude/tmp/plan/state.json"
  expected_output_file=$(normalize_path "$repo/.claude/tmp/plan/impl_coder_fix1.md")
  actual_output_file=$(normalize_path "$(jq -r '.phases[0].coder.output_file' "$state_file")")

  assert_file_contains "$stderr_file" 'Fix session ID was not captured; recorded phase output and engine without session linkage'
  assert_file_contains "$stdout_file" "$repo/.claude/tmp/plan/impl_coder_fix1.md"
  assert_jq_equals "$state_file" '.assignments.coder_engine' 'codex'
  assert_jq_equals "$state_file" '.phases[0].coder.engine' 'codex'
  assert_equals "$expected_output_file" "$actual_output_file" "fix coder output file should still be recorded without session linkage"
  assert_jq_equals "$state_file" '.sessions.coder_sessions | length' '0'
}

test_resume_uses_selected_engine_family() {
  local repo="$TMP_ROOT/family"
  local first_stdout="$repo/first.stdout"
  local first_stderr="$repo/first.stderr"
  local second_stdout="$repo/second.stdout"
  local second_stderr="$repo/second.stderr"
  local third_stdout="$repo/third.stdout"
  local third_stderr="$repo/third.stderr"
  local state_file
  local final_trace

  setup_fake_repo "$repo"
  run_auto "$repo" "$first_stdout" "$first_stderr" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine claude

  state_file=$(state_file_for_plan "$repo" "$repo/plan.md")
  remove_latest_coder_output "$repo"

  run_auto "$repo" "$second_stdout" "$second_stderr" \
    --resume "$state_file" \
    --run-coder \
    --coder-engine codex

  remove_latest_coder_output "$repo"

  run_auto "$repo" "$third_stdout" "$third_stderr" \
    --resume "$state_file" \
    --run-coder \
    --coder-engine claude

  final_trace=$(last_line "$repo/.claude/tmp/session.trace")
  assert_equals 'start:claude-session-002' "$final_trace" "resume should start a fresh session in the selected claude family"
  assert_file_contains "$third_stderr" 'Overriding persisted coder_engine: codex -> claude'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'resume:'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'fork:'
  assert_equals "1" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" "only the explicit codex run should hit the codex wrapper"
  assert_jq_equals "$state_file" '.assignments.coder_engine' 'claude'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | length' '3'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | last | .engine' 'claude'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | last | .session_id' 'claude-session-002'
}

test_resume_state_rejects_continue_flag() {
  local repo="$TMP_ROOT/continue-blocked"
  local first_stdout="$repo/first.stdout"
  local first_stderr="$repo/first.stderr"
  local resume_stdout="$repo/resume.stdout"
  local resume_stderr="$repo/resume.stderr"
  local state_file

  setup_fake_repo "$repo"
  run_auto "$repo" "$first_stdout" "$first_stderr" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine claude

  state_file=$(state_file_for_plan "$repo" "$repo/plan.md")
  strip_engine_metadata_from_state "$state_file"
  remove_latest_coder_output "$repo"

  if run_auto "$repo" "$resume_stdout" "$resume_stderr" \
    --resume "$state_file" \
    --run-coder \
    --continue-session \
    --coder-engine claude; then
    fail "continue-session should fail closed in orchestrated flow"
  fi

  assert_file_contains "$resume_stderr" 'Non-interactive invariant: --continue-session/--fork-session are disabled in orchestrated flow'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'resume:'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'fork:'
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" "continue-session rejection should not hit the codex wrapper"
}

test_resume_state_without_engine_metadata_defaults_to_new_codex_run() {
  local repo="$TMP_ROOT/legacy-default-codex"
  local first_stdout="$repo/first.stdout"
  local first_stderr="$repo/first.stderr"
  local resume_stdout="$repo/resume.stdout"
  local resume_stderr="$repo/resume.stderr"
  local state_file

  setup_fake_repo "$repo"
  run_auto "$repo" "$first_stdout" "$first_stderr" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine claude

  state_file=$(state_file_for_plan "$repo" "$repo/plan.md")
  strip_engine_metadata_from_state "$state_file"
  remove_latest_coder_output "$repo"

  run_auto "$repo" "$resume_stdout" "$resume_stderr" \
    --resume "$state_file" \
    --run-coder

  assert_file_contains "$resume_stderr" 'Coder engine: Codex'
  assert_file_not_contains "$resume_stderr" 'Legacy '
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'resume:'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'fork:'
  assert_equals "1" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" "legacy no-engine state should fall back to a fresh codex run"
  assert_jq_equals "$state_file" '.assignments.coder_engine' 'codex'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | length' '2'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | last | .engine' 'codex'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | last | .session_id' 'codex-session-001'
}

test_explicit_claude_starts_new_session_without_legacy_resume() {
  local repo="$TMP_ROOT/legacy-explicit-claude"
  local first_stdout="$repo/first.stdout"
  local first_stderr="$repo/first.stderr"
  local resume_stdout="$repo/resume.stdout"
  local resume_stderr="$repo/resume.stderr"
  local state_file
  local final_trace

  setup_fake_repo "$repo"
  run_auto "$repo" "$first_stdout" "$first_stderr" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine claude

  state_file=$(state_file_for_plan "$repo" "$repo/plan.md")
  strip_engine_metadata_from_state "$state_file"
  remove_latest_coder_output "$repo"

  run_auto "$repo" "$resume_stdout" "$resume_stderr" \
    --resume "$state_file" \
    --run-coder \
    --coder-engine claude

  final_trace=$(last_line "$repo/.claude/tmp/session.trace")
  assert_equals 'start:claude-session-002' "$final_trace" "explicit Claude should start a fresh session even without legacy engine metadata"
  assert_file_not_contains "$resume_stderr" 'Legacy '
  assert_file_contains "$resume_stderr" 'Coder engine: Claude'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'resume:'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'fork:'
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" "explicit Claude legacy resume should not hit the codex wrapper"
  assert_jq_equals "$state_file" '.assignments.coder_engine' 'claude'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | length' '2'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | last | .engine' 'claude'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | last | .session_id' 'claude-session-002'
}

test_explicit_coder_engine_overrides_invalid_persisted_assignment() {
  local repo="$TMP_ROOT/invalid-assignment-override"
  local first_stdout="$repo/first.stdout"
  local first_stderr="$repo/first.stderr"
  local resume_stdout="$repo/resume.stdout"
  local resume_stderr="$repo/resume.stderr"
  local state_file
  local final_trace

  setup_fake_repo "$repo"
  run_auto "$repo" "$first_stdout" "$first_stderr" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine claude

  state_file=$(state_file_for_plan "$repo" "$repo/plan.md")
  set_assignment_coder_engine "$state_file" 'broken'
  remove_latest_coder_output "$repo"

  run_auto "$repo" "$resume_stdout" "$resume_stderr" \
    --resume "$state_file" \
    --run-coder \
    --coder-engine claude

  final_trace=$(last_line "$repo/.claude/tmp/session.trace")
  assert_equals 'start:claude-session-002' "$final_trace" "explicit engine should recover from an invalid persisted assignment"
  assert_file_contains "$resume_stderr" 'Ignoring invalid persisted coder_engine: broken'
  assert_jq_equals "$state_file" '.assignments.coder_engine' 'claude'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | last | .engine' 'claude'
}

test_malformed_session_engine_metadata_is_ignored_for_state_resume() {
  local repo="$TMP_ROOT/malformed-session-engine"
  local first_stdout="$repo/first.stdout"
  local first_stderr="$repo/first.stderr"
  local resume_stdout="$repo/resume.stdout"
  local resume_stderr="$repo/resume.stderr"
  local state_file

  setup_fake_repo "$repo"
  run_auto "$repo" "$first_stdout" "$first_stderr" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine claude

  state_file=$(state_file_for_plan "$repo" "$repo/plan.md")
  set_first_session_engine_to_boolean_true "$state_file"
  remove_latest_coder_output "$repo"

  run_auto "$repo" "$resume_stdout" "$resume_stderr" \
    --resume "$state_file" \
    --run-coder

  assert_file_not_contains "$resume_stderr" 'jq: error'
  assert_file_contains "$resume_stderr" 'Coder engine: Codex'
  assert_file_not_contains "$resume_stderr" 'Malformed session engine metadata detected'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'resume:'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'fork:'
  assert_equals "1" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" "malformed engine metadata should still allow a fresh codex run"
  assert_jq_equals "$state_file" '.assignments.coder_engine' 'codex'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | last | .engine' 'codex'
}

test_explicit_claude_starts_new_session_after_codex_assignment_and_legacy_metadata() {
  local repo="$TMP_ROOT/legacy-claude-recover"
  local first_stdout="$repo/first.stdout"
  local first_stderr="$repo/first.stderr"
  local codex_stdout="$repo/codex.stdout"
  local codex_stderr="$repo/codex.stderr"
  local resume_stdout="$repo/resume.stdout"
  local resume_stderr="$repo/resume.stderr"
  local state_file
  local final_trace

  setup_fake_repo "$repo"
  run_auto "$repo" "$first_stdout" "$first_stderr" \
    --plan "$repo/plan.md" \
    --phase impl \
    --run-coder \
    --coder-engine claude

  state_file=$(state_file_for_plan "$repo" "$repo/plan.md")
  strip_engine_metadata_from_state "$state_file"
  remove_latest_coder_output "$repo"

  run_auto "$repo" "$codex_stdout" "$codex_stderr" \
    --resume "$state_file" \
    --run-coder

  remove_latest_coder_output "$repo"

  run_auto "$repo" "$resume_stdout" "$resume_stderr" \
    --resume "$state_file" \
    --run-coder \
    --coder-engine claude

  final_trace=$(last_line "$repo/.claude/tmp/session.trace")
  assert_equals 'start:claude-session-002' "$final_trace" "explicit Claude should start a fresh session even after codex assignment"
  assert_file_not_contains "$resume_stderr" 'Legacy '
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'resume:'
  assert_file_not_contains "$repo/.claude/tmp/session.trace" 'fork:'
  assert_equals "1" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" "only the intermediate codex run should hit the codex wrapper"
  assert_jq_equals "$state_file" '.assignments.coder_engine' 'claude'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | length' '3'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | last | .engine' 'claude'
  assert_jq_equals "$state_file" '.sessions.coder_sessions | last | .session_id' 'claude-session-002'
}

require_cmd bash
require_cmd git
require_cmd jq

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/coder_engine_truth.XXXXXX")"

  test_explicit_codex_truth
  test_security_sensitive_codex_uses_high_cached_lane
  test_codex_coder_rejects_wrapper_env_escape
test_explicit_claude_truth
test_resume_state_rejects_fork_flag
test_codex_run_records_phase_output_without_session_id
test_codex_fix_records_phase_output_without_session_id
test_resume_uses_selected_engine_family
test_resume_state_rejects_continue_flag
test_resume_state_without_engine_metadata_defaults_to_new_codex_run
test_explicit_claude_starts_new_session_without_legacy_resume
test_explicit_coder_engine_overrides_invalid_persisted_assignment
test_malformed_session_engine_metadata_is_ignored_for_state_resume
test_explicit_claude_starts_new_session_after_codex_assignment_and_legacy_metadata

printf 'PASS: coder_engine_truth\n'
