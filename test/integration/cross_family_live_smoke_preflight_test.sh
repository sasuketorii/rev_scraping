#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFLIGHT="$PROJECT_ROOT/scripts/cross-family-live-smoke-preflight.sh"

TMP_ROOT=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  /bin/rm -rf "${TMP_ROOT:-}" 2>/dev/null || true
}
trap cleanup EXIT

RC=0
OUT=""
OUT_JSON_FILE=""

run_preflight() {
  RC=0
  OUT=""
  OUT="$(bash "$PREFLIGHT" "$@" 2>&1)" || RC=$?
  OUT_JSON_FILE="$TMP_ROOT/preflight-output.json"
  printf '%s\n' "$OUT" > "$OUT_JSON_FILE"
}

assert_pass_json() {
  jq -e '
    .schema_version == "rev-harness-cross-family-live-smoke-preflight/v1"
    and .status == "PASS"
    and .live_execution_enabled == false
    and .completion_claim_allowed == false
    and (.violations | length) == 0
  ' "$OUT_JSON_FILE" >/dev/null \
    || { printf '%s\n' "$OUT" >&2; fail "expected PASS preflight JSON"; }
}

assert_block_json() {
  local needle="$1"
  jq -e --arg needle "$needle" '
    .schema_version == "rev-harness-cross-family-live-smoke-preflight/v1"
    and .status == "BLOCK"
    and .live_execution_enabled == false
    and .completion_claim_allowed == false
    and (.violations | map(select(contains($needle))) | length) > 0
  ' "$OUT_JSON_FILE" >/dev/null \
    || { printf '%s\n' "$OUT" >&2; fail "expected BLOCK preflight JSON containing: $needle"; }
}

require_rc() {
  local expected="$1"
  [[ "$RC" -eq "$expected" ]] || { printf '%s\n' "$OUT" >&2; fail "expected rc=$expected, got rc=$RC"; }
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cross-family-live-smoke-preflight.XXXXXX")"

# ---- Test 1: default JSON preflight is PASS ---------------------------------
run_preflight check --json
require_rc 0
assert_pass_json

# ---- Test 2: workspace path under .claude/** is BLOCK -----------------------
run_preflight check --json --workspace .claude/tmp/bad
require_rc 1
assert_block_json "workspace must be under workspace/<task>"

# ---- Test 3: artifact root path under workspace/** is BLOCK -----------------
run_preflight check --json --artifact-root workspace/bad
require_rc 1
assert_block_json "artifact_root must be under .claude/tmp/<task>"

# ---- Test 4: --require-cli BLOCK when CLIs are explicitly missing -----------
missing_codex="$TMP_ROOT/missing-codex"
missing_claude="$TMP_ROOT/missing-claude"
run_preflight check --json --require-cli --codex-cli "$missing_codex" --claude-cli "$missing_claude"
require_rc 1
assert_block_json "codex CLI path is not an executable file"
assert_block_json "claude CLI path is not an executable file"

# ---- Test 5: --require-cli PASS with stub codex and claude executables ------
stub_root="$TMP_ROOT/stubs"
mkdir -p "$stub_root"
stub_codex="$stub_root/codex"
stub_claude="$stub_root/claude"
printf '%s\n' '#!/usr/bin/env bash' 'echo "stub codex"' > "$stub_codex"
printf '%s\n' '#!/usr/bin/env bash' 'echo "stub claude"' > "$stub_claude"
chmod +x "$stub_codex" "$stub_claude"

run_preflight check --json --require-cli --codex-cli "$stub_codex" --claude-cli "$stub_claude"
require_rc 0
assert_pass_json
jq -e '
  .codex_cli.available == true
  and .claude_cli.available == true
  and .require_cli == true
' "$OUT_JSON_FILE" >/dev/null || { printf '%s\n' "$OUT" >&2; fail "stub CLI availability not reflected in JSON"; }

# ---- Test 6: live execution flags are rejected -------------------------------
for flag in --execute --live --run-live; do
  run_preflight check --json "$flag"
  require_rc 1
  assert_block_json "live execution flag rejected"
done

# ---- Test 7: symlink path components are rejected ----------------------------
sym_repo="$TMP_ROOT/sym-repo"
mkdir -p "$sym_repo/.claude/tmp" "$sym_repo/real-work"
ln -s "$sym_repo/real-work" "$sym_repo/workspace"
mkdir -p "$sym_repo/real-work/symlink-task"

run_preflight check --json --repo-root "$sym_repo" --workspace workspace/symlink-task
require_rc 1
assert_block_json "workspace contains symlink path component"

ln -s "$sym_repo/real-work" "$sym_repo/.claude/tmp/sym-task"
run_preflight check --json --repo-root "$sym_repo" --artifact-root .claude/tmp/sym-task/inner
require_rc 1
assert_block_json "artifact_root contains symlink path component"

# ---- Test 8: schema invariants for live + completion claims ------------------
run_preflight check --json
require_rc 0
jq -e '
  .live_execution_enabled == false
  and .completion_claim_allowed == false
' "$OUT_JSON_FILE" >/dev/null \
  || { printf '%s\n' "$OUT" >&2; fail "live/completion invariants are not false in default JSON"; }

# ---- Test 9: text mode also reports invariants -------------------------------
run_preflight check
require_rc 0
case "$OUT" in
  *"live_execution_enabled: false"*) ;;
  *) printf '%s\n' "$OUT" >&2; fail "text-mode preflight missing live_execution_enabled: false" ;;
esac
case "$OUT" in
  *"completion_claim_allowed: false"*) ;;
  *) printf '%s\n' "$OUT" >&2; fail "text-mode preflight missing completion_claim_allowed: false" ;;
esac

printf 'PASS: cross_family_live_smoke_preflight_test\n'
