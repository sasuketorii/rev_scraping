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

assert_pass() {
  local output=""
  if ! output="$(bash "$GUARD" "$@" --json 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "expected PASS: $*"
  fi
  printf '%s\n' "$output"
}

assert_block() {
  local output=""
  if output="$(bash "$GUARD" "$@" --json 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "expected BLOCK: $*"
  fi
  printf '%s\n' "$output"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-lease-lifecycle.XXXXXX")"
mkdir -p "$TMP_ROOT/repo/.claude/tmp/task"
registry="$TMP_ROOT/repo/.claude/tmp/task/leases.json"

open_output="$(assert_pass open \
  --repo-root "$TMP_ROOT/repo" \
  --file "$registry" \
  --lease-id "lease-codex-1" \
  --provider codex \
  --model gpt-5.5 \
  --purpose "focused lifecycle smoke" \
  --artifact ".claude/tmp/task/expected.md" \
  --now 2026-05-02T00:00:00Z)"
printf '%s\n' "$open_output" | jq -e '.schema_version == "rev-harness-lease-lifecycle/v1" and .action == "open" and .changed == true' >/dev/null \
  || fail "open should emit lifecycle PASS JSON"
jq -e '
  .schema_version == "rev-harness-agent-lease-registry/v1"
  and (.leases | length == 1)
  and .leases[0].lease_id == "lease-codex-1"
  and .leases[0].state == "running"
  and .leases[0].started_at == "2026-05-02T00:00:00Z"
  and .leases[0].last_heartbeat_at == "2026-05-02T00:00:00Z"
' "$registry" >/dev/null || fail "open should create a running lease"

assert_pass heartbeat \
  --repo-root "$TMP_ROOT/repo" \
  --file "$registry" \
  --lease-id "lease-codex-1" \
  --now 2026-05-02T00:05:00Z >/dev/null
jq -e '.leases[0].last_heartbeat_at == "2026-05-02T00:05:00Z" and .leases[0].state == "running"' "$registry" >/dev/null \
  || fail "heartbeat should update only running lease timestamp"

printf 'review artifact\n' > "$TMP_ROOT/repo/.claude/tmp/task/review.md"
assert_pass close \
  --repo-root "$TMP_ROOT/repo" \
  --file "$registry" \
  --lease-id "lease-codex-1" \
  --artifact ".claude/tmp/task/review.md" \
  --now 2026-05-02T00:10:00Z >/dev/null
jq -e '.leases[0].state == "completed" and .leases[0].completed_at == "2026-05-02T00:10:00Z" and .leases[0].artifact_paths == [".claude/tmp/task/review.md"]' "$registry" >/dev/null \
  || fail "close should complete lease with traceable artifact"

assert_pass validate --repo-root "$TMP_ROOT/repo" --file "$registry" >/dev/null

printf 'block artifact\n' > "$TMP_ROOT/repo/.claude/tmp/task/block.md"
assert_pass open \
  --repo-root "$TMP_ROOT/repo" \
  --file "$registry" \
  --lease-id "lease-claude-block" \
  --provider claude \
  --purpose "block smoke" \
  --artifact ".claude/tmp/task/block.md" \
  --now 2026-05-02T00:20:00Z >/dev/null
assert_pass block \
  --repo-root "$TMP_ROOT/repo" \
  --file "$registry" \
  --lease-id "lease-claude-block" \
  --artifact ".claude/tmp/task/block.md" \
  --now 2026-05-02T00:21:00Z >/dev/null
jq -e '.leases[] | select(.lease_id == "lease-claude-block") | .state == "blocked" and .blocked_at == "2026-05-02T00:21:00Z"' "$registry" >/dev/null \
  || fail "block should close lease as blocked"

printf 'reap artifact\n' > "$TMP_ROOT/repo/.claude/tmp/task/reap.md"
assert_pass open \
  --repo-root "$TMP_ROOT/repo" \
  --file "$registry" \
  --lease-id "lease-stale" \
  --provider codex \
  --purpose "reap smoke" \
  --artifact ".claude/tmp/task/reap.md" \
  --now 2026-05-02T00:00:00Z >/dev/null
reap_output="$(assert_pass reap \
  --repo-root "$TMP_ROOT/repo" \
  --file "$registry" \
  --stale-seconds 60 \
  --artifact ".claude/tmp/task/reap.md" \
  --now 2026-05-02T00:02:00Z)"
printf '%s\n' "$reap_output" | jq -e '.action == "reap" and .changed == true and (.lease_ids == ["lease-stale"])' >/dev/null \
  || fail "reap should report stale lease id"
jq -e '.leases[] | select(.lease_id == "lease-stale") | .state == "reaped" and .reaped_at == "2026-05-02T00:02:00Z"' "$registry" >/dev/null \
  || fail "reap should close stale running lease"
assert_pass validate --repo-root "$TMP_ROOT/repo" --file "$registry" >/dev/null

assert_block open \
  --repo-root "$TMP_ROOT/repo" \
  --file "$registry" \
  --lease-id "lease-escape" \
  --provider codex \
  --purpose "unsafe" \
  --artifact "../escape.md" >/dev/null

malformed="$TMP_ROOT/repo/.claude/tmp/task/malformed.json"
printf '{not json\n' > "$malformed"
assert_block heartbeat \
  --repo-root "$TMP_ROOT/repo" \
  --file "$malformed" \
  --lease-id "lease-any" >/dev/null

unsafe_existing="$TMP_ROOT/repo/.claude/tmp/task/unsafe-existing.json"
cat >"$unsafe_existing" <<'JSON'
{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-unsafe-existing",
      "provider": "codex",
      "state": "completed",
      "artifact_paths": ["../escape.md"]
    }
  ]
}
JSON
assert_block open \
  --repo-root "$TMP_ROOT/repo" \
  --file "$unsafe_existing" \
  --lease-id "lease-new" \
  --provider codex \
  --purpose "must not mutate unsafe existing registry" \
  --artifact ".claude/tmp/task/review.md" >/dev/null
