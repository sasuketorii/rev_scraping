#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTO_ORCHESTRATE="$PROJECT_ROOT/.claude/commands/auto_orchestrate.sh"
PACKET_HELPER="$PROJECT_ROOT/.claude/commands/lib/orchestration_packet.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

normalize_path() {
  local path="$1"
  local dir=""
  local base=""

  dir="$(cd "$(dirname "$path")" && pwd -P)"
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
}

function_source_path() {
  local function_name="$1"
  local restore_extdebug=""
  local declaration=""
  local source_path=""

  restore_extdebug="$(shopt -p extdebug 2>/dev/null || true)"
  shopt -s extdebug
  declaration="$(declare -F "$function_name" 2>/dev/null || true)"
  if [[ -n "$restore_extdebug" ]]; then
    eval "$restore_extdebug" >/dev/null 2>&1 || true
  else
    shopt -u extdebug >/dev/null 2>&1 || true
  fi

  [[ -n "$declaration" ]] || fail "missing function: $function_name"
  read -r _ _ source_path <<< "$declaration"
  [[ -n "$source_path" ]] || fail "missing source path for function: $function_name"
  normalize_path "$source_path"
}

[[ -f "$PACKET_HELPER" ]] || fail "missing packet helper: $PACKET_HELPER"

# shellcheck source=/dev/null
source "$AUTO_ORCHESTRATE"

expected_helper="$(normalize_path "$PACKET_HELPER")"

for function_name in \
  _baseline_freeze_script_is_available \
  _orchestration_packet_extract_single_tuple_json \
  _prepare_orchestration_packet_for_coder_launch; do
  actual_source="$(function_source_path "$function_name")"
  [[ "$actual_source" == "$expected_helper" ]] \
    || fail "$function_name should be owned by $expected_helper, got $actual_source"
done

printf 'PASS: auto_orchestrate_thin_coordinator_test\n'
