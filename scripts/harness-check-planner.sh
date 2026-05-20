#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE_CONFIG="$PROJECT_ROOT/.agent/registry/harness_operating_modes.json"

usage() {
  cat <<'EOF'
Usage: scripts/harness-check-planner.sh --mode <dev|review|release> [--] <path>...

Print deterministic check commands for the requested harness operating mode.
EOF
}

die() {
  printf 'harness-check-planner: %s\n' "$*" >&2
  exit 1
}

shell_quote() {
  local value="$1"
  printf '%q' "$value"
}

add_command() {
  local command="$1"
  local existing=""

  for existing in "${COMMANDS[@]}"; do
    [[ "$existing" != "$command" ]] || return 0
  done
  COMMANDS+=("$command")
}

mode=""
declare -a PATHS=()
declare -a COMMANDS=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ "$#" -ge 2 ]] || die "--mode requires a value"
      mode="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ "$#" -gt 0 ]]; do
        PATHS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      PATHS+=("$1")
      shift
      ;;
  esac
done

[[ -n "$mode" ]] || die "--mode is required"
[[ -r "$MODE_CONFIG" ]] || die "missing mode config: $MODE_CONFIG"
jq -e --arg mode "$mode" '.modes[$mode] | type == "object"' "$MODE_CONFIG" >/dev/null \
  || die "unknown mode: $mode"

if [[ "${#PATHS[@]}" -gt 0 ]]; then
  diff_command="git diff --check --"
  for path in "${PATHS[@]}"; do
    diff_command+=" $(shell_quote "$path")"
  done
  add_command "$diff_command"
fi

if [[ "$mode" == "review" && "${#PATHS[@]}" -gt 0 ]]; then
  review_command="git diff --stat --"
  for path in "${PATHS[@]}"; do
    review_command+=" $(shell_quote "$path")"
  done
  add_command "$review_command"
fi

for path in "${PATHS[@]}"; do
  case "$path" in
    *.sh)
      add_command "bash -n -- $(shell_quote "$path")"
      ;;
  esac

  case "$path" in
    *.json)
      add_command "jq empty -- $(shell_quote "$path")"
      ;;
  esac

  if [[ "$path" == ".agent/registry/orchestration_policy_projection.json" ]]; then
    add_command "bash scripts/harness-projection-preflight.sh --validate"
  fi

  if [[ "$path" == test/integration/*.sh && -x "$PROJECT_ROOT/$path" ]]; then
    add_command "bash -- $(shell_quote "$path")"
  fi
done

if [[ "$mode" == "release" ]]; then
  release_gate="$(jq -r '.commands.release_gate' "$MODE_CONFIG")"
  [[ -n "$release_gate" && "$release_gate" != "null" ]] || die "missing release gate command"
  add_command "$release_gate"
fi

printf '%s\n' "${COMMANDS[@]}"
