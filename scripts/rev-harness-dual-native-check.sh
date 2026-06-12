#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_FILES=()

cleanup() {
  if [[ "${#TMP_FILES[@]}" -gt 0 ]]; then
    /bin/rm -f -- "${TMP_FILES[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local file="$1"
  local pattern="$2"
  [[ -f "$REPO_ROOT/$file" ]] || fail "missing file: $file"
  rg -q "$pattern" "$REPO_ROOT/$file" || fail "missing pattern in $file: $pattern"
}

require_text "AGENTS.md" "Dual-native orchestration boundary"
require_text "AGENTS.md" "Codex native subagents"
require_text "AGENTS.md" "artifact packets"
require_text ".agent_rules/shared-delegation.md" "Orchestrator role selection is dual-native"
require_text ".agent_rules/shared-delegation.md" "top-level Claude"
require_text ".agent_rules/shared-delegation.md" "top-level Codex"
require_text "docs/roles/orchestrator.md" "dual-native"
require_text "docs/manual/harness-user-guide.md" "Dual-native orchestration rule"
require_text "docs/manual/subscription-orchestration.md" "Dual-native policy"
require_text "docs/manual/skill-routing-matrix.md" "Dual-native Orchestration Rule"
require_text "CLAUDE.md" "dual-native"
require_text "docs/manual/agent_review_loop.md" "dual-native"

if [[ -d "$REPO_ROOT/.codex/agents" ]]; then
  codex_tmp="$(mktemp "${TMPDIR:-/tmp}/rev-harness-dual-native-codex.XXXXXX")"
  TMP_FILES+=("$codex_tmp")
  if rg -n "codex-wrapper\\.sh|claude-wrapper\\.sh" "$REPO_ROOT/.codex/agents" >"$codex_tmp" 2>/dev/null; then
    cat "$codex_tmp" >&2
    fail ".codex/agents must not invoke wrapper scripts recursively"
  fi
fi

if [[ -d "$REPO_ROOT/.claude/agents" ]]; then
  claude_tmp="$(mktemp "${TMPDIR:-/tmp}/rev-harness-dual-native-claude.XXXXXX")"
  TMP_FILES+=("$claude_tmp")
  if rg -n "codex-wrapper\\.sh|claude-wrapper\\.sh" "$REPO_ROOT/.claude/agents" >"$claude_tmp" 2>/dev/null; then
    cat "$claude_tmp" >&2
    fail ".claude/agents must not invoke wrapper scripts recursively"
  fi
fi

printf '{"status":"ok","check":"dual-native-orchestration"}\n'
