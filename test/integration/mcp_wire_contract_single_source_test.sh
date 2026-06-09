#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mcp_wire_contract_single_source.XXXXXX")"

cleanup() {
  /bin/rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

normalize_json_entry() {
  local file="$1"
  jq -cS '
    .mcpServers["semantic-mcp"]
    | {command:(.command // null), args:(.args // []), env:(.env // {})}
  ' "$file"
}

normalize_claude_settings_entry() {
  jq -cS --arg root "$REPO_ROOT" '
    .mcpServers["semantic-mcp"]
    | {command:(.command // null), args:(.args // []), env:(.env // {})}
    | if .command == "./scripts/launch-semantic-mcp.sh"
      then .command = "\($root)/scripts/launch-semantic-mcp.sh"
      else .
      end
  ' "$REPO_ROOT/.claude/settings.json"
}

normalize_codex_entry() {
  python3 - "$REPO_ROOT/.codex/config.toml" "$REPO_ROOT" <<'PY'
import json
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)

entry = data.get("mcp_servers", {}).get("semantic-mcp")
if not isinstance(entry, dict):
    raise SystemExit("missing [mcp_servers.semantic-mcp]")

command = entry.get("command")
if command == "./scripts/launch-semantic-mcp.sh":
    command = sys.argv[2] + "/scripts/launch-semantic-mcp.sh"

print(json.dumps({
    "args": entry.get("args", []),
    "command": command,
    "env": entry.get("env", {}),
}, sort_keys=True, separators=(",", ":")))
PY
}

assert_same_entry() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf '%s\n' "$expected" > "$TMP_ROOT/$label.expected.json"
    printf '%s\n' "$actual" > "$TMP_ROOT/$label.actual.json"
    diff -u "$TMP_ROOT/$label.expected.json" "$TMP_ROOT/$label.actual.json" >&2 || true
    fail "$label does not match canonical MCP entry"
  fi
}

require_cmd jq
require_cmd python3

REFERENCE="$TMP_ROOT/rendered.mcp.json"
INSTALL_FIXTURE="$TMP_ROOT/install.fixture.json"
WIRE_FIXTURE="$TMP_ROOT/wire.fixture.json"

(cd "$REPO_ROOT" && bash scripts/render-mcp-json.sh --harness-root "$REPO_ROOT" --output "$REFERENCE")
(cd "$REPO_ROOT" && bash scripts/install-rev-harness-mcp.sh --self-test --output-fixture "$INSTALL_FIXTURE")
(cd "$REPO_ROOT" && bash scripts/rev-harness-mcp-wire.sh --self-test --output-fixture "$WIRE_FIXTURE")

CANONICAL_ENTRY="$(normalize_json_entry "$REFERENCE")"

assert_same_entry render-template "$CANONICAL_ENTRY" "$(normalize_json_entry "$REFERENCE")"
assert_same_entry install-rev-harness-mcp "$CANONICAL_ENTRY" "$(normalize_json_entry "$INSTALL_FIXTURE")"
assert_same_entry rev-harness-mcp-wire "$CANONICAL_ENTRY" "$(normalize_json_entry "$WIRE_FIXTURE")"
assert_same_entry harness-self-claude "$CANONICAL_ENTRY" "$(normalize_claude_settings_entry)"
assert_same_entry harness-self-codex "$CANONICAL_ENTRY" "$(normalize_codex_entry)"

printf 'PASS: mcp_wire_contract_single_source_test\n'
