#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP_ROOT=""

cleanup() {
  /bin/rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
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

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || fail "missing expected text in $file: $needle"
}

assert_jq_equals() {
  local file="$1"
  local query="$2"
  local expected="$3"
  local actual=""
  actual=$(jq -r "$query" "$file")
  assert_equals "$expected" "$actual" "jq assertion failed: $query"
}

assert_jq_true() {
  local file="$1"
  local query="$2"
  jq -e "$query" "$file" >/dev/null 2>&1 || fail "jq assertion failed: $query"
}

line_count() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo 0
    return 0
  fi

  wc -l < "$file" | tr -d '[:space:]'
}

state_file_for_plan() {
  local repo="$1"
  local plan_path="$2"
  local task=""
  task="$(basename "$plan_path")"
  task="${task%.*}"
  printf '%s/.claude/tmp/%s/state.json\n' "$repo" "$task"
}

slice_b_active_plan_path() {
  local repo="$1"
  printf '%s/.agent/active/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness.md\n' "$repo"
}

slice_b_addendum_path() {
  local repo="$1"
  printf '%s/.agent/active/sow/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum.md\n' "$repo"
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
    "$repo/.agent/active/prompts" \
    "$repo/.agent/active/sow" \
    "$repo/.shared" \
    "$repo/docs/prompts" \
    "$repo/scripts"

  /bin/cp "$PROJECT_ROOT/.claude/commands/auto_orchestrate.sh" "$repo/.claude/commands/auto_orchestrate.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/coder.sh" "$repo/.claude/commands/lib/coder.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/state.sh" "$repo/.claude/commands/lib/state.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/task_contract.sh" "$repo/.claude/commands/lib/task_contract.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/utils.sh" "$repo/.claude/commands/lib/utils.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/timeout.sh" "$repo/.claude/commands/lib/timeout.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/orchestration_packet.sh" "$repo/.claude/commands/lib/orchestration_packet.sh"

  write_file "$repo/.claude/commands/lib/session.sh" '#!/usr/bin/env bash
set -euo pipefail

_stub_counter_file() {
  local prefix="$1"
  printf "%s/%s.count\n" "${SESSION_COUNTER_DIR:?}" "$prefix"
}

_stub_next_session_id() {
  local prefix="$1"
  local count_file=""
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
  if [[ -n "$output_file" ]]; then
    printf "# stub coder output\n\n---OUTPUT-END---\n" > "$output_file"
  fi
}

_validate_session_id() {
  [[ -n "${1:-}" ]]
}

session_start() {
  local prompt="$1"
  local output_file="${2:-}"
  local session_id=""
  session_id=$(_stub_next_session_id "claude")
  _stub_write_output "$output_file"
  _stub_trace "start:${session_id}"
  printf "%s\n" "$session_id"
}

session_resume() {
  local session_id="$1"
  local prompt="$2"
  local output_file="${3:-}"
  _stub_write_output "$output_file"
  _stub_trace "resume:${session_id}"
  return 0
}

session_fork() {
  local parent_session_id="$1"
  local prompt="$2"
  local output_file="${3:-}"
  local session_id=""
  session_id=$(_stub_next_session_id "claude")
  _stub_write_output "$output_file"
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
  local session_id=""
  session_id=$(_stub_next_session_id "codex")
  _stub_trace "codex-latest:${session_id}"
  printf "%s\n" "$session_id"
}
'

  write_file "$repo/.claude/commands/lib/reviewer.sh" '#!/usr/bin/env bash
set -euo pipefail

reviewer_run_all() { return 1; }
reviewer_record_to_state() { :; }
show_issue_counts() { :; }
'

  write_file "$repo/.claude/commands/lib/context_analysis.sh" '#!/usr/bin/env bash
set -euo pipefail

context_update() { printf "{\"status\":\"ok\"}\n"; }
context_detect_deletions() { printf "{\"deleted_paths\":[],\"removed_symbols\":[],\"move_candidates\":[]}\n"; }
preflight_check() { printf "{\"verdict\":\"PASS\",\"conflicts\":[]}\n"; }
context_delta() { printf "{\"delta\":\"ok\"}\n"; }
context_diff_impact() { printf "{\"impact\":\"ok\"}\n"; }

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
  write_file "$repo/.agent/PROJECT_CONTEXT.md" '# Project Context

This is the fake project context for common task contract smoke tests.
'
  write_file "$repo/.agent/active/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness.md" '# ExecPlan: Support Surface Autonomy And Product Surface Freshness

## In-Scope
- .claude/commands/lib/task_contract.sh

## Out-Of-Scope
- native-layout freshness generalization

## Required Deterministic Checks
- bash -n .claude/commands/lib/task_contract.sh

## Completion Boundary
- broad active plan stays broad and does not gain slice-b-only freshness fields
'
  write_file "$repo/.agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md" '# SOW: Support Surface Autonomy And Product Surface Freshness

## Runtime Slice B Implementation Record

- closeout evidence paths:
  - `.agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md`
  - `.agent/active/prompts/handover_20260415_support-surface-autonomy-and-product-surface-freshness.md`
'
  write_file "$repo/.agent/active/prompts/handover_20260415_support-surface-autonomy-and-product-surface-freshness.md" '# Handover

Current restart guide for fake slice b support-context coverage.
'
  write_file "$repo/.agent/active/sow/20260415_slice-a_support-source-authority-runtime-resolver_addendum.md" '# Slice Addendum: Support Surface Autonomy And Product Surface Freshness A

Date: `2026-04-15`
Role: `orchestrator`
Plan: `.agent/active/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness.md`
Parent SOW: `.agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md`
Slice: `A - Support-Source Authority Contract And Runtime Resolver`
'
  write_file "$repo/.agent/active/sow/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum.md" '# Slice Addendum: Support Surface Autonomy And Product Surface Freshness B

Date: `2026-04-15`
Role: `orchestrator`
Plan: `.agent/active/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness.md`
Parent SOW: `.agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md`
Slice: `B - Support-Context Artifact And Freshness Contract`

## Slice Record

- change surface:
  - exact owned runtime files:
    - `.claude/commands/auto_orchestrate.sh`
    - `.claude/commands/lib/task_contract.sh`
    - `docs/manual/common-task-contract.md`
    - `test/integration/common_task_contract_smoke.sh`
    - `test/integration/semantic_coordination_test.sh`
  - exact closeout docs allowed:
    - `.agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md`
    - `.agent/active/prompts/handover_20260415_support-surface-autonomy-and-product-surface-freshness.md`
- in-scope:
  - machine-readable support-context artifact for the current runtime
  - task identity, artifact destination, support read-order, and freshness expectations encoded in the runtime contract surface
  - fail-closed handling when current plan, current SOW, or `PROJECT_CONTEXT` is missing or mismatched
  - optional current handover as existence-dependent freshness/linkage only, never authority elevation
- out-of-scope:
  - `.claude/commands/lib/state.sh`
  - `.claude/commands/lib/context_analysis.sh`
  - `.claude/commands/lib/context_capsule.sh`
  - `.agent/registry/policy_sources.json`
  - `test/integration/harness_release_gate.sh`

## Required Deterministic Checks For Future Runtime Slice B

- `git diff --check -- .claude/commands/auto_orchestrate.sh .claude/commands/lib/task_contract.sh docs/manual/common-task-contract.md test/integration/common_task_contract_smoke.sh test/integration/semantic_coordination_test.sh .agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md .agent/active/prompts/handover_20260415_support-surface-autonomy-and-product-surface-freshness.md`
- `bash -n .claude/commands/auto_orchestrate.sh .claude/commands/lib/task_contract.sh test/integration/common_task_contract_smoke.sh test/integration/semantic_coordination_test.sh`
- `bash test/integration/common_task_contract_smoke.sh`
- `bash test/integration/semantic_coordination_test.sh`
- `for path in AGENTS.md .agent_rules/RULES.md docs/manual/verification-truth-matrix.md docs/roles/orchestrator.md docs/roles/coder.md docs/roles/reviewer.md .agent/PROJECT_CONTEXT.md .agent/active/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness.md .agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md .agent/active/prompts/handover_20260415_support-surface-autonomy-and-product-surface-freshness.md .agent/active/sow/20260415_slice-a_support-source-authority-runtime-resolver_addendum.md .agent/active/sow/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum.md .claude/commands/auto_orchestrate.sh .claude/commands/lib/task_contract.sh docs/manual/common-task-contract.md test/integration/common_task_contract_smoke.sh test/integration/semantic_coordination_test.sh; do test -e "$path"; done`

## Completion Boundary

1. a machine-readable support-context artifact exists for the current runtime
2. optional current handover is handled as evidence-only linkage and never authority elevation
3. Slice `C` and Slice `D` remain open
'

  write_file "$repo/plan_common_task_contract.md" '# ExecPlan: Common Task Contract
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh
- .claude/commands/lib/task_contract.sh
- .claude/commands/lib/state.sh
- test/integration/common_task_contract_smoke.sh

## Out-Of-Scope
- reviewer runtime
- policy compiler

## Required Deterministic Checks
- `git diff --check -- .claude/commands/auto_orchestrate.sh .claude/commands/lib/task_contract.sh .claude/commands/lib/state.sh test/integration/common_task_contract_smoke.sh`
- bash -n .claude/commands/auto_orchestrate.sh
- bash -n .claude/commands/lib/task_contract.sh

## Completion Boundary
Slice A is complete only when:
1. exactly one repo-local task-contract.json is emitted before coder launch
2. invalid contracts block coder execution fail-closed
'
  write_file "$repo/.shared/project_id" 'common-task-contract
'

  chmod +x \
    "$repo/.claude/commands/auto_orchestrate.sh" \
    "$repo/.claude/commands/lib/session.sh" \
    "$repo/.claude/commands/lib/reviewer.sh" \
    "$repo/.claude/commands/lib/context_analysis.sh" \
    "$repo/.claude/commands/lib/context_capsule.sh" \
    "$repo/.claude/commands/lib/task_contract.sh" \
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

run_invalid_contract_gate() {
  local repo="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local task="plan_common_task_contract"

  (
    set -euo pipefail
    cd "$repo"
    CODEX_WRAPPER_TRACE="$repo/.claude/tmp/codex-wrapper.trace" \
    SESSION_HELPER_TRACE="$repo/.claude/tmp/session.trace" \
    SESSION_COUNTER_DIR="$repo/.claude/tmp/session-counters" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c '
      set -euo pipefail
      source "$1"

      PLAN="$2"
      PHASE="impl"
      CODER_ENGINE="codex"
      task_name="$3"
      tmpdir="$4"
      broken_rel_path=".claude/tmp/${task_name}/task-contract.json"
      broken_abs_path="$PWD/$broken_rel_path"

      state_init "$PLAN" "$task_name" "$tmpdir" >/dev/null
      state_upsert_phase "$PHASE" 5
      persist_coder_engine_assignment "$CODER_ENGINE"
      state_set ".status" "\"running\""
      state_set_phase_status "$PHASE" "running"
      state_save

      _prepare_task_contract_for_coder_launch "$tmpdir" "$PHASE" "$PLAN" "$task_name"

      printf "%s" "{\"contract_version\":\"1.0.0\",\"task_id\":\"broken\"}" > "$broken_abs_path"
      state_set_contract_path "$broken_rel_path"
      state_set_contract_id "task-contract-broken"
      state_save

      : > "$PWD/.claude/tmp/codex-wrapper.trace"
      _prepare_task_contract_for_coder_launch "$tmpdir" "$PHASE" "$PLAN" "$task_name"
    ' _ \
      "$repo/.claude/commands/auto_orchestrate.sh" \
      "$repo/plan_common_task_contract.md" \
      "$task" \
      "$repo/.claude/tmp/$task"
  ) >"$stdout_file" 2>"$stderr_file"
}

run_invalid_task_segment_gate() {
  local repo="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local task="plan_common_task_contract"

  (
    set -euo pipefail
    cd "$repo"
    CODEX_WRAPPER_TRACE="$repo/.claude/tmp/codex-wrapper.trace" \
    SESSION_HELPER_TRACE="$repo/.claude/tmp/session.trace" \
    SESSION_COUNTER_DIR="$repo/.claude/tmp/session-counters" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c '
      set -euo pipefail
      source "$1"

      PLAN="$2"
      PHASE="impl"
      CODER_ENGINE="codex"
      task_name="$3"
      tmpdir="$4"

      state_init "$PLAN" "$task_name" "$tmpdir" >/dev/null
      state_upsert_phase "$PHASE" 5
      persist_coder_engine_assignment "$CODER_ENGINE"
      state_set ".status" "\"running\""
      state_set_phase_status "$PHASE" "running"
      state_save

      : > "$PWD/.claude/tmp/codex-wrapper.trace"
      _prepare_task_contract_for_coder_launch "$tmpdir" "$PHASE" "$PLAN" ".."
    ' _ \
      "$repo/.claude/commands/auto_orchestrate.sh" \
      "$repo/plan_common_task_contract.md" \
      "$task" \
      "$repo/.claude/tmp/$task"
  ) >"$stdout_file" 2>"$stderr_file"
}

run_persisted_external_contract_path_gate() {
  local repo="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local task="plan_common_task_contract"

  (
    set -euo pipefail
    cd "$repo"
    CODEX_WRAPPER_TRACE="$repo/.claude/tmp/codex-wrapper.trace" \
    SESSION_HELPER_TRACE="$repo/.claude/tmp/session.trace" \
    SESSION_COUNTER_DIR="$repo/.claude/tmp/session-counters" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c '
      set -euo pipefail
      source "$1"

      PLAN="$2"
      PHASE="impl"
      CODER_ENGINE="codex"
      task_name="$3"
      tmpdir="$4"
      external_rel_path=".claude/tmp/unexpected-task/task-contract.json"
      external_abs_path="$PWD/$external_rel_path"
      task_id=""
      contract_id=""

      state_init "$PLAN" "$task_name" "$tmpdir" >/dev/null
      state_upsert_phase "$PHASE" 5
      persist_coder_engine_assignment "$CODER_ENGINE"
      state_set ".status" "\"running\""
      state_set_phase_status "$PHASE" "running"
      state_save

      task_id=$(state_get ".task.id")
      contract_id=$(bash "$PWD/.claude/commands/lib/task_contract.sh" emit \
        --plan "$PLAN" \
        --phase "$PHASE" \
        --task-id "$task_id" \
        --coder-engine "$CODER_ENGINE" \
        --artifact-destination "$external_rel_path" \
        --output "$external_abs_path")

      state_set_contract_path "$external_rel_path"
      state_set_contract_id "$contract_id"
      state_save

      : > "$PWD/.claude/tmp/codex-wrapper.trace"
      _prepare_task_contract_for_coder_launch "$tmpdir" "$PHASE" "$PLAN" "$task_name"
    ' _ \
      "$repo/.claude/commands/auto_orchestrate.sh" \
      "$repo/plan_common_task_contract.md" \
      "$task" \
      "$repo/.claude/tmp/$task"
  ) >"$stdout_file" 2>"$stderr_file"
}

run_persisted_mismatched_task_id_gate() {
  local repo="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local task="plan_common_task_contract"

  (
    set -euo pipefail
    cd "$repo"
    CODEX_WRAPPER_TRACE="$repo/.claude/tmp/codex-wrapper.trace" \
    SESSION_HELPER_TRACE="$repo/.claude/tmp/session.trace" \
    SESSION_COUNTER_DIR="$repo/.claude/tmp/session-counters" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c '
      set -euo pipefail
      source "$1"

      PLAN="$2"
      PHASE="impl"
      CODER_ENGINE="codex"
      task_name="$3"
      tmpdir="$4"
      canonical_rel_path=".claude/tmp/${task_name}/task-contract.json"
      canonical_abs_path="$PWD/$canonical_rel_path"
      contract_id=""

      state_init "$PLAN" "$task_name" "$tmpdir" >/dev/null
      state_upsert_phase "$PHASE" 5
      persist_coder_engine_assignment "$CODER_ENGINE"
      state_set ".status" "\"running\""
      state_set_phase_status "$PHASE" "running"
      state_save

      contract_id=$(bash "$PWD/.claude/commands/lib/task_contract.sh" emit \
        --plan "$PLAN" \
        --phase "$PHASE" \
        --task-id "unexpected-task-id" \
        --coder-engine "$CODER_ENGINE" \
        --artifact-destination "$canonical_rel_path" \
        --output "$canonical_abs_path")

      state_set_contract_path "$canonical_rel_path"
      state_set_contract_id "$contract_id"
      state_save

      : > "$PWD/.claude/tmp/codex-wrapper.trace"
      _prepare_task_contract_for_coder_launch "$tmpdir" "$PHASE" "$PLAN" "$task_name"
    ' _ \
      "$repo/.claude/commands/auto_orchestrate.sh" \
      "$repo/plan_common_task_contract.md" \
      "$task" \
      "$repo/.claude/tmp/$task"
  ) >"$stdout_file" 2>"$stderr_file"
}

test_valid_contract_emission() {
  local repo="$TMP_ROOT/valid"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local plan_path="$repo/plan_common_task_contract.md"
  local state_file=""
  local task_dir="plan_common_task_contract"
  local contract_path="$repo/.claude/tmp/$task_dir/task-contract.json"

  setup_fake_repo "$repo"
  run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$plan_path" \
    --phase impl \
    --run-coder \
    --coder-engine codex

  state_file=$(state_file_for_plan "$repo" "$plan_path")
  assert_file_exists "$contract_path"
  assert_file_exists "$state_file"

  bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$contract_path" \
    || fail "contract validation failed for $contract_path"

  assert_equals "1" "$(find "$repo/.claude/tmp/$task_dir" -name 'task-contract.json' | wc -l | tr -d '[:space:]')" \
    "unexpected task-contract.json count"
  assert_equals "1" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper should run exactly once"
  assert_jq_equals "$contract_path" '.contract_version' '1.0.0'
  assert_jq_equals "$contract_path" '.slice_id' 'slice-a'
  assert_jq_equals "$contract_path" '.phase' 'impl'
  assert_jq_equals "$contract_path" '.owner_role' 'orchestrator'
  assert_jq_equals "$contract_path" '.coder_engine' 'codex'
  assert_jq_equals "$contract_path" '.plan_path' 'plan_common_task_contract.md'
  assert_jq_equals "$contract_path" '.artifact_destination' '.claude/tmp/plan_common_task_contract/task-contract.json'
  assert_jq_true "$contract_path" '.in_scope | length > 0'
  assert_jq_true "$contract_path" '.required_checks == [
    "git diff --check -- .claude/commands/auto_orchestrate.sh .claude/commands/lib/task_contract.sh .claude/commands/lib/state.sh test/integration/common_task_contract_smoke.sh",
    "bash -n .claude/commands/auto_orchestrate.sh",
    "bash -n .claude/commands/lib/task_contract.sh"
  ]'
  assert_jq_true "$contract_path" 'all(.required_checks[]; contains("`") | not)'
  assert_jq_true "$contract_path" '.completion_boundary == [
    "exactly one repo-local task-contract.json is emitted before coder launch",
    "invalid contracts block coder execution fail-closed"
  ]'
  assert_jq_true "$contract_path" '.allowed_capabilities | length > 0'
  assert_jq_true "$contract_path" '.contract_id | type == "string" and length > 0'
  assert_jq_equals "$state_file" '.task.plan_path' 'plan_common_task_contract.md'
  assert_jq_equals "$state_file" '.task.contract_path' '.claude/tmp/plan_common_task_contract/task-contract.json'
  assert_jq_equals "$state_file" '.task.contract_id' "$(jq -r '.contract_id' "$contract_path")"
  assert_file_contains "$stderr_file" 'Task contract saved: .claude/tmp/plan_common_task_contract/task-contract.json'
}

