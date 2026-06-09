#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$PROJECT_ROOT/scripts/rev-harness-worker-lifecycle.sh"
TMP_PARENT="$PROJECT_ROOT/.tmp-rev-harness-worker-lifecycle-test"
mkdir -p "$TMP_PARENT"
TMP_ROOT="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$TMP_ROOT"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]]
}

setup_fixture() {
  local root="$1"

  mkdir -p "$root/evidence"
  printf 'closed worker evidence\n' >"$root/evidence/worker-closed.md"
  printf 'active worker evidence\n' >"$root/evidence/worker-active.md"
  printf 'blocked worker evidence\n' >"$root/evidence/worker-block.md"

  jq -n '{
    schema_version: "rev-harness-worker-lifecycle/v1",
    workers: [
      {
        id: "worker-closed",
        state: "closed",
        spawned_at: "2026-04-30T00:00:00Z",
        completed_at: "2026-04-30T00:05:00Z",
        closed_at: "2026-04-30T00:06:00Z",
        artifact_paths: ["evidence/worker-closed.md"],
        runtime_observation: "not-observed"
      },
      {
        id: "worker-active-retained",
        state: "active",
        spawned_at: "2026-04-30T00:01:00Z",
        retain_reason: "intentionally retained for orchestrator follow-up; runtime state not observed",
        artifact_paths: ["evidence/worker-active.md"],
        runtime_observation: {observed: false, reason: "not observed by manifest validator"}
      },
      {
        id: "worker-blocked",
        state: "BLOCK",
        spawned_at: "2026-04-30T00:02:00Z",
        block_reason: "required evidence unavailable",
        retain_reason: "kept as non-acceptance evidence",
        artifact_paths: ["evidence/worker-block.md"],
        runtime_observation: "not-observed"
      }
    ]
  }' >"$root/lifecycle.json"
}

run_checker() {
  local root="$1"
  shift

  REV_HARNESS_WORKER_LIFECYCLE_PROJECT_ROOT="$root" bash "$CHECKER" "$@"
}

assert_json_field() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual=""

  actual="$(printf '%s\n' "$json" | jq -r "$filter")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected, got $actual"
}

assert_fails_with() {
  local name="$1"
  local root="$2"
  local needle="$3"
  shift 3
  local stdout_file="$TMP_ROOT/$name.out"
  local stderr_file="$TMP_ROOT/$name.err"

  if run_checker "$root" "$@" >"$stdout_file" 2>"$stderr_file"; then
    fail "$name should fail"
  fi
  contains "$(cat "$stderr_file")" "$needle" || fail "$name failure should contain: $needle"
}

test_valid_lifecycle_passes_and_reports_non_observation() {
  local root="$TMP_ROOT/pass"
  local output=""
  setup_fixture "$root"

  output="$(run_checker "$root" validate --manifest lifecycle.json --json)"

  assert_json_field "$output" '.schema_version' "rev-harness-worker-lifecycle/v1"
  assert_json_field "$output" '.status' "PASS"
  assert_json_field "$output" '.worker_count' "3"
  assert_json_field "$output" '.runtime_state_observed' "false"
  assert_json_field "$output" '.failures | length' "0"
}

test_active_worker_without_retain_reason_fails_closed() {
  local root="$TMP_ROOT/active-missing-retain"
  setup_fixture "$root"
  jq 'del(.workers[1].retain_reason)' "$root/lifecycle.json" >"$root/lifecycle.tmp"
  mv "$root/lifecycle.tmp" "$root/lifecycle.json"

  assert_fails_with "active-missing-retain" "$root" "active retained worker requires retain_reason" validate --manifest lifecycle.json
}

test_closed_worker_without_closeout_timestamps_fails_closed() {
  local root="$TMP_ROOT/closed-missing-closeout"
  setup_fixture "$root"
  jq 'del(.workers[0].completed_at, .workers[0].closed_at)' "$root/lifecycle.json" >"$root/lifecycle.tmp"
  mv "$root/lifecycle.tmp" "$root/lifecycle.json"

  assert_fails_with "closed-missing-closeout" "$root" "closed worker requires completed_at" validate --manifest lifecycle.json
}

test_successor_link_requires_successor_id() {
  local root="$TMP_ROOT/successor-missing"
  setup_fixture "$root"
  jq '.workers[0].state = "successor-linked" | del(.workers[0].closed_at)' "$root/lifecycle.json" >"$root/lifecycle.tmp"
  mv "$root/lifecycle.tmp" "$root/lifecycle.json"

  assert_fails_with "successor-missing" "$root" "successor-linked worker requires successor_worker_id" validate --manifest lifecycle.json
}

test_runtime_thread_claim_fails_closed() {
  local root="$TMP_ROOT/runtime-claim"
  setup_fixture "$root"
  jq '.workers[1].thread_alive = true' "$root/lifecycle.json" >"$root/lifecycle.tmp"
  mv "$root/lifecycle.tmp" "$root/lifecycle.json"

  assert_fails_with "runtime-claim" "$root" "must not claim live runtime thread/process state" validate --manifest lifecycle.json
}

test_missing_artifact_path_fails_closed() {
  local root="$TMP_ROOT/missing-artifact"
  setup_fixture "$root"
  /bin/rm -f "$root/evidence/worker-active.md"

  assert_fails_with "missing-artifact" "$root" "missing artifact path" validate --manifest lifecycle.json
}

test_non_string_artifact_path_fails_closed_before_path_resolution() {
  local root="$TMP_ROOT/non-string-artifact"
  setup_fixture "$root"
  printf 'numeric filename evidence\n' >"$root/123"
  jq '.workers[0].artifact_paths = [123]' "$root/lifecycle.json" >"$root/lifecycle.tmp"
  mv "$root/lifecycle.tmp" "$root/lifecycle.json"

  assert_fails_with "non-string-artifact" "$root" "artifact path must be string" validate --manifest lifecycle.json
}

test_artifact_path_symlink_parent_escape_fails_closed() {
  local root="$TMP_ROOT/symlink-parent"
  local outside="$TMP_ROOT/outside-worker-artifacts"

  setup_fixture "$root"
  mkdir -p "$outside"
  printf 'escaped worker evidence\n' >"$outside/worker-active.md"
  rm -rf "$root/evidence"
  ln -s "$outside" "$root/evidence"

  assert_fails_with "symlink-parent" "$root" "symlink/realpath escape" validate --manifest lifecycle.json
}

test_deferred_worker_requires_reason_and_retain_reason() {
  local root="$TMP_ROOT/deferred-missing"
  setup_fixture "$root"
  jq '.workers[2].state = "deferred" | del(.workers[2].block_reason, .workers[2].retain_reason)' "$root/lifecycle.json" >"$root/lifecycle.tmp"
  mv "$root/lifecycle.tmp" "$root/lifecycle.json"

  assert_fails_with "deferred-missing" "$root" "deferred worker requires deferred_reason" validate --manifest lifecycle.json
}

test_valid_lifecycle_passes_and_reports_non_observation
test_active_worker_without_retain_reason_fails_closed
test_closed_worker_without_closeout_timestamps_fails_closed
test_successor_link_requires_successor_id
test_runtime_thread_claim_fails_closed
test_missing_artifact_path_fails_closed
test_non_string_artifact_path_fails_closed_before_path_resolution
test_artifact_path_symlink_parent_escape_fails_closed
test_deferred_worker_requires_reason_and_retain_reason

printf 'PASS: rev_harness_worker_lifecycle_test\n'
