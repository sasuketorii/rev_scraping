#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEMA_VERSION="rev-harness-cross-family-live-smoke-preflight/v1"

REPO_ROOT="$PROJECT_ROOT"
WORKSPACE_INPUT=""
ARTIFACT_ROOT_INPUT=""
CODEX_CLI_INPUT=""
CLAUDE_CLI_INPUT=""
REQUIRE_CLI=false
JSON=false

violations=()
notes=()

usage() {
  cat <<'EOF'
Usage:
  scripts/cross-family-live-smoke-preflight.sh check [options]

Read-only preflight that reports whether a cross-family Codex / Opus live
smoke is safe to attempt. This script never starts Codex, Claude, Opus,
app-server, or any model process. It does not establish a live conversation
and never asserts that one took place. completion_claim_allowed is always
false and live_execution_enabled is always false.

Options:
  --workspace <path>         Workspace path to validate. Must be under
                             workspace/<task>.
  --artifact-root <path>     Orchestration artifact root to validate. Must
                             be under .claude/tmp/<task>.
  --codex-cli <path>         Explicit codex CLI path (validated; not invoked).
  --claude-cli <path>        Explicit claude CLI path (validated; not invoked).
  --require-cli              Treat missing Codex / Claude CLI as BLOCK.
  --repo-root <path>         Repository root used for path validation.
                             Defaults to the script's project root.
  --json                     Emit a JSON preflight report.
  -h, --help                 Show this help.

Rejected (always BLOCK):
  --execute, --live, --run-live  Any flag that would imply live model
                                  execution from this preflight.
EOF
}

die() {
  printf 'cross-family-live-smoke-preflight: %s\n' "$*" >&2
  exit 2
}

add_violation() {
  violations+=("$1")
}

add_note() {
  notes+=("$1")
}

json_array_from() {
  local args=("$@")
  if [[ "${#args[@]}" -eq 0 ]]; then
    printf '[]'
    return 0
  fi
  jq -cn '$ARGS.positional' --args -- "${args[@]}"
}

