#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

provider="all"
json=false
settings_sources=()
violations=()
notes=()

usage() {
  cat <<'EOF'
Usage:
  scripts/subscription-auth-guard.sh check [--provider all|claude|codex] [--settings <file-or-json>] [--json]

Fails closed when orchestration would use API-key authentication instead of subscription credentials.

Blocked in subscription-only mode:
  Claude: ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, apiKeyHelper
  Codex:  OPENAI_API_KEY, CODEX_API_KEY

Allowed:
  Claude Code subscription OAuth, including CLAUDE_CODE_OAUTH_TOKEN when intentionally generated from a subscription login.
EOF
}

die() {
  printf 'subscription-auth-guard: %s\n' "$*" >&2
  exit 2
}

add_violation() {
  violations+=("$1")
}

add_note() {
  notes+=("$1")
}

json_array() {
  local item
  jq -cn '$ARGS.positional' --args "$@"
}

env_is_set() {
  local name="$1"
  [[ -n "${!name:-}" ]]
}

settings_has_api_key_helper() {
  local source="$1"
  local path=""
  local trimmed=""

  [[ -n "$source" ]] || return 1
  command -v jq >/dev/null 2>&1 || die "jq is required"

  trimmed="${source#"${source%%[![:space:]]*}"}"
  case "$trimmed" in
    \{*|\[*)
      printf '%s' "$source" | jq -e 'type == "object" and (.apiKeyHelper | type == "string" and length > 0)' >/dev/null 2>&1
      return $?
      ;;
  esac

  case "$source" in
    /*) path="$source" ;;
    *) path="$PROJECT_ROOT/$source" ;;
  esac

  [[ -f "$path" ]] || return 1
  jq -e 'type == "object" and (.apiKeyHelper | type == "string" and length > 0)' "$path" >/dev/null 2>&1
}

collect_default_settings_sources() {
  settings_sources+=("$PROJECT_ROOT/.claude/settings.json")
  if [[ -n "${HOME:-}" ]]; then
    settings_sources+=("$HOME/.claude/settings.json")
  fi
}

check_claude() {
  local source

  if env_is_set ANTHROPIC_API_KEY; then
    add_violation "ANTHROPIC_API_KEY is set; Claude Code non-interactive runs would use direct API-key auth."
  fi

  if env_is_set ANTHROPIC_AUTH_TOKEN; then
    add_violation "ANTHROPIC_AUTH_TOKEN is set; subscription-only orchestration must not carry Anthropic API auth tokens."
  fi

  if env_is_set CLAUDE_CODE_OAUTH_TOKEN; then
    add_note "CLAUDE_CODE_OAUTH_TOKEN is present; this is allowed only as Claude Code subscription OAuth, not API-key auth."
  fi

  for source in "${settings_sources[@]}"; do
    if settings_has_api_key_helper "$source"; then
      add_violation "apiKeyHelper is configured in Claude settings source: $source"
    fi
  done
}

check_codex() {
  if env_is_set OPENAI_API_KEY; then
    add_violation "OPENAI_API_KEY is set; Codex orchestration must use ChatGPT subscription auth, not OpenAI API-key auth."
  fi

  if env_is_set CODEX_API_KEY; then
    add_violation "CODEX_API_KEY is set; Codex orchestration must not use API-key auth."
  fi
}

emit_result() {
  local status="$1"
  local violations_json notes_json

  if [[ "$json" == true ]]; then
    violations_json="$(json_array "${violations[@]}")"
    notes_json="$(json_array "${notes[@]}")"
    jq -cn \
      --arg schema_version "rev-harness-subscription-auth-guard/v1" \
      --arg status "$status" \
      --arg provider "$provider" \
      --argjson violations "$violations_json" \
      --argjson notes "$notes_json" \
      '{
        schema_version: $schema_version,
        status: $status,
        provider: $provider,
        api_fallback_allowed: false,
        violations: $violations,
        notes: $notes
      }'
    return 0
  fi

  printf 'status: %s\n' "$status"
  printf 'api_fallback_allowed: false\n'
  if [[ "${#violations[@]}" -gt 0 ]]; then
    printf 'violations:\n'
    printf -- '- %s\n' "${violations[@]}"
  fi
  if [[ "${#notes[@]}" -gt 0 ]]; then
    printf 'notes:\n'
    printf -- '- %s\n' "${notes[@]}"
  fi
}

command="${1:-}"
shift || true

case "$command" in
  check) ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

collect_default_settings_sources

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      [[ $# -ge 2 ]] || die "--provider requires a value"
      provider="$2"
      shift 2
      ;;
    --provider=*)
      provider="${1#--provider=}"
      shift
      ;;
    --settings)
      [[ $# -ge 2 ]] || die "--settings requires a value"
      settings_sources+=("$2")
      shift 2
      ;;
    --settings=*)
      settings_sources+=("${1#--settings=}")
      shift
      ;;
    --json)
      json=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$provider" in
  all)
    check_claude
    check_codex
    ;;
  claude)
    check_claude
    ;;
  codex)
    check_codex
    ;;
  *)
    die "unknown provider: $provider"
    ;;
esac

if [[ "${#violations[@]}" -gt 0 ]]; then
  emit_result "BLOCK"
  exit 1
fi

emit_result "PASS"