test_slice_b_addendum_contract_emit_and_validate() {
  local repo="$TMP_ROOT/slice_b_addendum"
  local addendum_path=""
  local contract_path=""
  local handover_path=""
  local handover_sha=""

  setup_fake_repo "$repo"
  addendum_path="$(slice_b_addendum_path "$repo")"
  contract_path="$repo/.claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json"
  handover_path="$repo/.agent/active/prompts/handover_20260415_support-surface-autonomy-and-product-surface-freshness.md"
  handover_sha="$(shasum -a 256 "$handover_path" | awk '{print $1}')"

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$addendum_path" \
      --phase impl \
      --task-id slice-b-task \
      --coder-engine codex \
      --artifact-destination .claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$contract_path" \
    || fail "slice b addendum contract validation failed for $contract_path"

  assert_jq_equals "$contract_path" '.slice_id' 'slice-b'
  assert_jq_equals "$contract_path" '.plan_path' '.agent/active/sow/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum.md'
  assert_jq_true "$contract_path" '.required_checks == [
    "git diff --check -- .claude/commands/auto_orchestrate.sh .claude/commands/lib/task_contract.sh docs/manual/common-task-contract.md test/integration/common_task_contract_smoke.sh test/integration/semantic_coordination_test.sh .agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md .agent/active/prompts/handover_20260415_support-surface-autonomy-and-product-surface-freshness.md",
    "bash -n .claude/commands/auto_orchestrate.sh .claude/commands/lib/task_contract.sh test/integration/common_task_contract_smoke.sh test/integration/semantic_coordination_test.sh",
    "bash test/integration/common_task_contract_smoke.sh",
    "bash test/integration/semantic_coordination_test.sh",
    "for path in AGENTS.md .agent_rules/RULES.md docs/manual/verification-truth-matrix.md docs/roles/orchestrator.md docs/roles/coder.md docs/roles/reviewer.md .agent/PROJECT_CONTEXT.md .agent/active/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness.md .agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md .agent/active/prompts/handover_20260415_support-surface-autonomy-and-product-surface-freshness.md .agent/active/sow/20260415_slice-a_support-source-authority-runtime-resolver_addendum.md .agent/active/sow/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum.md .claude/commands/auto_orchestrate.sh .claude/commands/lib/task_contract.sh docs/manual/common-task-contract.md test/integration/common_task_contract_smoke.sh test/integration/semantic_coordination_test.sh; do test -e \"$path\"; done"
  ]'
  assert_jq_true "$contract_path" '.owned_runtime_surface.runtime_files == [
    ".claude/commands/auto_orchestrate.sh",
    ".claude/commands/lib/task_contract.sh",
    "docs/manual/common-task-contract.md",
    "test/integration/common_task_contract_smoke.sh",
    "test/integration/semantic_coordination_test.sh"
  ]'
  assert_jq_true "$contract_path" '.owned_runtime_surface.closeout_docs_allowed == [
    ".agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md",
    ".agent/active/prompts/handover_20260415_support-surface-autonomy-and-product-surface-freshness.md"
  ]'
  assert_jq_equals "$contract_path" '.support_context_freshness.resolver' 'bounded_support_context_freshness_v1'
  assert_jq_equals "$contract_path" '.support_context_freshness.current_plan_path' '.agent/active/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness.md'
  assert_jq_equals "$contract_path" '.support_context_freshness.current_sow_path' '.agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md'
  assert_jq_equals "$contract_path" '.support_context_freshness.project_context_path' '.agent/PROJECT_CONTEXT.md'
  assert_jq_true "$contract_path" '.support_context_freshness.support_read_order == [
    ".agent/active/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness.md",
    ".agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md",
    ".agent/PROJECT_CONTEXT.md"
  ]'
  assert_jq_true "$contract_path" '(.support_context_freshness.required_current_documents | map(.role) | sort) == ["current_plan", "current_sow", "project_context"]'
  assert_jq_equals "$contract_path" '.support_context_freshness.optional_handover.path' '.agent/active/prompts/handover_20260415_support-surface-autonomy-and-product-surface-freshness.md'
  assert_jq_equals "$contract_path" '.support_context_freshness.optional_handover.present' 'true'
  assert_jq_equals "$contract_path" '.support_context_freshness.optional_handover.evidence_only' 'true'
  assert_jq_equals "$contract_path" '.support_context_freshness.optional_handover.linked_from_sow' 'true'
  assert_jq_equals "$contract_path" '.support_context_freshness.optional_handover.sha256' "$handover_sha"
  assert_jq_true "$contract_path" '.support_context_freshness.freshness_expectations.optional_handover_evidence_only == true'
  assert_jq_true "$contract_path" '.support_context_freshness as $freshness | ($freshness.support_read_order | index($freshness.optional_handover.path)) == null'
}

