#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_ROOT="${REV_HARNESS_WORKER_LIFECYCLE_PROJECT_ROOT:-$DEFAULT_PROJECT_ROOT}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-worker-lifecycle.sh validate --manifest <path> [--root <dir>] [--json]

Validate a rev-harness-worker-lifecycle/v1 JSON file.

This validator checks lifecycle closeout claims recorded in the manifest. It
does not observe or assert live runtime thread/process state.
EOF
}

die() {
  printf 'rev-harness-worker-lifecycle: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_safe_relative_path() {
  local path="$1"

  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != *$'\n'* ]] || return 1
  case "/$path/" in
    *"//"*|*"/./"*|*"/../"*) return 1 ;;
  esac
  return 0
}

# shellcheck disable=SC2329
resolve_under_root() {
  local path="$1"

  is_safe_relative_path "$path" || return 1
  printf '%s/%s\n' "$PROJECT_ROOT" "$path"
}

abs_is_under_root() {
  local abs="$1"

  case "$abs" in
    "$PROJECT_ROOT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

path_has_symlink_parent() {
  local rel="$1"
  local parent=""
  local component=""
  local cursor="$PROJECT_ROOT"

  parent="$(dirname "$rel")"
  [[ "$parent" != "." ]] || return 1

  IFS='/' read -r -a components <<<"$parent"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    cursor="$cursor/$component"
    [[ ! -L "$cursor" ]] || return 0
  done
  return 1
}

resolve_existing_path_under_root() {
  local rel="$1"
  local abs_path=""
  local parent=""
  local parent_real=""
  local base=""

  is_safe_relative_path "$rel" || return 1
  path_has_symlink_parent "$rel" && return 1

  abs_path="$PROJECT_ROOT/$rel"
  [[ -e "$abs_path" && ! -L "$abs_path" ]] || return 1

  parent="$(dirname "$abs_path")"
  parent_real="$(cd "$parent" && pwd -P)" || return 1
  abs_is_under_root "$parent_real/" || return 1

  base="$(basename "$abs_path")"
  printf '%s/%s\n' "$parent_real" "$base"
}

resolve_manifest_under_root() {
  local input="$1"
  local rel=""

  if [[ "$input" == /* ]]; then
    case "$input" in
      "$PROJECT_ROOT"/*) rel="${input#"$PROJECT_ROOT"/}" ;;
      *) return 1 ;;
    esac
  else
    rel="$input"
  fi

  [[ -f "$PROJECT_ROOT/$rel" ]] || return 1
  resolve_existing_path_under_root "$rel"
}

record_failure() {
  local context="$1"
  local message="$2"
  local path="${3:-}"

  jq -nc \
    --arg context "$context" \
    --arg message "$message" \
    --arg path "$path" \
    '{context: $context, message: $message, path: $path}' >>"$FAILURES_JSONL"
}

failure_count() {
  wc -l <"$FAILURES_JSONL" | tr -d '[:space:]'
}

emit_json() {
  local status="$1"
  local worker_count="$2"
  local failures_json="[]"

  failures_json="$(jq -s '.' "$FAILURES_JSONL")"
  jq -nc \
    --arg schema_version "rev-harness-worker-lifecycle/v1" \
    --arg status "$status" \
    --argjson worker_count "$worker_count" \
    --argjson failures "$failures_json" \
    '{
      schema_version: $schema_version,
      status: $status,
      worker_count: $worker_count,
      runtime_state_observed: false,
      failures: $failures
    }'
}

json_has_nonempty_string() {
  local json="$1"
  local filter="$2"

  printf '%s\n' "$json" | jq -e "$filter | type == \"string\" and length > 0" >/dev/null
}

validate_artifact_paths() {
  local worker_index="$1"
  local worker="$2"
  local path_index=0
  local path_value=""
  local path=""
  local abs_path=""

  if ! printf '%s\n' "$worker" | jq -e '.artifact_paths | type == "array" and length > 0' >/dev/null; then
    record_failure "workers[$worker_index].artifact_paths" "artifact_paths must be a non-empty array"
    return 0
  fi

  while IFS= read -r path_value; do
    if ! printf '%s\n' "$path_value" | jq -e 'type == "string"' >/dev/null; then
      record_failure "workers[$worker_index].artifact_paths[$path_index]" "artifact path must be string" "$path_value"
      path_index=$((path_index + 1))
      continue
    fi

    path="$(printf '%s\n' "$path_value" | jq -r '.')"
    if ! is_safe_relative_path "$path"; then
      record_failure "workers[$worker_index].artifact_paths[$path_index]" "artifact path must be safe repository-relative path" "$path"
      path_index=$((path_index + 1))
      continue
    fi
    if ! abs_path="$(resolve_existing_path_under_root "$path")"; then
      record_failure "workers[$worker_index].artifact_paths[$path_index]" "missing artifact path or unsafe symlink/realpath escape" "$path"
      path_index=$((path_index + 1))
      continue
    fi
    path_index=$((path_index + 1))
  done < <(printf '%s\n' "$worker" | jq -c '.artifact_paths[]?')
}

validate_runtime_non_claim() {
  local worker_index="$1"
  local worker="$2"

  if printf '%s\n' "$worker" | jq -e 'has("runtime_thread_state") or has("process_state") or has("thread_alive") or has("runtime_state_verified") or has("runtime_observed")' >/dev/null; then
    record_failure "workers[$worker_index]" "manifest must not claim live runtime thread/process state"
  fi
  if printf '%s\n' "$worker" | jq -e 'has("runtime_observation")' >/dev/null; then
    if ! printf '%s\n' "$worker" | jq -e '
      (.runtime_observation == "not-observed")
      or (.runtime_observation | type == "object" and .observed == false)
    ' >/dev/null; then
      record_failure "workers[$worker_index].runtime_observation" "runtime_observation must be not-observed"
    fi
  fi
}

validate_worker() {
  local worker_index="$1"
  local worker="$2"
  local state=""

  if ! printf '%s\n' "$worker" | jq -e 'type == "object"' >/dev/null; then
    record_failure "workers[$worker_index]" "worker entry must be object"
    return 0
  fi

  if ! json_has_nonempty_string "$worker" '.id'; then
    record_failure "workers[$worker_index].id" "missing worker id"
  fi
  if ! json_has_nonempty_string "$worker" '.spawned_at'; then
    record_failure "workers[$worker_index].spawned_at" "missing spawned_at"
  fi

  state="$(printf '%s\n' "$worker" | jq -r '.state // empty')"
  case "$state" in
    active)
      if ! json_has_nonempty_string "$worker" '.retain_reason'; then
        record_failure "workers[$worker_index]" "active retained worker requires retain_reason"
      fi
      ;;
    closed)
      json_has_nonempty_string "$worker" '.completed_at' || record_failure "workers[$worker_index]" "closed worker requires completed_at"
      json_has_nonempty_string "$worker" '.closed_at' || record_failure "workers[$worker_index]" "closed worker requires closed_at"
      ;;
    successor-linked)
      json_has_nonempty_string "$worker" '.completed_at' || record_failure "workers[$worker_index]" "successor-linked worker requires completed_at"
      json_has_nonempty_string "$worker" '.successor_worker_id' || record_failure "workers[$worker_index]" "successor-linked worker requires successor_worker_id"
      ;;
    BLOCK)
      json_has_nonempty_string "$worker" '.block_reason' || record_failure "workers[$worker_index]" "BLOCK worker requires block_reason"
      json_has_nonempty_string "$worker" '.retain_reason' || record_failure "workers[$worker_index]" "BLOCK worker requires retain_reason"
      ;;
    deferred)
      json_has_nonempty_string "$worker" '.deferred_reason' || record_failure "workers[$worker_index]" "deferred worker requires deferred_reason"
      json_has_nonempty_string "$worker" '.retain_reason' || record_failure "workers[$worker_index]" "deferred worker requires retain_reason"
      ;;
    "")
      record_failure "workers[$worker_index].state" "missing worker state"
      ;;
    *)
      record_failure "workers[$worker_index].state" "invalid worker state: $state"
      ;;
  esac

  validate_runtime_non_claim "$worker_index" "$worker"
  validate_artifact_paths "$worker_index" "$worker"
}

command="${1:-}"
[[ "$command" == "validate" ]] || {
  usage >&2
  exit 2
}
shift

manifest_input=""
json=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      [[ $# -ge 2 ]] || die "--manifest requires a value"
      manifest_input="$2"
      shift 2
      ;;
    --root)
      [[ $# -ge 2 ]] || die "--root requires a value"
      PROJECT_ROOT="$(cd "$2" && pwd -P)" || die "cannot resolve --root: $2"
      shift 2
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

require_cmd jq

[[ -n "$manifest_input" ]] || die "--manifest is required"
manifest_path="$(resolve_manifest_under_root "$manifest_input")" || die "manifest must be a regular file under root without symlink parents: $manifest_input"
jq empty "$manifest_path" >/dev/null || die "manifest is not valid JSON: $manifest_input"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-worker-lifecycle.XXXXXX")"
FAILURES_JSONL="$TMP_DIR/failures.jsonl"
: >"$FAILURES_JSONL"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! jq -e '.schema_version == "rev-harness-worker-lifecycle/v1"' "$manifest_path" >/dev/null; then
  record_failure "schema_version" "expected rev-harness-worker-lifecycle/v1"
fi
if ! jq -e '.workers | type == "array" and length > 0' "$manifest_path" >/dev/null; then
  record_failure "workers" "workers must be a non-empty array"
else
  worker_index=0
  while IFS= read -r worker; do
    validate_worker "$worker_index" "$worker"
    worker_index=$((worker_index + 1))
  done < <(jq -c '.workers[]' "$manifest_path")
fi

worker_count="$(jq '.workers // [] | length' "$manifest_path")"
failures="$(failure_count)"

if [[ "$failures" == "0" ]]; then
  if [[ "$json" == true ]]; then
    emit_json "PASS" "$worker_count"
  else
    printf 'PASS: worker lifecycle validation\n'
    printf 'worker_count: %s\n' "$worker_count"
    printf 'runtime_state_observed: false\n'
  fi
  exit 0
fi

if [[ "$json" == true ]]; then
  emit_json "FAIL" "$worker_count"
else
  jq -r '. | "FAIL: \(.context): \(.message)\(if .path == "" then "" else " [" + .path + "]" end)"' "$FAILURES_JSONL" >&2
fi
exit 1
