#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/ci/addon-absent-or-compliant-check.sh --semantic [--root <path>]

Exit codes:
  0  semantic MCP config is absent, or present and compliant
  1  semantic MCP config is present but non-compliant
  2  usage error
  3  environment or unreadable-file error
USAGE
}

die_usage() {
  usage
  exit 2
}

die_env() {
  printf 'addon-absent-or-compliant-check: %s\n' "$*" >&2
  exit 3
}

record_finding() {
  local file="$1" code="$2" detail="$3"
  findings=$((findings + 1))
  printf 'ERROR[%s] %s: %s\n' "$code" "$file" "$detail" >&2
}

SEMANTIC=0
ROOT=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --semantic)
      SEMANTIC=1
      shift
      ;;
    --root)
      [[ "$#" -ge 2 ]] || die_usage
      ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage
      ;;
  esac
done

[[ "$SEMANTIC" -eq 1 ]] || die_usage
command -v jq >/dev/null 2>&1 || die_env "jq is required"
command -v python3 >/dev/null 2>&1 || die_env "python3 with tomllib is required"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "$ROOT" ]]; then
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
else
  ROOT="$(cd "$ROOT" && pwd -P)" || die_env "cannot resolve --root"
fi

LAUNCHER="$ROOT/scripts/launch-semantic-mcp.sh"
CLAUDE_SETTINGS="$ROOT/.claude/settings.json"
CODEX_CONFIG="$ROOT/.codex/config.toml"
MCP_TEMPLATE="$ROOT/.mcp.json.template"

for required in "$CLAUDE_SETTINGS" "$CODEX_CONFIG" "$MCP_TEMPLATE"; do
  [[ -f "$required" ]] || die_env "required config file is missing: ${required#"$ROOT"/}"
  [[ -r "$required" ]] || die_env "required config file is not readable: ${required#"$ROOT"/}"
done

findings=0
enabled_entries=0

is_legacy_key() {
  case "$1" in
    semantic|semantic-node|semantic_node|semanticNode) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_command() {
  local command_value="$1"
  case "$command_value" in
    ./scripts/launch-semantic-mcp.sh)
      printf '%s\n' "$LAUNCHER"
      ;;
    "$ROOT"/scripts/launch-semantic-mcp.sh)
      printf '%s\n' "$command_value"
      ;;
    /*)
      printf '%s\n' "$command_value"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

validate_entry_common() {
  local file="$1" command_value="$2" args_json="$3" env_json="$4" resolved
  enabled_entries=$((enabled_entries + 1))
  resolved="$(resolve_command "$command_value")"
  if [[ "$resolved" != "$LAUNCHER" ]]; then
    record_finding "$file" "launcher" "semantic command must resolve to $LAUNCHER"
  elif [[ ! -x "$resolved" ]]; then
    record_finding "$file" "launcher" "semantic launcher is missing or not executable"
  fi
  if ! jq -e 'type == "array" and length == 0' >/dev/null 2>&1 <<<"$args_json"; then
    record_finding "$file" "args" "semantic launcher args must be an empty array"
  fi
  if jq -e 'type == "object" and has("SEMANTIC_MCP_PROJECT_ID")' >/dev/null 2>&1 <<<"$env_json"; then
    record_finding "$file" "legacy-sentinel" "SEMANTIC_MCP_PROJECT_ID env sentinel is forbidden"
  fi
}

check_json_config() {
  local file="$1" rel keys key command_value args_json env_json
  rel="${file#"$ROOT"/}"
  if ! jq empty "$file" >/dev/null 2>&1; then
    record_finding "$rel" "json" "invalid JSON"
    return
  fi
  if grep -Fq 'SEMANTIC_MCP_PROJECT_ID' "$file"; then
    record_finding "$rel" "legacy-sentinel" "SEMANTIC_MCP_PROJECT_ID literal is forbidden in semantic MCP config"
  fi
  keys="$(jq -r '(.mcpServers // {}) | keys[]?' "$file")"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if is_legacy_key "$key"; then
      record_finding "$rel" "legacy-key" "legacy MCP server key '$key' is forbidden; use 'semantic-mcp' only for explicit addon opt-in"
      continue
    fi
    [[ "$key" == "semantic-mcp" ]] || continue
    command_value="$(jq -r '.mcpServers."semantic-mcp".command // ""' "$file")"
    args_json="$(jq -c '.mcpServers."semantic-mcp".args // []' "$file")"
    env_json="$(jq -c '.mcpServers."semantic-mcp".env // {}' "$file")"
    validate_entry_common "$rel" "$command_value" "$args_json" "$env_json"
  done <<<"$keys"
}

check_codex_toml() {
  local file="$1" rel entries entry key command_value args_json env_json
  rel="${file#"$ROOT"/}"
  if grep -Fq 'SEMANTIC_MCP_PROJECT_ID' "$file"; then
    record_finding "$rel" "legacy-sentinel" "SEMANTIC_MCP_PROJECT_ID literal is forbidden in semantic MCP config"
  fi
  if ! entries="$(python3 - "$file" <<'PY'
import json
import sys
import tomllib

try:
    with open(sys.argv[1], "rb") as handle:
        data = tomllib.load(handle)
except tomllib.TOMLDecodeError as exc:
    print(json.dumps({"error": str(exc)}))
    raise SystemExit(0)

for key, value in data.get("mcp_servers", {}).items():
    if not isinstance(value, dict):
        value = {}
    print(json.dumps({
        "key": key,
        "command": value.get("command", ""),
        "args": value.get("args", []),
        "env": value.get("env", {}),
    }, sort_keys=True, separators=(",", ":")))
PY
  )"; then
    die_env "python3 failed while parsing $rel"
  fi
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if jq -e 'has("error")' >/dev/null 2>&1 <<<"$entry"; then
      record_finding "$rel" "toml" "invalid TOML: $(jq -r '.error' <<<"$entry")"
      continue
    fi
    key="$(jq -r '.key' <<<"$entry")"
    if is_legacy_key "$key"; then
      record_finding "$rel" "legacy-key" "legacy MCP server key '$key' is forbidden; use 'semantic-mcp' only for explicit addon opt-in"
      continue
    fi
    [[ "$key" == "semantic-mcp" ]] || continue
    command_value="$(jq -r '.command // ""' <<<"$entry")"
    args_json="$(jq -c '.args // []' <<<"$entry")"
    env_json="$(jq -c '.env // {}' <<<"$entry")"
    validate_entry_common "$rel" "$command_value" "$args_json" "$env_json"
  done <<<"$entries"
}

check_json_config "$CLAUDE_SETTINGS"
check_codex_toml "$CODEX_CONFIG"
check_json_config "$MCP_TEMPLATE"

if [[ "$findings" -gt 0 ]]; then
  printf 'FAIL semantic-addon-config: findings=%s enabled_entries=%s\n' "$findings" "$enabled_entries" >&2
  exit 1
fi

if [[ "$enabled_entries" -eq 0 ]]; then
  printf 'PASS semantic-addon-config: absent\n'
else
  printf 'PASS semantic-addon-config: compliant enabled_entries=%s\n' "$enabled_entries"
fi
