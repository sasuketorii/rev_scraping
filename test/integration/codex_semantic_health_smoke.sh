#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
WRAPPER="$REPO_ROOT/scripts/codex-wrapper.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-sem-health-smoke.XXXXXX")"
STDOUT_FILE="$TMP_DIR/stdout.txt"
STDERR_FILE="$TMP_DIR/stderr.redacted.txt"
STDERR_FIFO="$TMP_DIR/stderr.fifo"

cleanup() {
  /bin/rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

redact_text() {
  sed -E -e "s#${HOME%/}/#~/#g" -e 's#/Users/[^/[:space:]]+/#~/#g' -e 's#/home/[^/[:space:]]+/#~/#g'
}

prompt='Call MCP tool `sem.health` from server `semantic-mcp` with empty JSON arguments. Print only the raw JSON object returned by the tool, with no Markdown or commentary.'

mkfifo "$STDERR_FIFO"
redact_text <"$STDERR_FIFO" >"$STDERR_FILE" &
redactor_pid=$!

set +e
printf '%s\n' "$prompt" \
  | "$WRAPPER" --role standard --stdin \
      >"$STDOUT_FILE" \
      2>"$STDERR_FIFO"
wrapper_rc=$?
wait "$redactor_pid"
redactor_rc=$?
set -e

if [[ "$redactor_rc" -ne 0 ]]; then
  printf '[codex-sem-health-smoke] FAIL: stderr redaction failed: %s\n' "$redactor_rc" >&2
  exit "$redactor_rc"
fi

printf '[codex-sem-health-smoke] wrapper_exit=%s\n' "$wrapper_rc"
printf '[codex-sem-health-smoke] stdout_begin\n'
redact_text <"$STDOUT_FILE"
printf '\n[codex-sem-health-smoke] stdout_end\n'

if [[ -s "$STDERR_FILE" ]]; then
  printf '[codex-sem-health-smoke] stderr_begin\n' >&2
  cat "$STDERR_FILE" >&2
  printf '\n[codex-sem-health-smoke] stderr_end\n' >&2
fi

if grep -Fq 'user cancelled MCP tool call' "$STDOUT_FILE" "$STDERR_FILE"; then
  printf '[codex-sem-health-smoke] FAIL: observed user cancelled MCP tool call\n' >&2
  exit 1
fi

if [[ "$wrapper_rc" -ne 0 ]]; then
  printf '[codex-sem-health-smoke] FAIL: wrapper exited non-zero: %s\n' "$wrapper_rc" >&2
  exit "$wrapper_rc"
fi

if ! jq -e '
  type == "object"
  and .status == "ok"
  and (.tables | type == "array")
  and (.version | type == "string")
  and (.tool_count | type == "number")
' "$STDOUT_FILE" >/dev/null; then
  printf '[codex-sem-health-smoke] FAIL: stdout is not a valid sem.health JSON response\n' >&2
  exit 1
fi

printf '[codex-sem-health-smoke] PASS: sem.health returned valid JSON\n'