jq -e '(.leases | length == 1) and .leases[0].lease_id == "lease-unsafe-existing"' "$unsafe_existing" >/dev/null \
  || fail "unsafe existing registry must not be mutated"

duplicate_existing="$TMP_ROOT/repo/.claude/tmp/task/duplicate-existing.json"
cat >"$duplicate_existing" <<'JSON'
{
  "schema_version": "rev-harness-agent-lease-registry/v1",
  "leases": [
    {
      "lease_id": "lease-dup",
      "provider": "codex",
      "state": "running",
      "artifact_paths": [".claude/tmp/task/review.md"]
    },
    {
      "lease_id": "lease-dup",
      "provider": "claude",
      "state": "running",
      "artifact_paths": [".claude/tmp/task/block.md"]
    }
  ]
}
JSON
assert_block heartbeat \
  --repo-root "$TMP_ROOT/repo" \
  --file "$duplicate_existing" \
  --lease-id "lease-dup" >/dev/null

symlink_registry="$TMP_ROOT/repo/.claude/tmp/task/symlink-registry.json"
target_registry="$TMP_ROOT/target-registry.json"
printf '{"schema_version":"rev-harness-agent-lease-registry/v1","leases":[]}\n' > "$target_registry"
ln -s "$target_registry" "$symlink_registry"
assert_block open \
  --repo-root "$TMP_ROOT/repo" \
  --file "$symlink_registry" \
  --lease-id "lease-symlink" \
  --provider codex \
  --purpose "symlink registry" \
  --artifact ".claude/tmp/task/review.md" >/dev/null
jq -e '.leases == []' "$target_registry" >/dev/null \
  || fail "symlink registry failure must not mutate target"

explicit_bin="$TMP_ROOT/stubs/explicit-agent-core"
hostile_cargo="$TMP_ROOT/stubs/hostile-cargo"
mkdir -p "$TMP_ROOT/stubs"
cat >"$explicit_bin" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "lease" && "${2:-}" == "validate" ]]; then
  printf '{"schema_version":"rev-harness-lease-guard/v1","status":"PASS","file":"stub","repo_root":"stub","completion_allowed":true,"violations":[]}\n'
  exit 0
