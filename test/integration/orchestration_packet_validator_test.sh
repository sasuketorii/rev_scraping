#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP_ROOT=""
TEST_CASE_TIMEOUT_SECS="${ORCHESTRATION_PACKET_VALIDATOR_TEST_CASE_TIMEOUT_SECS:-60}"
TIMEOUT_DIAG_ROOT="${ORCHESTRATION_PACKET_VALIDATOR_DIAG_ROOT:-$PROJECT_ROOT/.claude/tmp/orchestration-packet-validator-timeouts}"
POLL_TICKS_PER_SEC=10

cleanup() {
  /bin/rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

write_file() {
  local path="$1"
  local content="$2"

  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
}

run_test_case() {
  local case_name="$1"
  local expect_timeout="${2:-NO}"
  local pid=""
  local elapsed_ticks=0
  local timeout_ticks=0
  local status=0
  local diag_dir=""

  [[ "$TEST_CASE_TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid ORCHESTRATION_PACKET_VALIDATOR_TEST_CASE_TIMEOUT_SECS: $TEST_CASE_TIMEOUT_SECS"
  timeout_ticks=$((TEST_CASE_TIMEOUT_SECS * POLL_TICKS_PER_SEC))

  ( "$case_name" ) &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed_ticks" -ge "$timeout_ticks" ]]; then
      diag_dir="$TIMEOUT_DIAG_ROOT/$(date -u +%Y%m%dT%H%M%SZ)_$$_$case_name"
      mkdir -p "$diag_dir"
      {
        printf 'case=%s\n' "$case_name"
        printf 'pid=%s\n' "$pid"
        printf 'timeout_secs=%s\n' "$TEST_CASE_TIMEOUT_SECS"
        printf 'timed_out_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      } > "$diag_dir/timeout.txt"
      ps -ax -o pid,ppid,pgid,etime,stat,command > "$diag_dir/process-snapshot-before-timeout-kill.log" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      if [[ "$expect_timeout" == "YES" ]]; then
        return 124
      fi
      fail "test case timed out: $case_name (diagnostics: $diag_dir)"
    fi
    sleep 0.1
    elapsed_ticks=$((elapsed_ticks + 1))
  done

  if wait "$pid"; then
    return 0
  else
    status=$?
    fail "test case failed: $case_name (rc=$status)"
  fi
}

test_timeout_probe_hangs() {
  sleep 5
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || fail "missing file: $path"
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

  actual="$(jq -r "$query" "$file")"
  [[ "$actual" == "$expected" ]] || fail "jq assertion failed: $query (expected=$expected actual=$actual)"
}

run_timeout_probe() {
  local timeout_file=""
  local snapshot_file=""
  local status=0

  /bin/rm -rf "$TIMEOUT_DIAG_ROOT"
  mkdir -p "$TIMEOUT_DIAG_ROOT"

  if run_test_case test_timeout_probe_hangs YES; then
    fail "timeout probe unexpectedly passed"
  else
    status=$?
  fi
  [[ "$status" == "124" ]] || fail "timeout probe returned unexpected status: $status"

  timeout_file="$(find "$TIMEOUT_DIAG_ROOT" -name timeout.txt -print | head -n 1)"
  [[ -n "$timeout_file" ]] || fail "timeout probe did not write timeout.txt"
  snapshot_file="$(dirname "$timeout_file")/process-snapshot-before-timeout-kill.log"
  assert_file_exists "$snapshot_file"
  assert_file_contains "$timeout_file" "case=test_timeout_probe_hangs"
  assert_file_contains "$timeout_file" "timeout_secs=$TEST_CASE_TIMEOUT_SECS"

  printf 'PASS: orchestration_packet_validator_timeout_probe\n'
}

setup_fake_repo() {
  local repo="$1"

  mkdir -p \
    "$repo/.claude/commands/lib" \
    "$repo/.agent/registry" \
    "$repo/.agent/active/prompts" \
    "$repo/.agent/active/sow" \
    "$repo/.agent_rules" \
    "$repo/docs/manual" \
    "$repo/docs/roles" \
    "$repo/scripts"

  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/utils.sh" "$repo/.claude/commands/lib/utils.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/task_contract.sh" "$repo/.claude/commands/lib/task_contract.sh"
  /bin/cp "$PROJECT_ROOT/.claude/commands/lib/orchestration_policy.sh" "$repo/.claude/commands/lib/orchestration_policy.sh"
  /bin/cp "$PROJECT_ROOT/scripts/validate-orchestration-packet.sh" "$repo/scripts/validate-orchestration-packet.sh"
  /bin/cp "$PROJECT_ROOT/.agent/registry/orchestration_policy_projection.json" "$repo/.agent/registry/orchestration_policy_projection.json"

  chmod +x \
    "$repo/.claude/commands/lib/utils.sh" \
    "$repo/.claude/commands/lib/task_contract.sh" \
    "$repo/.claude/commands/lib/orchestration_policy.sh" \
    "$repo/scripts/validate-orchestration-packet.sh"

  write_file "$repo/AGENTS.md" '# AGENTS

runtime truth only'

  write_file "$repo/.agent_rules/RULES.md" '# RULES

repo-wide hard rules'

  write_file "$repo/.agent/PROJECT_CONTEXT.md" '# Project Context

local project context'

  write_file "$repo/docs/manual/common-task-contract.md" '# Common Task Contract

runtime envelope guide'

  write_file "$repo/docs/manual/verification-truth-matrix.md" '# Verification Truth Matrix

acceptance truth'

  write_file "$repo/docs/roles/reviewer.md" '# Reviewer

review output contract'

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

  write_file "$repo/.agent/active/plan_execplan.md" '# ExecPlan: Packet Validator Fixture

## In-Scope
- scripts/validate-orchestration-packet.sh

## Out-Of-Scope
- auto_orchestrate integration

## Required Deterministic Checks
- git diff --check
- bash test/integration/orchestration_packet_validator_test.sh

## Completion Boundary
- packet validates before launch

## Hard Constraints
- derived-only bundle remains non-authoritative

## Stop-Rule
- missing packet evidence is fail-closed
'

  write_file "$repo/.agent/active/sow/sow_fixture.md" '# SOW: Packet Validator Fixture

packet evidence only
'

  write_file "$repo/.agent/active/sow/task-lineage-ledger.md" '# Task Lineage Ledger

## task-fixture
- task id: `task-fixture`
- latest orchestrator-accepted slice: `slice-accepted`
- current active slice: `slice-active`
- carried task-level counters:
  - `task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-21T10:00:00Z; last-progress=2026-04-21T10:15:00Z`
  - `task-level stall-or-wall-time budget status: within-budget`
'

  write_file "$repo/.agent/active/prompts/coder_fixture.md" '# Coder Prompt

implement fixture change
'

  write_file "$repo/.agent/active/prompts/reviewer_fixture.md" '# Reviewer Prompt

review fixture change
'

  : > "$repo/.agent/active/prompts/coder_fixture_output.md"
  : > "$repo/.agent/active/prompts/reviewer_fixture_output.md"

  write_file "$repo/.agent/active/sow/baseline_freeze.txt" '# baseline_freeze_version=1
# repo_root=/tmp/fake-repo
# generated_at=2026-04-21T10:20:00Z
'

  git -C "$repo" init -q
}

run_compile() {
  local repo="$1"
  local status=0

  pushd "$repo" >/dev/null
  bash "$repo/scripts/validate-orchestration-packet.sh" compile \
    --output "$repo/.claude/packet-policy.json" \
    --manifest .agent/registry/policy_sources.json \
    >/dev/null
  status=$?
  popd >/dev/null
  return "$status"
}

run_validate() {
  local repo="$1"
  local status=0
  shift

  pushd "$repo" >/dev/null
  bash "$repo/scripts/validate-orchestration-packet.sh" validate \
    --bundle "$repo/.claude/packet-policy.json" \
    --plan "$repo/.agent/active/plan_execplan.md" \
    --sow "$repo/.agent/active/sow/sow_fixture.md" \
    --ledger "$repo/.agent/active/sow/task-lineage-ledger.md" \
    --coder-prompt "$repo/.agent/active/prompts/coder_fixture.md" \
    --reviewer-prompt "$repo/.agent/active/prompts/reviewer_fixture.md" \
    --coder-output-stub "$repo/.agent/active/prompts/coder_fixture_output.md" \
    --reviewer-output-stub "$repo/.agent/active/prompts/reviewer_fixture_output.md" \
    --baseline-freeze "$repo/.agent/active/sow/baseline_freeze.txt" \
    --task-id task-fixture \
    --expected-accepted-slice slice-accepted \
    --expected-active-slice slice-active \
    "$@"
  status=$?
  popd >/dev/null
  return "$status"
}

test_success_case() {
  local repo="$TMP_ROOT/success"

  setup_fake_repo "$repo"
  run_compile "$repo"
  assert_file_exists "$repo/.claude/packet-policy.json"
  assert_jq_equals "$repo/.claude/packet-policy.json" '.derived_only' 'true'
  assert_jq_equals "$repo/.claude/packet-policy.json" '.projection.baseline_snapshot_name' 'baseline_freeze.txt'
  assert_jq_equals "$repo/.claude/packet-policy.json" '.projection.reviewer_contract.canonical_worker_outcome_contract_source' 'docs/manual/verification-truth-matrix.md :: Worker Outcome Contract'
  assert_jq_equals "$repo/.claude/packet-policy.json" '.sources | length' '8'
  run_validate "$repo"
}

test_missing_baseline_fails() {
  local repo="$TMP_ROOT/missing_baseline"

  setup_fake_repo "$repo"
  run_compile "$repo"
  /bin/rm -f "$repo/.agent/active/sow/baseline_freeze.txt"

  if run_validate "$repo" >/dev/null 2>&1; then
    fail "missing baseline snapshot should fail"
  fi
}

test_missing_reviewer_stub_fails() {
  local repo="$TMP_ROOT/missing_reviewer_stub"

  setup_fake_repo "$repo"
  run_compile "$repo"
  /bin/rm -f "$repo/.agent/active/prompts/reviewer_fixture_output.md"

  if run_validate "$repo" >/dev/null 2>&1; then
    fail "missing reviewer stub should fail"
  fi
}

test_deprecated_alias_fails() {
  local repo="$TMP_ROOT/deprecated_alias"

  setup_fake_repo "$repo"
  run_compile "$repo"
  printf '\n- checkpoint boundary: stale field alias\n' >> "$repo/.agent/active/plan_execplan.md"

  if run_validate "$repo" >/dev/null 2>&1; then
    fail "deprecated alias should fail"
  fi
}

test_deprecated_alias_numbered_list_fails() {
  local repo="$TMP_ROOT/deprecated_alias_numbered"

  setup_fake_repo "$repo"
  run_compile "$repo"
  printf '\n1. checkpoint boundary: stale field alias\n' >> "$repo/.agent/active/plan_execplan.md"

  if run_validate "$repo" >/dev/null 2>&1; then
    fail "numbered-list deprecated alias should fail"
  fi
}

test_deprecated_alias_prose_allowed() {
  local repo="$TMP_ROOT/deprecated_alias_prose"

  setup_fake_repo "$repo"
  run_compile "$repo"
  printf '\n- `checkpoint boundary:` is deprecated; use completion boundary instead\n' >> "$repo/.agent/active/plan_execplan.md"

  run_validate "$repo" >/dev/null
}

test_deprecated_alias_backticked_key_fails() {
  local repo="$TMP_ROOT/deprecated_alias_backticked_key"

  setup_fake_repo "$repo"
  run_compile "$repo"
  printf '\n- `checkpoint boundary`: stale field alias\n' >> "$repo/.agent/active/plan_execplan.md"

  if run_validate "$repo" >/dev/null 2>&1; then
    fail "backticked deprecated alias key should fail"
  fi
}

test_ledger_mismatch_fails() {
  local repo="$TMP_ROOT/ledger_mismatch"

  setup_fake_repo "$repo"
  run_compile "$repo"

  if (
    cd "$repo"
    bash "$repo/scripts/validate-orchestration-packet.sh" validate \
      --bundle "$repo/.claude/packet-policy.json" \
      --plan "$repo/.agent/active/plan_execplan.md" \
      --sow "$repo/.agent/active/sow/sow_fixture.md" \
      --ledger "$repo/.agent/active/sow/task-lineage-ledger.md" \
      --coder-prompt "$repo/.agent/active/prompts/coder_fixture.md" \
      --reviewer-prompt "$repo/.agent/active/prompts/reviewer_fixture.md" \
      --coder-output-stub "$repo/.agent/active/prompts/coder_fixture_output.md" \
      --reviewer-output-stub "$repo/.agent/active/prompts/reviewer_fixture_output.md" \
      --baseline-freeze "$repo/.agent/active/sow/baseline_freeze.txt" \
      --task-id task-fixture \
      --expected-accepted-slice slice-accepted \
      --expected-active-slice slice-wrong
  ) >/dev/null 2>&1; then
    fail "ledger mismatch should fail"
  fi
}

test_invalid_required_check_fails() {
  local repo="$TMP_ROOT/invalid_required_check"
  local tmp_plan=""

  setup_fake_repo "$repo"
  run_compile "$repo"
  tmp_plan="$(mktemp "${TMPDIR:-/tmp}/invalid-required-check.XXXXXX")"
  awk '
    BEGIN {
      replaced = 0
    }
    !replaced && $0 == "- git diff --check" {
      print "- echo ok; true"
      replaced = 1
      next
    }
    {
      print
    }
  ' "$repo/.agent/active/plan_execplan.md" > "$tmp_plan"
  mv "$tmp_plan" "$repo/.agent/active/plan_execplan.md"

  if run_validate "$repo" >/dev/null 2>&1; then
    fail "invalid required check should fail"
  fi
}

test_source_digest_drift_fails() {
  local repo="$TMP_ROOT/source_drift"

  setup_fake_repo "$repo"
  run_compile "$repo"
  printf '\ndrift\n' >> "$repo/AGENTS.md"

  if run_validate "$repo" >/dev/null 2>&1; then
    fail "source digest drift should fail"
  fi
}

test_tampered_bundle_projection_fails() {
  local repo="$TMP_ROOT/tampered_bundle_projection"
  local tmp_bundle=""
  local bundle_id=""

  setup_fake_repo "$repo"
  run_compile "$repo"
  tmp_bundle="$(mktemp "${TMPDIR:-/tmp}/tampered-bundle.XXXXXX")"
  jq '.projection.deprecated_field_aliases = []' \
    "$repo/.claude/packet-policy.json" > "$tmp_bundle"

  (
    cd "$repo"
    # shellcheck disable=SC1090
    source "$repo/.claude/commands/lib/orchestration_policy.sh"
    bundle_id="$(orchestration_policy_compute_bundle_id_from_file "$tmp_bundle")"
    jq --arg bundle_id "$bundle_id" '.bundle_id = $bundle_id' "$tmp_bundle" > "$repo/.claude/packet-policy.json"
  )
  /bin/rm -f "$tmp_bundle"

  if run_validate "$repo" >/dev/null 2>&1; then
    fail "tampered bundle projection should fail"
  fi
}

test_unstable_manifest_compile_fails() {
  local repo="$TMP_ROOT/unstable_manifest"
  local tmp_manifest=""

  setup_fake_repo "$repo"
  tmp_manifest="$(mktemp "${TMPDIR:-/tmp}/unstable-manifest.XXXXXX")"
  jq '.[0].stable = false' "$repo/.agent/registry/policy_sources.json" > "$tmp_manifest"
  mv "$tmp_manifest" "$repo/.agent/registry/policy_sources.json"

  if (
    cd "$repo"
    bash "$repo/scripts/validate-orchestration-packet.sh" compile \
      --output "$repo/.claude/packet-policy.json" \
      --manifest .agent/registry/policy_sources.json
  ) >/dev/null 2>&1; then
    fail "unstable manifest should fail compile"
  fi
}

test_invalid_projection_source_compile_fails() {
  local repo="$TMP_ROOT/invalid_projection_source"
  local tmp_projection=""

  setup_fake_repo "$repo"
  tmp_projection="$(mktemp "${TMPDIR:-/tmp}/invalid-projection-source.XXXXXX")"
  jq 'del(.reviewer_contract.accepted_review_verdicts)' "$repo/.agent/registry/orchestration_policy_projection.json" > "$tmp_projection"
  mv "$tmp_projection" "$repo/.agent/registry/orchestration_policy_projection.json"

  if (
    cd "$repo"
    bash "$repo/scripts/validate-orchestration-packet.sh" compile \
      --output "$repo/.claude/packet-policy.json" \
      --manifest .agent/registry/policy_sources.json
  ) >/dev/null 2>&1; then
    fail "invalid projection source should fail compile"
  fi
}

test_noncanonical_review_verdicts_compile_fails() {
  local repo="$TMP_ROOT/noncanonical_review_verdicts"
  local tmp_projection=""

  setup_fake_repo "$repo"
  tmp_projection="$(mktemp "${TMPDIR:-/tmp}/noncanonical-review-verdicts.XXXXXX")"
  jq '.reviewer_contract.accepted_review_verdicts = ["LGTM", "BLOCK", "FOLLOWUP", "Needs verification", "Needs Discussion"]
      | .reviewer_contract.verdict_outgoing_next_status = {
          "LGTM": "pending acceptance",
          "BLOCK": "blocked",
          "FOLLOWUP": "pending review",
          "Needs verification": "pending verification",
          "Needs Discussion": "blocked"
        }' \
    "$repo/.agent/registry/orchestration_policy_projection.json" > "$tmp_projection"
  mv "$tmp_projection" "$repo/.agent/registry/orchestration_policy_projection.json"

  if (
    cd "$repo"
    bash "$repo/scripts/validate-orchestration-packet.sh" compile \
      --output "$repo/.claude/packet-policy.json" \
      --manifest .agent/registry/policy_sources.json
  ) >/dev/null 2>&1; then
    fail "noncanonical review verdicts should fail compile"
  fi
}

test_external_projection_override_compile_fails() {
  local repo="$TMP_ROOT/external_projection_override"
  local external_projection=""

  setup_fake_repo "$repo"
  external_projection="$(mktemp "${TMPDIR:-/tmp}/external-projection.XXXXXX")"
  /bin/cp "$repo/.agent/registry/orchestration_policy_projection.json" "$external_projection"

  if (
    cd "$repo"
    ORCHESTRATION_POLICY_PROJECTION_PATH="$external_projection" \
      bash "$repo/scripts/validate-orchestration-packet.sh" compile \
        --output "$repo/.claude/packet-policy.json" \
        --manifest .agent/registry/policy_sources.json
  ) >/dev/null 2>&1; then
    fail "external projection override should fail compile without explicit allow flag"
  fi

  /bin/rm -f "$external_projection"
}

test_external_manifest_compile_fails() {
  local repo="$TMP_ROOT/external_manifest"
  local external_manifest=""

  setup_fake_repo "$repo"
  external_manifest="$(mktemp "${TMPDIR:-/tmp}/external-manifest.XXXXXX")"
  /bin/cp "$repo/.agent/registry/policy_sources.json" "$external_manifest"

  if (
    cd "$repo"
    bash "$repo/scripts/validate-orchestration-packet.sh" compile \
      --output "$repo/.claude/packet-policy.json" \
      --manifest "$external_manifest"
  ) >/dev/null 2>&1; then
    fail "external manifest path should fail compile"
  fi

  /bin/rm -f "$external_manifest"
}

test_projection_source_missing_from_manifest_compile_fails() {
  local repo="$TMP_ROOT/missing_projection_source_manifest"
  local tmp_manifest=""

  setup_fake_repo "$repo"
  tmp_manifest="$(mktemp "${TMPDIR:-/tmp}/missing-projection-source-manifest.XXXXXX")"
  jq '[.[] | select(.path != ".agent/registry/orchestration_policy_projection.json")]' \
    "$repo/.agent/registry/policy_sources.json" > "$tmp_manifest"
  mv "$tmp_manifest" "$repo/.agent/registry/policy_sources.json"

  if (
    cd "$repo"
    bash "$repo/scripts/validate-orchestration-packet.sh" compile \
      --output "$repo/.claude/packet-policy.json" \
      --manifest .agent/registry/policy_sources.json
  ) >/dev/null 2>&1; then
    fail "manifest missing projection source should fail compile"
  fi
}

test_repo_escape_manifest_compile_fails() {
  local repo="$TMP_ROOT/repo_escape_manifest"
  local tmp_manifest=""

  setup_fake_repo "$repo"
  printf 'outside\n' > "$TMP_ROOT/outside.md"
  tmp_manifest="$(mktemp "${TMPDIR:-/tmp}/repo-escape-manifest.XXXXXX")"
  jq '. + [{
      "path": "../outside.md",
      "authority_type": "runtime_policy",
      "governs": ["outside"],
      "stable": true,
      "required_checks_surface": ["git diff --check"]
    }]' "$repo/.agent/registry/policy_sources.json" > "$tmp_manifest"
  mv "$tmp_manifest" "$repo/.agent/registry/policy_sources.json"

  if (
    cd "$repo"
    bash "$repo/scripts/validate-orchestration-packet.sh" compile \
      --output "$repo/.claude/packet-policy.json" \
      --manifest .agent/registry/policy_sources.json
  ) >/dev/null 2>&1; then
    fail "repo-escape manifest path should fail compile"
  fi
}

test_volatile_manifest_compile_fails() {
  local repo="$TMP_ROOT/volatile_manifest"
  local tmp_manifest=""

  setup_fake_repo "$repo"
  printf 'volatile\n' > "$repo/.agent/active/volatile.md"
  tmp_manifest="$(mktemp "${TMPDIR:-/tmp}/volatile-manifest.XXXXXX")"
  jq '. + [{
      "path": ".agent/active/volatile.md",
      "authority_type": "runtime_policy",
      "governs": ["volatile"],
      "stable": true,
      "required_checks_surface": ["git diff --check"]
    }]' "$repo/.agent/registry/policy_sources.json" > "$tmp_manifest"
  mv "$tmp_manifest" "$repo/.agent/registry/policy_sources.json"

  if (
    cd "$repo"
    bash "$repo/scripts/validate-orchestration-packet.sh" compile \
      --output "$repo/.claude/packet-policy.json" \
      --manifest .agent/registry/policy_sources.json
  ) >/dev/null 2>&1; then
    fail "volatile manifest path should fail compile"
  fi
}

main() {
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchestration-packet-validator.XXXXXX")"

  if [[ "${ORCHESTRATION_PACKET_VALIDATOR_TIMEOUT_PROBE:-0}" == "1" ]]; then
    run_timeout_probe
    return 0
  fi

  run_test_case test_success_case
  run_test_case test_missing_baseline_fails
  run_test_case test_missing_reviewer_stub_fails
  run_test_case test_deprecated_alias_fails
  run_test_case test_deprecated_alias_numbered_list_fails
  run_test_case test_deprecated_alias_prose_allowed
  run_test_case test_deprecated_alias_backticked_key_fails
  run_test_case test_ledger_mismatch_fails
  run_test_case test_invalid_required_check_fails
  run_test_case test_source_digest_drift_fails
  run_test_case test_tampered_bundle_projection_fails
  run_test_case test_invalid_projection_source_compile_fails
  run_test_case test_unstable_manifest_compile_fails
  run_test_case test_repo_escape_manifest_compile_fails
  run_test_case test_volatile_manifest_compile_fails

  printf 'PASS: orchestration_packet_validator_test\n'
}

main "$@"
