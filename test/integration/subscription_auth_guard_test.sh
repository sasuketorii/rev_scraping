#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$PROJECT_ROOT/scripts/subscription-auth-guard.sh"
TMP_ROOT=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  /bin/rm -rf "${TMP_ROOT:-}" 2>/dev/null || true
}
trap cleanup EXIT

run_clean_env() {
  env -i PATH="$PATH" HOME="$TMP_ROOT/home" "$@"
}

assert_pass() {
  local output=""
  if ! output="$(run_clean_env "$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "expected PASS: $*"
  fi
  printf '%s\n' "$output"
}

assert_block() {
  local output=""
  if output="$(run_clean_env "$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "expected BLOCK: $*"
  fi
  printf '%s\n' "$output"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/subscription-auth-guard-test.XXXXXX")"
mkdir -p "$TMP_ROOT/home/.claude"

clean_json="$(assert_pass bash "$GUARD" check --json)"
printf '%s\n' "$clean_json" | jq -e '.status == "PASS" and .api_fallback_allowed == false and (.violations | length == 0)' >/dev/null \
  || fail "clean env JSON should pass"

anthropic_output="$(env -i PATH="$PATH" HOME="$TMP_ROOT/home" ANTHROPIC_API_KEY="secret" bash "$GUARD" check --provider claude --json 2>&1 || true)"
printf '%s\n' "$anthropic_output" | jq -e '.status == "BLOCK" and any(.violations[]; contains("ANTHROPIC_API_KEY"))' >/dev/null \
  || fail "ANTHROPIC_API_KEY should block"

openai_output="$(env -i PATH="$PATH" HOME="$TMP_ROOT/home" OPENAI_API_KEY="secret" bash "$GUARD" check --provider codex --json 2>&1 || true)"
printf '%s\n' "$openai_output" | jq -e '.status == "BLOCK" and any(.violations[]; contains("OPENAI_API_KEY"))' >/dev/null \
  || fail "OPENAI_API_KEY should block"

codex_output="$(env -i PATH="$PATH" HOME="$TMP_ROOT/home" CODEX_API_KEY="secret" bash "$GUARD" check --provider codex --json 2>&1 || true)"
printf '%s\n' "$codex_output" | jq -e '.status == "BLOCK" and any(.violations[]; contains("CODEX_API_KEY"))' >/dev/null \
  || fail "CODEX_API_KEY should block"

settings="$TMP_ROOT/settings.json"
printf '{"apiKeyHelper":"security find-generic-password"}\n' > "$settings"
settings_output="$(assert_block bash "$GUARD" check --provider claude --settings "$settings" --json)"
printf '%s\n' "$settings_output" | jq -e '.status == "BLOCK" and any(.violations[]; contains("apiKeyHelper"))' >/dev/null \
  || fail "apiKeyHelper settings should block"

oauth_json="$(env -i PATH="$PATH" HOME="$TMP_ROOT/home" CLAUDE_CODE_OAUTH_TOKEN="subscription-oauth" bash "$GUARD" check --provider claude --json)"
printf '%s\n' "$oauth_json" | jq -e '.status == "PASS" and any(.notes[]; contains("CLAUDE_CODE_OAUTH_TOKEN"))' >/dev/null \
  || fail "CLAUDE_CODE_OAUTH_TOKEN should be allowed with note"

printf 'subscription_auth_guard_test: PASS\n'