validate_relative_path_under() {
  local label="$1"
  local prefix="$2"
  local path="$3"

  case "$path" in
    "")
      return 0
      ;;
    /*)
      add_violation "$label must be a relative path under $prefix: $path"
      return 1
      ;;
  esac

  case "$path" in
    *"/../"*|"../"*|*"/.."|"..")
      add_violation "$label must not contain parent traversal segments: $path"
      return 1
      ;;
  esac

  case "$path" in
    "$prefix"/*) ;;
    *)
      add_violation "$label must be under $prefix/<task>: $path"
      return 1
      ;;
  esac

  return 0
}

reject_symlink_components() {
  local label="$1"
  local rel="$2"

  [[ -n "$rel" ]] || return 0

  local accum="$REPO_ROOT"
  local IFS_BACKUP="${IFS-}"
  local parts=()
  IFS=/ read -r -a parts <<<"$rel"
  IFS="$IFS_BACKUP"

  local part
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    accum="$accum/$part"
    if [[ -L "$accum" ]]; then
      add_violation "$label contains symlink path component: $accum"
      return 1
    fi
  done
  return 0
}

resolve_cli_path() {
  local explicit="$1"
  local fallback_name="$2"

  if [[ -n "$explicit" ]]; then
    if [[ -f "$explicit" && -x "$explicit" && ! -L "$explicit" ]]; then
      printf '%s' "$explicit"
    else
      printf ''
    fi
    return 0
  fi

  local resolved=""
  resolved="$(command -v "$fallback_name" 2>/dev/null || true)"
  if [[ -n "$resolved" && -x "$resolved" && ! -L "$resolved" ]]; then
    printf '%s' "$resolved"
  else
    printf ''
  fi
}

check_harness_dependencies() {
  local deps=(
    "scripts/subscription-auth-guard.sh"
    "scripts/rev-harness-lease-guard.sh"
    "scripts/cross-family-live-smoke-preflight.sh"
  )
  local rel
  for rel in "${deps[@]}"; do
    local abs="$REPO_ROOT/$rel"
    if [[ ! -f "$abs" ]]; then
      add_violation "harness dependency missing: $rel"
    elif [[ -L "$abs" ]]; then
      add_violation "harness dependency must not be a symlink: $rel"
    fi
  done
}

emit_report() {
  local status="$1"
  local codex_resolved="$2"
  local claude_resolved="$3"
  local require_cli_json="false"
  local live_flag_json="false"
  local completion_flag_json="false"
  local codex_available_json="false"
  local claude_available_json="false"

  [[ "$REQUIRE_CLI" == true ]] && require_cli_json="true"
  [[ -n "$codex_resolved" ]] && codex_available_json="true"
  [[ -n "$claude_resolved" ]] && claude_available_json="true"

  if [[ "$JSON" == true ]]; then
    local violations_json notes_json
    violations_json="$(json_array_from "${violations[@]}")"
    notes_json="$(json_array_from "${notes[@]}")"

    jq -cn \
      --arg schema_version "$SCHEMA_VERSION" \
      --arg status "$status" \
      --argjson live_execution_enabled "$live_flag_json" \
      --argjson completion_claim_allowed "$completion_flag_json" \
      --arg repo_root "$REPO_ROOT" \
      --arg workspace "$WORKSPACE_INPUT" \
      --arg artifact_root "$ARTIFACT_ROOT_INPUT" \
      --argjson require_cli "$require_cli_json" \
      --arg codex_cli_requested "$CODEX_CLI_INPUT" \
      --arg codex_cli_resolved "$codex_resolved" \
      --argjson codex_cli_available "$codex_available_json" \
      --arg claude_cli_requested "$CLAUDE_CLI_INPUT" \
      --arg claude_cli_resolved "$claude_resolved" \
      --argjson claude_cli_available "$claude_available_json" \
      --argjson violations "$violations_json" \
      --argjson notes "$notes_json" \
      '{
        schema_version: $schema_version,
        status: $status,
        live_execution_enabled: $live_execution_enabled,
        completion_claim_allowed: $completion_claim_allowed,
        repo_root: $repo_root,
        workspace: $workspace,
        artifact_root: $artifact_root,
        require_cli: $require_cli,
        codex_cli: {
          requested_path: $codex_cli_requested,
          resolved_path: $codex_cli_resolved,
          available: $codex_cli_available
        },
        claude_cli: {
          requested_path: $claude_cli_requested,
          resolved_path: $claude_cli_resolved,
          available: $claude_cli_available
        },
        violations: $violations,
        notes: $notes
      }'
    return 0
  fi

  printf 'schema_version: %s\n' "$SCHEMA_VERSION"
  printf 'status: %s\n' "$status"
  printf 'live_execution_enabled: false\n'
  printf 'completion_claim_allowed: false\n'
  printf 'repo_root: %s\n' "$REPO_ROOT"
  printf 'workspace: %s\n' "${WORKSPACE_INPUT:-<unset>}"
  printf 'artifact_root: %s\n' "${ARTIFACT_ROOT_INPUT:-<unset>}"
  printf 'require_cli: %s\n' "$REQUIRE_CLI"
  printf 'codex_cli.requested_path: %s\n' "${CODEX_CLI_INPUT:-<unset>}"
  printf 'codex_cli.resolved_path: %s\n' "${codex_resolved:-<none>}"
  printf 'codex_cli.available: %s\n' "$([[ -n "$codex_resolved" ]] && printf 'true' || printf 'false')"
  printf 'claude_cli.requested_path: %s\n' "${CLAUDE_CLI_INPUT:-<unset>}"
  printf 'claude_cli.resolved_path: %s\n' "${claude_resolved:-<none>}"
  printf 'claude_cli.available: %s\n' "$([[ -n "$claude_resolved" ]] && printf 'true' || printf 'false')"

  if [[ "${#violations[@]}" -gt 0 ]]; then
    printf 'violations:\n'
    printf -- '- %s\n' "${violations[@]}"
  fi
  if [[ "${#notes[@]}" -gt 0 ]]; then
    printf 'notes:\n'
    printf -- '- %s\n' "${notes[@]}"
  fi
}

command_arg="${1:-check}"
case "$command_arg" in
  check)
    shift
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    if [[ "$command_arg" == --* ]]; then
      :
    else
      die "unknown command: $command_arg"
    fi
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      [[ $# -ge 2 ]] || die "--workspace requires a value"
      WORKSPACE_INPUT="$2"
      shift 2
      ;;
    --workspace=*)
      WORKSPACE_INPUT="${1#--workspace=}"
      shift
      ;;
    --artifact-root)
      [[ $# -ge 2 ]] || die "--artifact-root requires a value"
      ARTIFACT_ROOT_INPUT="$2"
      shift 2
      ;;
    --artifact-root=*)
      ARTIFACT_ROOT_INPUT="${1#--artifact-root=}"
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
    --require-cli)
      REQUIRE_CLI=true
      shift
      ;;
    --repo-root)
      [[ $# -ge 2 ]] || die "--repo-root requires a value"
      REPO_ROOT="$2"
      shift 2
      ;;
    --repo-root=*)
      REPO_ROOT="${1#--repo-root=}"
      shift
      ;;
    --json)
      JSON=true
      shift
      ;;
    --execute|--live|--run-live)
      add_violation "live execution flag rejected; this preflight never starts a model process: $1"
      shift
      ;;
    --execute=*|--live=*|--run-live=*)
      add_violation "live execution flag rejected; this preflight never starts a model process: ${1%%=*}"
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

if [[ ! -d "$REPO_ROOT" ]]; then
  add_violation "repo_root is not a directory: $REPO_ROOT"
elif [[ -L "$REPO_ROOT" ]]; then
  add_violation "repo_root must not be a symlink: $REPO_ROOT"
fi

check_harness_dependencies

if [[ -n "$WORKSPACE_INPUT" ]]; then
  if validate_relative_path_under "workspace" "workspace" "$WORKSPACE_INPUT"; then
    reject_symlink_components "workspace" "$WORKSPACE_INPUT" || true
  fi
fi

if [[ -n "$ARTIFACT_ROOT_INPUT" ]]; then
  if validate_relative_path_under "artifact_root" ".claude/tmp" "$ARTIFACT_ROOT_INPUT"; then
    reject_symlink_components "artifact_root" "$ARTIFACT_ROOT_INPUT" || true
  fi
fi

codex_resolved="$(resolve_cli_path "$CODEX_CLI_INPUT" "codex")"
claude_resolved="$(resolve_cli_path "$CLAUDE_CLI_INPUT" "claude")"

if [[ "$REQUIRE_CLI" == true ]]; then
  if [[ -z "$codex_resolved" ]]; then
    if [[ -n "$CODEX_CLI_INPUT" ]]; then
      add_violation "--require-cli: codex CLI path is not an executable file: $CODEX_CLI_INPUT"
    else
      add_violation "--require-cli: codex CLI not found on PATH"
    fi
  fi
  if [[ -z "$claude_resolved" ]]; then
    if [[ -n "$CLAUDE_CLI_INPUT" ]]; then
      add_violation "--require-cli: claude CLI path is not an executable file: $CLAUDE_CLI_INPUT"
    else
      add_violation "--require-cli: claude CLI not found on PATH"
    fi
  fi
else
  if [[ -z "$codex_resolved" ]]; then
    add_note "codex CLI not detected; --require-cli would block. This preflight does not start codex."
  fi
  if [[ -z "$claude_resolved" ]]; then
    add_note "claude CLI not detected; --require-cli would block. This preflight does not start claude."
  fi
fi

add_note "this preflight is not a live Codex/Claude/Opus conversation proof"

if [[ "${#violations[@]}" -gt 0 ]]; then
  emit_report "BLOCK" "$codex_resolved" "$claude_resolved"
  exit 1
fi

emit_report "PASS" "$codex_resolved" "$claude_resolved"
