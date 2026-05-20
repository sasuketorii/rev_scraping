#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DEFAULT_MANIFEST_REL=".agent/active/sow/rev_harness_90_point_dirty_surface_manifest.json"
SCHEMA_VERSION="rev-harness-dirty-surface/v1"
PREFLIGHT_SCHEMA_VERSION="rev-harness-dirty-surface-preflight/v1"

usage() {
  printf '%s\n' \
    'Usage:' \
    '  scripts/rev-harness-dirty-surface.sh --check [--json] [--manifest <path>] [--root <path>]' \
    '' \
    'Read-only dirty/HOLD ownership preflight for Revharness reviewer intake.' \
    'The manifest must be machine-readable JSON with:' \
    '  schema_version: rev-harness-dirty-surface/v1' \
    '  owned_review_set: array of dirty paths owned by the active slice' \
    '  paths: array of current git dirty paths with path, owner, disposition,' \
    '         include_in_review, reason, and optional acceptance_relevant' \
    '  hold_items: optional array of HOLD records with owner, disposition,' \
    '              include_in_review, reason, and optional id/path' \
    '' \
    'Allowed dispositions:' \
    '  owned by active slice, unrelated user change, protected evidence,' \
    '  cleanup candidate, deferred, BLOCK' \
    '' \
    'Safety:' \
    '  This command only reads git status and the manifest. It never cleans,' \
    '  stages, checks out, deletes, archives, or rewrites live git state.'
}

die() {
  printf 'rev-harness-dirty-surface: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
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

is_safe_manifest_path() {
  local path="$1"

  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != *$'\n'* ]] || return 1
  case "/$path/" in
    *"//"*|*"/./"*|*"/../"*) return 1 ;;
  esac
  return 0
}

