#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="$REPO_ROOT/.claude/commands/lib"
RESOLVER="$REPO_ROOT/scripts/resolve-semantic-project-id.sh"
LAUNCHER="$REPO_ROOT/scripts/launch-semantic-mcp.sh"
INIT_PROJECT="$REPO_ROOT/scripts/init-project.sh"
SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"
TEST_PROMPT_DIR=""
TEST_CODER_OUTPUT=""
TEST_TMPDIR=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
}

assert_fails() {
  if "$@"; then
    fail "command unexpectedly succeeded: $*"
  fi
  return 0
}

run_resolver() {
  local repo_root="$1"
  local resolver="$RESOLVER"
  shift
  if [[ -x "$repo_root/scripts/resolve-semantic-project-id.sh" ]]; then
    resolver="$repo_root/scripts/resolve-semantic-project-id.sh"
  fi
  bash "$resolver" --repo-root "$repo_root" "$@"
}

test_settings_launch_path() {
  local command=""
  command="$(jq -r '.mcpServers.semantic.command' "$SETTINGS_FILE")"
  [[ "$command" == "./scripts/launch-semantic-mcp.sh" ]] || fail "semantic MCP command mismatch: $command"
}

test_resolver_success_and_failure() {
  local tmprepo="$1/resolver"
  local tmprepo_real=""
  mkdir -p "$tmprepo/.agent" "$tmprepo/.shared" "$tmprepo/scripts"
  tmprepo_real="$(cd "$tmprepo" && pwd -P)"
  cp "$REPO_ROOT/scripts/project-id.sh" "$tmprepo/scripts/project-id.sh"
  cp "$RESOLVER" "$tmprepo/scripts/resolve-semantic-project-id.sh"
  chmod +x "$tmprepo/scripts/project-id.sh" "$tmprepo/scripts/resolve-semantic-project-id.sh"

  assert_fails run_resolver "$tmprepo" --print

  printf 'valid-proj_01\n' > "$tmprepo/.shared/project_id"
  [[ "$(run_resolver "$tmprepo" --print)" == "valid-proj_01" ]] || fail "resolver did not return valid project_id"
  [[ "$(run_resolver "$tmprepo" --path)" == "$tmprepo_real/.shared/project_id" ]] || fail "resolver path mismatch"
  jq -e '.classification == "aligned"' < <(run_resolver "$tmprepo" --health) >/dev/null \
    || fail "resolver health should report aligned when only canonical project_id exists"

  printf 'legacy-other\n' > "$tmprepo/.agent/project_id"
  jq -e '.classification == "warn-drift"' < <(run_resolver "$tmprepo" --health) >/dev/null \
    || fail "resolver health should warn when legacy and canonical project_id drift"

  printf '\n' > "$tmprepo/.shared/project_id"
  assert_fails run_resolver "$tmprepo" --print

  printf 'bad value\n' > "$tmprepo/.shared/project_id"
  assert_fails run_resolver "$tmprepo" --print

  printf 'agent_base\n' > "$tmprepo/.shared/project_id"
  assert_fails run_resolver "$tmprepo" --print
  assert_fails run_resolver "$tmprepo" --bootstrap demo
  [[ "$(tr -d '\r\n' < "$tmprepo/.shared/project_id")" == "agent_base" ]] || fail "invalid artifact was overwritten"
}

