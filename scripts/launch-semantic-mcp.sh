#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'launch-semantic-mcp.sh: %s\n' "$*" >&2
  exit 1
}

script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P
}

readonly SCRIPT_DIR="$(script_dir)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly PROJECT_ID_TOOL="$REPO_ROOT/scripts/project-id.sh"

if [[ -n "${SEMANTIC_PROJECT_ID_RESOLVER:-}" ]]; then
  die "SEMANTIC_PROJECT_ID_RESOLVER override is forbidden; canonical repo-local helper is required"
fi
if [[ -n "${PROJECT_ID_SCRIPT:-}" ]]; then
  die "PROJECT_ID_SCRIPT override is forbidden; canonical repo-local helper is required"
fi
if [[ -n "${SEMANTIC_MCP_ENTRYPOINT:-}" ]]; then
  die "SEMANTIC_MCP_ENTRYPOINT override is forbidden; canonical repo-local entrypoint is required"
fi
if [[ -n "${SEMANTIC_MCP_NODE_BIN:-}" ]]; then
  die "SEMANTIC_MCP_NODE_BIN override is forbidden; canonical node runtime lookup is required"
fi

[[ -x "$PROJECT_ID_TOOL" ]] || die "project_id helper not found or not executable: $PROJECT_ID_TOOL"

exec env PROJECT_ID_REPO_ROOT="$REPO_ROOT" bash "$PROJECT_ID_TOOL" exec-mcp-server "$@"
