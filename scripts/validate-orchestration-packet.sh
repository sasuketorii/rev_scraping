#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
POLICY_LIB="$REPO_ROOT/.claude/commands/lib/orchestration_policy.sh"

# shellcheck source=.claude/commands/lib/orchestration_policy.sh
# shellcheck disable=SC1091
source "$POLICY_LIB"

fatal() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  validate-orchestration-packet.sh compile --output PATH [--manifest PATH]
  validate-orchestration-packet.sh validate \
    --bundle PATH \
    --plan PATH \
    --sow PATH \
    --ledger PATH \
    --coder-prompt PATH \
    --reviewer-prompt PATH \
    --coder-output-stub PATH \
    --reviewer-output-stub PATH \
    --baseline-freeze PATH \
    --task-id ID \
    [--expected-accepted-slice SLICE] \
    [--expected-active-slice SLICE]
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
  compile)
    output_path=""
    manifest_path=".agent/registry/policy_sources.json"

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output_path="${2:-}"
          shift 2
          ;;
        --manifest)
          manifest_path="${2:-}"
          shift 2
          ;;
        *)
          fatal "unknown compile argument: $1"
          ;;
      esac
    done

    [[ -n "$output_path" ]] || fatal "compile requires --output"
    orchestration_policy_compile_bundle "$output_path" "$manifest_path" >/dev/null
    printf 'PASS: validate-orchestration-packet compile\n'
    ;;
  validate)
    bundle_path=""
    plan_path=""
    sow_path=""
    ledger_path=""
    coder_prompt_path=""
    reviewer_prompt_path=""
    coder_output_stub_path=""
    reviewer_output_stub_path=""
    baseline_freeze_path=""
    task_id=""
    expected_accepted_slice=""
    expected_active_slice=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --bundle) bundle_path="${2:-}"; shift 2 ;;
        --plan) plan_path="${2:-}"; shift 2 ;;
        --sow) sow_path="${2:-}"; shift 2 ;;
        --ledger) ledger_path="${2:-}"; shift 2 ;;
        --coder-prompt) coder_prompt_path="${2:-}"; shift 2 ;;
        --reviewer-prompt) reviewer_prompt_path="${2:-}"; shift 2 ;;
        --coder-output-stub) coder_output_stub_path="${2:-}"; shift 2 ;;
        --reviewer-output-stub) reviewer_output_stub_path="${2:-}"; shift 2 ;;
        --baseline-freeze) baseline_freeze_path="${2:-}"; shift 2 ;;
        --task-id) task_id="${2:-}"; shift 2 ;;
        --expected-accepted-slice) expected_accepted_slice="${2:-}"; shift 2 ;;
        --expected-active-slice) expected_active_slice="${2:-}"; shift 2 ;;
        *)
          fatal "unknown validate argument: $1"
          ;;
      esac
    done

    orchestration_policy_validate_packet \
      "$bundle_path" \
      "$plan_path" \
      "$sow_path" \
      "$ledger_path" \
      "$coder_prompt_path" \
      "$reviewer_prompt_path" \
      "$coder_output_stub_path" \
      "$reviewer_output_stub_path" \
      "$baseline_freeze_path" \
      "$task_id" \
      "$expected_accepted_slice" \
      "$expected_active_slice"
    printf 'PASS: validate-orchestration-packet validate\n'
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    usage >&2
    fatal "unknown command: $cmd"
    ;;
esac