test_slice_b_support_context_fail_closed_cases() {
  local repo="$TMP_ROOT/slice_b_fail_closed"
  local addendum_path=""
  local contract_path=""
  local current_sow=""
  local project_context=""
  local invalid_support_read_order_contract=""
  local invalid_handover_digest_contract=""
  local broad_plan_path=""
  local broad_contract_path=""
  local invalid_broad_plan_support_context_contract=""
  local mutator_script=""

  setup_fake_repo "$repo"
  addendum_path="$(slice_b_addendum_path "$repo")"
  broad_plan_path="$(slice_b_active_plan_path "$repo")"
  contract_path="$repo/.claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json"
  broad_contract_path="$repo/.claude/tmp/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness/task-contract.json"
  current_sow="$repo/.agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md"
  project_context="$repo/.agent/PROJECT_CONTEXT.md"
  invalid_support_read_order_contract="$repo/.claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract-invalid-support-read-order.json"
  invalid_handover_digest_contract="$repo/.claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract-invalid-handover-digest.json"
  invalid_broad_plan_support_context_contract="$repo/.claude/tmp/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness/task-contract-invalid-support-context.json"
  mutator_script="$repo/mutate_slice_b_contract.sh"

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$addendum_path" \
      --phase impl \
      --task-id slice-b-task \
      --coder-engine codex \
      --artifact-destination .claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  /bin/rm -f "$current_sow"
  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$contract_path" >/dev/null 2>&1; then
    fail "slice b contract unexpectedly validated without current sow"
  fi

  setup_fake_repo "$repo"
  addendum_path="$(slice_b_addendum_path "$repo")"
  contract_path="$repo/.claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json"
  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$addendum_path" \
      --phase impl \
      --task-id slice-b-task \
      --coder-engine codex \
      --artifact-destination .claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  /bin/rm -f "$project_context"
  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$contract_path" >/dev/null 2>&1; then
    fail "slice b contract unexpectedly validated without PROJECT_CONTEXT"
  fi

  setup_fake_repo "$repo"
  addendum_path="$(slice_b_addendum_path "$repo")"
  contract_path="$repo/.claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json"
  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$addendum_path" \
      --phase impl \
      --task-id slice-b-task \
      --coder-engine codex \
      --artifact-destination .claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.support_context_freshness.support_read_order += [.support_context_freshness.optional_handover.path] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.support_context_freshness.support_read_order += [.support_context_freshness.optional_handover.path] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"
  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_support_read_order_contract"
  )
  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_support_read_order_contract" >/dev/null 2>&1; then
    fail "slice b contract unexpectedly accepted optional handover in support_read_order"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.support_context_freshness.optional_handover.sha256 = "1111111111111111111111111111111111111111111111111111111111111111" | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.support_context_freshness.optional_handover.sha256 = "1111111111111111111111111111111111111111111111111111111111111111" | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"
  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_handover_digest_contract"
  )
  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_handover_digest_contract" >/dev/null 2>&1; then
    fail "slice b contract unexpectedly accepted mismatched optional handover digest"
  fi

  setup_fake_repo "$repo"
  addendum_path="$(slice_b_addendum_path "$repo")"
  broad_plan_path="$(slice_b_active_plan_path "$repo")"
  contract_path="$repo/.claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json"
  broad_contract_path="$repo/.claude/tmp/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness/task-contract.json"
  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$addendum_path" \
      --phase impl \
      --task-id slice-b-task \
      --coder-engine codex \
      --artifact-destination .claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json \
      --output "$contract_path"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$broad_plan_path" \
      --phase impl \
      --task-id broad-active-plan-task \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_20260415_2000_support-surface-autonomy-and-product-surface-freshness/task-contract.json \
      --output "$broad_contract_path"
  ) >/dev/null

  bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$broad_contract_path" \
    || fail "broad active plan contract validation failed without slice-b-only support context"
  assert_jq_true "$broad_contract_path" 'has("support_context_freshness") | not'
  assert_jq_true "$broad_contract_path" 'has("owned_runtime_surface") | not'

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(
  jq -s '.[0] + {
    support_context_freshness: .[1].support_context_freshness,
    owned_runtime_surface: .[1].owned_runtime_surface
  } | del(.contract_id)' "$2" "$3"
)
contract_id=$(task_contract_compute_id "$payload")
jq -s --arg contract_id "$contract_id" '.[0] + {
  support_context_freshness: .[1].support_context_freshness,
  owned_runtime_surface: .[1].owned_runtime_surface
} | .contract_id = $contract_id' "$2" "$3" > "$4"
EOF
  chmod +x "$mutator_script"
  (
    cd "$repo"
    bash "$mutator_script" \
      "$repo/.claude/commands/lib/task_contract.sh" \
      "$broad_contract_path" \
      "$contract_path" \
      "$invalid_broad_plan_support_context_contract"
  )
  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_broad_plan_support_context_contract" >/dev/null 2>&1; then
    fail "broad active plan contract unexpectedly accepted slice-b-only support context"
  fi

  setup_fake_repo "$repo"
  addendum_path="$(slice_b_addendum_path "$repo")"
  contract_path="$repo/.claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json"
  current_sow="$repo/.agent/active/sow/20260415_support-surface-autonomy-and-product-surface-freshness.md"
  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$addendum_path" \
      --phase impl \
      --task-id slice-b-task \
      --coder-engine codex \
      --artifact-destination .claude/tmp/20260415_slice-b_support-context-artifact-and-freshness-contract_addendum/task-contract.json \
      --output "$contract_path"
  ) >/dev/null
  write_file "$current_sow" '# SOW: Support Surface Autonomy And Product Surface Freshness

