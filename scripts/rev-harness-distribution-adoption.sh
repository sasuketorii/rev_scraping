#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SKILL_CHECKER="$DEFAULT_PROJECT_ROOT/scripts/rev-harness-skill-projection.sh"
DIRTY_SURFACE_CHECKER="$DEFAULT_PROJECT_ROOT/scripts/rev-harness-dirty-surface.sh"
EVIDENCE_MANIFEST_CHECKER="$DEFAULT_PROJECT_ROOT/scripts/rev-harness-evidence-manifest.sh"
WORKER_LIFECYCLE_CHECKER="$DEFAULT_PROJECT_ROOT/scripts/rev-harness-worker-lifecycle.sh"
DEFAULT_DISTRIBUTION_MANIFEST=".agent/registry/rev_harness_distribution_manifest.json"
DEFAULT_SKILL_MANIFEST=".agent/registry/skill_projection_manifest.json"
DEFAULT_PREREQUISITE_MANIFEST=".agent/registry/rev_harness_distribution_adoption_prerequisites.json"

usage() {
  printf '%s\n' \
    'Usage:' \
    '  scripts/rev-harness-distribution-adoption.sh --check [--json] [--root <path>] [--distribution-manifest <path>] [--skill-manifest <path>] [--prerequisite-manifest <path>]' \
    '' \
    'Verify distribution/adoption prerequisites without publishing, tagging, or installing.' \
    'The preflight fails closed unless active Claude and installed Codex skill paths exist,' \
    'the generated Codex projection remains install-required, and intake-reduction' \
    'prerequisite artifacts are present or explicitly BLOCK/deferred.'
}