test_init_project_bootstrap() {
  local tmprepo="$1/init"
  mkdir -p "$tmprepo/scripts"

  cp "$INIT_PROJECT" "$tmprepo/scripts/init-project.sh"
  cp "$REPO_ROOT/scripts/project-id.sh" "$tmprepo/scripts/project-id.sh"
  cp "$RESOLVER" "$tmprepo/scripts/resolve-semantic-project-id.sh"
  chmod +x "$tmprepo/scripts/init-project.sh" "$tmprepo/scripts/project-id.sh" "$tmprepo/scripts/resolve-semantic-project-id.sh"

  bash "$tmprepo/scripts/init-project.sh" init-demo >/dev/null

  [[ -f "$tmprepo/.shared/project_id" ]] || fail "init-project did not create .shared/project_id"
  local first_id=""
  first_id="$(tr -d '\r\n' < "$tmprepo/.shared/project_id")"
  [[ "$first_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fail "init-project created invalid project_id: $first_id"
  [[ "$first_id" != "agent_base" ]] || fail "init-project created forbidden literal project_id"

  printf 'preexisting-fixed-id\n' > "$tmprepo/.shared/project_id"
  bash "$tmprepo/scripts/init-project.sh" other-seed >/dev/null
  [[ "$(tr -d '\r\n' < "$tmprepo/.shared/project_id")" == "preexisting-fixed-id" ]] || fail "init-project overwrote existing project_id"
}

test_launcher_exec_path() {
  local tmprepo="$1/launcher"
  local entrypoint="$tmprepo/entry.js"
  local launcher_stderr="$tmprepo/launcher.stderr"

  mkdir -p "$tmprepo/scripts" "$tmprepo/.shared"
  cp "$REPO_ROOT/scripts/project-id.sh" "$tmprepo/scripts/project-id.sh"
  cp "$RESOLVER" "$tmprepo/scripts/resolve-semantic-project-id.sh"
  cp "$REPO_ROOT/scripts/semantic-review-queue.sh" "$tmprepo/scripts/semantic-review-queue.sh"
  cp "$LAUNCHER" "$tmprepo/scripts/launch-semantic-mcp.sh"
  chmod +x \
    "$tmprepo/scripts/project-id.sh" \
    "$tmprepo/scripts/resolve-semantic-project-id.sh" \
    "$tmprepo/scripts/semantic-review-queue.sh" \
    "$tmprepo/scripts/launch-semantic-mcp.sh"

  printf 'launch-proj-01\n' > "$tmprepo/.shared/project_id"
  : > "$entrypoint"

  if SEMANTIC_MCP_ENTRYPOINT="$entrypoint" \
    bash "$tmprepo/scripts/launch-semantic-mcp.sh" --stdio --trace >/dev/null 2>"$launcher_stderr"; then
    fail "launcher should reject entrypoint override env"
  fi
  grep -Fq "SEMANTIC_MCP_ENTRYPOINT override is forbidden" "$launcher_stderr" \
    || fail "launcher did not report forbidden entrypoint override"
}

test_reviewer_state_contraction() {
  local tmpdir="$1/reviewer"
  local state_dir="$tmpdir/state"
  local prompt_dir="$tmpdir/prompts"
  local output_dir="$tmpdir/out"
  local coder_output="$tmpdir/coder_output.md"
  local reviews_file="$tmpdir/reviews.md"
  local state_file=""

  mkdir -p "$state_dir" "$prompt_dir" "$output_dir"
  printf '# reviewer prompt\n' > "$prompt_dir/reviewer_safety.md"
  printf 'coder output\n' > "$coder_output"
  printf '# aggregated reviews\n' > "$reviews_file"
  TEST_PROMPT_DIR="$prompt_dir"
  TEST_CODER_OUTPUT="$coder_output"

  # shellcheck source=/dev/null
  source "$LIB_DIR/utils.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/state.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/reviewer.sh"

  state_file="$(state_init "$tmpdir/plan.md" "reviewer_state_contraction" "$state_dir")"
  state_load "$state_file"
  state_upsert_phase "impl" "2"

  _ensure_codex_wrapper() { return 0; }
  _get_prompt_dir() { printf '%s\n' "$TEST_PROMPT_DIR"; }
  _reviewer_build_out_of_window_dependency_alert() { printf '%s\n' ""; }
  _reviewer_build_packet() { printf '%s\n' "$TEST_CODER_OUTPUT"; }
  reviewer_run_single() {
    local _reviewer_name="$1"
    local _coder_output="$2"
    local output_file="$3"
    local _timeout_secs="${4:-}"
    printf 'review ok\n' > "$output_file"
  }

  reviewer_run_parallel "safety" "$coder_output" "$output_dir" 5 "impl" "$state_dir" "impl" || fail "reviewer_run_parallel failed after reviewer session APIs were removed"
  reviewer_record_to_state "impl" "1" "$reviews_file" || fail "reviewer_record_to_state should no-op successfully"

  jq -e '.phases | length == 1 and .[0].name == "impl"' "$state_file" >/dev/null || fail "state phase setup mismatch"
  if jq -e '.phases[] | has("reviews") or has("fixes")' "$state_file" >/dev/null; then
    fail "live state.json still contains durable reviewer payload fields"
  fi
  if jq -e '.. | objects | select(has("session_id"))' "$state_file" >/dev/null; then
    fail "live state.json still contains reviewer session metadata"
  fi

  return 0
}

main() {
  require_cmd jq

  TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/project_id_state_contraction.XXXXXX")"
  trap 'rm -rf "$TEST_TMPDIR" || true' EXIT

  test_settings_launch_path
  test_resolver_success_and_failure "$TEST_TMPDIR"
  test_init_project_bootstrap "$TEST_TMPDIR"
  test_launcher_exec_path "$TEST_TMPDIR"
  test_reviewer_state_contraction "$TEST_TMPDIR"

  printf 'PASS: project_id_state_contraction\n'
  return 0
}

main "$@"
exit 0
