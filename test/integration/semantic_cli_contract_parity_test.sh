#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=""
RUST_WORKSPACE_ROOT=""

cleanup() {
  rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
}

load_trusted_runtime_env() {
  local binary_name="$1"
  local runtime_env=""

  runtime_env="$(
    cd "$REPO_ROOT" && \
    /bin/bash scripts/semantic-review-queue.sh __internal-runtime-env --binary "$binary_name" --repo-root "$REPO_ROOT"
  )"

  unset RUNTIME_BINARY RUNTIME_PATH RUNTIME_HOME
  eval "$runtime_env"

  [[ -n "${RUNTIME_BINARY:-}" ]] || fail "missing trusted runtime binary for $binary_name"
  [[ -n "${RUNTIME_PATH:-}" ]] || fail "missing trusted runtime PATH for $binary_name"
  [[ -n "${RUNTIME_HOME:-}" ]] || fail "missing trusted runtime HOME for $binary_name"
}

load_rust_workspace_root() {
  RUST_WORKSPACE_ROOT="$(
    cd "$REPO_ROOT" && \
    /bin/bash scripts/semantic-review-queue.sh __internal-rust-workspace-root --repo-root "$REPO_ROOT"
  )"

  [[ -n "$RUST_WORKSPACE_ROOT" ]] || fail "missing trusted rust workspace root"
  [[ -f "$RUST_WORKSPACE_ROOT/Cargo.toml" ]] || fail "trusted rust workspace manifest not found: $RUST_WORKSPACE_ROOT/Cargo.toml"
}

run_node_cli_capture() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2

  load_trusted_runtime_env node
  (
    cd "$REPO_ROOT"
    /usr/bin/env -i \
      "PATH=$RUNTIME_PATH" \
      "HOME=$RUNTIME_HOME" \
      "$RUNTIME_BINARY" \
      "$REPO_ROOT/scripts/semantic-mcp-server/dist/cli.js" \
      "$@"
  ) >"$stdout_file" 2>"$stderr_file"
}

run_rust_cli_capture() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2

  load_trusted_runtime_env cargo
  (
    cd "$REPO_ROOT"
    /usr/bin/env -i \
      "PATH=$RUNTIME_PATH" \
      "HOME=$RUNTIME_HOME" \
      "$RUNTIME_BINARY" \
      run --quiet --manifest-path "$RUST_WORKSPACE_ROOT/Cargo.toml" -p semantic-mcp -- \
      "$@"
  ) >"$stdout_file" 2>"$stderr_file"
}

assert_json_equals() {
  local left_file="$1"
  local right_file="$2"

  diff -u <(jq -S . "$left_file") <(jq -S . "$right_file") >/dev/null \
    || fail "JSON payloads differed: $left_file vs $right_file"
}

assert_trimmed_stderr_equals() {
  local expected="$1"
  local file_path="$2"
  local actual=""

  actual="$(<"$file_path")"
  actual="${actual%$'\n'}"
  [[ "$actual" == "$expected" ]] || fail "unexpected stderr in $file_path: $actual"
}

test_project_id_validate_trim_parity() {
  local node_out="$TMP_ROOT/node-project-id-trim.json"
  local node_err="$TMP_ROOT/node-project-id-trim.stderr"
  local rust_out="$TMP_ROOT/rust-project-id-trim.json"
  local rust_err="$TMP_ROOT/rust-project-id-trim.stderr"

  run_node_cli_capture "$node_out" "$node_err" project-id validate --value " demo "
  run_rust_cli_capture "$rust_out" "$rust_err" project-id validate --value " demo "

  jq -e '.ok == true and .project_id == "demo"' "$node_out" >/dev/null 2>&1 \
    || fail "node project-id validate did not normalize whitespace"
  jq -e '.ok == true and .project_id == "demo"' "$rust_out" >/dev/null 2>&1 \
    || fail "rust project-id validate did not normalize whitespace"
  [[ ! -s "$node_err" ]] || fail "node project-id validate emitted stderr unexpectedly"
  [[ ! -s "$rust_err" ]] || fail "rust project-id validate emitted stderr unexpectedly"
  assert_json_equals "$node_out" "$rust_out"
}

test_project_id_validate_rejects_agent_base_with_parity() {
  local node_out="$TMP_ROOT/node-project-id-agent-base.stdout"
  local node_err="$TMP_ROOT/node-project-id-agent-base.stderr"
  local rust_out="$TMP_ROOT/rust-project-id-agent-base.stdout"
  local rust_err="$TMP_ROOT/rust-project-id-agent-base.stderr"
  local expected="[semantic-mcp-cli] project_id literal 'agent_base' is forbidden; bootstrap a repo-local immutable id"

  if run_node_cli_capture "$node_out" "$node_err" project-id validate --value agent_base; then
    fail "node project-id validate unexpectedly accepted agent_base"
  fi
  if run_rust_cli_capture "$rust_out" "$rust_err" project-id validate --value agent_base; then
    fail "rust project-id validate unexpectedly accepted agent_base"
  fi

  [[ ! -s "$node_out" ]] || fail "node project-id reject path wrote stdout unexpectedly"
  [[ ! -s "$rust_out" ]] || fail "rust project-id reject path wrote stdout unexpectedly"
  assert_trimmed_stderr_equals "$expected" "$node_err"
  assert_trimmed_stderr_equals "$expected" "$rust_err"
}

test_unknown_command_contract_parity() {
  local node_out="$TMP_ROOT/node-unknown-command.stdout"
  local node_err="$TMP_ROOT/node-unknown-command.stderr"
  local rust_out="$TMP_ROOT/rust-unknown-command.stdout"
  local rust_err="$TMP_ROOT/rust-unknown-command.stderr"
  local expected="[semantic-mcp-cli] unknown command: bogus cmd"

  if run_node_cli_capture "$node_out" "$node_err" bogus cmd; then
    fail "node CLI unexpectedly accepted unknown command"
  fi
  if run_rust_cli_capture "$rust_out" "$rust_err" bogus cmd; then
    fail "rust CLI unexpectedly accepted unknown command"
  fi

  [[ ! -s "$node_out" ]] || fail "node unknown-command path wrote stdout unexpectedly"
  [[ ! -s "$rust_out" ]] || fail "rust unknown-command path wrote stdout unexpectedly"
  assert_trimmed_stderr_equals "$expected" "$node_err"
  assert_trimmed_stderr_equals "$expected" "$rust_err"
}

main() {
  require_cmd jq
  require_cmd cargo
  require_cmd diff
  require_cmd mktemp

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/semantic_cli_contract_parity.XXXXXX")"
  load_rust_workspace_root

  test_project_id_validate_trim_parity
  test_project_id_validate_rejects_agent_base_with_parity
  test_unknown_command_contract_parity

  printf 'PASS: semantic_cli_contract_parity_test\n'
}

main "$@"
