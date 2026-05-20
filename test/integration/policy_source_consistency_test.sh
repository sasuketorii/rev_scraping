#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST_PATH="$PROJECT_ROOT/.agent/registry/policy_sources.json"

normalize_repo_path() {
  local rel_path="$1"
  local rel_dir=""
  local rel_base=""
  local abs_dir=""
  local abs_path=""

  rel_dir="$(dirname "$rel_path")"
  rel_base="$(basename "$rel_path")"

  abs_dir="$(
    cd "$PROJECT_ROOT/$rel_dir" 2>/dev/null &&
      pwd -P
  )" || {
    printf 'ERROR: failed to normalize manifest path: %s\n' "$rel_path" >&2
    exit 1
  }

  abs_path="${abs_dir}/${rel_base}"
  printf '%s\n' "$abs_path"
}

is_volatile_prefix() {
  case "$1" in
    .agent/active/*|.agent/archive/*|.claude/tmp/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_file() {
  local path="$1"

  if [[ ! -e "$path" ]]; then
    printf 'ERROR: missing file: %s\n' "$path" >&2
    exit 1
  fi
}

is_known_authority_type() {
  case "$1" in
    hard_rules|verification_truth|runtime_policy|project_context|role_policy|dependency_gate|contract_surface|contract_runtime)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_file "$MANIFEST_PATH"
jq empty "$MANIFEST_PATH" >/dev/null

if ! jq -e 'type == "array"' "$MANIFEST_PATH" >/dev/null; then
  printf 'ERROR: manifest root must be a flat JSON array\n' >&2
  exit 1
fi

if ! jq -e 'all(.[]; type == "object")' "$MANIFEST_PATH" >/dev/null; then
  printf 'ERROR: manifest entries must be JSON objects\n' >&2
  exit 1
fi

if ! jq -e '
  all(
    .[];
    has("path")
    and (.path | type == "string")
    and (.path | length > 0)
    and has("authority_type")
    and (.authority_type | type == "string")
    and (.authority_type | length > 0)
    and has("governs")
    and (.governs | type == "array")
    and all(.governs[]?; type == "string" and length > 0)
    and has("stable")
    and (.stable | type == "boolean")
    and (.stable == true)
    and has("required_checks_surface")
    and (.required_checks_surface | type == "array")
    and all(.required_checks_surface[]?; type == "string" and length > 0)
  )
' "$MANIFEST_PATH" >/dev/null; then
  printf 'ERROR: manifest entries must include the required minimum surface and must be stable\n' >&2
  exit 1
fi

duplicate_paths="$(
  jq -r '.[].path' "$MANIFEST_PATH" \
    | sort \
    | uniq -d
)"

if [[ -n "$duplicate_paths" ]]; then
  printf 'ERROR: duplicate manifest paths detected:\n%s\n' "$duplicate_paths" >&2
  exit 1
fi

while IFS=$'\t' read -r rel_path authority_type; do
  local_abs_path=""

  [[ -n "$rel_path" ]] || continue

  if ! is_known_authority_type "$authority_type"; then
    printf 'ERROR: unknown authority_type for %s: %s\n' "$rel_path" "$authority_type" >&2
    exit 1
  fi

  if [[ "$rel_path" = /* ]]; then
    printf 'ERROR: manifest path must be repo-relative: %s\n' "$rel_path" >&2
    exit 1
  fi

  if is_volatile_prefix "$rel_path"; then
    printf 'ERROR: manifest path must not point to volatile surface: %s\n' "$rel_path" >&2
    exit 1
  fi

  local_abs_path="$(normalize_repo_path "$rel_path")"

  case "$local_abs_path" in
    "$PROJECT_ROOT"/*)
      ;;
    *)
      printf 'ERROR: manifest path escapes repo root: %s -> %s\n' "$rel_path" "$local_abs_path" >&2
      exit 1
      ;;
  esac

  if [[ ! -e "$local_abs_path" ]]; then
    printf 'ERROR: manifest path does not exist: %s\n' "$rel_path" >&2
    exit 1
  fi
done < <(jq -r '.[] | [.path, .authority_type] | @tsv' "$MANIFEST_PATH")

printf 'PASS: policy_source_consistency_test\n'
