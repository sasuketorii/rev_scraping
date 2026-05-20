#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEMA_VERSION="rev-harness-cross-family-live-artifact-smoke/v1"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)_$$"
ARTIFACT_ROOT=".claude/tmp/cross-family-live-smoke-$RUN_ID"
WORKSPACE_ROOT="workspace/cross-family-live-smoke-$RUN_ID"
JSON=false
CODEX_CLI_INPUT=""
CLAUDE_CLI_INPUT=""
CODEX_WRAPPER="${REV_HARNESS_CODEX_WRAPPER:-$PROJECT_ROOT/scripts/codex-wrapper.sh}"
CLAUDE_WRAPPER="${REV_HARNESS_CLAUDE_WRAPPER:-$PROJECT_ROOT/scripts/claude-wrapper.sh}"
COMMAND_TIMEOUT_SECS="${REV_HARNESS_LIVE_SMOKE_COMMAND_TIMEOUT_SECS:-900}"
PROCESS_SNAPSHOT_FILE="${REV_HARNESS_PROCESS_SNAPSHOT_FILE:-}"

violations=()

usage() {
  cat <<'EOF'
Usage:
  scripts/cross-family-live-artifact-smoke.sh [options]

Runs one short-lived subscription-authenticated Codex worker -> Opus reviewer
artifact handoff and validates packet / lease closeout. This is opt-in and
intended for manual or workflow_dispatch use, not default CI.

Options:
  --artifact-root <path>  Artifact root under .claude/tmp/<task>.
  --workspace <path>      Workspace path under workspace/<task>.
  --codex-cli <path>      Explicit non-symlink Codex CLI executable.
  --claude-cli <path>     Explicit non-symlink Claude CLI executable.
  --json                  Emit a JSON report.
  -h, --help              Show this help.

Environment overrides for tests:
  REV_HARNESS_CODEX_WRAPPER
  REV_HARNESS_CLAUDE_WRAPPER
  REV_HARNESS_LIVE_SMOKE_COMMAND_TIMEOUT_SECS
  REV_HARNESS_PROCESS_SNAPSHOT_FILE
EOF
}

die() {
  printf 'cross-family-live-artifact-smoke: %s\n' "$*" >&2
  exit 2
}

add_violation() {
  violations+=("$1")
}

json_array_from() {
  local args=("$@")
  if [[ "${#args[@]}" -eq 0 ]]; then
    printf '[]'
    return 0
  fi
  jq -cn '$ARGS.positional' --args -- "${args[@]}"
}

resolve_executable_realpath() {
  local requested="$1"
  local fallback="$2"
  local candidate=""

  if [[ -n "$requested" ]]; then
    candidate="$requested"
  else
    candidate="$(command -v "$fallback" 2>/dev/null || true)"
  fi
  [[ -n "$candidate" ]] || return 1

  if command -v realpath >/dev/null 2>&1; then
    candidate="$(realpath "$candidate" 2>/dev/null || printf '%s' "$candidate")"
  elif command -v python3 >/dev/null 2>&1; then
    candidate="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$candidate" 2>/dev/null || printf '%s' "$candidate")"
  fi

  [[ -f "$candidate" && -x "$candidate" && ! -L "$candidate" ]] || return 1
  printf '%s\n' "$candidate"
}

validate_relative_subpath() {
  local label="$1"
  local prefix="$2"
  local input="$3"
  local current="$PROJECT_ROOT"
  local part=""
  local -a parts=()

  case "$input" in
    /*)
      add_violation "$label must be a relative path under $prefix: $input"
      return 1
      ;;
    "$prefix"/*) ;;
    *)
      add_violation "$label must stay under $prefix: $input"
      return 1
      ;;
  esac

  case "$input" in
    *"/../"*|*"/./"*|*/..|*/.|*//*)
      add_violation "$label contains unsafe path components: $input"
      return 1
      ;;
  esac

  IFS='/' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    if [[ -z "$part" || "$part" == "." || "$part" == ".." ]]; then
      add_violation "$label contains unsafe path component: $input"
      return 1
    fi
    current="$current/$part"
    if [[ -L "$current" ]]; then
      add_violation "$label contains symlink component: $current"
      return 1
    fi
  done
}

run_bounded() {
  local timeout_secs="$1"
  local input_path="$2"
  local stdout_path="$3"
  local stderr_path="$4"
  shift 4
  local pid=""
  local pgid=""
  local elapsed=0
  local status=0
  local command_runner=("$@")

  if [[ ! "$timeout_secs" =~ ^[1-9][0-9]*$ ]]; then
    add_violation "invalid live smoke command timeout: $timeout_secs"
    return 2
  fi

  if command -v perl >/dev/null 2>&1; then
    perl -e 'use POSIX qw(setsid); setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!";' \
      -- "${command_runner[@]}" < "$input_path" > "$stdout_path" 2> "$stderr_path" &
  else
    "${command_runner[@]}" < "$input_path" > "$stdout_path" 2> "$stderr_path" &
  fi
  pid=$!
  pgid=$pid

  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed" -ge "$timeout_secs" ]]; then
      kill -TERM -- -"$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -KILL -- -"$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if wait "$pid"; then
    return 0
  fi
  status=$?
  return "$status"
}

