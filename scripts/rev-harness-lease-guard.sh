#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUST_MANIFEST="$PROJECT_ROOT/harness-rust/Cargo.toml"
DEFAULT_RUST_BIN="${REV_HARNESS_LEASE_GUARD_DEFAULT_RUST_BIN:-$PROJECT_ROOT/harness-rust/target/debug/agent-core}"
CARGO_BIN="${REV_HARNESS_LEASE_GUARD_CARGO_BIN:-cargo}"
DEFAULT_CARGO_TARGET_DIR="$PROJECT_ROOT/harness-rust/target"

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-lease-guard.sh validate --file <lease-registry.json> [--repo-root <path>] [--json]
  scripts/rev-harness-lease-guard.sh open --file <lease-registry.json> --lease-id <id> --provider <codex|claude> --purpose <text> --artifact <path> [--model <model>] [--repo-root <path>] [--json]
  scripts/rev-harness-lease-guard.sh heartbeat --file <lease-registry.json> --lease-id <id> [--repo-root <path>] [--json]
  scripts/rev-harness-lease-guard.sh close --file <lease-registry.json> --lease-id <id> --artifact <path> [--repo-root <path>] [--json]
  scripts/rev-harness-lease-guard.sh block --file <lease-registry.json> --lease-id <id> --artifact <path> [--repo-root <path>] [--json]
  scripts/rev-harness-lease-guard.sh reap --file <lease-registry.json> --stale-seconds <n> --artifact <path> [--repo-root <path>] [--json]

Validates and mutates Rev Harness agent lease registries.
EOF
}

has_json_flag() {
  local arg
  for arg in "$@"; do
    [[ "$arg" == "--json" ]] && return 0
  done
  return 1
}

emit_block_json() {
  local violation="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -cn \
      --arg schema_version "rev-harness-lease-guard/v1" \
      --arg status "BLOCK" \
      --arg file "" \
      --arg repo_root "$PROJECT_ROOT" \
      --arg violation "$violation" \
      '{
        schema_version: $schema_version,
        status: $status,
        file: $file,
        repo_root: $repo_root,
        completion_allowed: false,
        violations: [$violation]
      }'
  else
    printf '{"schema_version":"rev-harness-lease-guard/v1","status":"BLOCK","file":"","repo_root":"%s","completion_allowed":false,"violations":["%s"]}\n' \
      "$PROJECT_ROOT" "$violation"
  fi
}

emit_block() {
  local violation="$1"
  shift || true
  if has_json_flag "$@"; then
    emit_block_json "$violation"
  else
    printf 'status: BLOCK\n'
    printf 'completion_allowed: false\n'
    printf 'violations:\n'
    printf -- '- %s\n' "$violation"
  fi
}