## Runtime Slice B Implementation Record

- historical-only note:
  - prior closeout once mentioned `.agent/active/prompts/handover_20260415_support-surface-autonomy-and-product-surface-freshness.md`, but that note is not current linkage
- verification record:
  - `rg -n "handover_20260415_support-surface-autonomy-and-product-surface-freshness.md" .agent/active/sow/archive.md` -> `PASS`
'
  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$contract_path" >/dev/null 2>&1; then
    fail "slice b contract unexpectedly accepted historical-only or quoted handover mention inside current Runtime Slice B section"
  fi
}

test_plan_path_normalization_stabilizes_contract_id() {
  local repo="$TMP_ROOT/plan_path_normalization"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local abs_plan="$repo/plan_common_task_contract.md"
  local rel_plan="./plan_common_task_contract.md"
  local abs_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-abs.json"
  local rel_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-rel.json"
  local abs_contract_id=""
  local rel_contract_id=""
  local state_file=""

  setup_fake_repo "$repo"

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$abs_plan" \
      --phase impl \
      --task-id stable-task \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$abs_contract"
  ) >/dev/null

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$rel_plan" \
      --phase impl \
      --task-id stable-task \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$rel_contract"
  ) >/dev/null

  abs_contract_id="$(jq -r '.contract_id' "$abs_contract")"
  rel_contract_id="$(jq -r '.contract_id' "$rel_contract")"
  assert_equals "$abs_contract_id" "$rel_contract_id" "contract_id should be stable across equivalent plan_path spellings"
  assert_jq_equals "$abs_contract" '.plan_path' 'plan_common_task_contract.md'
  assert_jq_equals "$rel_contract" '.plan_path' 'plan_common_task_contract.md'

  run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$abs_plan" \
    --phase impl \
    --run-coder \
    --coder-engine codex

  state_file=$(state_file_for_plan "$repo" "$abs_plan")
  assert_jq_equals "$state_file" '.task.plan_path' 'plan_common_task_contract.md'
}