capture_process_snapshot() {
  local output="$1"

  if [[ -n "$PROCESS_SNAPSHOT_FILE" ]]; then
    [[ -f "$PROCESS_SNAPSHOT_FILE" ]] || return 1
    cp "$PROCESS_SNAPSHOT_FILE" "$output"
    return 0
  fi

  ps -axo pid,ppid,pgid,stat,etime,command > "$output" 2>/dev/null
}

require_line() {
  local file="$1"
  local pattern="$2"
  local message="$3"

  if [[ -f "$file" ]] && grep -q "$pattern" "$file"; then
    return 0
  fi
  add_violation "$message"
}

emit_report() {
  local status="$1"
  local preflight_path="$2"
  local packet_path="$3"
  local lease_guard_path="$4"
  local residual_path="$5"
  local violations_json

  violations_json="$(json_array_from "${violations[@]}")"

  if [[ "$JSON" == true ]]; then
    jq -n \
      --arg schema_version "$SCHEMA_VERSION" \
      --arg status "$status" \
      --arg artifact_root "$ARTIFACT_ROOT" \
      --arg workspace "$WORKSPACE_ROOT" \
      --arg preflight "$preflight_path" \
      --arg packet "$packet_path" \
      --arg lease_guard "$lease_guard_path" \
      --arg residual_processes "$residual_path" \
      --argjson violations "$violations_json" \
      '{
        schema_version: $schema_version,
        status: $status,
        artifact_root: $artifact_root,
        workspace: $workspace,
        preflight: $preflight,
        packet: $packet,
        lease_guard: $lease_guard,
        residual_processes: $residual_processes,
        violations: $violations
      }'
    return 0
  fi

  printf 'schema_version: %s\n' "$SCHEMA_VERSION"
  printf 'status: %s\n' "$status"
  printf 'artifact_root: %s\n' "$ARTIFACT_ROOT"
  printf 'workspace: %s\n' "$WORKSPACE_ROOT"
  printf 'preflight: %s\n' "$preflight_path"
  printf 'packet: %s\n' "$packet_path"
  printf 'lease_guard: %s\n' "$lease_guard_path"
  printf 'residual_processes: %s\n' "$residual_path"
  if [[ "${#violations[@]}" -gt 0 ]]; then
    printf 'violations:\n'
    printf -- '- %s\n' "${violations[@]}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact-root)
      [[ $# -ge 2 ]] || die "--artifact-root requires a value"
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --artifact-root=*)
      ARTIFACT_ROOT="${1#--artifact-root=}"
      shift
      ;;
    --workspace)
      [[ $# -ge 2 ]] || die "--workspace requires a value"
      WORKSPACE_ROOT="$2"
      shift 2
      ;;
    --workspace=*)
      WORKSPACE_ROOT="${1#--workspace=}"
      shift
      ;;
    --codex-cli)
      [[ $# -ge 2 ]] || die "--codex-cli requires a value"
      CODEX_CLI_INPUT="$2"
      shift 2
      ;;
    --codex-cli=*)
      CODEX_CLI_INPUT="${1#--codex-cli=}"
      shift
      ;;
    --claude-cli)
      [[ $# -ge 2 ]] || die "--claude-cli requires a value"
      CLAUDE_CLI_INPUT="$2"
      shift 2
      ;;
    --claude-cli=*)
      CLAUDE_CLI_INPUT="${1#--claude-cli=}"
      shift
      ;;
    --json)
      JSON=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

preflight_path="$ARTIFACT_ROOT/preflight.json"
packet_path="$ARTIFACT_ROOT/packet.json"
leases_path="$ARTIFACT_ROOT/agent-leases.json"
lease_guard_path="$ARTIFACT_ROOT/lease-guard.json"
residual_path="$ARTIFACT_ROOT/residual-processes.txt"
codex_request="$ARTIFACT_ROOT/codex-worker-request.md"
codex_artifact="$ARTIFACT_ROOT/codex-worker-artifact.md"
codex_stdout="$ARTIFACT_ROOT/codex-worker-run.log"
codex_stderr="$ARTIFACT_ROOT/codex-worker-run.stderr"
opus_request="$ARTIFACT_ROOT/opus-reviewer-request.md"
opus_artifact="$ARTIFACT_ROOT/opus-reviewer-artifact.md"
opus_stdout="$ARTIFACT_ROOT/opus-reviewer-run.log"
opus_stderr="$ARTIFACT_ROOT/opus-reviewer-run.stderr"
codex_status=0
opus_status=0

