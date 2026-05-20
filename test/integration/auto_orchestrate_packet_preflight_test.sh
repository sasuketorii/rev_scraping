#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP_ROOT=""
RUN_AUTO_TIMEOUT_SECS="${AUTO_ORCHESTRATE_PACKET_PREFLIGHT_RUN_TIMEOUT_SECS:-60}"
TIMEOUT_DIAG_ROOT="${AUTO_ORCHESTRATE_PACKET_PREFLIGHT_TIMEOUT_DIAG_ROOT:-$PROJECT_ROOT/.claude/tmp/auto-orchestrate-packet-preflight-timeouts}"
POLL_TICKS_PER_SEC=10

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

assert_file_not_exists() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "unexpected file exists: $path"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || fail "missing expected text in $file: $needle"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$expected" == "$actual" ]] || fail "$message (expected=$expected actual=$actual)"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
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

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s' "$*" > "$path"
}

remove_matching_line_occurrence() {
  local path="$1"
  local needle="$2"
  local occurrence="${3:-1}"
  local tmp=""

  [[ "$occurrence" =~ ^[1-9][0-9]*$ ]] || fail "invalid occurrence: $occurrence"
  tmp="$(mktemp "${TMPDIR:-/tmp}/auto-orchestrate-packet-preflight-edit.XXXXXX")"
  if ! awk -v needle="$needle" -v occurrence="$occurrence" '
    index($0, needle) {
      hits += 1
      if (hits == occurrence && removed == 0) {
        removed = 1
        next
      }
    }
    { print }
    END {
      if (removed != 1) {
        exit 42
      }
    }
  ' "$path" > "$tmp"; then
    /bin/rm -f "$tmp"
    fail "missing needle: $needle"
  fi
  mv "$tmp" "$path"
}

