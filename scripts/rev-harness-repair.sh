#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JSON_OUTPUT=false
VERBOSE=false
STRICT=false

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-repair.sh [--json] [--verbose] [--strict]

Runs harness-doctor.sh --quick and prints one advisory repair suggestion.
Phase G never auto-executes repair actions.

Exit codes:
  0 advisory result emitted
  2 CLI misuse before doctor runs
EOF
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

suggestion_for() {
  local text="$1"
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == *"semantic"* || "$lower" == *"sem."* ]]; then
    printf 'Re-run scripts/semantic-bootstrap.sh; in canonical context, inspect scripts/launch-semantic-mcp.sh for project MCP startup.'
  elif [[ "$lower" == *"cargo"* || "$lower" == *"harness-rust"* ]]; then
    printf 'Run: cd harness-rust && cargo build'
  elif [[ "$lower" == *"project_id"* || "$lower" == *".shared"* ]]; then
    printf 'Re-run scripts/init-project.sh'
  elif [[ "$lower" == *"hooks"* || "$lower" == *"pre-commit"* ]]; then
    printf 'Re-run scripts/install-rev-harness-hooks.sh'
  else
    printf 'Re-run scripts/rev-harness-adopter-setup.sh resume'
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --json) JSON_OUTPUT=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --strict) STRICT=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'rev-harness-repair: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

doctor_args=(--quick)
[[ "$STRICT" == true ]] && doctor_args+=(--strict)

set +e
doctor_out="$(bash "$SCRIPT_DIR/harness-doctor.sh" "${doctor_args[@]}" 2>&1)"
doctor_exit=$?
set -e

if [[ "$doctor_exit" -eq 0 ]]; then
  suggestion="doctor: healthy, no repair needed"
else
  suggestion="$(suggestion_for "$doctor_out")"
fi

if [[ "$JSON_OUTPUT" == true ]]; then
  printf '{"schema":"rev-harness-repair/v1","doctor_exit":%s,"suggestion":"%s","ts":"%s"}\n' \
    "$doctor_exit" "$(json_escape "$suggestion")" "$(now_iso)"
else
  [[ "$VERBOSE" == true ]] && printf '%s\n\n' "$doctor_out"
  printf '%s\n' "$suggestion"
fi

exit 0
