#!/usr/bin/env bash
set -euo pipefail

safe_dirname() {
  /usr/bin/dirname "$1"
}

safe_basename() {
  /usr/bin/basename "$1"
}

safe_readlink() {
  /usr/bin/readlink "$1"
}

resolve_self_path() {
  local source_path="${BASH_SOURCE[0]}"
  local source_dir=""
  local target_path=""

  while [[ -L "$source_path" ]]; do
    source_dir="$(cd "$(safe_dirname "$source_path")" && pwd -P)" || return 1
    target_path="$(safe_readlink "$source_path")" || return 1
    case "$target_path" in
      /*) source_path="$target_path" ;;
      *) source_path="$source_dir/$target_path" ;;
    esac
  done

  source_dir="$(cd "$(safe_dirname "$source_path")" && pwd -P)" || return 1
  printf '%s/%s\n' "$source_dir" "$(safe_basename "$source_path")"
}

die() {
  printf 'run-semantic-node-tool.sh: %s\n' "$*" >&2
  exit 1
}

run_runtime_env_resolver() {
  local repo_root="$1"
  local output_file="$2"
  local timeout_secs="${RUN_SEMANTIC_NODE_TOOL_RESOLVER_TIMEOUT_SECS:-45}"
  local pid=""
  local elapsed_secs=0
  local timeout_diag="${output_file}.timeout"

  [[ "$timeout_secs" =~ ^[1-9][0-9]*$ ]] || die "invalid runtime resolver timeout: $timeout_secs"

  /bin/bash "$repo_root/scripts/semantic-review-queue.sh" \
    __internal-runtime-env --binary node --repo-root "$repo_root" --json > "$output_file" &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed_secs" -ge "$timeout_secs" ]]; then
      {
        printf 'timed_out_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'timeout_secs=%s\n' "$timeout_secs"
        printf 'repo_root=%s\n' "$repo_root"
        ps -ax -o pid,ppid,pgid,etime,stat,command 2>/dev/null || true
      } > "$timeout_diag"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      printf 'run-semantic-node-tool.sh: runtime resolver timed out; diagnostics: %s\n' "$timeout_diag" >&2
      return 124
    fi
    sleep 1
    elapsed_secs=$((elapsed_secs + 1))
  done

  wait "$pid"
}

usage() {
  cat <<'EOF'
Usage:
  run-semantic-node-tool.sh npm <args...>
  run-semantic-node-tool.sh npx <args...>
EOF
}

resolve_runtime_env() {
  local repo_root="$1"
  local runtime_json_file=""

  runtime_json_file="$(mktemp "${TMPDIR:-/tmp}/run_semantic_node_runtime.XXXXXX")" || return 1
  trap '/bin/rm -f "$runtime_json_file"' RETURN

  if ! run_runtime_env_resolver "$repo_root" "$runtime_json_file"; then
    /bin/rm -f "$runtime_json_file"
    trap - RETURN
    return 1
  fi

  unset RUNTIME_BINARY RUNTIME_PATH RUNTIME_HOME
  RUNTIME_BINARY="$(jq -r '.runtime_binary // empty' "$runtime_json_file")" || return 1
  RUNTIME_PATH="$(jq -r '.runtime_path // empty' "$runtime_json_file")" || return 1
  RUNTIME_HOME="$(jq -r '.runtime_home // empty' "$runtime_json_file")" || return 1
  /bin/rm -f "$runtime_json_file"
  trap - RETURN

  [[ -n "${RUNTIME_BINARY:-}" ]] || die "trusted node runtime binary is required"
  [[ -n "${RUNTIME_PATH:-}" ]] || die "trusted node runtime PATH is required"
  [[ -n "${RUNTIME_HOME:-}" ]] || die "trusted node runtime HOME is required"
}

node_install_prefix() {
  local node_binary="$1"
  local node_dir=""

  node_dir="$(cd "$(safe_dirname "$node_binary")" && pwd -P)" || return 1
  cd "$node_dir/.." && pwd -P
}

tool_entrypoint() {
  local tool_name="$1"
  local install_prefix="$2"
  local cli_path=""

  case "$tool_name" in
    npm)
      cli_path="$install_prefix/lib/node_modules/npm/bin/npm-cli.js"
      ;;
    npx)
      cli_path="$install_prefix/lib/node_modules/npm/bin/npx-cli.js"
      ;;
    *)
      die "unsupported tool: $tool_name"
      ;;
  esac

  [[ -f "$cli_path" ]] || die "tool entrypoint not found: $cli_path"
  printf '%s\n' "$cli_path"
}

main() {
  local tool_name="${1:-}"
  local repo_root=""
  local self_path=""
  local expected_helper=""
  local install_prefix=""
  local cli_path=""
  local node_dir=""

  case "$tool_name" in
    -h|--help|"")
      usage
      [[ -n "$tool_name" ]] || exit 1
      exit 0
      ;;
  esac
  shift || true

  self_path="$(resolve_self_path)" || die "failed to resolve helper path"
  repo_root="$(cd "$(safe_dirname "$self_path")/.." && pwd -P)" || die "failed to resolve repo root"
  expected_helper="$repo_root/scripts/run-semantic-node-tool.sh"
  [[ "$self_path" == "$expected_helper" ]] || die "helper must execute from canonical repo path: $expected_helper"
  [[ -x "$repo_root/scripts/semantic-review-queue.sh" ]] || die "trusted semantic runtime resolver not found: $repo_root/scripts/semantic-review-queue.sh"
  resolve_runtime_env "$repo_root"

  install_prefix="$(node_install_prefix "$RUNTIME_BINARY")" || die "failed to resolve node install prefix"
  cli_path="$(tool_entrypoint "$tool_name" "$install_prefix")"
  node_dir="$(cd "$(safe_dirname "$RUNTIME_BINARY")" && pwd -P)" || die "failed to resolve node runtime directory"

  exec /usr/bin/env -i \
    "PATH=$node_dir:$RUNTIME_PATH" \
    "HOME=$RUNTIME_HOME" \
    "$RUNTIME_BINARY" \
    "$cli_path" \
    "$@"
}

main "$@"