test_required_checks_exact_commands_enforced() {
  local repo="$TMP_ROOT/required_checks"
  local invalid_plan="$repo/plan_invalid_required_checks.md"
  local invalid_section_plan="$repo/plan_invalid_required_checks_section.md"
  local missing_section_plan="$repo/plan_missing_required_checks_section.md"
  local multiline_plan="$repo/plan_multiline_required_checks.md"
  local comment_suffix_plan="$repo/plan_comment_suffix_required_checks.md"
  local chaining_plan="$repo/plan_chaining_required_checks.md"
  local redirection_plan="$repo/plan_redirection_required_checks.md"
  local shell_wrapper_plan="$repo/plan_shell_wrapper_required_checks.md"
  local prefixed_shell_wrapper_plan="$repo/plan_prefixed_shell_wrapper_required_checks.md"
  local env_prefixed_plan="$repo/plan_env_prefixed_required_checks.md"
  local assignment_prefixed_plan="$repo/plan_assignment_prefixed_required_checks.md"
  local variable_expansion_plan="$repo/plan_variable_expansion_required_checks.md"
  local braced_variable_expansion_plan="$repo/plan_braced_variable_expansion_required_checks.md"
  local build_stdout="$repo/build-stdout.txt"
  local build_stderr="$repo/build-stderr.txt"
  local contract_path="$repo/.claude/tmp/plan_common_task_contract/task-contract.json"
  local invalid_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-invalid.json"
  local invalid_chaining_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-chaining-invalid.json"
  local invalid_redirection_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-redirection-invalid.json"
  local invalid_shell_wrapper_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-shell-wrapper-invalid.json"
  local invalid_prefixed_shell_wrapper_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-prefixed-shell-wrapper-invalid.json"
  local invalid_env_prefixed_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-env-prefixed-invalid.json"
  local invalid_assignment_prefixed_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-assignment-prefixed-invalid.json"
  local invalid_nested_prefixed_shell_wrapper_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-nested-prefixed-shell-wrapper-invalid.json"
  local invalid_variable_expansion_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-variable-expansion-invalid.json"
  local invalid_braced_variable_expansion_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-braced-variable-expansion-invalid.json"
  local invalid_comment_suffix_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-comment-suffix-invalid.json"
  local invalid_multiline_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-multiline-invalid.json"
  local invalid_control_char_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-control-char-invalid.json"
  local mutator_script="$repo/mutate_invalid_required_checks.sh"

  setup_fake_repo "$repo"
  write_file "$invalid_plan" '# ExecPlan: Invalid Required Checks
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- reviewer LGTM

## Completion Boundary
- invalid required_checks must fail closed
'
  write_file "$invalid_section_plan" '# ExecPlan: Invalid Required Checks Section
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
reviewer LGTM

## Completion Boundary
- invalid required_checks section content must fail closed
'
  write_file "$missing_section_plan" '# ExecPlan: Missing Required Checks Section
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Completion Boundary
- missing required_checks section must fail closed
'
  write_file "$multiline_plan" '# ExecPlan: Multiline Required Checks
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
Only the list items below are authoritative deterministic checks.
- bash -n .claude/commands/lib/task_contract.sh
  with a continuation line that must fail closed

## Completion Boundary
- multiline required_checks must fail closed
'
  write_file "$comment_suffix_plan" '# ExecPlan: Comment Suffix Required Checks
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- bash -n .claude/commands/lib/task_contract.sh # trailing prose must fail closed

## Completion Boundary
- comment-suffixed required_checks must fail closed
'
  write_file "$chaining_plan" '# ExecPlan: Chaining Required Checks
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- git diff --check && echo sneaky

## Completion Boundary
- chaining required_checks must fail closed
'
  write_file "$redirection_plan" '# ExecPlan: Redirection Required Checks
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- git diff --check >/tmp/trace

## Completion Boundary
- redirection required_checks must fail closed
'
  write_file "$shell_wrapper_plan" '# ExecPlan: Shell Wrapper Required Checks
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- bash -lc "echo nope"

## Completion Boundary
- shell wrapper required_checks must fail closed
'
  write_file "$prefixed_shell_wrapper_plan" '# ExecPlan: Prefixed Shell Wrapper Required Checks
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- command bash -lc "echo nope"

## Completion Boundary
- prefixed shell wrapper required_checks must fail closed
'
  write_file "$env_prefixed_plan" '# ExecPlan: Env Prefixed Required Checks
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- env GIT_CONFIG_GLOBAL=/tmp/evil git diff --check

## Completion Boundary
- env-prefixed required_checks must fail closed
'
  write_file "$assignment_prefixed_plan" '# ExecPlan: Assignment Prefixed Required Checks
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- GIT_CONFIG_GLOBAL=/tmp/evil git diff --check

## Completion Boundary
- assignment-prefixed required_checks must fail closed
'
  write_file "$variable_expansion_plan" '# ExecPlan: Variable Expansion Required Checks
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- git diff --check $TRACE_FILE

## Completion Boundary
- variable expansion required_checks must fail closed
'
  write_file "$braced_variable_expansion_plan" '# ExecPlan: Braced Variable Expansion Required Checks
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/auto_orchestrate.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- git diff --check "${TRACE_FILE}"

## Completion Boundary
- braced variable expansion required_checks must fail closed
'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$invalid_plan" \
      --phase impl \
      --task-id invalid-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted prose-only required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks entry must be an exact command: reviewer LGTM'

  if (
    cd "$repo"
    reviewer() { :; }
    export -f reviewer
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$invalid_plan" \
      --phase impl \
      --task-id invalid-required-checks-exported-reviewer \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted exported reviewer function as required_checks command"
  fi

  assert_file_contains "$build_stderr" 'required_checks entry must be an exact command: reviewer LGTM'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$invalid_section_plan" \
      --phase impl \
      --task-id invalid-required-checks-section \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted prose-only required_checks section content"
  fi

  assert_file_contains "$build_stderr" 'required_checks section is empty: Required Deterministic Checks'
  assert_file_contains "$build_stderr" 'task_contract_build_json: missing or empty Required Deterministic Checks section'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$multiline_plan" \
      --phase impl \
      --task-id multiline-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted multiline required_checks bullet continuation"
  fi

  assert_file_contains "$build_stderr" 'required_checks section contains non-list content after list start: Required Deterministic Checks'
  assert_file_contains "$build_stderr" 'task_contract_build_json: failed to extract exact required_checks from plan'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$comment_suffix_plan" \
      --phase impl \
      --task-id comment-suffix-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted comment-suffixed required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks entry must be an exact command: bash -n .claude/commands/lib/task_contract.sh # trailing prose must fail closed'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$missing_section_plan" \
      --phase impl \
      --task-id missing-required-checks-section \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted missing required_checks section"
  fi

  assert_file_contains "$build_stderr" 'required_checks section is missing: Required Deterministic Checks'
  assert_file_contains "$build_stderr" 'task_contract_build_json: missing or empty Required Deterministic Checks section'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$chaining_plan" \
      --phase impl \
      --task-id chaining-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted chaining required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks entry must be an exact command: git diff --check && echo sneaky'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$redirection_plan" \
      --phase impl \
      --task-id redirection-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted redirection required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks entry must be an exact command: git diff --check >/tmp/trace'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$shell_wrapper_plan" \
      --phase impl \
      --task-id shell-wrapper-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted shell-wrapper required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks entry must be an exact command: bash -lc "echo nope"'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$prefixed_shell_wrapper_plan" \
      --phase impl \
      --task-id prefixed-shell-wrapper-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted prefixed shell-wrapper required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks entry must be an exact command: command bash -lc "echo nope"'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$env_prefixed_plan" \
      --phase impl \
      --task-id env-prefixed-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted env-prefixed required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks entry must be an exact command: env GIT_CONFIG_GLOBAL=/tmp/evil git diff --check'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$assignment_prefixed_plan" \
      --phase impl \
      --task-id assignment-prefixed-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted assignment-prefixed required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks entry must be an exact command: GIT_CONFIG_GLOBAL=/tmp/evil git diff --check'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$variable_expansion_plan" \
      --phase impl \
      --task-id variable-expansion-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted variable expansion required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks entry must be an exact command: git diff --check $TRACE_FILE'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$braced_variable_expansion_plan" \
      --phase impl \
      --task-id braced-variable-expansion-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted braced variable expansion required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks entry must be an exact command: git diff --check "${TRACE_FILE}"'

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$repo/plan_common_task_contract.md" \
      --phase impl \
      --task-id valid-required-checks \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.required_checks = ["reviewer LGTM"] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.required_checks = ["reviewer LGTM"] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted prose-only required_checks"
  fi

  if (
    cd "$repo"
    reviewer() { :; }
    export -f reviewer
    bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_contract"
  ) >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted exported reviewer function as required_checks command"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.required_checks = ["sh -c \"echo nope\""] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.required_checks = ["sh -c \"echo nope\""] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_shell_wrapper_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_shell_wrapper_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted shell-wrapper required_checks"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.required_checks = ["git diff --check && echo sneaky"] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.required_checks = ["git diff --check && echo sneaky"] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_chaining_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_chaining_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted chaining required_checks"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.required_checks = ["git diff --check >/tmp/trace"] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.required_checks = ["git diff --check >/tmp/trace"] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_redirection_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_redirection_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted redirection required_checks"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.required_checks = ["command bash -lc \"echo nope\""] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.required_checks = ["command bash -lc \"echo nope\""] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_prefixed_shell_wrapper_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_prefixed_shell_wrapper_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted prefixed shell-wrapper required_checks"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.required_checks = ["env GIT_CONFIG_GLOBAL=/tmp/evil git diff --check"] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.required_checks = ["env GIT_CONFIG_GLOBAL=/tmp/evil git diff --check"] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_env_prefixed_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_env_prefixed_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted env-prefixed required_checks"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.required_checks = ["GIT_CONFIG_GLOBAL=/tmp/evil git diff --check"] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.required_checks = ["GIT_CONFIG_GLOBAL=/tmp/evil git diff --check"] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_assignment_prefixed_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_assignment_prefixed_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted assignment-prefixed required_checks"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.required_checks = ["env command bash -lc \"echo nope\""] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.required_checks = ["env command bash -lc \"echo nope\""] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_nested_prefixed_shell_wrapper_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_nested_prefixed_shell_wrapper_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted nested prefixed shell-wrapper required_checks"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.required_checks = ["git diff --check $TRACE_FILE"] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.required_checks = ["git diff --check $TRACE_FILE"] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_variable_expansion_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_variable_expansion_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted variable expansion required_checks"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.required_checks = ["git diff --check \"${TRACE_FILE}\""] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.required_checks = ["git diff --check \"${TRACE_FILE}\""] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_braced_variable_expansion_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_braced_variable_expansion_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted braced variable expansion required_checks"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.required_checks = ["bash -n .claude/commands/lib/task_contract.sh # trailing prose must fail closed"] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.required_checks = ["bash -n .claude/commands/lib/task_contract.sh # trailing prose must fail closed"] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_comment_suffix_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_comment_suffix_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted comment-suffixed required_checks"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