validate_relative_subpath "artifact_root" ".claude/tmp" "$ARTIFACT_ROOT" || true
validate_relative_subpath "workspace" "workspace" "$WORKSPACE_ROOT" || true

if [[ "${#violations[@]}" -gt 0 ]]; then
  emit_report "BLOCK" "$preflight_path" "$packet_path" "$lease_guard_path" "$residual_path"
  exit 1
fi

mkdir -p "$PROJECT_ROOT/$ARTIFACT_ROOT" "$PROJECT_ROOT/$WORKSPACE_ROOT"

codex_cli="$(resolve_executable_realpath "$CODEX_CLI_INPUT" codex 2>/dev/null || true)"
claude_cli="$(resolve_executable_realpath "$CLAUDE_CLI_INPUT" claude 2>/dev/null || true)"

if [[ -z "$codex_cli" ]]; then
  add_violation "Codex CLI is missing, not executable, or resolves to a symlink"
fi
if [[ -z "$claude_cli" ]]; then
  add_violation "Claude CLI is missing, not executable, or resolves to a symlink"
fi
if [[ ! -x "$CODEX_WRAPPER" || -d "$CODEX_WRAPPER" ]]; then
  add_violation "Codex wrapper is not executable: $CODEX_WRAPPER"
fi
if [[ ! -x "$CLAUDE_WRAPPER" || -d "$CLAUDE_WRAPPER" ]]; then
  add_violation "Claude wrapper is not executable: $CLAUDE_WRAPPER"
fi

if [[ "${#violations[@]}" -eq 0 ]]; then
  if ! bash "$PROJECT_ROOT/scripts/subscription-auth-guard.sh" check --provider all --json > "$ARTIFACT_ROOT/subscription-auth.json"; then
    add_violation "subscription auth guard failed"
  fi
fi

if [[ "${#violations[@]}" -eq 0 ]]; then
  if ! bash "$PROJECT_ROOT/scripts/cross-family-live-smoke-preflight.sh" check \
      --json \
      --require-cli \
      --workspace "$WORKSPACE_ROOT" \
      --artifact-root "$ARTIFACT_ROOT" \
      --codex-cli "$codex_cli" \
      --claude-cli "$claude_cli" > "$preflight_path"; then
    add_violation "live smoke preflight failed"
  fi
fi

if [[ "${#violations[@]}" -gt 0 ]]; then
  emit_report "BLOCK" "$preflight_path" "$packet_path" "$lease_guard_path" "$residual_path"
  exit 1
fi

printf '%s\n' \
  'You are the Codex worker in a RevHarness cross-family live artifact smoke.' \
  '' \
  'Worker-to-worker communication is English. Do not modify tracked repository' \
  'source, docs, scripts, tests, or git state.' \
  '' \
  'Create exactly one worker artifact at:' \
  "\`$codex_artifact\`" \
  '' \
  'Required artifact content:' \
  '- provider: codex' \
  '- model_family: gpt' \
  '- role: coder' \
  '- status: completed' \
  '- task: tiny deterministic shell bug proposal' \
  '- proposed_fix: one concrete shell robustness improvement' \
  '- checks: at least two deterministic checks' \
  '- handoff_to: opus-reviewer' \
  > "$codex_request"

run_bounded "$COMMAND_TIMEOUT_SECS" "$codex_request" "$codex_stdout" "$codex_stderr" \
  "$CODEX_WRAPPER" --role coder --stdin || codex_status=$?
if [[ "$codex_status" -ne 0 ]]; then
  add_violation "Codex worker failed or timed out"
fi
if [[ ! -f "$codex_artifact" ]]; then
  add_violation "Codex worker failed or timed out"
fi

require_line "$codex_artifact" '^provider: codex$' "Codex artifact missing provider"
require_line "$codex_artifact" '^status: completed$' "Codex artifact missing completed status"
require_line "$codex_artifact" '^handoff_to: opus-reviewer$' "Codex artifact missing Opus handoff"

if [[ "${#violations[@]}" -eq 0 ]]; then
  printf '%s\n' \
    'You are the Opus reviewer in a RevHarness cross-family live artifact smoke.' \
    '' \
    'Review only this Codex worker artifact:' \
    "\`$codex_artifact\`" \
    '' \
    'Do not modify tracked repository source, docs, scripts, tests, or git state.' \
    '' \
    'Write exactly one reviewer artifact at:' \
    "\`$opus_artifact\`" \
    '' \
    'Required reviewer artifact content:' \
    '- provider: claude' \
    '- model_family: opus' \
    '- role: reviewer' \
    "- reviewed_artifact: \`$codex_artifact\`" \
    '- verdict: LGTM or REQUEST_CHANGES' \
    '- findings: none or compact actionable findings' \
    '- live_smoke_result: codex_artifact_received' \
    '- handoff_to: orchestrator' \
    > "$opus_request"

  run_bounded "$COMMAND_TIMEOUT_SECS" /dev/null "$opus_stdout" "$opus_stderr" \
    "$CLAUDE_WRAPPER" \
      --model opus \
      --effort low \
      --mode orchestrator-full \
      --allowed-tools Read,Write \
      --no-session-persistence \
      --timeout 600 \
      --input "$opus_request" \
      --output "$opus_stdout" || opus_status=$?
  if [[ "$opus_status" -ne 0 ]]; then
    add_violation "Opus reviewer failed or timed out"
  fi