resolve_root() {
  local input="$1"
  local abs=""
  local git_root=""

  if [[ "$input" == /* ]]; then
    abs="$input"
  else
    abs="$PWD/$input"
  fi
  [[ -d "$abs" ]] || die "--root must be an existing directory: $input"
  git_root="$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null)" \
    || die "--root must be inside a git repository: $input"
  (cd "$git_root" && pwd -P)
}

resolve_manifest() {
  local input="$1"
  local abs=""
  local parent=""
  local parent_real=""
  local base=""

  if [[ "$input" == /* ]]; then
    abs="$input"
  else
    abs="$PROJECT_ROOT/$input"
  fi
  [[ -f "$abs" ]] || die "missing dirty surface manifest: $input"
  [[ ! -L "$abs" ]] || die "dirty surface manifest cannot be a symlink: $input"

  parent="$(dirname "$abs")"
  parent_real="$(cd "$parent" && pwd -P)"
  base="$(basename "$abs")"
  printf '%s/%s\n' "$parent_real" "$base"
}

relative_to_root() {
  local path="$1"

  case "$path" in
    "$PROJECT_ROOT"/*) printf '%s\n' "${path#"$PROJECT_ROOT"/}" ;;
    "$PROJECT_ROOT") printf '%s\n' "." ;;
    *) printf '%s\n' "$path" ;;
  esac
}

collect_git_status() {
  local entry=""
  local xy=""
  local path=""

  : >"$STATUS_JSONL"
  while IFS= read -r -d '' entry; do
    xy="${entry:0:2}"
    path="${entry:3}"
    jq -nc --arg path "$path" --arg status "$xy" \
      '{path: $path, status: $status}' >>"$STATUS_JSONL"

    case "$xy" in
      R*|?R|C*|?C)
        IFS= read -r -d '' _ || true
        ;;
    esac
  done < <(git -C "$PROJECT_ROOT" status --porcelain=v1 -uall -z)

  jq -s 'sort_by(.path)' "$STATUS_JSONL" >"$STATUS_JSON"
}

write_sorted_path_file() {
  local source="$1"
  local output="$2"

  jq -r "$source" "$MANIFEST" | LC_ALL=C sort -u >"$output"
}

write_status_path_file() {
  jq -r '.[].path' "$STATUS_JSON" | LC_ALL=C sort -u >"$STATUS_PATHS"
}

append_jq_failures() {
  local filter="$1"
  local context="$2"
  local message="$3"

  while IFS= read -r path; do
    [[ -n "$path" ]] || path="<missing>"
    record_failure "$context" "$message" "$path"
  done < <(jq -r "$filter" "$MANIFEST")
}

validate_manifest_element_shapes() {
  local index=""

  while IFS= read -r index; do
    record_failure "manifest.paths" "path entry must be an object" "index:$index"
  done < <(jq -r '.paths | to_entries[] | select(.value | type != "object") | .key' "$MANIFEST")

  while IFS= read -r index; do
    record_failure "hold_items" "HOLD item must be an object" "index:$index"
  done < <(jq -r '(.hold_items // []) | to_entries[] | select(.value | type != "object") | .key' "$MANIFEST")

  [[ ! -s "$FAILURES_JSONL" ]]
}

validate_schema() {
  if ! jq empty "$MANIFEST" >/dev/null 2>&1; then
    record_failure "manifest" "invalid JSON" "$(relative_to_root "$MANIFEST")"
    return 1
  fi

  if ! jq -e --arg schema "$SCHEMA_VERSION" '
    .schema_version == $schema
    and (.owned_review_set | type == "array")
    and (.paths | type == "array")
    and ((.hold_items // []) | type == "array")
    and ((.expected_unrelated_paths // []) | type == "array")
  ' "$MANIFEST" >/dev/null; then
    record_failure "manifest" "schema_version, owned_review_set, paths, or hold_items shape is invalid" "$(relative_to_root "$MANIFEST")"
    return 1
  fi

  return 0
}

validate_manifest_records() {
  local path=""
  local duplicate=""

  append_jq_failures '
    .paths[]
    | select(type == "object")
    | select((.path | type != "string") or (.path | length == 0))
    | (.path // "<missing>")
  ' "manifest.paths" "path entry lacks path"

  while IFS= read -r path; do
    is_safe_manifest_path "$path" || record_failure "manifest.paths" "unsafe path entry" "$path"
  done < <(jq -r '.paths[] | select(type == "object" and (.path | type == "string")) | .path' "$MANIFEST")

  append_jq_failures '
    .paths[]
    | select(type == "object")
    | select((.owner | type != "string") or (.owner | length == 0))
    | (.path // "<missing>")
  ' "manifest.paths" "dirty path lacks owner"

  append_jq_failures '
    .paths[]
    | select(type == "object")
    | select((.disposition | type != "string") or (.disposition | length == 0))
    | (.path // "<missing>")
  ' "manifest.paths" "dirty path lacks disposition"

  append_jq_failures '
    .paths[]
    | select(type == "object")
    | select((.include_in_review | type) != "boolean")
    | (.path // "<missing>")
  ' "manifest.paths" "dirty path lacks boolean include_in_review"

  append_jq_failures '
    .paths[]
    | select(type == "object")
    | select((.reason | type != "string") or (.reason | length == 0))
    | (.path // "<missing>")
  ' "manifest.paths" "dirty path lacks reason"

  append_jq_failures '
    .paths[]
    | select(type == "object")
    | select((.acceptance_relevant // false) == true and ((.disposition | type != "string") or (.disposition | length == 0)))
    | (.path // "<missing>")
  ' "manifest.paths" "acceptance-relevant path lacks disposition"

  append_jq_failures '
    .paths[]
    | select(type == "object")
    | select((.disposition | type == "string") and (.disposition | IN("owned by active slice", "unrelated user change", "protected evidence", "cleanup candidate", "deferred", "BLOCK") | not))
    | (.path // "<missing>")
  ' "manifest.paths" "dirty path has unsupported disposition"

  append_jq_failures '
    .paths[]
    | select(type == "object")
    | select((.acceptance_relevant // false) == true and .disposition == "unrelated user change")
    | (.path // "<missing>")
  ' "manifest.paths" "acceptance-relevant path cannot be unrelated user change"

  append_jq_failures '
    .paths[]
    | select(type == "object")
    | select(.include_in_review == true and .disposition != "owned by active slice")
    | (.path // "<missing>")
  ' "manifest.paths" "review-included path must use owned by active slice disposition"

  while IFS= read -r duplicate; do
    [[ -n "$duplicate" ]] || continue
    record_failure "manifest.paths" "duplicate dirty path entry" "$duplicate"
  done < <(jq -r '.paths[] | select(type == "object") | .path' "$MANIFEST" | LC_ALL=C sort | uniq -d)

  while IFS= read -r path; do
    is_safe_manifest_path "$path" || record_failure "owned_review_set" "unsafe owned_review_set path" "$path"
  done < <(jq -r '.owned_review_set[] | select(type == "string")' "$MANIFEST")

  append_jq_failures '
    .owned_review_set[]
    | select(type != "string" or length == 0)
    | tostring
  ' "owned_review_set" "owned_review_set entry must be a non-empty string"

  while IFS= read -r duplicate; do
    [[ -n "$duplicate" ]] || continue
    record_failure "owned_review_set" "duplicate owned_review_set entry" "$duplicate"
  done < <(jq -r '.owned_review_set[] | select(type == "string")' "$MANIFEST" | LC_ALL=C sort | uniq -d)

  # shellcheck disable=SC2016
  append_jq_failures '
    (.owned_review_set[] | select(type == "string")) as $p
    | select((([.paths[]? | select(type == "object") | .path] | index($p))) | not)
    | $p
  ' "owned_review_set" "owned_review_set path missing from manifest paths"

  # shellcheck disable=SC2016
  append_jq_failures '
    (.owned_review_set[] | select(type == "string")) as $p
    | .paths[]? | select(type == "object") | select(.path == $p and .include_in_review != true)
    | .path
  ' "owned_review_set" "owned_review_set path is not review-included"

  # shellcheck disable=SC2016
  append_jq_failures '
    (.owned_review_set[] | select(type == "string")) as $p
    | .paths[]? | select(type == "object") | select(.path == $p and .disposition != "owned by active slice")
    | .path
  ' "owned_review_set" "owned_review_set path is not owned by active slice"

}

validate_owned_review_set_completeness() {
  local path=""

  write_sorted_path_file '.owned_review_set[] | select(type == "string")' "$OWNED_PATHS"
  jq -r '.paths[] | select(type == "object" and .include_in_review == true) | .path' "$MANIFEST" \
    | LC_ALL=C sort -u >"$INCLUDE_PATHS"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if ! grep -Fx -- "$path" "$OWNED_PATHS" >/dev/null; then
      record_failure "owned_review_set" "review-included path missing from owned_review_set" "$path"
    fi
  done <"$INCLUDE_PATHS"

  append_jq_failures '
    (.expected_unrelated_paths // [])[]
    | select(type != "string" or length == 0)
    | tostring
  ' "expected_unrelated_paths" "expected_unrelated_paths entry must be a non-empty string"

  # shellcheck disable=SC2016
  append_jq_failures '
    ((.expected_unrelated_paths // [])[] | select(type == "string")) as $p
    | select((([.paths[]? | select(type == "object" and .path == $p and .disposition == "unrelated user change")] | length) == 0))
    | $p
  ' "expected_unrelated_paths" "expected unrelated path missing unrelated disposition"
}

validate_hold_items() {
  local item_id=""

  append_jq_failures '
    (.hold_items // [])[]
    | select(type == "object")
    | select((.owner | type != "string") or (.owner | length == 0))
    | (.id // .path // "<missing>")
  ' "hold_items" "HOLD item lacks owner"

  append_jq_failures '
    (.hold_items // [])[]
    | select(type == "object")
    | select((.disposition | type != "string") or (.disposition | length == 0))
    | (.id // .path // "<missing>")
  ' "hold_items" "HOLD item lacks disposition"

  append_jq_failures '
    (.hold_items // [])[]
    | select(type == "object")
    | select((.include_in_review | type) != "boolean")
    | (.id // .path // "<missing>")
  ' "hold_items" "HOLD item lacks boolean include_in_review"

  append_jq_failures '
    (.hold_items // [])[]
    | select(type == "object")
    | select((.reason | type != "string") or (.reason | length == 0))
    | (.id // .path // "<missing>")
  ' "hold_items" "HOLD item lacks reason"

  append_jq_failures '
    (.hold_items // [])[]
    | select(type == "object")
    | select((.acceptance_relevant // false) == true and ((.disposition | type != "string") or (.disposition | length == 0)))
    | (.id // .path // "<missing>")
  ' "hold_items" "acceptance-relevant HOLD item lacks disposition"

  append_jq_failures '
    (.hold_items // [])[].path?
    | select(type == "string" and length > 0 and ((. | startswith("/")) or (. | contains("\n")) or (. | test("(^|/)\\.\\.(/|$)|(^|/)\\.(/|$)|//"))))
  ' "hold_items" "unsafe HOLD item path"

  append_jq_failures '
    (.hold_items // [])[]
    | select(type == "object")
    | select((.disposition | type == "string") and (.disposition | IN("owned by active slice", "unrelated user change", "protected evidence", "cleanup candidate", "deferred", "BLOCK") | not))
    | (.id // .path // "<missing>")
  ' "hold_items" "HOLD item has unsupported disposition"

  while IFS= read -r item_id; do
    [[ -n "$item_id" ]] || continue
    record_failure "hold_items" "duplicate HOLD item id/path" "$item_id"
  done < <(jq -r '(.hold_items // [])[] | select(type == "object") | (.id // .path // empty)' "$MANIFEST" | LC_ALL=C sort | uniq -d)
}

validate_status_manifest_match() {
  local path=""

  write_status_path_file
  write_sorted_path_file '.paths[] | select(type == "object") | .path' "$MANIFEST_PATHS"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if ! grep -Fx -- "$path" "$MANIFEST_PATHS" >/dev/null; then
      record_failure "git_status" "dirty path missing manifest ownership" "$path"
    fi
  done <"$STATUS_PATHS"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if ! grep -Fx -- "$path" "$STATUS_PATHS" >/dev/null; then
      record_failure "manifest.paths" "manifest path is not dirty" "$path"
    fi
  done <"$MANIFEST_PATHS"
}

json_array_from_jsonl() {
  local file="$1"

  if [[ -s "$file" ]]; then
    jq -s -c '.' "$file"
  else
    printf '[]'
  fi
}

emit_json_result() {
  local status="$1"
  local failures_json=""

  failures_json="$(json_array_from_jsonl "$FAILURES_JSONL")"
  if ! jq empty "$MANIFEST" >/dev/null 2>&1; then
    jq -nc \
      --arg schema_version "$PREFLIGHT_SCHEMA_VERSION" \
      --arg status "$status" \
      --arg root "$PROJECT_ROOT" \
      --arg manifest "$(relative_to_root "$MANIFEST")" \
      --slurpfile dirty_paths "$STATUS_JSON" \
      --argjson failures "$failures_json" '
        {
          schema_version: $schema_version,
          status: $status,
          root: $root,
          manifest: $manifest,
          read_only: true,
          dirty_path_count: ($dirty_paths[0] | length),
          manifest_path_count: null,
          hold_item_count: null,
          owned_review_set: [],
          expected_unrelated_paths: [],
          dirty_paths: $dirty_paths[0],
          paths: [],
          hold_items: [],
          failures: $failures
        }'
    return 0
  fi

  jq -nc \
    --arg schema_version "$PREFLIGHT_SCHEMA_VERSION" \
    --arg status "$status" \
    --arg root "$PROJECT_ROOT" \
    --arg manifest "$(relative_to_root "$MANIFEST")" \
    --slurpfile dirty_paths "$STATUS_JSON" \
    --slurpfile manifest_doc "$MANIFEST" \
    --argjson failures "$failures_json" '
      (if ($manifest_doc[0].paths | type) == "array" then $manifest_doc[0].paths else [] end) as $raw_paths
      | (if ($manifest_doc[0].hold_items | type) == "array" then $manifest_doc[0].hold_items else [] end) as $raw_hold_items
      | (if ($manifest_doc[0].owned_review_set | type) == "array" then $manifest_doc[0].owned_review_set else [] end) as $raw_owned_review_set
      | (if ($manifest_doc[0].expected_unrelated_paths | type) == "array" then $manifest_doc[0].expected_unrelated_paths else [] end) as $raw_expected_unrelated_paths
      | ($raw_paths | map(select(type == "object"))) as $paths
      | {
          schema_version: $schema_version,
          status: $status,
          root: $root,
          manifest: $manifest,
          read_only: true,
          dirty_path_count: ($dirty_paths[0] | length),
          manifest_path_count: ($raw_paths | length),
          hold_item_count: ($raw_hold_items | length),
          owned_review_set: ($raw_owned_review_set | sort),
          expected_unrelated_paths: ($raw_expected_unrelated_paths | sort),
          dirty_paths: $dirty_paths[0],
          paths: ($paths | sort_by(.path)),
          hold_items: ($raw_hold_items | map(select(type == "object")) | sort_by(.id // .path // "")),
          failures: $failures
        }'
}

emit_json_input_failure() {
  local context="$1"
  local message="$2"
  local path="$3"

  jq -nc \
    --arg schema_version "$PREFLIGHT_SCHEMA_VERSION" \
    --arg root "$PROJECT_ROOT" \
    --arg manifest "$path" \
    --arg context "$context" \
    --arg message "$message" \
    --arg failure_path "$path" '
      {
        schema_version: $schema_version,
        status: "FAIL",
        root: $root,
        manifest: $manifest,
        read_only: true,
        dirty_path_count: null,
        manifest_path_count: null,
        hold_item_count: null,
        owned_review_set: [],
        expected_unrelated_paths: [],
        dirty_paths: [],
        paths: [],
        hold_items: [],
        failures: [
          {
            context: $context,
            message: $message,
            path: $failure_path
          }
        ]
      }'
}

emit_text_success() {
  printf 'dirty_surface_preflight: PASS\n'
  printf 'root: %s\n' "$PROJECT_ROOT"
  printf 'manifest: %s\n' "$(relative_to_root "$MANIFEST")"
  printf 'read_only: true\n'
  printf 'dirty_path_count: %s\n' "$(jq -r 'length' "$STATUS_JSON")"
  printf 'manifest_path_count: %s\n' "$(jq -r '.paths | length' "$MANIFEST")"
  printf 'hold_item_count: %s\n' "$(jq -r '(.hold_items // []) | length' "$MANIFEST")"
  printf 'owned_review_set:\n'
  jq -r '.owned_review_set | sort[] | "  " + .' "$MANIFEST"
  printf 'skipped_paths:\n'
  jq -r '
    .paths
    | sort_by(.path)[]
    | select(.include_in_review == false)
    | "  " + .path + " [" + .disposition + "] owner=" + .owner + " reason=" + .reason
  ' "$MANIFEST"
  printf 'hold_items:\n'
  jq -r '
    (.hold_items // [])
    | sort_by(.id // .path // "")[]
    | "  " + (.id // .path // "<missing>") + " [" + .disposition + "] owner=" + .owner + " reason=" + .reason
  ' "$MANIFEST"
}

emit_text_failure() {
  jq -r '.context + ": " + .message + " :: " + .path' "$FAILURES_JSONL" >&2
}

if [[ "$#" -eq 0 ]]; then
  usage
  exit 2
fi

mode=""
json=false
root_input="$DEFAULT_PROJECT_ROOT"
manifest_input="$DEFAULT_MANIFEST_REL"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --check)
      mode="check"
      shift
      ;;
    --json)
      json=true
      shift
      ;;
    --root)
      [[ "$#" -ge 2 ]] || die "--root requires a value"
      root_input="$2"
      shift 2
      ;;
    --manifest)
      [[ "$#" -ge 2 ]] || die "--manifest requires a value"
      manifest_input="$2"
      shift 2
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

[[ "$mode" == "check" ]] || die "missing required --check"

require_cmd git
require_cmd jq

PROJECT_ROOT="$(resolve_root "$root_input")"
if [[ "$manifest_input" == /* ]]; then
  manifest_candidate="$manifest_input"
else
  manifest_candidate="$PROJECT_ROOT/$manifest_input"
fi
if [[ ! -f "$manifest_candidate" ]]; then
  if [[ "$json" == true ]]; then
    emit_json_input_failure "manifest" "missing dirty surface manifest" "$manifest_input"
    exit 1
  fi
  die "missing dirty surface manifest: $manifest_input"
fi
MANIFEST="$(resolve_manifest "$manifest_input")"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-dirty-surface.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

FAILURES_JSONL="$TMP_DIR/failures.jsonl"
STATUS_JSONL="$TMP_DIR/status.jsonl"
STATUS_JSON="$TMP_DIR/status.json"
STATUS_PATHS="$TMP_DIR/status-paths.txt"
MANIFEST_PATHS="$TMP_DIR/manifest-paths.txt"
OWNED_PATHS="$TMP_DIR/owned-review-set.txt"
INCLUDE_PATHS="$TMP_DIR/include-in-review.txt"
: >"$FAILURES_JSONL"

collect_git_status

if validate_schema; then
  if validate_manifest_element_shapes; then
    validate_manifest_records
    validate_owned_review_set_completeness
    validate_hold_items
    validate_status_manifest_match
  fi
fi

if [[ -s "$FAILURES_JSONL" ]]; then
  if [[ "$json" == true ]]; then
    emit_json_result "FAIL"
  else
    emit_text_failure
  fi
  exit 1
fi

if [[ "$json" == true ]]; then
  emit_json_result "PASS"
else
  emit_text_success
fi
