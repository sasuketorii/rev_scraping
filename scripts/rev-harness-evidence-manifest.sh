#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_ROOT="${REV_HARNESS_EVIDENCE_PROJECT_ROOT:-$DEFAULT_PROJECT_ROOT}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-evidence-manifest.sh validate --manifest <path> [--root <dir>] [--final-acceptance] [--json]

Validate a rev-harness-evidence-manifest/v1 JSON file.

The validator checks required artifact existence, sha256 integrity, command
status, acceptance eligibility, and the final reviewer capsule gates. It does
not grant LGTM, release acceptance, or completion.
EOF
}

die() {
  printf 'rev-harness-evidence-manifest: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

hash_file() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
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

resolve_existing_file_under_root() {
  local rel="$1"
  local abs_path=""
  local parent=""
  local parent_real=""
  local base=""

  is_safe_relative_path "$rel" || return 1
  path_has_symlink_parent "$rel" && return 1

  abs_path="$PROJECT_ROOT/$rel"
  [[ -f "$abs_path" && ! -L "$abs_path" ]] || return 1

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

  resolve_existing_file_under_root "$rel"
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
  local acceptance_eligible="$2"
  local manifest_claimed_acceptance_eligible="$3"
  local derived_final_acceptance_eligible="$4"
  local artifact_count="$5"
  local command_count="$6"
  local failures_json="[]"

  failures_json="$(jq -s '.' "$FAILURES_JSONL")"
  jq -nc \
    --arg schema_version "rev-harness-evidence-manifest/v1" \
    --arg status "$status" \
    --argjson acceptance_eligible "$acceptance_eligible" \
    --argjson manifest_claimed_acceptance_eligible "$manifest_claimed_acceptance_eligible" \
    --argjson derived_final_acceptance_eligible "$derived_final_acceptance_eligible" \
    --argjson final_acceptance_requested "$final_acceptance_requested" \
    --argjson artifact_count "$artifact_count" \
    --argjson command_count "$command_count" \
    --argjson failures "$failures_json" \
    '{
      schema_version: $schema_version,
      status: $status,
      acceptance_eligible: $acceptance_eligible,
      manifest_claimed_acceptance_eligible: $manifest_claimed_acceptance_eligible,
      derived_final_acceptance_eligible: $derived_final_acceptance_eligible,
      final_acceptance_requested: $final_acceptance_requested,
      artifact_count: $artifact_count,
      command_count: $command_count,
      failures: $failures
    }'
}

validate_capsule() {
  local gate=""
  local status=""
  local evidence_path=""

  if ! jq -e '.reviewer_capsule | type == "object"' "$manifest_path" >/dev/null; then
    record_failure "reviewer_capsule" "missing reviewer_capsule object"
    return 0
  fi

  for gate in plan_lgtm implementation_lgtm security_lgtm release_acceptance; do
    if ! jq -e --arg gate "$gate" '.reviewer_capsule[$gate] | type == "object"' "$manifest_path" >/dev/null; then
      record_failure "reviewer_capsule:$gate" "missing distinct gate object"
      continue
    fi
    if ! jq -e --arg gate "$gate" '.reviewer_capsule[$gate].gate == $gate' "$manifest_path" >/dev/null; then
      record_failure "reviewer_capsule:$gate" "gate field must match object key"
    fi
    if ! jq -e --arg gate "$gate" '.reviewer_capsule[$gate].status | type == "string" and length > 0' "$manifest_path" >/dev/null; then
      record_failure "reviewer_capsule:$gate" "missing status"
      continue
    fi
    evidence_path="$(jq -r --arg gate "$gate" '.reviewer_capsule[$gate].evidence_path // empty' "$manifest_path")"
    if [[ -z "$evidence_path" ]]; then
      record_failure "reviewer_capsule:$gate" "missing evidence_path"
      continue
    fi
    if ! is_safe_relative_path "$evidence_path"; then
      record_failure "reviewer_capsule:$gate" "evidence_path must be safe repository-relative path" "$evidence_path"
      continue
    fi
    if ! resolve_existing_file_under_root "$evidence_path" >/dev/null; then
      record_failure "reviewer_capsule:$gate" "evidence_path must resolve to an existing file under root without symlink parents" "$evidence_path"
      continue
    fi
    if ! jq -e --arg path "$evidence_path" '
      any(.artifacts[]?; .path == $path and .required == true)
    ' "$manifest_path" >/dev/null; then
      record_failure "reviewer_capsule:$gate" "evidence_path must match a required artifact" "$evidence_path"
    fi
  done

  for gate in plan_lgtm implementation_lgtm security_lgtm; do
    status="$(jq -r --arg gate "$gate" '.reviewer_capsule[$gate].status // empty' "$manifest_path")"
    case "$status" in
      not-requested|pending|LGTM|BLOCK|"Request Changes"|"Needs verification"|"Needs Discussion"|not-applicable) ;;
      "") ;;
      *) record_failure "reviewer_capsule:$gate" "invalid LGTM gate status: $status" ;;
    esac
  done

  status="$(jq -r '.reviewer_capsule.release_acceptance.status // empty' "$manifest_path")"
  case "$status" in
    not-attempted|"pending acceptance"|accepted|blocked|not-applicable) ;;
    "") ;;
    LGTM)
      record_failure "reviewer_capsule:release_acceptance" "release acceptance must not be represented as LGTM"
      ;;
    *)
      record_failure "reviewer_capsule:release_acceptance" "invalid release acceptance status: $status"
      ;;
  esac
}