die() {
  printf 'rev-harness-distribution-adoption: %s\n' "$*" >&2
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

resolve_root_path() {
  local path="$1"

  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$PROJECT_ROOT" "$path" ;;
  esac
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
  local input="$1"
  local rel=""
  local abs_path=""
  local parent=""
  local parent_real=""
  local base=""

  if [[ "$input" == /* ]]; then
    case "$input" in
      "$PROJECT_ROOT"/*) rel="${input#"$PROJECT_ROOT"/}" ;;
      *) return 1 ;;
    esac
  else
    rel="$input"
  fi

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

record_prerequisite() {
  local name="$1"
  local status="$2"
  local path="$3"
  local schema_version="$4"
  local reason="$5"

  jq -nc \
    --arg name "$name" \
    --arg status "$status" \
    --arg path "$path" \
    --arg schema_version "$schema_version" \
    --arg reason "$reason" \
    '{name: $name, status: $status, path: $path, schema_version: $schema_version, reason: $reason}' >>"$PREREQUISITES_JSONL"
}

validate_distribution_manifest() {
  if ! DISTRIBUTION_MANIFEST_ABS="$(resolve_existing_file_under_root "$DISTRIBUTION_MANIFEST_DISPLAY")"; then
    record_failure "distribution-manifest" "missing distribution manifest or unsafe symlink/realpath escape" "$DISTRIBUTION_MANIFEST_DISPLAY"
    return 1
  fi
  if ! jq empty "$DISTRIBUTION_MANIFEST_ABS" >/dev/null 2>&1; then
    record_failure "distribution-manifest" "invalid JSON" "$DISTRIBUTION_MANIFEST_DISPLAY"
    return 1
  fi

  jq -e '
    type == "object"
    and .schema_version == "rev-harness-distribution-manifest/v1"
    and .canonical.display_name == "Revharness"
    and .canonical.machine_name == "rev_harness"
    and (.legacy_aliases | type == "array" and index("agent_base") and index("agent-base"))
    and (.source_url | type == "string" and length > 0)
    and .preserve_globs_semantics == "adoption-local-preserve-only"
    and (.preserve_globs | type == "array" and length > 0)
    and (.client_distribution | type == "object")
    and (.client_distribution.exclude_globs | type == "array" and length > 0)
    and (.client_distribution.exclude_globs | index(".agent/archive/**"))
    and (.client_distribution.exclude_globs | index(".claude/tmp/**"))
    and (.client_distribution.exclude_globs | index("workspace/**"))
    and (.client_distribution.exclude_globs | index("~/.semantic-mcp/*/semantic.db"))
    and (.client_distribution.exclude_globs | index("~/.local/share/Revharness/semantic-mcp/v1/*/semantic.db"))
    and (.client_distribution.exclude_globs | index("~/Library/Application Support/Revharness/semantic-mcp/v1/*/semantic.db"))
    and (.client_distribution.exclude_globs | index("%LOCALAPPDATA%\\Revharness\\semantic-mcp\\v1\\*\\semantic.db"))
    and .client_distribution.ship_semantic_db == false
    and (.client_distribution.semantic_db_regeneration | type == "string" and length > 0)
    and (.managed_candidate_globs | type == "array" and length > 0)
  ' "$DISTRIBUTION_MANIFEST_ABS" >/dev/null || {
    record_failure "distribution-manifest" "invalid distribution manifest schema" "$DISTRIBUTION_MANIFEST_DISPLAY"
    return 1
  }
}

validate_required_docs() {
  local rel=""
  local ok=true

  for rel in README.md .agent/PROJECT_CONTEXT.md docs/manual/harness-user-guide.md; do
    if [[ ! -f "$PROJECT_ROOT/$rel" ]]; then
      record_failure "distribution-docs" "missing adoption prerequisite document" "$rel"
      ok=false
    fi
  done

  [[ "$ok" == true ]]
}

run_skill_projection_check() {
  local output=""

  if [[ ! -x "$SKILL_CHECKER" && ! -f "$SKILL_CHECKER" ]]; then
    record_failure "skill-projection" "missing skill projection checker" "scripts/rev-harness-skill-projection.sh"
    return 1
  fi

  if output="$(bash "$SKILL_CHECKER" --root "$PROJECT_ROOT" --manifest "$SKILL_MANIFEST_DISPLAY" --check --json 2>"$TMP_DIR/skill-projection.err")"; then
    printf '%s\n' "$output" >"$SKILL_REPORT_JSON"
  else
    record_failure "skill-projection" "skill projection acceptance check failed" "$SKILL_MANIFEST_DISPLAY"
    if [[ -s "$TMP_DIR/skill-projection.err" ]]; then
      record_failure "skill-projection" "$(tr '\n' ';' <"$TMP_DIR/skill-projection.err")" "$SKILL_MANIFEST_DISPLAY"
    fi
    return 1
  fi

  jq -e '
    .status == "PASS"
    and .mode == "acceptance"
    and .acceptance_eligible == true
    and any(.sources[]; .skill == "rustskills-architecture" and .status == "PASS")
    and any(.projections[]; .skill == "rustskills-architecture" and .provider == "claude" and .activation_status == "project-local-active" and .auto_discoverable == true and .status == "PASS")
    and any(.projections[]; .skill == "rustskills-architecture" and .provider == "codex-installed" and .activation_status == "installed-active" and .auto_discoverable == true and .status == "PASS")
    and any(.projections[]; .skill == "rustskills-architecture" and .provider == "codex-generated" and .activation_status == "install-required" and .auto_discoverable == false and .status == "PASS")
    and all(.projections[]; if .provider == "codex-generated" then (.activation_status == "install-required" and .auto_discoverable == false) else true end)
  ' "$SKILL_REPORT_JSON" >/dev/null || {
    record_failure "skill-projection" "active skill path contract failed" "$SKILL_MANIFEST_DISPLAY"
    return 1
  }
}

validate_prerequisite_manifest_schema() {
  if ! PREREQUISITE_MANIFEST_ABS="$(resolve_existing_file_under_root "$PREREQUISITE_MANIFEST_DISPLAY")"; then
    record_failure "distribution-adoption-prerequisite" "missing prerequisite manifest evidence or unsafe symlink/realpath escape" "$PREREQUISITE_MANIFEST_DISPLAY"
    return 1
  fi
  if ! jq empty "$PREREQUISITE_MANIFEST_ABS" >/dev/null 2>&1; then
    record_failure "distribution-adoption-prerequisite" "invalid prerequisite manifest JSON" "$PREREQUISITE_MANIFEST_DISPLAY"
    return 1
  fi

  jq -e '
    type == "object"
    and .schema_version == "rev-harness-distribution-adoption-prerequisites/v1"
    and (.prerequisites | type == "array" and length > 0)
    and all(.prerequisites[];
      (.name | type == "string" and length > 0)
      and (.status | IN("present", "BLOCK", "deferred"))
      and (if .status == "present" then (.path | type == "string" and length > 0) else (.reason | type == "string" and length > 0) end)
    )
  ' "$PREREQUISITE_MANIFEST_ABS" >/dev/null || {
    record_failure "distribution-adoption-prerequisite" "invalid prerequisite manifest schema" "$PREREQUISITE_MANIFEST_DISPLAY"
    return 1
  }
}