fi
exit 2
STUB
chmod +x "$explicit_bin"
cat >"$hostile_cargo" <<'STUB'
#!/usr/bin/env bash
printf 'hostile cargo must not execute\n' >&2
exit 99
STUB
chmod +x "$hostile_cargo"
if ! env \
  REV_HARNESS_LEASE_GUARD_RUST_BIN="$explicit_bin" \
  REV_HARNESS_LEASE_GUARD_CARGO_BIN="$hostile_cargo" \
  bash "$GUARD" validate --repo-root "$TMP_ROOT/repo" --file "$registry" --json >/dev/null; then
  fail "explicit Rust binary should bypass cargo"
fi

build_once_bin="$TMP_ROOT/stubs/build-once-agent-core"
build_once_replacement_bin="$TMP_ROOT/stubs/build-once-agent-core.replacement"
build_once_cargo="$TMP_ROOT/stubs/build-once-cargo"
build_once_log="$TMP_ROOT/stubs/build-once-cargo.log"
cat >"$build_once_replacement_bin" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "lease" && "${3:-}" == "--help" ]]; then
  exit 0
fi
if [[ "$1" == "lease" && "$2" == "validate" ]]; then
  printf '{"schema_version":"rev-harness-lease-guard/v1","status":"PASS","file":"stub","repo_root":"stub","completion_allowed":true,"violations":[]}\n'
  exit 0
fi
exit 2
STUB
cat >"$build_once_cargo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BUILD_ONCE_LOG"
if [[ "$*" == *" run "* || "$1" == "run" ]]; then
  printf 'forbidden cargo subcommand executed\n' >&2
  exit 98
fi
cp "$BUILD_ONCE_REPLACEMENT_BIN" "$BUILD_ONCE_BIN"
chmod +x "$BUILD_ONCE_BIN"
touch -t 203001010000 "$BUILD_ONCE_BIN"
STUB
chmod +x "$build_once_cargo"
[[ ! -e "$build_once_bin" ]] || fail "build-once default binary should start missing"
if ! env \
  BUILD_ONCE_BIN="$build_once_bin" \
  BUILD_ONCE_LOG="$build_once_log" \
  BUILD_ONCE_REPLACEMENT_BIN="$build_once_replacement_bin" \
  REV_HARNESS_LEASE_GUARD_DEFAULT_RUST_BIN="$build_once_bin" \
  REV_HARNESS_LEASE_GUARD_CARGO_BIN="$build_once_cargo" \
  bash "$GUARD" validate --repo-root "$TMP_ROOT/repo" --file "$registry" --json >/dev/null; then
  fail "missing default binary should trigger cargo build then binary execution"
fi
if ! env \
  BUILD_ONCE_BIN="$build_once_bin" \
  BUILD_ONCE_LOG="$build_once_log" \
  BUILD_ONCE_REPLACEMENT_BIN="$build_once_replacement_bin" \
  REV_HARNESS_LEASE_GUARD_DEFAULT_RUST_BIN="$build_once_bin" \
  REV_HARNESS_LEASE_GUARD_CARGO_BIN="$build_once_cargo" \
  bash "$GUARD" validate --repo-root "$TMP_ROOT/repo" --file "$registry" --json >/dev/null; then
  fail "fresh default binary should execute without rebuilding"
fi
[[ "$(wc -l < "$build_once_log" | tr -d ' ')" == "1" ]] \
  || fail "stale/missing default binary should trigger exactly one cargo build across two calls"
if rg -n '(^| )run($| )' "$build_once_log" >/dev/null; then
  fail "lease guard must not use the run subcommand on fallback"
fi