required_check=$'git diff --check\nrm -rf /'
payload=$(jq --arg required_check "$required_check" '.required_checks = [$required_check] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg required_check "$required_check" --arg contract_id "$contract_id" '.required_checks = [$required_check] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_multiline_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_multiline_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted multiline required_checks"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
required_check=$'git diff --check\t--cached'
payload=$(jq --arg required_check "$required_check" '.required_checks = [$required_check] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg required_check "$required_check" --arg contract_id "$contract_id" '.required_checks = [$required_check] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_control_char_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_control_char_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted control-character required_checks"
  fi
}

test_required_checks_intro_prose_with_numbered_item_passes() {
  local repo="$TMP_ROOT/required_checks_intro_prose"
  local plan_path="$repo/plan_required_checks_intro_prose.md"
  local contract_path="$repo/.claude/tmp/plan_common_task_contract/task-contract.json"

  setup_fake_repo "$repo"
  write_file "$plan_path" '# ExecPlan: Required Checks Intro Prose
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/lib/task_contract.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
Only the numbered commands below are authoritative deterministic checks.
1. bash -n .claude/commands/lib/task_contract.sh

## Completion Boundary
- intro prose is ignored, but numbered required_checks items are kept
'

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$plan_path" \
      --phase impl \
      --task-id required-checks-intro-prose \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$contract_path" \
    || fail "task_contract validate rejected Required Deterministic Checks intro prose with numbered item"

  assert_jq_true "$contract_path" '.required_checks == [
    "bash -n .claude/commands/lib/task_contract.sh"
  ]'
}

test_required_checks_exact_existence_probe_loop_passes() {
  local repo="$TMP_ROOT/required_checks_exact_existence_probe_loop"
  local plan_path="$repo/plan_required_checks_exact_existence_probe_loop.md"
  local contract_path="$repo/.claude/tmp/plan_common_task_contract/task-contract.json"

  setup_fake_repo "$repo"
  write_file "$plan_path" '# ExecPlan: Required Checks Exact Existence Probe Loop
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/lib/task_contract.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- for path in AGENTS.md .agent/PROJECT_CONTEXT.md .claude/commands/lib/task_contract.sh; do test -e "$path"; done

## Completion Boundary
- exact file-existence probe loop is accepted as one bounded required check
'

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$plan_path" \
      --phase impl \
      --task-id required-checks-exact-loop \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$contract_path" \
    || fail "task_contract validate rejected exact existence-probe loop required check"

  assert_jq_true "$contract_path" '.required_checks == [
    "for path in AGENTS.md .agent/PROJECT_CONTEXT.md .claude/commands/lib/task_contract.sh; do test -e \"$path\"; done"
  ]'
}

test_required_checks_pre_list_markdown_structure_fails_closed() {
  local repo="$TMP_ROOT/required_checks_pre_list_markdown_structure"
  local heading_plan="$repo/plan_required_checks_pre_list_heading.md"
  local code_fence_plan="$repo/plan_required_checks_pre_list_code_fence.md"
  local build_stdout="$repo/build-stdout.txt"
  local build_stderr="$repo/build-stderr.txt"
  local contract_path="$repo/.claude/tmp/plan_common_task_contract/task-contract.json"

  setup_fake_repo "$repo"
  write_file "$heading_plan" '# ExecPlan: Required Checks Pre-List Heading
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/lib/task_contract.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
### Commands
- bash -n .claude/commands/lib/task_contract.sh

## Completion Boundary
- pre-list heading in required_checks must fail closed
'
  write_file "$code_fence_plan" '# ExecPlan: Required Checks Pre-List Code Fence
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/lib/task_contract.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
```text
bash -n .claude/commands/lib/task_contract.sh
```
- bash -n .claude/commands/lib/task_contract.sh

## Completion Boundary
- pre-list code fence in required_checks must fail closed
'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$heading_plan" \
      --phase impl \
      --task-id required-checks-pre-list-heading \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted pre-list heading in required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks section contains markdown structure before list start: Required Deterministic Checks'
  assert_file_contains "$build_stderr" 'task_contract_build_json: failed to extract exact required_checks from plan'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$code_fence_plan" \
      --phase impl \
      --task-id required-checks-pre-list-code-fence \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted pre-list code fence in required_checks"
  fi

  assert_file_contains "$build_stderr" 'required_checks section contains markdown structure before list start: Required Deterministic Checks'
  assert_file_contains "$build_stderr" 'task_contract_build_json: failed to extract exact required_checks from plan'
}