normalize_validate_args() {
  local normalized=()
  local repo_root_seen=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-root)
        [[ $# -ge 2 ]] || {
          normalized+=("$1")
          shift
          continue
        }
        repo_root_seen=true
        if [[ "$2" == /* ]]; then
          normalized+=("$1" "$2")
        else
          normalized+=("$1" "$PROJECT_ROOT/$2")
        fi
        shift 2
        ;;
      --repo-root=*)
        repo_root_seen=true
        local value="${1#--repo-root=}"
        if [[ "$value" == /* ]]; then
          normalized+=("$1")
        else
          normalized+=("--repo-root=$PROJECT_ROOT/$value")
        fi
        shift
        ;;
      *)
        normalized+=("$1")
        shift
        ;;
    esac
  done
  if [[ "$repo_root_seen" == false ]]; then
    normalized+=("--repo-root" "$PROJECT_ROOT")
  fi
  printf '%s\0' "${normalized[@]}"
}

rust_bin_is_fresh() {
  local bin="$1"
  local source
  local source_dir
  local freshness_sources=(
    "$RUST_MANIFEST"
    "$PROJECT_ROOT/harness-rust/Cargo.lock"
    "$PROJECT_ROOT/harness-rust/crates/agent-core/Cargo.toml"
    "$PROJECT_ROOT/harness-rust/crates/shared/Cargo.toml"
  )

  [[ -x "$bin" ]] || return 1

  for source_dir in \
    "$PROJECT_ROOT/harness-rust/crates/agent-core/src" \
    "$PROJECT_ROOT/harness-rust/crates/shared/src"; do
    [[ -d "$source_dir" ]] || return 1
    while IFS= read -r -d '' source; do
      freshness_sources+=("$source")
    done < <(find "$source_dir" -type f -name '*.rs' -print0)
  done

  for source in "${freshness_sources[@]}"; do
    [[ -f "$source" && "$bin" -nt "$source" ]] || return 1
  done
  return 0
}

build_default_rust_bin() {
  [[ -f "$RUST_MANIFEST" ]] || return 127
  command -v "$CARGO_BIN" >/dev/null 2>&1 || return 127
  CARGO_TARGET_DIR="$DEFAULT_CARGO_TARGET_DIR" \
    "$CARGO_BIN" build --quiet --manifest-path "$RUST_MANIFEST" -p agent-core
}

rust_bin_supports_lease() {
  local bin="$1"
  local action="${2:-}"

  [[ -x "$bin" ]] || return 1
  "$bin" lease "$action" --help >/dev/null 2>&1
}

run_rust_validator() {
  if [[ -n "${REV_HARNESS_LEASE_GUARD_RUST_BIN:-}" ]]; then
    [[ -x "$REV_HARNESS_LEASE_GUARD_RUST_BIN" ]] || return 127
    "$REV_HARNESS_LEASE_GUARD_RUST_BIN" lease "$@"
    return $?
  fi

  if rust_bin_is_fresh "$DEFAULT_RUST_BIN" \
    && rust_bin_supports_lease "$DEFAULT_RUST_BIN" "${1:-}"; then
    "$DEFAULT_RUST_BIN" lease "$@"
    return $?
  fi

  build_default_rust_bin || return 127
  if rust_bin_supports_lease "$DEFAULT_RUST_BIN" "${1:-}"; then
    "$DEFAULT_RUST_BIN" lease "$@"
    return $?
  fi
  return 127
}

command="${1:-}"
case "$command" in
  validate|open|heartbeat|close|block|reap) ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
shift || true

normalized_args=()
while IFS= read -r -d '' arg; do
  normalized_args+=("$arg")
done < <(normalize_validate_args "$@")

output=""
set +e
output="$(run_rust_validator "$command" "${normalized_args[@]}" 2>&1)"
status=$?
set -e

if [[ "$command" == "validate" ]] && has_json_flag "${normalized_args[@]}"; then
  if ! command -v jq >/dev/null 2>&1; then
    emit_block "jq is required to validate Rust JSON output" "${normalized_args[@]}"
    exit 1
  fi
  if ! printf '%s\n' "$output" | jq -s -e '
    length == 1
    and (.[0] | type == "object")
    and .[0].schema_version == "rev-harness-lease-guard/v1"
    and (.[0].status == "PASS" or .[0].status == "BLOCK")
    and (.[0].file | type == "string")
    and (.[0].repo_root | type == "string")
    and (.[0].completion_allowed | type == "boolean")
    and (.[0].violations | type == "array")
    and (
      (.[0].status == "PASS" and .[0].completion_allowed == true and (.[0].violations | length) == 0)
      or (.[0].status == "BLOCK" and .[0].completion_allowed == false and (.[0].violations | length) > 0)
    )
  ' >/dev/null 2>&1; then
    emit_block "rust validator returned invalid JSON" "${normalized_args[@]}"
    exit 1
  fi
  if ! printf '%s\n' "$output" | jq -s -e --argjson status "$status" '
    length == 1
    and (
      (.[0].status == "PASS" and $status == 0)
      or (.[0].status == "BLOCK" and $status == 1)
    )
  ' >/dev/null 2>&1; then
    emit_block "rust validator JSON/exit status mismatch" "${normalized_args[@]}"
    exit 1
  fi
fi

if [[ "$command" == "validate" && -n "${REV_HARNESS_LEASE_GUARD_PARITY_ORACLE_BIN:-}" ]]; then
  if [[ ! -x "$REV_HARNESS_LEASE_GUARD_PARITY_ORACLE_BIN" ]]; then
    emit_block "shell/Rust parity oracle is missing" "${normalized_args[@]}"
    exit 1
  fi
  oracle_output=""
  set +e
  oracle_output="$("$REV_HARNESS_LEASE_GUARD_PARITY_ORACLE_BIN" validate "${normalized_args[@]}" 2>&1)"
  oracle_status=$?
  set -e
  if [[ "$oracle_status" != "$status" ]]; then
    emit_block "shell/Rust parity mismatch" "${normalized_args[@]}"
    exit 1
  fi
  if has_json_flag "${normalized_args[@]}"; then
    if ! diff -u <(printf '%s\n' "$oracle_output" | jq -S .) <(printf '%s\n' "$output" | jq -S .) >/dev/null; then
      emit_block "shell/Rust parity mismatch" "${normalized_args[@]}"
      exit 1
    fi
  elif [[ "$oracle_output" != "$output" ]]; then
    emit_block "shell/Rust parity mismatch" "${normalized_args[@]}"
    exit 1
  fi
fi

case "$status" in
  0)
    printf '%s\n' "$output"
    exit "$status"
    ;;
  1)
    if [[ "$command" == "validate" ]]; then
      printf '%s\n' "$output"
      exit "$status"
    fi
    emit_block "rust lifecycle execution failed" "${normalized_args[@]}"
    exit 1
    ;;
  *)
    if [[ "$command" == "validate" ]]; then
      emit_block "rust validator execution failed" "${normalized_args[@]}"
    else
      emit_block "rust lifecycle execution failed" "${normalized_args[@]}"
    fi
    exit 1
    ;;
esac
