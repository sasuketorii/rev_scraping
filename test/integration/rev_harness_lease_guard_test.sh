#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$PROJECT_ROOT/scripts/rev-harness-lease-guard.sh"
TMP_ROOT=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  /bin/rm -rf "${TMP_ROOT:-}" 2>/dev/null || true
}
trap cleanup EXIT

write_json() {
  local path="$1"
  shift
  printf '%s\n' "$*" > "$path"
}

assert_pass() {
  local output=""
  if ! output="$(bash "$GUARD" validate --repo-root "$TMP_ROOT/repo" --file "$1" --json 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "expected PASS for $1"
  fi
  printf '%s\n' "$output"
}

assert_block() {
  local output=""
  if output="$(bash "$GUARD" validate --repo-root "$TMP_ROOT/repo" --file "$1" --json 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "expected BLOCK for $1"
  fi
  printf '%s\n' "$output"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-lease-guard-test.XXXXXX")"
mkdir -p "$TMP_ROOT/repo/.claude/tmp/task"
printf 'artifact\n' > "$TMP_ROOT/repo/.claude/tmp/task/review.md"
printf 'blocked artifact\n' > "$TMP_ROOT/repo/.claude/tmp/task/block.md"

good="$TMP_ROOT/good.json"
write_json "$good" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-codex-review",
      "provider": "codex",
      "state": "completed",
      "artifact_paths": [".claude/tmp/task/review.md"]
    },
    {
      "lease_id": "lease-claude-blocked",
      "provider": "claude",
      "state": "blocked",
      "artifact_paths": [".claude/tmp/task/block.md"]
    }
  ]
}'
good_output="$(assert_pass "$good")"
printf '%s\n' "$good_output" | jq -e '.status == "PASS" and .completion_allowed == true' >/dev/null \
  || fail "closed leases should pass"

running="$TMP_ROOT/running.json"
write_json "$running" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-running",
      "provider": "codex",
      "state": "running",
      "artifact_paths": [".claude/tmp/task/review.md"]
    }
  ]
}'
running_output="$(assert_block "$running")"
printf '%s\n' "$running_output" | jq -e '.status == "BLOCK" and .completion_allowed == false and any(.violations[]; contains("not closed"))' >/dev/null \
  || fail "running lease should block"

failed="$TMP_ROOT/failed.json"
write_json "$failed" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-failed",
      "provider": "claude",
      "state": "failed",
      "artifact_paths": [".claude/tmp/task/review.md"]
    }
  ]
}'
assert_block "$failed" | jq -e 'any(.violations[]; contains("not closed"))' >/dev/null \
  || fail "failed lease should block"

missing_artifact="$TMP_ROOT/missing-artifact.json"
write_json "$missing_artifact" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-missing",
      "provider": "codex",
      "state": "completed",
      "artifact_paths": [".claude/tmp/task/missing.md"]
    }
  ]
}'
assert_block "$missing_artifact" | jq -e 'any(.violations[]; contains("artifact is missing or unsafe"))' >/dev/null \
  || fail "missing artifact should block"

printf 'numeric artifact\n' > "$TMP_ROOT/repo/123"
numeric_artifact="$TMP_ROOT/numeric-artifact.json"
write_json "$numeric_artifact" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-numeric-artifact",
      "provider": "codex",
      "state": "completed",
      "artifact_paths": [123]
    }
  ]
}'
assert_block "$numeric_artifact" | jq -e 'any(.violations[]; contains("artifact paths must be non-empty strings"))' >/dev/null \
  || fail "numeric artifact path should block"

boolean_artifact="$TMP_ROOT/boolean-artifact.json"
write_json "$boolean_artifact" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-boolean-artifact",
      "provider": "codex",
      "state": "completed",
      "artifact_paths": [true]
    }
  ]
}'
assert_block "$boolean_artifact" | jq -e 'any(.violations[]; contains("artifact paths must be non-empty strings"))' >/dev/null \
  || fail "boolean artifact path should block"

null_artifact="$TMP_ROOT/null-artifact.json"
write_json "$null_artifact" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-null-artifact",
      "provider": "codex",
      "state": "completed",
      "artifact_paths": [null]
    }
  ]
}'
assert_block "$null_artifact" | jq -e 'any(.violations[]; contains("artifact paths must be non-empty strings"))' >/dev/null \
  || fail "null artifact path should block"

object_artifact="$TMP_ROOT/object-artifact.json"
write_json "$object_artifact" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-object-artifact",
      "provider": "codex",
      "state": "completed",
      "artifact_paths": [{}]
    }
  ]
}'
assert_block "$object_artifact" | jq -e 'any(.violations[]; contains("artifact paths must be non-empty strings"))' >/dev/null \
  || fail "object artifact path should block"

numeric_lease_id="$TMP_ROOT/numeric-lease-id.json"
write_json "$numeric_lease_id" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": 123,
      "provider": "codex",
      "state": "completed",
      "artifact_paths": [".claude/tmp/task/review.md"]
    }
  ]
}'
assert_block "$numeric_lease_id" | jq -e 'any(.violations[]; contains("missing lease_id"))' >/dev/null \
  || fail "numeric lease_id should block"

numeric_provider="$TMP_ROOT/numeric-provider.json"
write_json "$numeric_provider" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-numeric-provider",
      "provider": 123,
      "state": "completed",
      "artifact_paths": [".claude/tmp/task/review.md"]
    }
  ]
}'
assert_block "$numeric_provider" | jq -e 'any(.violations[]; contains("provider must be a non-empty string"))' >/dev/null \
  || fail "numeric provider should block"

numeric_state="$TMP_ROOT/numeric-state.json"
write_json "$numeric_state" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-numeric-state",
      "provider": "codex",
      "state": 123,
      "artifact_paths": [".claude/tmp/task/review.md"]
    }
  ]
}'
assert_block "$numeric_state" | jq -e 'any(.violations[]; contains("state must be a non-empty string"))' >/dev/null \
  || fail "numeric state should block"

unknown_state="$TMP_ROOT/unknown-state.json"
write_json "$unknown_state" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-unknown",
      "provider": "codex",
      "state": "done",
      "artifact_paths": [".claude/tmp/task/review.md"]
    }
  ]
}'
assert_block "$unknown_state" | jq -e 'any(.violations[]; contains("unknown state"))' >/dev/null \
  || fail "unknown state should block"

escape="$TMP_ROOT/escape.json"
write_json "$escape" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-escape",
      "provider": "codex",
      "state": "completed",
      "artifact_paths": ["../outside.md"]
    }
  ]
}'
assert_block "$escape" | jq -e 'any(.violations[]; contains("artifact is missing or unsafe"))' >/dev/null \
  || fail "path escape should block"

printf 'rev_harness_lease_guard_test: PASS\n'