test_required_slice_sections_fail_closed() {
  local repo="$TMP_ROOT/required_slice_sections"
  local missing_in_scope_plan="$repo/plan_missing_in_scope.md"
  local missing_completion_boundary_plan="$repo/plan_missing_completion_boundary.md"
  local empty_out_of_scope_plan="$repo/plan_empty_out_of_scope.md"
  local prose_only_out_of_scope_plan="$repo/plan_prose_only_out_of_scope.md"
  local whitespace_only_out_of_scope_plan="$repo/plan_whitespace_only_out_of_scope.md"
  local build_stdout="$repo/build-stdout.txt"
  local build_stderr="$repo/build-stderr.txt"
  local contract_path="$repo/.claude/tmp/plan_common_task_contract/task-contract.json"
  local invalid_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-empty-out-of-scope.json"
  local invalid_whitespace_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-whitespace-out-of-scope.json"
  local mutator_script="$repo/mutate_empty_out_of_scope.sh"

  setup_fake_repo "$repo"
  write_file "$missing_in_scope_plan" '# ExecPlan: Missing In-Scope
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- bash -n .claude/commands/lib/task_contract.sh

## Completion Boundary
- missing in-scope must fail closed
'
  write_file "$missing_completion_boundary_plan" '# ExecPlan: Missing Completion Boundary
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/lib/task_contract.sh

## Out-Of-Scope
- reviewer runtime

## Required Deterministic Checks
- bash -n .claude/commands/lib/task_contract.sh
'
  write_file "$empty_out_of_scope_plan" '# ExecPlan: Empty Out-Of-Scope
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/lib/task_contract.sh

## Out-Of-Scope

## Required Deterministic Checks
- bash -n .claude/commands/lib/task_contract.sh

## Completion Boundary
- empty out-of-scope must fail closed
'
  write_file "$prose_only_out_of_scope_plan" '# ExecPlan: Prose Only Out-Of-Scope
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/lib/task_contract.sh

## Out-Of-Scope
This section exists, but prose alone must not satisfy contract completeness.

## Required Deterministic Checks
- bash -n .claude/commands/lib/task_contract.sh

## Completion Boundary
- prose-only out-of-scope must fail closed
'
  write_file "$whitespace_only_out_of_scope_plan" '# ExecPlan: Whitespace Only Out-Of-Scope
Owner role: `orchestrator`

### Slice A: Contract Artifact Emission For Orchestrated Coder Runs

## In-Scope
- .claude/commands/lib/task_contract.sh

## Out-Of-Scope
'
  printf '%s\n' '-    ' >> "$whitespace_only_out_of_scope_plan"
  printf '%s' '
## Required Deterministic Checks
- bash -n .claude/commands/lib/task_contract.sh

## Completion Boundary
- whitespace-only out-of-scope item must fail closed
' >> "$whitespace_only_out_of_scope_plan"

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$missing_in_scope_plan" \
      --phase impl \
      --task-id missing-in-scope \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted missing In-Scope section"
  fi

  assert_file_contains "$build_stderr" 'required section is missing: In-Scope'
  assert_file_contains "$build_stderr" 'task_contract_build_json: missing or empty required section: In-Scope'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$missing_completion_boundary_plan" \
      --phase impl \
      --task-id missing-completion-boundary \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted missing Completion Boundary section"
  fi

  assert_file_contains "$build_stderr" 'required section is missing: Completion Boundary'
  assert_file_contains "$build_stderr" 'task_contract_build_json: missing or empty required section: Completion Boundary'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$empty_out_of_scope_plan" \
      --phase impl \
      --task-id empty-out-of-scope \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted empty Out-Of-Scope section"
  fi

  assert_file_contains "$build_stderr" 'required section is empty: Out-Of-Scope'
  assert_file_contains "$build_stderr" 'task_contract_build_json: missing or empty required section: Out-Of-Scope'

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$prose_only_out_of_scope_plan" \
      --phase impl \
      --task-id prose-only-out-of-scope \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr" && fail "task_contract emit unexpectedly accepted prose-only Out-Of-Scope section"

  assert_file_contains "$build_stderr" 'required section is empty: Out-Of-Scope'
  assert_file_contains "$build_stderr" 'task_contract_build_json: missing or empty required section: Out-Of-Scope'

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$whitespace_only_out_of_scope_plan" \
      --phase impl \
      --task-id whitespace-only-out-of-scope \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted whitespace-only Out-Of-Scope list item"
  fi

  assert_file_contains "$build_stderr" 'required section contains an empty list item: Out-Of-Scope'
  assert_file_contains "$build_stderr" 'task_contract_build_json: missing or empty required section: Out-Of-Scope'

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$repo/plan_common_task_contract.md" \
      --phase impl \
      --task-id valid-out-of-scope \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.out_of_scope = [] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.out_of_scope = [] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted empty out_of_scope"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.out_of_scope = ["   "] | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.out_of_scope = ["   "] | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_whitespace_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_whitespace_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted whitespace-only out_of_scope entry"
  fi
}

test_completion_boundary_intro_prose_with_numbered_items_passes() {
  local repo="$TMP_ROOT/completion_boundary_intro_prose"
  local contract_path="$repo/.claude/tmp/plan_common_task_contract/task-contract.json"

  setup_fake_repo "$repo"

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$repo/plan_common_task_contract.md" \
      --phase impl \
      --task-id completion-boundary-prose \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$contract_path" \
    || fail "task_contract validate rejected Completion Boundary intro prose with numbered items"

  assert_jq_true "$contract_path" '.completion_boundary == [
    "exactly one repo-local task-contract.json is emitted before coder launch",
    "invalid contracts block coder execution fail-closed"
  ]'
}

test_contract_version_must_match_exactly() {
  local repo="$TMP_ROOT/contract_version"
  local contract_path="$repo/.claude/tmp/plan_common_task_contract/task-contract.json"
  local invalid_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-invalid-version.json"
  local mutator_script="$repo/mutate_invalid_contract_version.sh"

  setup_fake_repo "$repo"

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$repo/plan_common_task_contract.md" \
      --phase impl \
      --task-id invalid-contract-version \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.contract_version = "9.9.9" | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.contract_version = "9.9.9" | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted mismatched contract_version"
  fi
}

test_contract_id_is_required() {
  local repo="$TMP_ROOT/contract_id_required"
  local contract_path="$repo/.claude/tmp/plan_common_task_contract/task-contract.json"
  local invalid_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-missing-id.json"
  local mutator_script="$repo/mutate_missing_contract_id.sh"

  setup_fake_repo "$repo"

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$repo/plan_common_task_contract.md" \
      --phase impl \
      --task-id required-contract-id \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

jq 'del(.contract_id)' "$1" > "$2"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$contract_path" "$invalid_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted missing contract_id"
  fi
}

