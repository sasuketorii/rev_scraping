#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
tmp_root="$(mktemp -d)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

cleanup() {
  /bin/rm -rf "$tmp_root"
}
trap cleanup EXIT

new_adopter() {
  local path="$tmp_root/$1"
  mkdir -p "$path"
  git -C "$path" init -q
  printf '%s\n' "$path"
}

export REVHARNESS_PARALLEL_QUIESCE=1
export REV_HARNESS_SMOKE_SKIP_HEAVY=1

default_adopter="$(new_adopter default)"
(
  cd "$repo_root"
  bash scripts/rev-harness install --target "$default_adopter"
) >"$tmp_root/default.out" 2>"$tmp_root/default.err"
[[ ! -e "$default_adopter/.mcp.json" ]] || fail "default install created .mcp.json"
pass "default install leaves .mcp.json absent"

wire_adopter="$(new_adopter withwire)"
(
  cd "$repo_root"
  bash scripts/rev-harness install --target "$wire_adopter" --with-mcp-wire
) >"$tmp_root/withwire.out" 2>"$tmp_root/withwire.err"
[[ -f "$wire_adopter/.mcp.json" ]] || fail "--with-mcp-wire did not create .mcp.json"
jq -e --arg command "$repo_root/scripts/launch-semantic-mcp.sh" '.mcpServers["semantic-mcp"].command == $command' "$wire_adopter/.mcp.json" >/dev/null \
  || fail "--with-mcp-wire did not merge semantic-mcp entry"
compgen -G "$wire_adopter/.mcp.json.bak.*" >/dev/null \
  || fail "--with-mcp-wire did not create rollback backup"
pass "--with-mcp-wire creates .mcp.json with semantic-mcp entry"

printf 'PASS: mcp-wire opt-in integration test complete\n'
