#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEASE_GUARD="$PROJECT_ROOT/scripts/rev-harness-lease-guard.sh"
TMP_ROOT=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  /bin/rm -rf "${TMP_ROOT:-}" 2>/dev/null || true
}
trap cleanup EXIT

write_file() {
  local path="$1"
  shift
  printf '%s\n' "$*" > "$path"
}

assert_packet_pass() {
  local packet="$1"

  jq -e '
    .schema_version == "rev-harness-cross-family-artifact-packet/v1"
    and .coordination_mode == "artifact-only"
    and .direct_long_lived_chat == false
    and (.workers | length) == 2
    and any(.workers[]; .provider == "codex" and .role == "coder" and .status == "completed")
    and any(.workers[]; .provider == "claude" and .model == "opus" and .role == "reviewer" and .verdict == "LGTM")
    and .orchestrator.acceptance == "PASS"
    and (.required_checks | index("lease_guard_validate"))
    and (.required_checks | index("artifact_packet_schema"))
  ' "$packet" >/dev/null || fail "artifact packet did not satisfy cross-family contract"

  jq -r '
    [.workers[].artifact_path, .orchestrator.artifact_path] | .[]
  ' "$packet" | while IFS= read -r artifact_rel; do
    [[ -n "$artifact_rel" ]] || fail "packet contains an empty artifact path"
    case "$artifact_rel" in
      .claude/tmp/cross-family-smoke/*) ;;
      *) fail "packet artifact path is outside orchestration artifact root: $artifact_rel" ;;
    esac
    [[ -f "$TMP_ROOT/repo/$artifact_rel" && ! -L "$TMP_ROOT/repo/$artifact_rel" ]] \
      || fail "packet artifact is missing or unsafe: $artifact_rel"
  done
}

assert_packet_block() {
  local packet="$1"

  if jq -e '
    .schema_version == "rev-harness-cross-family-artifact-packet/v1"
    and .coordination_mode == "artifact-only"
    and .direct_long_lived_chat == false
    and .orchestrator.acceptance == "PASS"
  ' "$packet" >/dev/null; then
    fail "unsafe artifact packet unexpectedly passed"
  fi
}

assert_lease_guard_pass() {
  local registry="$1"
  local output=""

  if ! output="$(bash "$LEASE_GUARD" validate --repo-root "$TMP_ROOT/repo" --file "$registry" --json 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "expected closed cross-family leases to pass"
  fi
  printf '%s\n' "$output" | jq -e '
    .schema_version == "rev-harness-lease-guard/v1"
    and .status == "PASS"
    and .completion_allowed == true
    and (.violations | length) == 0
  ' >/dev/null || fail "lease guard pass JSON did not match contract"
}

assert_lease_guard_block() {
  local registry="$1"
  local output=""

  if output="$(bash "$LEASE_GUARD" validate --repo-root "$TMP_ROOT/repo" --file "$registry" --json 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "expected unsafe cross-family leases to block"
  fi
  printf '%s\n' "$output" | jq -e '
    .schema_version == "rev-harness-lease-guard/v1"
    and .status == "BLOCK"
    and .completion_allowed == false
    and (.violations | length) > 0
  ' >/dev/null || fail "lease guard block JSON did not match contract"
}

packet_leases_match() {
  local packet="$1"
  local registry="$2"

  jq -s -e '
    .[0] as $packet
    | .[1] as $registry
    | ($packet.workers | map({
        provider,
        model,
        artifact_path
      })) as $workers
    | ($registry.leases | map(select(.state == "completed") | {
        provider,
        model,
        artifact_paths
      })) as $completed_leases
    | all($workers[]; . as $worker |
        any($completed_leases[]; . as $lease |
          $lease.provider == $worker.provider
          and ($lease.model // "") == ($worker.model // "")
          and (($lease.artifact_paths // []) | index($worker.artifact_path))
        )
      )
  ' "$packet" "$registry" >/dev/null
}

assert_packet_leases_match() {
  local packet="$1"
  local registry="$2"

  packet_leases_match "$packet" "$registry" \
    || fail "packet worker artifacts do not match completed lease artifacts"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cross-family-artifact-smoke.XXXXXX")"
artifact_root="$TMP_ROOT/repo/.claude/tmp/cross-family-smoke"
mkdir -p "$artifact_root"

write_file "$artifact_root/codex-worker.md" \
  '# Codex Worker Artifact' \
  '' \
  '- provider: codex' \
  '- role: coder' \
  '- result: completed' \
  '- required_check: artifact_packet_schema'

write_file "$artifact_root/opus-reviewer.md" \
  '# Opus Reviewer Artifact' \
  '' \
  '- provider: claude' \
  '- model: opus' \
  '- role: reviewer' \
  '- verdict: LGTM' \
  '- required_check: lease_guard_validate'

write_file "$artifact_root/orchestrator-acceptance.md" \
  '# Orchestrator Acceptance Packet' \
  '' \
  '- coordination_mode: artifact-only' \
  '- direct_long_lived_chat: false' \
  '- acceptance: PASS'

packet="$artifact_root/packet.json"
jq -n \
  --arg schema_version "rev-harness-cross-family-artifact-packet/v1" \
  --arg coordination_mode "artifact-only" \
  --argjson direct_long_lived_chat false \
  --arg codex_artifact ".claude/tmp/cross-family-smoke/codex-worker.md" \
  --arg opus_artifact ".claude/tmp/cross-family-smoke/opus-reviewer.md" \
  --arg orchestrator_artifact ".claude/tmp/cross-family-smoke/orchestrator-acceptance.md" \
  '{
    schema_version: $schema_version,
    coordination_mode: $coordination_mode,
    direct_long_lived_chat: $direct_long_lived_chat,
    workers: [
      {
        provider: "codex",
        model: "gpt-5.5",
        role: "coder",
        status: "completed",
        artifact_path: $codex_artifact
      },
      {
        provider: "claude",
        model: "opus",
        role: "reviewer",
        verdict: "LGTM",
        artifact_path: $opus_artifact
      }
    ],
    orchestrator: {
      artifact_path: $orchestrator_artifact,
      acceptance: "PASS"
    },
    required_checks: [
      "artifact_packet_schema",
      "lease_guard_validate"
    ]
  }' > "$packet"

registry="$artifact_root/agent-leases.json"
jq -n \
  '{
    schema_version: "rev-harness-agent-lease-registry/v1",
    leases: [
      {
        lease_id: "cross-family-codex-coder",
        provider: "codex",
        model: "gpt-5.5",
        purpose: "artifact-only cross-family smoke coder",
        state: "completed",
        artifact_paths: [".claude/tmp/cross-family-smoke/codex-worker.md"]
      },
      {
        lease_id: "cross-family-opus-reviewer",
        provider: "claude",
        model: "opus",
        purpose: "artifact-only cross-family smoke reviewer",
        state: "completed",
        artifact_paths: [".claude/tmp/cross-family-smoke/opus-reviewer.md"]
      }
    ]
  }' > "$registry"

assert_packet_pass "$packet"
assert_packet_leases_match "$packet" "$registry"
assert_lease_guard_pass "$registry"

unsafe_packet="$artifact_root/unsafe-direct-chat-packet.json"
jq '.direct_long_lived_chat = true' "$packet" > "$unsafe_packet"
assert_packet_block "$unsafe_packet"

running_registry="$artifact_root/running-lease.json"
jq '.leases[1].state = "running"' "$registry" > "$running_registry"
assert_lease_guard_block "$running_registry"

missing_artifact_registry="$artifact_root/missing-artifact-lease.json"
jq '.leases[0].artifact_paths = [".claude/tmp/cross-family-smoke/missing.md"]' "$registry" > "$missing_artifact_registry"
assert_lease_guard_block "$missing_artifact_registry"

missing_packet_lease_registry="$artifact_root/missing-packet-lease.json"
jq 'del(.leases[] | select(.lease_id == "cross-family-opus-reviewer"))' "$registry" > "$missing_packet_lease_registry"
if packet_leases_match "$packet" "$missing_packet_lease_registry" 2>/dev/null; then
  fail "packet-to-lease matching unexpectedly passed with missing Opus lease"
fi

printf 'PASS: cross_family_artifact_smoke_test\n'