test_artifact_destination_rejects_dot_segment_and_control_character_escape() {
  local repo="$TMP_ROOT/artifact_destination_escape"
  local build_stdout="$repo/build-stdout.txt"
  local build_stderr="$repo/build-stderr.txt"
  local contract_path="$repo/.claude/tmp/plan_common_task_contract/task-contract.json"
  local invalid_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-dot-segment.json"
  local invalid_multiline_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-multiline.json"
  local invalid_control_char_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-control-char.json"
  local invalid_space_segment_contract="$repo/.claude/tmp/plan_common_task_contract/task-contract-space-segment.json"
  local mutator_script="$repo/mutate_invalid_artifact_destination.sh"

  setup_fake_repo "$repo"

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$repo/plan_common_task_contract.md" \
      --phase impl \
      --task-id invalid-artifact-destination-newline \
      --coder-engine codex \
      --artifact-destination $'.claude/tmp/evil\nname/task-contract.json' \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted multiline artifact_destination"
  fi

  if (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$repo/plan_common_task_contract.md" \
      --phase impl \
      --task-id invalid-artifact-destination-space-segment \
      --coder-engine codex \
      --artifact-destination '.claude/tmp/evil name/task-contract.json' \
      --output "$contract_path"
  ) >"$build_stdout" 2>"$build_stderr"; then
    fail "task_contract emit unexpectedly accepted space-segment artifact_destination"
  fi

  assert_file_contains "$build_stderr" 'task_contract_build_json: invalid artifact_destination: .claude/tmp/evil name/task-contract.json'

  (
    cd "$repo"
    bash "$repo/.claude/commands/lib/task_contract.sh" emit \
      --plan "$repo/plan_common_task_contract.md" \
      --phase impl \
      --task-id invalid-artifact-destination \
      --coder-engine codex \
      --artifact-destination .claude/tmp/plan_common_task_contract/task-contract.json \
      --output "$contract_path"
  ) >/dev/null

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
payload=$(jq '.artifact_destination = ".claude/tmp/../task-contract.json" | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg contract_id "$contract_id" '.artifact_destination = ".claude/tmp/../task-contract.json" | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted dot-segment artifact_destination"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
artifact_destination=$'.claude/tmp/evil\nname/task-contract.json'
payload=$(jq --arg artifact_destination "$artifact_destination" '.artifact_destination = $artifact_destination | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg artifact_destination "$artifact_destination" --arg contract_id "$contract_id" '.artifact_destination = $artifact_destination | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_multiline_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_multiline_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted multiline artifact_destination"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
artifact_destination=$'.claude/tmp/evil\tname/task-contract.json'
payload=$(jq --arg artifact_destination "$artifact_destination" '.artifact_destination = $artifact_destination | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg artifact_destination "$artifact_destination" --arg contract_id "$contract_id" '.artifact_destination = $artifact_destination | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_control_char_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_control_char_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted control-character artifact_destination"
  fi

  cat > "$mutator_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$1"
artifact_destination='.claude/tmp/evil name/task-contract.json'
payload=$(jq --arg artifact_destination "$artifact_destination" '.artifact_destination = $artifact_destination | del(.contract_id)' "$2")
contract_id=$(task_contract_compute_id "$payload")
jq --arg artifact_destination "$artifact_destination" --arg contract_id "$contract_id" '.artifact_destination = $artifact_destination | .contract_id = $contract_id' "$2" > "$3"
EOF
  chmod +x "$mutator_script"

  (
    cd "$repo"
    bash "$mutator_script" "$repo/.claude/commands/lib/task_contract.sh" "$contract_path" "$invalid_space_segment_contract"
  )

  if bash "$repo/.claude/commands/lib/task_contract.sh" validate --file "$invalid_space_segment_contract" >/dev/null 2>&1; then
    fail "task_contract validate unexpectedly accepted non-canonical space-segment artifact_destination"
  fi
}

test_invalid_task_segment_blocks_before_coder() {
  local repo="$TMP_ROOT/invalid_task_segment"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local state_file="$repo/.claude/tmp/plan_common_task_contract/state.json"

  setup_fake_repo "$repo"
  if run_invalid_task_segment_gate "$repo" "$stdout_file" "$stderr_file"; then
    fail "invalid task segment gate unexpectedly succeeded"
  fi

  assert_file_exists "$state_file"
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper must not run after invalid task segment rejection"
  assert_jq_equals "$state_file" '.error.code' 'TASK_CONTRACT_BLOCK'
  assert_file_contains "$stderr_file" 'Invalid task artifact path segment: ..'
  assert_file_contains "$stderr_file" 'Task contract emission failed: invalid task artifact path segment: ..'
}

test_persisted_external_contract_path_blocks_before_coder() {
  local repo="$TMP_ROOT/persisted_external_contract_path"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local state_file="$repo/.claude/tmp/plan_common_task_contract/state.json"

  setup_fake_repo "$repo"
  if run_persisted_external_contract_path_gate "$repo" "$stdout_file" "$stderr_file"; then
    fail "persisted external contract path gate unexpectedly succeeded"
  fi

  assert_file_exists "$state_file"
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper must not run after persisted external contract path rejection"
  assert_jq_equals "$state_file" '.error.code' 'TASK_CONTRACT_BLOCK'
  assert_file_contains "$stderr_file" 'Task contract persisted path is outside canonical location for this task.'
}

test_persisted_mismatched_task_id_blocks_before_coder() {
  local repo="$TMP_ROOT/persisted_mismatched_task_id"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local state_file="$repo/.claude/tmp/plan_common_task_contract/state.json"

  setup_fake_repo "$repo"
  if run_persisted_mismatched_task_id_gate "$repo" "$stdout_file" "$stderr_file"; then
    fail "persisted mismatched task_id gate unexpectedly succeeded"
  fi

  assert_file_exists "$state_file"
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper must not run after persisted task_id mismatch rejection"
  assert_jq_equals "$state_file" '.error.code' 'TASK_CONTRACT_BLOCK'
  assert_file_contains "$stderr_file" 'Task contract task_id mismatch for persisted artifact.'
}

test_invalid_contract_blocks_before_coder() {
  local repo="$TMP_ROOT/invalid"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local state_file="$repo/.claude/tmp/plan_common_task_contract/state.json"

  setup_fake_repo "$repo"
  if run_invalid_contract_gate "$repo" "$stdout_file" "$stderr_file"; then
    fail "invalid contract gate unexpectedly succeeded"
  fi

  assert_file_exists "$state_file"
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper must not run after contract validation failure"
  assert_jq_equals "$state_file" '.error.code' 'TASK_CONTRACT_BLOCK'
  assert_file_contains "$stderr_file" 'Task contract invalid, unreadable, or incomplete.'
}

test_missing_contract_library_blocks_before_coder() {
  local repo="$TMP_ROOT/missing_lib"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local plan_path="$repo/plan_common_task_contract.md"
  local state_file=""
  local coder_output="$repo/.claude/tmp/plan_common_task_contract/impl_coder.md"
  local missing_contract_lib="$repo/.claude/commands/lib/task_contract.missing.sh"
  local rc=0

  setup_fake_repo "$repo"
  perl -0pi -e 's#TASK_CONTRACT_LIB="\$LIB_DIR/task_contract\.sh"#TASK_CONTRACT_LIB="\$LIB_DIR/task_contract.missing.sh"#' \
    "$repo/.claude/commands/auto_orchestrate.sh"
  [[ ! -e "$missing_contract_lib" ]] || fail "expected missing task contract library fixture: $missing_contract_lib"

  set +e
  run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$plan_path" \
    --phase impl \
    --run-coder \
    --coder-engine codex
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    fail "missing task_contract.sh gate unexpectedly succeeded"
  fi

  state_file=$(state_file_for_plan "$repo" "$plan_path")
  assert_file_exists "$state_file"
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper must not run when task_contract.sh is unavailable"
  [[ ! -f "$coder_output" ]] || fail "coder output must not exist when task_contract.sh is unavailable"
  assert_jq_equals "$state_file" '.error.code' 'TASK_CONTRACT_BLOCK'
  assert_file_contains "$stderr_file" 'Task contract library unavailable on orchestrated coder path.'
  assert_file_contains "$stderr_file" 'missing or unreadable:'
}

test_exported_task_contract_functions_do_not_bypass_missing_library_gate() {
  local repo="$TMP_ROOT/missing_lib_exported_functions"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local plan_path="$repo/plan_common_task_contract.md"
  local state_file=""
  local coder_output="$repo/.claude/tmp/plan_common_task_contract/impl_coder.md"
  local rc=0

  setup_fake_repo "$repo"
  perl -0pi -e 's#TASK_CONTRACT_LIB="\$LIB_DIR/task_contract\.sh"#TASK_CONTRACT_LIB="\$LIB_DIR/task_contract.missing.sh"#' \
    "$repo/.claude/commands/auto_orchestrate.sh"

  set +e
  (
    cd "$repo"
    task_contract_emit() { printf 'task-contract-exported\n'; }
    task_contract_validate_file() { return 0; }
    task_contract_read_id() { printf 'task-contract-exported\n'; }
    export -f task_contract_emit task_contract_validate_file task_contract_read_id
    CODEX_WRAPPER_TRACE="$repo/.claude/tmp/codex-wrapper.trace" \
    SESSION_HELPER_TRACE="$repo/.claude/tmp/session.trace" \
    SESSION_COUNTER_DIR="$repo/.claude/tmp/session-counters" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$repo/.claude/commands/auto_orchestrate.sh" \
      --plan "$plan_path" \
      --phase impl \
      --run-coder \
      --coder-engine codex
  ) >"$stdout_file" 2>"$stderr_file"
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    fail "exported task_contract functions unexpectedly bypassed missing library gate"
  fi

  state_file=$(state_file_for_plan "$repo" "$plan_path")
  assert_file_exists "$state_file"
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper must not run when exported task_contract functions are present but the canonical library is missing"
  [[ ! -f "$coder_output" ]] || fail "coder output must not exist when canonical task_contract library is missing"
  assert_jq_equals "$state_file" '.error.code' 'TASK_CONTRACT_BLOCK'
  assert_file_contains "$stderr_file" 'Task contract library unavailable on orchestrated coder path.'
  assert_file_contains "$stderr_file" 'missing or unreadable:'
}

main() {
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/common_task_contract_smoke.XXXXXX")"
  test_valid_contract_emission
  test_slice_b_addendum_contract_emit_and_validate
  test_slice_b_support_context_fail_closed_cases
  test_plan_path_normalization_stabilizes_contract_id
  test_required_checks_exact_commands_enforced
  test_required_checks_intro_prose_with_numbered_item_passes
  test_required_checks_exact_existence_probe_loop_passes
  test_required_checks_pre_list_markdown_structure_fails_closed
  test_required_slice_sections_fail_closed
  test_completion_boundary_intro_prose_with_numbered_items_passes
  test_contract_version_must_match_exactly
  test_contract_id_is_required
  test_artifact_destination_rejects_dot_segment_and_control_character_escape
  test_invalid_contract_blocks_before_coder
  test_invalid_task_segment_blocks_before_coder
  test_persisted_external_contract_path_blocks_before_coder
  test_persisted_mismatched_task_id_blocks_before_coder
  test_missing_contract_library_blocks_before_coder
  test_exported_task_contract_functions_do_not_bypass_missing_library_gate
  printf 'PASS: common_task_contract_smoke\n'
}

main "$@"