validate_artifacts() {
  local index=0
  local artifact=""
  local path=""
  local expected=""
  local required=""
  local abs_path=""
  local actual=""

  if ! jq -e '.artifacts | type == "array"' "$manifest_path" >/dev/null; then
    record_failure "artifacts" "missing artifacts array"
    return 0
  fi

  while IFS= read -r artifact; do
    if ! printf '%s\n' "$artifact" | jq -e 'type == "object"' >/dev/null; then
      record_failure "artifacts[$index]" "artifact entry must be object"
      index=$((index + 1))
      continue
    fi

    path="$(printf '%s\n' "$artifact" | jq -r '.path // empty')"
    expected="$(printf '%s\n' "$artifact" | jq -r '.sha256 // empty')"
    required=""
    if printf '%s\n' "$artifact" | jq -e 'has("required") and (.required | type == "boolean")' >/dev/null; then
      required="$(printf '%s\n' "$artifact" | jq -r '.required')"
    fi

    if ! printf '%s\n' "$artifact" | jq -e 'has("required") and (.required | type == "boolean")' >/dev/null; then
      record_failure "artifacts[$index]" "required must be boolean" "$path"
    fi
    if ! is_safe_relative_path "$path"; then
      record_failure "artifacts[$index]" "artifact path must be safe repository-relative path" "$path"
      index=$((index + 1))
      continue
    fi
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
      record_failure "artifacts[$index]" "sha256 must be 64 hex characters" "$path"
      index=$((index + 1))
      continue
    fi

    if ! abs_path="$(resolve_existing_file_under_root "$path")"; then
      record_failure "artifacts[$index]" "missing artifact file or unsafe symlink/realpath escape" "$path"
      index=$((index + 1))
      continue
    fi

    actual="$(hash_file "$abs_path")"
    actual="$(printf '%s' "$actual" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    expected="$(printf '%s' "$expected" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [[ "$actual" != "$expected" ]]; then
      record_failure "artifacts[$index]" "sha256 mismatch" "$path"
    fi

    index=$((index + 1))
  done < <(jq -c '.artifacts[]?' "$manifest_path")
}

validate_commands() {
  local index=0
  local command_entry=""
  local command_text=""
  local status=""
  local required=""

  if ! jq -e '.commands | type == "array"' "$manifest_path" >/dev/null; then
    record_failure "commands" "missing commands array"
    return 0
  fi

  while IFS= read -r command_entry; do
    if ! printf '%s\n' "$command_entry" | jq -e 'type == "object"' >/dev/null; then
      record_failure "commands[$index]" "command entry must be object"
      index=$((index + 1))
      continue
    fi

    command_text="$(printf '%s\n' "$command_entry" | jq -r '.command // empty')"
    status="$(printf '%s\n' "$command_entry" | jq -r '.status // .result // empty')"
    required=""
    if printf '%s\n' "$command_entry" | jq -e 'has("required") and (.required | type == "boolean")' >/dev/null; then
      required="$(printf '%s\n' "$command_entry" | jq -r '.required')"
    fi

    [[ -n "$command_text" ]] || record_failure "commands[$index]" "missing command"
    if ! printf '%s\n' "$command_entry" | jq -e 'has("required") and (.required | type == "boolean")' >/dev/null; then
      record_failure "commands[$index]" "required must be boolean"
    fi
    case "$status" in
      PASS|FAIL|SKIPPED|BLOCKED) ;;
      "") record_failure "commands[$index]" "missing command status" ;;
      *) record_failure "commands[$index]" "invalid command status: $status" ;;
    esac
    if [[ "$required" == "true" && "$status" != "PASS" ]]; then
      record_failure "commands[$index]" "required command did not PASS: $status"
    fi
    if [[ "$required" == "false" && "$status" == "SKIPPED" ]]; then
      if ! printf '%s\n' "$command_entry" | jq -e '.reason | type == "string" and length > 0' >/dev/null; then
        record_failure "commands[$index]" "skipped optional command requires reason"
      fi
    fi

    index=$((index + 1))
  done < <(jq -c '.commands[]?' "$manifest_path")
}