setup_fake_repo() {
  local repo="$1"

  mkdir -p \
    "$repo/.claude/commands/lib" \
    "$repo/.claude/tmp" \
    "$repo/.agent/active/prompts" \
    "$repo/.agent/active/sow" \
    "$repo/.agent/registry" \
    "$repo/.agent_rules" \
    "$repo/.shared" \
    "$repo/docs/manual" \
    "$repo/docs/prompts" \
    "$repo/docs/roles" \
    "$repo/scripts"

  /bin/cp "$PROJECT_ROOT/.claude/commands/auto_orchestrate.sh" "$repo/.claude/commands/auto_orchestrate.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/coder.sh" "$repo/.claude/commands/lib/coder.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/state.sh" "$repo/.claude/commands/lib/state.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/task_contract.sh" "$repo/.claude/commands/lib/task_contract.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/utils.sh" "$repo/.claude/commands/lib/utils.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/timeout.sh" "$repo/.claude/commands/lib/timeout.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/orchestration_packet.sh" "$repo/.claude/commands/lib/orchestration_packet.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/orchestration_policy.sh" "$repo/.claude/commands/lib/orchestration_policy.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/baseline_freeze.sh" "$repo/.claude/commands/lib/baseline_freeze.sh"
  /bin/cp "$PROJECT_ROOT/.agent/registry/orchestration_policy_projection.json" "$repo/.agent/registry/orchestration_policy_projection.json"
  /bin/cp "$PROJECT_ROOT/scripts/validate-orchestration-packet.sh" "$repo/scripts/validate-orchestration-packet.sh"

  write_file "$repo/.claude/commands/lib/session.sh" '#!/usr/bin/env bash
set -euo pipefail

session_start() {
  local prompt="$1"
  local output_file="${2:-}"
  [[ -n "$output_file" ]] && printf "# coder output\n\n---OUTPUT-END---\n" > "$output_file"
  printf "codex-session-001\n"
}

session_resume() {
  local session_id="$1"
  local prompt="$2"
  local output_file="${3:-}"
  [[ -n "$output_file" ]] && printf "# coder output\n\n---OUTPUT-END---\n" > "$output_file"
  return 0
}

session_fork() {
  local parent_session_id="$1"
  local prompt="$2"
  local output_file="${3:-}"
  [[ -n "$output_file" ]] && printf "# coder output\n\n---OUTPUT-END---\n" > "$output_file"
  printf "codex-session-002\n"
}

session_run_with_timeout() {
  local timeout_secs="$1"
  local session_id="$2"
  local prompt="$3"
  local output_file="${4:-}"
  [[ -n "$output_file" ]] && printf "# coder output\n\n---OUTPUT-END---\n" > "$output_file"
}

get_latest_codex_session() {
  printf "codex-session-latest\n"
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

  write_file "$repo/AGENTS.md" '# AGENTS

runtime truth only
'
  write_file "$repo/.agent_rules/RULES.md" '# RULES

repo-wide hard rules
'
  write_file "$repo/.agent/PROJECT_CONTEXT.md" '# Project Context

local project context
'
  write_file "$repo/docs/manual/common-task-contract.md" '# Common Task Contract

runtime envelope guide
'
  write_file "$repo/docs/manual/verification-truth-matrix.md" '# Verification Truth Matrix

acceptance truth
'
  write_file "$repo/docs/roles/reviewer.md" '# Reviewer

review output contract
'
  write_file "$repo/.agent/registry/policy_sources.json" '[
  {
    "path": ".agent_rules/RULES.md",
    "authority_type": "hard_rules",
    "governs": ["repo-wide invariants"],
    "stable": true,
    "required_checks_surface": ["git diff --check"]
  },
  {
    "path": "docs/manual/verification-truth-matrix.md",
    "authority_type": "verification_truth",
    "governs": ["verification truth placement"],
    "stable": true,
    "required_checks_surface": ["git diff --check"]
  },
  {
    "path": "AGENTS.md",
    "authority_type": "runtime_policy",
    "governs": ["runtime contract"],
    "stable": true,
    "required_checks_surface": ["git diff --check"]
  },
  {
    "path": ".agent/registry/orchestration_policy_projection.json",
    "authority_type": "contract_surface",
    "governs": ["projection source"],
    "stable": true,
    "required_checks_surface": ["jq empty"]
  },
  {
    "path": ".agent/PROJECT_CONTEXT.md",
    "authority_type": "project_context",
    "governs": ["project context"],
    "stable": true,
    "required_checks_surface": ["git diff --check"]
  },
  {
    "path": "docs/roles/reviewer.md",
    "authority_type": "role_policy",
    "governs": ["reviewer contract"],
    "stable": true,
    "required_checks_surface": ["git diff --check"]
  },
  {
    "path": "docs/manual/common-task-contract.md",
    "authority_type": "contract_surface",
    "governs": ["contract guide"],
    "stable": true,
    "required_checks_surface": ["git diff --check"]
  },
  {
    "path": ".claude/commands/lib/task_contract.sh",
    "authority_type": "contract_runtime",
    "governs": ["task contract enforcement"],
    "stable": true,
    "required_checks_surface": ["bash -n"]
  }
]'

  write_file "$repo/.agent/active/plan_packet_preflight.md" '# ExecPlan: auto_orchestrate Packet Preflight Fixture

- task id: `task-auto-orchestrate-packet-preflight`

## Slice 構成

### Slice P1: packet preflight

- slice id: `auto-orchestrate-packet-s1`
- SOW: `.agent/active/sow/20260421_auto_orchestrate_packet_preflight.md`
- coder prompt: `.agent/active/prompts/coder_auto_orchestrate_packet_preflight.md`
- reviewer prompt: `.agent/active/prompts/reviewer_auto_orchestrate_packet_preflight.md`
- coder output stub: `.agent/active/prompts/coder_auto_orchestrate_packet_preflight_output.md`
- reviewer output stub: `.agent/active/prompts/reviewer_auto_orchestrate_packet_preflight_output.md`
- evidence destination: `.claude/tmp/packet-preflight/evidence/`

## In-Scope
- auto_orchestrate coder-launch packet preflight

## Out-Of-Scope
- reviewer launch integration

## Required Deterministic Checks
- bash test/integration/auto_orchestrate_packet_preflight_test.sh

## Completion Boundary
- packet validates before coder launch

## Hard Constraints
- single packet tuple only

## Stop-Rule
- malformed packetized plan is fail-closed
'
  write_file "$repo/.agent/active/plan_ambiguous_packet_preflight.md" '# ExecPlan: ambiguous Packet Preflight Fixture

- task id: `task-auto-orchestrate-packet-preflight`

## Slice 構成

### Slice P1: first

- slice id: `auto-orchestrate-packet-s1`
- SOW: `.agent/active/sow/20260421_auto_orchestrate_packet_preflight.md`
- coder prompt: `.agent/active/prompts/coder_auto_orchestrate_packet_preflight.md`
- reviewer prompt: `.agent/active/prompts/reviewer_auto_orchestrate_packet_preflight.md`
- coder output stub: `.agent/active/prompts/coder_auto_orchestrate_packet_preflight_output.md`
- reviewer output stub: `.agent/active/prompts/reviewer_auto_orchestrate_packet_preflight_output.md`
- evidence destination: `.claude/tmp/packet-preflight/evidence/`

### Slice P2: second

- slice id: `auto-orchestrate-packet-s2`
- SOW: `.agent/active/sow/20260421_auto_orchestrate_packet_preflight.md`
- coder prompt: `.agent/active/prompts/coder_auto_orchestrate_packet_preflight.md`
- reviewer prompt: `.agent/active/prompts/reviewer_auto_orchestrate_packet_preflight.md`
- coder output stub: `.agent/active/prompts/coder_auto_orchestrate_packet_preflight_output_2.md`
- reviewer output stub: `.agent/active/prompts/reviewer_auto_orchestrate_packet_preflight_output_2.md`
- evidence destination: `.claude/tmp/packet-preflight/evidence-2/`

## In-Scope
- auto_orchestrate coder-launch packet preflight

## Out-Of-Scope
- reviewer launch integration

## Required Deterministic Checks
- bash test/integration/auto_orchestrate_packet_preflight_test.sh

## Completion Boundary
- packet validates before coder launch

## Hard Constraints
- single packet tuple only

## Stop-Rule
- malformed packetized plan is fail-closed
'
  write_file "$repo/.agent/active/sow/20260421_auto_orchestrate_packet_preflight.md" '# SOW: auto_orchestrate Packet Preflight Fixture

packet evidence only
'
  write_file "$repo/.agent/active/prompts/coder_auto_orchestrate_packet_preflight.md" '# Coder Prompt

implement fixture change
'
  write_file "$repo/.agent/active/prompts/reviewer_auto_orchestrate_packet_preflight.md" '# Reviewer Prompt

review fixture change
'
  write_file "$repo/.agent/active/sow/task-lineage-ledger.md" '# Task Lineage Ledger

## task-auto-orchestrate-packet-preflight
- task id: `task-auto-orchestrate-packet-preflight`
- latest orchestrator-accepted slice: `auto-orchestrate-packet-s0`
- current active slice: `auto-orchestrate-packet-s1`
- carried task-level counters:
  - `task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-21T10:00:00Z; last-progress=2026-04-21T10:15:00Z`
  - `task-level stall-or-wall-time budget status: within-budget`
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
  write_file "$repo/.shared/project_id" 'auto-orchestrate-packet-preflight
'

  chmod +x \
    "$repo/.claude/commands/auto_orchestrate.sh" \
    "$repo/.claude/commands/lib/session.sh" \
    "$repo/.claude/commands/lib/reviewer.sh" \
    "$repo/.claude/commands/lib/context_analysis.sh" \
    "$repo/.claude/commands/lib/context_capsule.sh" \
    "$repo/.claude/commands/lib/task_contract.sh" \
    "$repo/.claude/commands/lib/orchestration_policy.sh" \
    "$repo/.claude/commands/lib/baseline_freeze.sh" \
    "$repo/scripts/validate-orchestration-packet.sh" \
    "$repo/scripts/codex-wrapper.sh" \
    "$repo/scripts/resolve-semantic-project-id.sh"

  git -C "$repo" init -q

  : > "$repo/.claude/tmp/codex-wrapper.trace"
}