fi

if [[ ! -f "$opus_artifact" ]]; then
  add_violation "Opus reviewer failed or timed out"
fi

require_line "$opus_artifact" '^provider: claude$' "Opus artifact missing provider"
require_line "$opus_artifact" '^verdict: LGTM$' "Opus artifact did not return LGTM"
require_line "$opus_artifact" '^live_smoke_result: codex_artifact_received$' "Opus artifact did not record Codex receipt"

if [[ "${#violations[@]}" -eq 0 ]]; then
  jq -n \
    --arg schema_version "rev-harness-cross-family-artifact-packet/v1" \
    --arg coordination_mode "artifact-only" \
    --argjson direct_long_lived_chat false \
    --arg codex_artifact "$codex_artifact" \
    --arg opus_artifact "$opus_artifact" \
    --arg preflight "$preflight_path" \
    '{
      schema_version: $schema_version,
      coordination_mode: $coordination_mode,
      direct_long_lived_chat: $direct_long_lived_chat,
      workers: [
        {
          provider: "codex",
          model: "gpt-5.5",
          role: "coder",
          status: "completed",
          artifact_path: $codex_artifact
        },
        {
          provider: "claude",
          model: "opus",
          role: "reviewer",
          verdict: "LGTM",
          artifact_path: $opus_artifact
        }
      ],
      orchestrator: {
        artifact_path: $preflight,
        acceptance: "PASS"
      },
      required_checks: [
        "subscription_auth_guard",
        "cross_family_live_smoke_preflight",
        "artifact_packet_schema",
        "lease_guard_validate"
      ]
    }' > "$packet_path"

  jq -n \
    --arg codex_artifact "$codex_artifact" \
    --arg opus_artifact "$opus_artifact" \
    '{
      schema_version: "rev-harness-agent-lease-registry/v1",
      leases: [
        {
          lease_id: "live-smoke-codex-coder",
          provider: "codex",
          model: "gpt-5.5",
          purpose: "live cross-family smoke coder artifact",
          state: "completed",
          artifact_paths: [$codex_artifact]
        },
        {
          lease_id: "live-smoke-opus-reviewer",
          provider: "claude",
          model: "opus",
          purpose: "live cross-family smoke reviewer artifact",
          state: "completed",
          artifact_paths: [$opus_artifact]
        }
      ]
    }' > "$leases_path"

  bash "$PROJECT_ROOT/scripts/rev-harness-lease-guard.sh" validate \
    --file "$leases_path" \
    --json > "$lease_guard_path" || add_violation "lease guard failed"
fi

if [[ -f "$lease_guard_path" ]]; then
  jq -e '.status == "PASS" and .completion_allowed == true and (.violations | length) == 0' "$lease_guard_path" >/dev/null \
    || add_violation "lease guard invariant failed"
else
  add_violation "lease guard invariant failed"
fi
if [[ -f "$packet_path" ]]; then
  jq -e '.workers[0].status == "completed" and .workers[1].verdict == "LGTM" and .direct_long_lived_chat == false and .orchestrator.acceptance == "PASS"' "$packet_path" >/dev/null \
    || add_violation "packet invariant failed"
else
  add_violation "packet invariant failed"
fi

if capture_process_snapshot "$ARTIFACT_ROOT/process-snapshot.txt"; then
  awk '
    /codex-wrapper.sh --role coder|claude-wrapper.sh --model opus|codex exec|claude -p|claude --print|claude\.exe --print/ {
      if ($0 !~ /awk / && $0 !~ /process-snapshot/) {
        print
      }
    }
  ' "$ARTIFACT_ROOT/process-snapshot.txt" > "$residual_path"
  if [[ -s "$residual_path" ]]; then
    add_violation "residual Codex/Opus/release-gate worker processes remain"
  fi
else
  add_violation "residual process scan failed"
fi

if [[ "${#violations[@]}" -gt 0 ]]; then
  emit_report "BLOCK" "$preflight_path" "$packet_path" "$lease_guard_path" "$residual_path"
  exit 1
fi

emit_report "PASS" "$preflight_path" "$packet_path" "$lease_guard_path" "$residual_path"
