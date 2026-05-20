#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$PROJECT_ROOT/scripts/rev-harness-lease-guard.sh"
RUST_MANIFEST="$PROJECT_ROOT/harness-rust/Cargo.toml"
RUST_BIN="$PROJECT_ROOT/harness-rust/target/debug/agent-core"
BASELINE_COMMIT="8cb8c1e2f9d5f4da3fd4c46523110a1615daaee7"
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

run_capture() {
  local out_file="$1"
  shift
  set +e
  "$@" >"$out_file" 2>&1
  local status=$?
  return "$status"
}

assert_json_equal() {
  local left="$1"
  local right="$2"
  diff -u <(jq -S . "$left") <(jq -S . "$right") >/dev/null \
    || fail "JSON mismatch: $left vs $right"
}

assert_case_parity() {
  local name="$1"
  local manifest="$2"
  local old_out="$TMP_ROOT/out/$name.old.json"
  local rust_out="$TMP_ROOT/out/$name.rust.json"
  local adapter_out="$TMP_ROOT/out/$name.adapter.json"

  set +e
  run_capture "$old_out" bash "$TMP_ROOT/old-lease-guard.sh" validate --repo-root "$TMP_ROOT/repo" --file "$manifest" --json
  local old_status=$?
  run_capture "$rust_out" "$RUST_BIN" lease validate --repo-root "$TMP_ROOT/repo" --file "$manifest" --json
  local rust_status=$?
  run_capture "$adapter_out" env \
    REV_HARNESS_LEASE_GUARD_RUST_BIN="$RUST_BIN" \
    REV_HARNESS_LEASE_GUARD_PARITY_ORACLE_BIN="$TMP_ROOT/old-lease-guard.sh" \
    bash "$GUARD" validate --repo-root "$TMP_ROOT/repo" --file "$manifest" --json
  local adapter_status=$?
  set -e

  [[ "$old_status" -eq "$rust_status" ]] || fail "$name Rust exit mismatch: old=$old_status rust=$rust_status"
  [[ "$old_status" -eq "$adapter_status" ]] || fail "$name adapter exit mismatch: old=$old_status adapter=$adapter_status"
  assert_json_equal "$old_out" "$rust_out"
  assert_json_equal "$old_out" "$adapter_out"
}

assert_adapter_blocks_with_stub() {
  local name="$1"
  local stub="$2"
  local manifest="$3"
  local out="$TMP_ROOT/out/$name.stub.json"

  if env \
    REV_HARNESS_LEASE_GUARD_RUST_BIN="$stub" \
    REV_HARNESS_LEASE_GUARD_PARITY_ORACLE_BIN="$TMP_ROOT/old-lease-guard.sh" \
    bash "$GUARD" validate --repo-root "$TMP_ROOT/repo" --file "$manifest" --json >"$out" 2>&1; then
    cat "$out" >&2
    fail "$name should block"
  fi
  jq -e '.status == "BLOCK" and .completion_allowed == false' "$out" >/dev/null \
    || fail "$name should emit BLOCK JSON"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-lease-guard-parity.XXXXXX")"
mkdir -p "$TMP_ROOT/repo/.claude/tmp/task" "$TMP_ROOT/out" "$TMP_ROOT/stubs"
printf 'artifact\n' > "$TMP_ROOT/repo/.claude/tmp/task/review.md"
printf 'blocked artifact\n' > "$TMP_ROOT/repo/.claude/tmp/task/block.md"
printf 'outside\n' > "$TMP_ROOT/outside.md"
ln -s "$TMP_ROOT/repo/.claude/tmp/task/review.md" "$TMP_ROOT/repo/.claude/tmp/task/link.md"

git -C "$PROJECT_ROOT" show "$BASELINE_COMMIT:scripts/rev-harness-lease-guard.sh" >"$TMP_ROOT/old-lease-guard.sh"
chmod +x "$TMP_ROOT/old-lease-guard.sh"

cargo build --quiet --manifest-path "$RUST_MANIFEST" -p agent-core
[[ -x "$RUST_BIN" ]] || fail "agent-core binary missing after cargo build"

good="$TMP_ROOT/good.json"
write_json "$good" '{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {"lease_id":"lease-codex-review","provider":"codex","state":"completed","artifact_paths":[".claude/tmp/task/review.md"]},
    {"lease_id":"lease-claude-blocked","provider":"claude","state":"blocked","artifact_paths":[".claude/tmp/task/block.md"]}
  ]
}'

malformed="$TMP_ROOT/malformed.json"
printf '{not json\n' > "$malformed"

invalid_schema="$TMP_ROOT/invalid-schema.json"
write_json "$invalid_schema" '{"schema_version":"wrong","leases":[]}'

empty_leases="$TMP_ROOT/empty-leases.json"
write_json "$empty_leases" '{"schema_version":"rev-harness-agent-lease-registry/v1","leases":[]}'

running="$TMP_ROOT/running.json"
write_json "$running" '{"schema_version":"rev-harness-agent-lease-registry/v1","leases":[{"lease_id":"lease-running","provider":"codex","state":"running","artifact_paths":[".claude/tmp/task/review.md"]}]}'

