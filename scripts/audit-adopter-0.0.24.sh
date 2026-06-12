#!/usr/bin/env bash
set -euo pipefail

# Deprecated historical audit for 0.0.24 adopters. It intentionally detects the
# legacy `mcpServers.semantic` key; current addon opt-in uses `semantic-mcp`.

usage() {
  cat >&2 <<'USAGE'
usage: bash scripts/audit-adopter-0.0.24.sh [--target <adopter-path>]

Read-only audit. Prints:
  <adopter-path>: OK | DRIFT | LEGACY
USAGE
}

detail() {
  printf '%s\n' "$*" >&2
}

set_status() {
  local next="$1"
  case "$STATUS:$next" in
    LEGACY:*) ;;
    *:LEGACY) STATUS="LEGACY" ;;
    DRIFT:*) ;;
    *:DRIFT) STATUS="DRIFT" ;;
    *) STATUS="OK" ;;
  esac
}

is_abs_path() {
  case "$1" in
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

TARGET="${PWD}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --target)
      [[ "$#" -ge 2 ]] || { detail "ERROR: --target requires a path"; usage; exit 2; }
      TARGET="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      detail "ERROR: unknown argument: $1"
      usage
      exit 2
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

if [[ -d "$TARGET" ]]; then
  TARGET="$(cd "$TARGET" && pwd -P)"
else
  printf '%s: DRIFT\n' "$TARGET"
  detail "$TARGET: target missing"
  exit 0
fi

STATUS="OK"
SETTINGS="$TARGET/.claude/settings.json"
HOOK="$TARGET/.git/hooks/pre-commit"
LOCAL_LAUNCHER="$TARGET/scripts/launch-semantic-mcp.sh"

if [[ ! -f "$SETTINGS" ]]; then
  set_status DRIFT
  detail "$TARGET: .claude/settings.json missing"
elif ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  set_status DRIFT
  detail "$TARGET: .claude/settings.json is not valid JSON"
else
  has_semantic="$(jq -r '(.mcpServers // {}) | has("semantic")' "$SETTINGS")"
  has_semantic_mcp="$(jq -r '(.mcpServers // {}) | has("semantic-mcp")' "$SETTINGS")"
  if [[ "$has_semantic" == "true" && "$has_semantic_mcp" == "true" ]]; then
    set_status LEGACY
    detail "$TARGET: LEGACY mcpServers contains both semantic and semantic-mcp"
  elif [[ "$has_semantic" == "true" ]]; then
    semantic_cmd="$(jq -r '.mcpServers.semantic.command // ""' "$SETTINGS")"
    case "$semantic_cmd" in
      ./*|../*|"")
        set_status DRIFT
        detail "$TARGET: DRIFT mcpServers uses legacy semantic key with relative command: ${semantic_cmd:-<missing>}"
        ;;
      *)
        set_status LEGACY
        detail "$TARGET: LEGACY mcpServers uses legacy semantic key with absolute command"
        ;;
    esac
  elif [[ "$has_semantic_mcp" == "true" ]]; then
    canonical_cmd="$(jq -r '.mcpServers["semantic-mcp"].command // ""' "$SETTINGS")"
    if is_abs_path "$canonical_cmd"; then
      detail "$TARGET: OK mcpServers semantic-mcp command is absolute"
    else
      set_status DRIFT
      detail "$TARGET: DRIFT semantic-mcp command is not absolute: ${canonical_cmd:-<missing>}"
    fi
    if jq -e '.mcpServers["semantic-mcp"].env | has("SEMANTIC_MCP_PROJECT_ID")' "$SETTINGS" >/dev/null 2>&1; then
      set_status DRIFT
      detail "$TARGET: DRIFT semantic-mcp env contains SEMANTIC_MCP_PROJECT_ID sentinel"
    fi
  else
    set_status DRIFT
    detail "$TARGET: DRIFT mcpServers missing semantic-mcp"
  fi
fi

if [[ ! -f "$HOOK" ]]; then
  set_status DRIFT
  detail "$TARGET: DRIFT pre-commit hook missing"
elif grep -Fq 'HARNESS_ROOT_LITERAL=' "$HOOK"; then
  detail "$TARGET: OK pre-commit hook uses HARNESS_ROOT_LITERAL"
elif grep -Fq 'git rev-parse --show-toplevel' "$HOOK"; then
  set_status DRIFT
  detail "$TARGET: DRIFT pre-commit hook uses runtime git rev-parse root"
else
  set_status DRIFT
  detail "$TARGET: DRIFT pre-commit hook is not recognized as PR-3 fresh"
fi

if [[ -e "$LOCAL_LAUNCHER" ]]; then
  set_status DRIFT
  detail "$TARGET: DRIFT adopter-local scripts/launch-semantic-mcp.sh is present"
else
  detail "$TARGET: OK no adopter-local scripts/launch-semantic-mcp.sh copy"
fi

printf '%s: %s\n' "$TARGET" "$STATUS"
exit 0
