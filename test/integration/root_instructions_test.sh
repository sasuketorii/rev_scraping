#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'root_instructions_test: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -s "$1" ]] || fail "expected non-empty file: $1"
}

assert_contains() {
  local pattern="$1"
  local file="$2"
  grep -q "$pattern" "$file" || fail "expected '$pattern' in $file"
}

assert_not_contains() {
  local pattern="$1"
  local file="$2"
  if grep -q "$pattern" "$file"; then
    fail "unexpected '$pattern' in $file"
  fi
}

assert_file AGENTS.md
assert_file CLAUDE.md
assert_file .claude/CLAUDE-LOCAL.md
assert_file .agent_rules/shared-semantic.md
assert_file .cursor/rules/revharness-detailed.mdc

head -n 12 CLAUDE.md | grep -qi 'vendor-neutral' || fail "CLAUDE.md lacks vendor-neutral disclosure near top"
head -n 15 AGENTS.md | grep -q 'RevHarness invariants' || fail "AGENTS.md lacks RevHarness invariants disclosure near top"

assert_contains 'AGENTS.md' CLAUDE.md
assert_contains '.claude/CLAUDE-LOCAL.md' CLAUDE.md
assert_contains 'docs/manual/verification-truth-matrix.md' CLAUDE.md
assert_contains '.shared/project_id' CLAUDE.md

assert_not_contains 'codex-wrapper.sh --role' CLAUDE.md
assert_not_contains 'claude-wrapper.sh' CLAUDE.md
assert_not_contains '役割変更ルール' CLAUDE.md

assert_contains 'codex-wrapper.sh' .claude/CLAUDE-LOCAL.md
assert_contains 'claude-wrapper.sh' .claude/CLAUDE-LOCAL.md
assert_contains 'Orchestrator Hard Rules' .claude/CLAUDE-LOCAL.md
assert_contains '役割変更ルール' .claude/CLAUDE-LOCAL.md
assert_contains 'Semantic coordination uses a four-layer model' .agent_rules/shared-semantic.md
assert_contains 'Layer 0 ground' .agent_rules/shared-semantic.md
assert_contains 'Layer 1 pre-flight' .agent_rules/shared-semantic.md
assert_contains 'Layer 2 prompt capsule' .agent_rules/shared-semantic.md
assert_contains 'Layer 3' .agent_rules/shared-semantic.md
assert_contains 'execution feedback' .agent_rules/shared-semantic.md
assert_contains 'four-layer context model is primarily orchestrator context management' .cursor/rules/revharness-detailed.mdc