validate_prerequisite_artifact_integrity() {
  local name="$1"
  local path="$2"
  local abs_path="$3"
  local output=""
  local stderr_file="$TMP_DIR/${name//[^A-Za-z0-9_.-]/_}.err"

  case "$name" in
    "dirty surface manifest")
      if ! jq -e '
        .schema_version == "rev-harness-dirty-surface/v1"
        and (.paths | type == "array" and length > 0)
        and (.owned_review_set | type == "array")
      ' "$abs_path" >/dev/null; then
        record_failure "distribution-adoption-prerequisite" "dirty surface artifact is empty or lacks required fields" "$path"
        return 1
      fi
      if output="$(bash "$DIRTY_SURFACE_CHECKER" --root "$PROJECT_ROOT" --manifest "$path" --check --json 2>"$stderr_file")"; then
        if ! printf '%s\n' "$output" | jq -e '.status == "PASS"' >/dev/null; then
          record_failure "distribution-adoption-prerequisite" "dirty surface validator did not PASS" "$path"
          return 1
        fi
      else
        record_failure "distribution-adoption-prerequisite" "dirty surface validator failed" "$path"
        if [[ -s "$stderr_file" ]]; then
          record_failure "distribution-adoption-prerequisite" "$(tr '\n' ';' <"$stderr_file")" "$path"
        fi
        return 1
      fi
      ;;
    "evidence manifest")
      if ! jq -e '
        .schema_version == "rev-harness-evidence-manifest/v1"
        and (.artifacts | type == "array" and length > 0)
        and (.commands | type == "array" and length > 0)
        and (.reviewer_capsule | type == "object")
      ' "$abs_path" >/dev/null; then
        record_failure "distribution-adoption-prerequisite" "evidence manifest artifact is empty or lacks required fields" "$path"
        return 1
      fi
      if output="$(bash "$EVIDENCE_MANIFEST_CHECKER" validate --root "$PROJECT_ROOT" --manifest "$path" --json 2>"$stderr_file")"; then
        if ! printf '%s\n' "$output" | jq -e '.status == "PASS"' >/dev/null; then
          record_failure "distribution-adoption-prerequisite" "evidence manifest validator did not PASS" "$path"
          return 1
        fi
      else
        record_failure "distribution-adoption-prerequisite" "evidence manifest validator failed" "$path"
        if [[ -s "$stderr_file" ]]; then
          record_failure "distribution-adoption-prerequisite" "$(tr '\n' ';' <"$stderr_file")" "$path"
        fi
        return 1
      fi
      ;;
    "worker lifecycle manifest")
      if ! jq -e '
        .schema_version == "rev-harness-worker-lifecycle/v1"
        and (.workers | type == "array" and length > 0)
      ' "$abs_path" >/dev/null; then
        record_failure "distribution-adoption-prerequisite" "worker lifecycle artifact is empty or lacks required fields" "$path"
        return 1
      fi
      if output="$(bash "$WORKER_LIFECYCLE_CHECKER" validate --root "$PROJECT_ROOT" --manifest "$path" --json 2>"$stderr_file")"; then
        if ! printf '%s\n' "$output" | jq -e '.status == "PASS"' >/dev/null; then
          record_failure "distribution-adoption-prerequisite" "worker lifecycle validator did not PASS" "$path"
          return 1
        fi
      else
        record_failure "distribution-adoption-prerequisite" "worker lifecycle validator failed" "$path"
        if [[ -s "$stderr_file" ]]; then
          record_failure "distribution-adoption-prerequisite" "$(tr '\n' ';' <"$stderr_file")" "$path"
        fi
        return 1
      fi
      ;;
    "counter admission preflight"|"schema-micro-fix admission")
      local expected_admission_type=""

      case "$name" in
        "counter admission preflight") expected_admission_type="counter" ;;
        "schema-micro-fix admission") expected_admission_type="schema-micro-fix" ;;
      esac

      if ! jq -e --arg admission_type "$expected_admission_type" '
        .schema_version == "rev-harness-admission-result/v1"
        and .admission_type == $admission_type
        and .status == "ADMIT"
        and .allowed == true
        and .review_intake_allowed == true
        and ((.fail_closed_reasons? // []) | type == "array" and length == 0)
        and (.non_claims | type == "object")
        and .non_claims.acceptance == false
        and .non_claims.completed == false
        and .non_claims.lgtm == false
        and .non_claims.reviewer_waived == false
        and .non_claims.counter_reset == false
      ' "$abs_path" >/dev/null; then
        record_failure "distribution-adoption-prerequisite" "admission result artifact is empty, placeholder, or not an ADMIT non-claim result" "$path"
        return 1
      fi
      ;;
  esac
}

validate_named_prerequisite() {
  local name="$1"
  local expected_schema="$2"
  local count=""
  local status=""
  local path=""
  local schema_version=""
  local reason=""
  local abs_path=""

  count="$(jq -r --arg name "$name" '[.prerequisites[] | select(.name == $name)] | length' "$PREREQUISITE_MANIFEST_ABS")"
  if [[ "$count" != "1" ]]; then
    record_failure "distribution-adoption-prerequisite" "required prerequisite must appear exactly once" "$name"
    return 1
  fi

  status="$(jq -r --arg name "$name" '.prerequisites[] | select(.name == $name) | .status' "$PREREQUISITE_MANIFEST_ABS")"
  path="$(jq -r --arg name "$name" '.prerequisites[] | select(.name == $name) | .path // ""' "$PREREQUISITE_MANIFEST_ABS")"
  schema_version="$(jq -r --arg name "$name" '.prerequisites[] | select(.name == $name) | .schema_version // ""' "$PREREQUISITE_MANIFEST_ABS")"
  reason="$(jq -r --arg name "$name" '.prerequisites[] | select(.name == $name) | .reason // ""' "$PREREQUISITE_MANIFEST_ABS")"

  if [[ "$status" == "present" ]]; then
    if ! is_safe_relative_path "$path"; then
      record_failure "distribution-adoption-prerequisite" "present prerequisite path must be safe repository-relative" "$path"
      return 1
    fi
    if ! abs_path="$(resolve_existing_file_under_root "$path")"; then
      record_failure "distribution-adoption-prerequisite" "present prerequisite artifact missing or unsafe symlink/realpath escape" "$path"
      return 1
    fi
    if [[ -n "$expected_schema" ]]; then
      if [[ "$schema_version" != "$expected_schema" ]]; then
        record_failure "distribution-adoption-prerequisite" "manifest evidence declares wrong schema" "$path"
        return 1
      fi
      if ! jq -e --arg schema "$expected_schema" '.schema_version == $schema' "$abs_path" >/dev/null 2>&1; then
        record_failure "distribution-adoption-prerequisite" "artifact schema does not match prerequisite evidence" "$path"
        return 1
      fi
    fi
    validate_prerequisite_artifact_integrity "$name" "$path" "$abs_path" || return 1
  elif [[ "$status" == "BLOCK" || "$status" == "deferred" ]]; then
    [[ -n "$reason" ]] || {
      record_failure "distribution-adoption-prerequisite" "BLOCK/deferred prerequisite requires a reason" "$name"
      return 1
    }
  else
    record_failure "distribution-adoption-prerequisite" "invalid prerequisite status" "$name"
    return 1
  fi

  record_prerequisite "$name" "$status" "$path" "$schema_version" "$reason"
}

validate_prerequisites() {
  local ok=true

  validate_prerequisite_manifest_schema || return 1
  validate_named_prerequisite "dirty surface manifest" "rev-harness-dirty-surface/v1" || ok=false
  validate_named_prerequisite "evidence manifest" "rev-harness-evidence-manifest/v1" || ok=false
  validate_named_prerequisite "worker lifecycle manifest" "rev-harness-worker-lifecycle/v1" || ok=false
  validate_named_prerequisite "counter admission preflight" "rev-harness-admission-result/v1" || ok=false
  validate_named_prerequisite "schema-micro-fix admission" "rev-harness-admission-result/v1" || ok=false

  [[ "$ok" == true ]]
}

emit_report() {
  local status="$1"

  if [[ "$OUTPUT_JSON" == true ]]; then
    jq -n \
      --arg status "$status" \
      --arg schema_version "rev-harness-distribution-adoption-preflight/v1" \
      --arg distribution_manifest "$DISTRIBUTION_MANIFEST_DISPLAY" \
      --arg skill_manifest "$SKILL_MANIFEST_DISPLAY" \
      --arg prerequisite_manifest "$PREREQUISITE_MANIFEST_DISPLAY" \
      --slurpfile prerequisites "$PREREQUISITES_JSONL" \
      --slurpfile failures "$FAILURES_JSONL" \
      --slurpfile skill_projection "$SKILL_REPORT_JSON" \
      '{
        schema_version: $schema_version,
        status: $status,
        adoption_enabled: ($status == "PASS"),
        publish_enabled: false,
        tag_enabled: false,
        package_enabled: false,
        distribution_manifest: $distribution_manifest,
        skill_manifest: $skill_manifest,
        prerequisite_manifest: $prerequisite_manifest,
        skill_projection: ($skill_projection[0] // null),
        prerequisites: $prerequisites,
        failures: $failures
      }'
    return 0
  fi

  if [[ "$status" == "PASS" ]]; then
    printf 'PASS: distribution/adoption preflight\n'
    printf 'publish_enabled: false\n'
    printf 'tag_enabled: false\n'
    printf 'package_enabled: false\n'
    jq -r '"prerequisite: \(.name) status=\(.status) path=\(.path)"' "$PREREQUISITES_JSONL"
  else
    jq -r '"FAIL: \(.context): \(.message) \(.path)"' "$FAILURES_JSONL" >&2
  fi
}

CHECK=false
OUTPUT_JSON=false
PROJECT_ROOT="$DEFAULT_PROJECT_ROOT"
DISTRIBUTION_MANIFEST_DISPLAY="$DEFAULT_DISTRIBUTION_MANIFEST"
SKILL_MANIFEST_DISPLAY="$DEFAULT_SKILL_MANIFEST"
PREREQUISITE_MANIFEST_DISPLAY="$DEFAULT_PREREQUISITE_MANIFEST"
TMP_DIR=""
FAILURES_JSONL=""
PREREQUISITES_JSONL=""
SKILL_REPORT_JSON=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK=true
      shift
      ;;
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    --root)
      [[ "$#" -ge 2 ]] || die "--root requires a value"
      PROJECT_ROOT="$(cd "$2" && pwd -P)"
      shift 2
      ;;
    --distribution-manifest)
      [[ "$#" -ge 2 ]] || die "--distribution-manifest requires a value"
      DISTRIBUTION_MANIFEST_DISPLAY="$2"
      shift 2
      ;;
    --skill-manifest)
      [[ "$#" -ge 2 ]] || die "--skill-manifest requires a value"
      SKILL_MANIFEST_DISPLAY="$2"
      shift 2
      ;;
    --prerequisite-manifest)
      [[ "$#" -ge 2 ]] || die "--prerequisite-manifest requires a value"
      PREREQUISITE_MANIFEST_DISPLAY="$2"
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

[[ "$CHECK" == true ]] || die "--check is required"
require_cmd jq
require_cmd bash

DISTRIBUTION_MANIFEST_ABS="$(resolve_root_path "$DISTRIBUTION_MANIFEST_DISPLAY")"
PREREQUISITE_MANIFEST_ABS="$(resolve_root_path "$PREREQUISITE_MANIFEST_DISPLAY")"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-distribution-adoption.XXXXXX")"
FAILURES_JSONL="$TMP_DIR/failures.jsonl"
PREREQUISITES_JSONL="$TMP_DIR/prerequisites.jsonl"
SKILL_REPORT_JSON="$TMP_DIR/skill-projection.json"
: >"$FAILURES_JSONL"
: >"$PREREQUISITES_JSONL"
printf 'null\n' >"$SKILL_REPORT_JSON"
trap 'rm -rf "$TMP_DIR"' EXIT

validate_distribution_manifest || true
validate_required_docs || true
run_skill_projection_check || true
validate_prerequisites || true

if [[ -s "$FAILURES_JSONL" ]]; then
  emit_report "FAIL"
  exit 1
fi

emit_report "PASS"