command="${1:-}"
[[ "$command" == "validate" ]] || {
  usage >&2
  exit 2
}
shift

manifest_input=""
json=false
final_acceptance_requested=false

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
    --final-acceptance)
      final_acceptance_requested=true
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

require_cmd jq

[[ -n "$manifest_input" ]] || die "--manifest is required"
manifest_path="$(resolve_manifest_under_root "$manifest_input")" || die "manifest must be a regular file under root without symlink parents: $manifest_input"
jq empty "$manifest_path" >/dev/null || die "manifest is not valid JSON: $manifest_input"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-evidence.XXXXXX")"
FAILURES_JSONL="$TMP_DIR/failures.jsonl"
: >"$FAILURES_JSONL"
trap '/bin/rm -rf "$TMP_DIR"' EXIT

if ! jq -e '.schema_version == "rev-harness-evidence-manifest/v1"' "$manifest_path" >/dev/null; then
  record_failure "schema_version" "expected rev-harness-evidence-manifest/v1"
fi
if ! jq -e '.acceptance_eligible | type == "boolean"' "$manifest_path" >/dev/null; then
  record_failure "acceptance_eligible" "acceptance_eligible must be boolean"
fi

validate_artifacts
validate_commands
validate_capsule

manifest_acceptance_eligible="$(jq -r 'if (.acceptance_eligible | type) == "boolean" then .acceptance_eligible else false end' "$manifest_path")"
derived_final_acceptance_eligible=false
if [[ "$(failure_count)" == "0" ]] && jq -e '
  .reviewer_capsule.plan_lgtm.status == "LGTM"
  and .reviewer_capsule.implementation_lgtm.status == "LGTM"
  and .reviewer_capsule.security_lgtm.status == "LGTM"
  and .reviewer_capsule.release_acceptance.status == "accepted"
' "$manifest_path" >/dev/null; then
  derived_final_acceptance_eligible=true
fi

acceptance_eligible="$derived_final_acceptance_eligible"
if [[ "$final_acceptance_requested" == true && "$manifest_acceptance_eligible" != "true" ]]; then
  record_failure "acceptance_eligible" "final acceptance requested while acceptance_eligible is false"
fi
if [[ "$final_acceptance_requested" == true && "$derived_final_acceptance_eligible" != "true" ]]; then
  record_failure "reviewer_capsule" "final acceptance requires all capsule gates accepted with verified evidence"
fi

artifact_count="$(jq '.artifacts // [] | length' "$manifest_path")"
command_count="$(jq '.commands // [] | length' "$manifest_path")"
failures="$(failure_count)"

if [[ "$failures" == "0" ]]; then
  if [[ "$json" == true ]]; then
    emit_json "PASS" "$acceptance_eligible" "$manifest_acceptance_eligible" "$derived_final_acceptance_eligible" "$artifact_count" "$command_count"
  else
    printf 'PASS: evidence manifest validation\n'
    printf 'acceptance_eligible: %s\n' "$acceptance_eligible"
    printf 'manifest_claimed_acceptance_eligible: %s\n' "$manifest_acceptance_eligible"
    printf 'derived_final_acceptance_eligible: %s\n' "$derived_final_acceptance_eligible"
    printf 'artifact_count: %s\n' "$artifact_count"
    printf 'command_count: %s\n' "$command_count"
  fi
  exit 0
fi

if [[ "$json" == true ]]; then
  emit_json "FAIL" "$acceptance_eligible" "$manifest_acceptance_eligible" "$derived_final_acceptance_eligible" "$artifact_count" "$command_count"
else
  jq -r '. | "FAIL: \(.context): \(.message)\(if .path == "" then "" else " [" + .path + "]" end)"' "$FAILURES_JSONL" >&2
fi
exit 1