run_auto() {
  local repo="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local status=0
  local pid=""
  local pgid=""
  local timeout_diag_dir=""
  local command_runner=()
  local elapsed_ticks=0
  local timeout_ticks=0
  shift 3

  [[ "$RUN_AUTO_TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid AUTO_ORCHESTRATE_PACKET_PREFLIGHT_RUN_TIMEOUT_SECS: $RUN_AUTO_TIMEOUT_SECS"
  timeout_ticks=$((RUN_AUTO_TIMEOUT_SECS * POLL_TICKS_PER_SEC))

  command_runner=(
    /bin/bash
    -c
    'repo="$1"; shift; cd "$repo" || exit 1; export CODEX_WRAPPER_TRACE="$repo/.claude/tmp/codex-wrapper.trace"; export PATH="/usr/bin:/bin:/usr/sbin:/sbin"; exec /bin/bash "$repo/.claude/commands/auto_orchestrate.sh" "$@"'
    run_auto
    "$repo"
    "$@"
  )

  if command -v perl >/dev/null 2>&1; then
    perl -e 'use POSIX qw(setsid); setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!";' \
      -- "${command_runner[@]}" >"$stdout_file" 2>"$stderr_file" &
  else
    "${command_runner[@]}" >"$stdout_file" 2>"$stderr_file" &
  fi
  pid=$!
  pgid=$pid

  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed_ticks" -ge "$timeout_ticks" ]]; then
      status=124
      timeout_diag_dir="$TIMEOUT_DIAG_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "$repo")"
      mkdir -p "$timeout_diag_dir"
      {
        printf 'timed_out_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'timeout_secs=%s\n' "$RUN_AUTO_TIMEOUT_SECS"
        printf 'repo=%s\n' "$repo"
        printf 'args=%s\n' "$*"
      } > "$timeout_diag_dir/run_auto_timeout.txt"
      cp "$timeout_diag_dir/run_auto_timeout.txt" "$repo/run_auto_timeout.txt" 2>/dev/null || true
      ps -ax -o pid,ppid,pgid,etime,stat,command > "$timeout_diag_dir/process_snapshot_before_timeout_kill.log" 2>/dev/null || true
      cp "$timeout_diag_dir/process_snapshot_before_timeout_kill.log" "$repo/run_auto_process_snapshot_before_timeout_kill.log" 2>/dev/null || true
      kill -TERM -- -"$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -KILL -- -"$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      printf 'FAIL: run_auto timed out after %ss; diagnostics=%s\n' "$RUN_AUTO_TIMEOUT_SECS" "$timeout_diag_dir" >&2
      return "$status"
    fi
    sleep 0.1
    elapsed_ticks=$((elapsed_ticks + 1))
  done

  wait "$pid"
}

test_timeout_and_status_probe() {
  local repo="$TMP_ROOT/timeout-probe"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local plan_path="$repo/.agent/active/plan_packet_preflight.md"
  local status=0

  /bin/rm -rf "$TIMEOUT_DIAG_ROOT"
  setup_fake_repo "$repo"
  write_file "$repo/.claude/commands/auto_orchestrate.sh" '#!/usr/bin/env bash
set -euo pipefail
sleep 5
'
  chmod +x "$repo/.claude/commands/auto_orchestrate.sh"

  if run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$plan_path" \
    --phase impl \
    --run-coder \
    --coder-engine codex; then
    fail "timeout probe unexpectedly passed"
  else
    status=$?
  fi
  assert_equals "124" "$status" "timeout probe status"
  assert_file_exists "$repo/run_auto_timeout.txt"
  assert_file_exists "$repo/run_auto_process_snapshot_before_timeout_kill.log"
  assert_file_contains "$repo/run_auto_timeout.txt" "timeout_secs=$RUN_AUTO_TIMEOUT_SECS"

  repo="$TMP_ROOT/status-probe"
  stdout_file="$repo/stdout.txt"
  stderr_file="$repo/stderr.txt"
  plan_path="$repo/.agent/active/plan_packet_preflight.md"
  setup_fake_repo "$repo"
  write_file "$repo/.claude/commands/auto_orchestrate.sh" '#!/usr/bin/env bash
exit 42
'
  chmod +x "$repo/.claude/commands/auto_orchestrate.sh"

  if run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$plan_path" \
    --phase impl \
    --run-coder \
    --coder-engine codex; then
    fail "status propagation probe unexpectedly passed"
  else
    status=$?
  fi
  assert_equals "42" "$status" "status propagation probe status"

  printf 'PASS: auto_orchestrate_packet_preflight_timeout_probe\n'
}

test_single_tuple_preflight_passes() {
  local repo="$TMP_ROOT/green"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local plan_path="$repo/.agent/active/plan_packet_preflight.md"
  local state_file=""

  setup_fake_repo "$repo"
  run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$plan_path" \
    --phase impl \
    --run-coder \
    --coder-engine codex

  state_file=$(state_file_for_plan "$repo" "$plan_path")

  assert_file_exists "$repo/.claude/tmp/plan_packet_preflight/orchestration-policy.bundle.json"
  assert_file_exists "$repo/.claude/tmp/packet-preflight/evidence/baseline_freeze.txt"
  assert_file_exists "$repo/.agent/active/prompts/coder_auto_orchestrate_packet_preflight_output.md"
  assert_file_exists "$repo/.agent/active/prompts/reviewer_auto_orchestrate_packet_preflight_output.md"
  assert_equals "0" "$(wc -c < "$repo/.agent/active/prompts/coder_auto_orchestrate_packet_preflight_output.md" | tr -d '[:space:]')" \
    "coder output stub should remain empty before coder launch"
  assert_equals "0" "$(wc -c < "$repo/.agent/active/prompts/reviewer_auto_orchestrate_packet_preflight_output.md" | tr -d '[:space:]')" \
    "reviewer output stub should remain empty before reviewer launch"
  assert_file_contains "$stderr_file" 'Orchestration packet preflight passed: slice=auto-orchestrate-packet-s1 task=task-auto-orchestrate-packet-preflight'
  assert_equals "1" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper should run exactly once on green path"
  assert_file_exists "$state_file"
}

test_missing_reviewer_prompt_blocks_before_coder_launch() {
  local repo="$TMP_ROOT/missing-reviewer-prompt"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local plan_path="$repo/.agent/active/plan_packet_preflight.md"
  local state_file=""

  setup_fake_repo "$repo"
  /bin/rm -f "$repo/.agent/active/prompts/reviewer_auto_orchestrate_packet_preflight.md"

  if run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$plan_path" \
    --phase impl \
    --run-coder \
    --coder-engine codex; then
    fail "auto_orchestrate unexpectedly succeeded without reviewer prompt"
  fi

  state_file=$(state_file_for_plan "$repo" "$plan_path")
  assert_file_exists "$state_file"
  assert_file_contains "$stderr_file" 'Orchestration packet preflight validation failed closed.'
  assert_file_contains "$state_file" '"code": "ORCHESTRATION_PACKET_BLOCK"'
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper must not run when packet preflight blocks"
}

test_incomplete_single_tuple_plan_blocks_before_coder_launch() {
  local repo="$TMP_ROOT/incomplete-single"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local plan_path="$repo/.agent/active/plan_packet_preflight.md"
  local state_file=""

  setup_fake_repo "$repo"
  remove_matching_line_occurrence "$plan_path" '- reviewer prompt:' 1

  if run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$plan_path" \
    --phase impl \
    --run-coder \
    --coder-engine codex; then
    fail "auto_orchestrate unexpectedly succeeded with incomplete single packet tuple"
  fi

  state_file=$(state_file_for_plan "$repo" "$plan_path")
  assert_file_exists "$state_file"
  assert_file_contains "$stderr_file" 'Orchestration packet preflight failed closed: packet tuple declared but required fields are missing'
  assert_file_contains "$state_file" '"code": "ORCHESTRATION_PACKET_BLOCK"'
  assert_equals "0" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper must not run when a single packet tuple is malformed"
}

test_ambiguous_tuple_plan_skips_v1_preflight() {
  local repo="$TMP_ROOT/ambiguous"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local plan_path="$repo/.agent/active/plan_ambiguous_packet_preflight.md"

  setup_fake_repo "$repo"
  run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$plan_path" \
    --phase impl \
    --run-coder \
    --coder-engine codex

  assert_file_contains "$stderr_file" 'Orchestration packet preflight skipped: multiple packet tuples declared in plan'
  assert_file_not_exists "$repo/.claude/tmp/plan_ambiguous_packet_preflight/orchestration-policy.bundle.json"
  assert_equals "1" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper should still run when v1 packet preflight skips ambiguous tuples"
}

test_mixed_complete_incomplete_tuple_plan_skips_v1_preflight() {
  local repo="$TMP_ROOT/mixed-ambiguous"
  local stdout_file="$repo/stdout.txt"
  local stderr_file="$repo/stderr.txt"
  local plan_path="$repo/.agent/active/plan_ambiguous_packet_preflight.md"

  setup_fake_repo "$repo"
  remove_matching_line_occurrence "$plan_path" '- reviewer prompt:' 2
  run_auto "$repo" "$stdout_file" "$stderr_file" \
    --plan "$plan_path" \
    --phase impl \
    --run-coder \
    --coder-engine codex

  assert_file_contains "$stderr_file" 'Orchestration packet preflight skipped: multiple packet tuples declared in plan; at least one tuple is incomplete'
  assert_file_not_exists "$repo/.claude/tmp/plan_ambiguous_packet_preflight/orchestration-policy.bundle.json"
  assert_equals "1" "$(line_count "$repo/.claude/tmp/codex-wrapper.trace")" \
    "coder wrapper should still run when multi-slice packet tuples are mixed complete/incomplete"
}

require_cmd bash
require_cmd git
require_cmd jq
require_cmd awk

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/auto_orchestrate_packet_preflight.XXXXXX")"

if [[ "${AUTO_ORCHESTRATE_PACKET_PREFLIGHT_TIMEOUT_PROBE:-0}" == "1" ]]; then
  test_timeout_and_status_probe
  exit 0
fi

test_single_tuple_preflight_passes
test_missing_reviewer_prompt_blocks_before_coder_launch
test_incomplete_single_tuple_plan_blocks_before_coder_launch
test_ambiguous_tuple_plan_skips_v1_preflight
test_mixed_complete_incomplete_tuple_plan_skips_v1_preflight

printf 'PASS: auto_orchestrate_packet_preflight_test\n'