stale_bin="$TMP_ROOT/stubs/stale-agent-core"
stale_cargo="$TMP_ROOT/stubs/stale-cargo"
stale_log="$TMP_ROOT/stubs/stale-cargo.log"
stale_marker="$TMP_ROOT/stubs/stale-binary-executed.marker"
stale_replacement_bin="$TMP_ROOT/stubs/stale-agent-core.replacement"
cat >"$stale_bin" <<STUB
#!/usr/bin/env bash
printf 'stale binary executed\n' > "$stale_marker"
exit 97
STUB
chmod +x "$stale_bin"
touch -t 202001010000 "$stale_bin"
cat >"$stale_replacement_bin" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "lease" && "${3:-}" == "--help" ]]; then
  exit 0
fi
if [[ "$1" == "lease" && "$2" == "validate" ]]; then
  printf '{"schema_version":"rev-harness-lease-guard/v1","status":"PASS","file":"stub","repo_root":"stub","completion_allowed":true,"violations":[]}\n'
  exit 0
fi
exit 2
STUB
cat >"$stale_cargo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STALE_LOG"
if [[ "$*" == *" run "* || "$1" == "run" ]]; then
  printf 'forbidden cargo subcommand executed\n' >&2
  exit 98
fi
cp "$STALE_REPLACEMENT_BIN" "$STALE_BIN"
chmod +x "$STALE_BIN"
touch -t 203001010000 "$STALE_BIN"
STUB
chmod +x "$stale_cargo"
if ! env \
  STALE_BIN="$stale_bin" \
  STALE_LOG="$stale_log" \
  STALE_REPLACEMENT_BIN="$stale_replacement_bin" \
  REV_HARNESS_LEASE_GUARD_DEFAULT_RUST_BIN="$stale_bin" \
  REV_HARNESS_LEASE_GUARD_CARGO_BIN="$stale_cargo" \
  bash "$GUARD" validate --repo-root "$TMP_ROOT/repo" --file "$registry" --json >/dev/null; then
  fail "stale default binary should trigger cargo build then binary execution"
fi
[[ ! -e "$stale_marker" ]] || fail "stale default binary must not execute before rebuild"
[[ "$(wc -l < "$stale_log" | tr -d ' ')" == "1" ]] \
  || fail "stale default binary should trigger exactly one cargo build"
if rg -n '(^| )run($| )' "$stale_log" >/dev/null; then
  fail "lease guard must not use the run subcommand for stale binary fallback"
fi

missing_source_root="$TMP_ROOT/missing-source-root"
mkdir -p "$missing_source_root/scripts" "$missing_source_root/harness-rust/target/debug"
cp "$GUARD" "$missing_source_root/scripts/rev-harness-lease-guard.sh"
printf '[workspace]\nmembers = []\n' > "$missing_source_root/harness-rust/Cargo.toml"
missing_source_bin="$missing_source_root/harness-rust/target/debug/agent-core"
missing_source_marker="$TMP_ROOT/stubs/missing-source-binary-executed.marker"
missing_source_cargo="$TMP_ROOT/stubs/missing-source-cargo"
cat >"$missing_source_bin" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "lease" && "\${3:-}" == "--help" ]]; then
  exit 0
fi
printf 'missing source stale binary executed\n' > "$missing_source_marker"
printf '{"schema_version":"rev-harness-lease-guard/v1","status":"PASS","file":"stub","repo_root":"stub","completion_allowed":true,"violations":[]}\n'
exit 0
STUB
chmod +x "$missing_source_bin"
touch -t 203001010000 "$missing_source_bin"
cat >"$missing_source_cargo" <<'STUB'
#!/usr/bin/env bash
exit 88
STUB
chmod +x "$missing_source_cargo"
if env \
  REV_HARNESS_LEASE_GUARD_CARGO_BIN="$missing_source_cargo" \
  bash "$missing_source_root/scripts/rev-harness-lease-guard.sh" validate --repo-root "$TMP_ROOT/repo" --file "$registry" --json >/dev/null 2>&1; then
  fail "missing freshness sources should fail closed instead of executing default binary"
fi
[[ ! -e "$missing_source_marker" ]] \
  || fail "default binary must not execute when freshness source files are missing"

printf 'rev_harness_lease_lifecycle_test: PASS\n'