stale="$TMP_ROOT/stale.json"
write_json "$stale" '{"schema_version":"rev-harness-agent-lease-registry/v1","leases":[{"lease_id":"lease-stale","provider":"codex","state":"stale","artifact_paths":[".claude/tmp/task/review.md"]}]}'

failed="$TMP_ROOT/failed.json"
write_json "$failed" '{"schema_version":"rev-harness-agent-lease-registry/v1","leases":[{"lease_id":"lease-failed","provider":"claude","state":"failed","artifact_paths":[".claude/tmp/task/review.md"]}]}'

artifact_type="$TMP_ROOT/artifact-type.json"
write_json "$artifact_type" '{"schema_version":"rev-harness-agent-lease-registry/v1","leases":[{"lease_id":"lease-type","provider":"codex","state":"completed","artifact_paths":[123]}]}'

missing_artifact="$TMP_ROOT/missing-artifact.json"
write_json "$missing_artifact" '{"schema_version":"rev-harness-agent-lease-registry/v1","leases":[{"lease_id":"lease-missing","provider":"codex","state":"completed","artifact_paths":[".claude/tmp/task/missing.md"]}]}'

symlink_artifact="$TMP_ROOT/symlink-artifact.json"
write_json "$symlink_artifact" '{"schema_version":"rev-harness-agent-lease-registry/v1","leases":[{"lease_id":"lease-symlink","provider":"codex","state":"completed","artifact_paths":[".claude/tmp/task/link.md"]}]}'

repo_escape="$TMP_ROOT/repo-escape.json"
write_json "$repo_escape" '{"schema_version":"rev-harness-agent-lease-registry/v1","leases":[{"lease_id":"lease-escape","provider":"codex","state":"completed","artifact_paths":["../outside.md"]}]}'

assert_case_parity good "$good"
assert_case_parity malformed "$malformed"
assert_case_parity invalid-schema "$invalid_schema"
assert_case_parity empty-leases "$empty_leases"
assert_case_parity running "$running"
assert_case_parity stale "$stale"
assert_case_parity failed "$failed"
assert_case_parity artifact-type "$artifact_type"
assert_case_parity missing-artifact "$missing_artifact"
assert_case_parity symlink-artifact "$symlink_artifact"
assert_case_parity repo-escape "$repo_escape"

missing_bin="$TMP_ROOT/stubs/missing-agent-core"
assert_adapter_blocks_with_stub missing-rust-validator "$missing_bin" "$good"

execution_failure="$TMP_ROOT/stubs/execution-failure"
cat >"$execution_failure" <<'STUB'
#!/usr/bin/env bash
exit 42
STUB
chmod +x "$execution_failure"
assert_adapter_blocks_with_stub rust-execution-failure "$execution_failure" "$good"

invalid_json="$TMP_ROOT/stubs/invalid-json"
cat >"$invalid_json" <<'STUB'
#!/usr/bin/env bash
printf 'not json\n'
exit 0
STUB
chmod +x "$invalid_json"
assert_adapter_blocks_with_stub invalid-rust-json "$invalid_json" "$good"

invalid_schema="$TMP_ROOT/stubs/invalid-schema"
cat >"$invalid_schema" <<'STUB'
#!/usr/bin/env bash
printf '{"schema_version":"rev-harness-lease-guard/v1","status":"PASS","completion_allowed":true,"violations":[]}\n'
exit 0
STUB
chmod +x "$invalid_schema"
assert_adapter_blocks_with_stub invalid-rust-schema "$invalid_schema" "$good"

exit_json_mismatch="$TMP_ROOT/stubs/exit-json-mismatch"
cat >"$exit_json_mismatch" <<'STUB'
#!/usr/bin/env bash
printf '{"schema_version":"rev-harness-lease-guard/v1","status":"BLOCK","file":"x","repo_root":"y","completion_allowed":false,"violations":["blocked"]}\n'
exit 0
STUB
chmod +x "$exit_json_mismatch"
assert_adapter_blocks_with_stub rust-json-exit-mismatch "$exit_json_mismatch" "$good"

json_stream_bypass="$TMP_ROOT/stubs/json-stream-bypass"
cat >"$json_stream_bypass" <<'STUB'
#!/usr/bin/env bash
printf '{"schema_version":"rev-harness-lease-guard/v1","status":"PASS","completion_allowed":true,"violations":[]}\n'
printf '{"schema_version":"rev-harness-lease-guard/v1","status":"PASS","file":"x","repo_root":"y","completion_allowed":true,"violations":[]}\n'
exit 0
STUB
chmod +x "$json_stream_bypass"
assert_adapter_blocks_with_stub rust-json-stream-bypass "$json_stream_bypass" "$good"

mismatch="$TMP_ROOT/stubs/mismatch"
cat >"$mismatch" <<'STUB'
#!/usr/bin/env bash
printf '{"schema_version":"rev-harness-lease-guard/v1","status":"PASS","file":"","repo_root":"","completion_allowed":true,"violations":[]}\n'
exit 0
STUB
chmod +x "$mismatch"
assert_adapter_blocks_with_stub shell-rust-mismatch "$mismatch" "$running"

printf 'rev_harness_lease_guard_parity_test: PASS\n'
