#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: scripts/ci/mcp-wire-contract-check.sh [--quick] [--strict] [--adopter <path>]

P8 semantics: absent semantic MCP wiring is compliant core state. When semantic
addon wiring is present, scripts/ci/addon-absent-or-compliant-check.sh
--semantic enforces the Addon-I-13 opt-in contract.
USAGE
}

die_usage() {
  usage
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
CHECKER="$HARNESS_ROOT/scripts/ci/addon-absent-or-compliant-check.sh"

STRICT=0
ADOPTER_PATH=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --quick)
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --adopter)
      [[ "$#" -ge 2 ]] || die_usage
      ADOPTER_PATH="$2"
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

[[ -x "$CHECKER" ]] || {
  printf 'mcp-wire-contract-check: checker missing or not executable: %s\n' "$CHECKER" >&2
  exit 3
}

ROOT_ARG="$HARNESS_ROOT"
if [[ -n "$ADOPTER_PATH" ]]; then
  ROOT_ARG="$ADOPTER_PATH"
fi

set +e
output="$("$CHECKER" --semantic --root "$ROOT_ARG" 2>&1)"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  printf '%s\n' "$output"
  exit 0
fi

if [[ "$status" -eq 1 && "$STRICT" -eq 0 ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && printf 'WARN: %s\n' "$line" >&2
  done <<<"$output"
  exit 0
fi

printf '%s\n' "$output" >&2
exit "$status"
