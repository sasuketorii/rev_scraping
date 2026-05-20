#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP_ROOT=""
ARTIFACT_DIR=""

cleanup() {
  /bin/rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
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

assert_file_exact() {
  local path="$1"
  local expected="$2"
  [[ -f "$path" ]] || fail "missing file: $path"
  local actual
  actual="$(tr -d '\r' < "$path")"
  [[ "$actual" == "$expected" ]] || fail "unexpected file contents in $path: $actual"
}

require_cmd claude
require_cmd jq

auth_json="$(claude auth status)"
logged_in="$(printf '%s' "$auth_json" | jq -r '.loggedIn // false')"
[[ "$logged_in" == "true" ]] || fail "claude auth status is not logged in"

[[ -w "$HOME/.claude" ]] || fail "~/.claude is not writable"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude_live_runtime_smoke.XXXXXX")"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR="$PROJECT_ROOT/.claude/tmp/runtime-routing-semantic-retention/slice-b2/$timestamp"
mkdir -p "$ARTIFACT_DIR"
printf '%s\n' "$auth_json" > "$ARTIFACT_DIR/claude_auth_status.json"

DIRECT_OUT="$ARTIFACT_DIR/claude_live_output.txt"
DIRECT_STDERR="$ARTIFACT_DIR/claude_live_stderr.log"
SESSION_OUT="$ARTIFACT_DIR/claude_session_output.txt"

"$PROJECT_ROOT/scripts/claude-wrapper.sh" \
  --mode orchestrator-full \
  --effort low \
  --timeout 120 \
  --output "$DIRECT_OUT" \
  "Return exactly B2_ORCHESTRATOR_SMOKE_OK and nothing else." \
  > /dev/null 2> "$DIRECT_STDERR"

assert_file_exact "$DIRECT_OUT" "B2_ORCHESTRATOR_SMOKE_OK"

REPO_ROOT="$PROJECT_ROOT"
LIB_DIR="$PROJECT_ROOT/.claude/commands/lib"
export REPO_ROOT LIB_DIR TMPDIR="$TMP_ROOT" CLAUDE_CODE_EFFORT_LEVEL=low SESSION_TIMEOUT=120

# shellcheck source=/dev/null
source "$PROJECT_ROOT/.claude/commands/lib/utils.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/.claude/commands/lib/state.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/.claude/commands/lib/timeout.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/.claude/commands/lib/session.sh"

session_id="$(session_start 'Return exactly B2_SESSION_START_OK and nothing else.' "$SESSION_OUT")"
[[ -n "$session_id" ]] || fail "session_start did not return a session id"

assert_file_exact "$SESSION_OUT" "B2_SESSION_START_OK"

cat > "$ARTIFACT_DIR/summary.md" <<EOF
# B2 Live Runtime Smoke

- timestamp: \`$timestamp\`
- auth status: \`PASS\`
- wrapper mode: \`orchestrator-full\`
- output file: \`$DIRECT_OUT\`
- stderr log: \`$DIRECT_STDERR\`
- session output: \`$SESSION_OUT\`
- session id captured: \`yes\`
- result: \`PASS\`
EOF

printf 'PASS: claude_live_runtime_smoke\n'
