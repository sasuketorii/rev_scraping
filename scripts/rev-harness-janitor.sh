#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT_REAL="$(cd "$PROJECT_ROOT" && pwd -P)"
TMP_ROOT="$PROJECT_ROOT/.claude/tmp"
PRUNER="$PROJECT_ROOT/scripts/harness-active-artifact-pruner.sh"

PROTECTION_NOTE="Relies on harness-active-artifact-pruner protections: non-symlink .claude/tmp roots, no repo-outside escape, tracked-file protection, latest_pointer/pinned_baseline manifest protection, and archive-only movement."

usage() {
  printf '%s\n' \
    'Usage:' \
    '  scripts/rev-harness-janitor.sh inspect [--root <path>] [--keep-latest <N>] [--max-age-days <D>] [--json] [--full-tree-summary]' \
    '  scripts/rev-harness-janitor.sh plan [--root <path>] [--keep-latest <N>] [--max-age-days <D>] [--json]' \
    '  scripts/rev-harness-janitor.sh archive [--archive-dir <path>] [--root <path>] [--keep-latest <N>] [--max-age-days <D>] [--json] [--dry-run]' \
    '' \
    'Commands:' \
    '  inspect   Read-only bounded summary of tmp size, file count, candidate count, and planned action count.' \
    '  plan      Dry-run candidate plan using harness-active-artifact-pruner.sh.' \
    '  archive   Dry-run report only. This extension slice does not move files.' \
    '' \
    'Safety:' \
    '  This CLI never deletes files.' \
    '  inspect uses a bounded depth-2 summary by default; full recursive size/count requires --full-tree-summary.' \
    '  This CLI has no apply path; janitor extensions are inspect/plan/archive-report-only.' \
    '  Janitor extensions only report stale evidence, dirty-surface, worker-lifecycle, and reviewer-capsule manifest residue.' \
    '  Active lineage and release evidence are protected by the existing pruner checks:' \
    '    - root must be a non-symlink directory inside repo-local .claude/tmp' \
    '    - symlink/path escape roots and archive destinations fail closed' \
    '    - tracked files are not archived' \
    '    - manifest latest_pointer and pinned_baseline runs are protected' \
    '    - unmanifested legacy artifacts are archive-only candidates, never safe-delete candidates' \
    '  archive is non-mutating in this slice; live movement requires a separately reviewed authorization manifest.'
}

die() {
  printf 'rev-harness-janitor: %s\n' "$*" >&2
  exit 2
}

require_pruner() {
  [[ -f "$PRUNER" && ! -L "$PRUNER" ]] || die "missing existing pruner: $PRUNER"
}

to_project_abs() {
  local input="$1"
  [[ -n "$input" ]] || die "path cannot be empty"

  if [[ "$input" == /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s/%s\n' "$PROJECT_ROOT" "$input"
  fi
}

strip_trailing_slashes() {
  local path="$1"

  while [[ "$path" != "/" && "$path" == */ ]]; do
    path="${path%/}"
  done
  printf '%s\n' "$path"
}

reject_symlink_path_components() {
  local label="$1"
  local input="$2"
  local abs=""
  local rel=""
  local current=""
  local part=""
  local remaining=""

  abs="$(to_project_abs "$input")"
  abs="$(strip_trailing_slashes "$abs")"
  [[ "$abs" == /* ]] || die "$label must resolve to an absolute path: $input"

  rel="${abs#/}"
  [[ -n "$rel" ]] || return 0

  current=""
  remaining="$rel"
  while [[ -n "$remaining" ]]; do
    if [[ "$remaining" == */* ]]; then
      part="${remaining%%/*}"
      remaining="${remaining#*/}"
    else
      part="$remaining"
      remaining=""
    fi
    [[ -n "$part" ]] || continue
    [[ "$part" == "." ]] && continue
    current="$current/$part"
    [[ ! -L "$current" ]] || die "$label cannot contain a symlink path component: $input"
  done
}

canonical_existing_dir() {
  local label="$1"
  local input="$2"
  local abs=""

  abs="$(to_project_abs "$input")"
  abs="$(strip_trailing_slashes "$abs")"
  [[ "$abs" != "/" ]] || die "$label cannot be /"
  reject_symlink_path_components "$label" "$input"
  [[ ! -L "$abs" ]] || die "$label cannot be a symlink: $input"
  [[ -d "$abs" ]] || die "$label must be an existing directory: $input"

  (cd "$abs" && pwd -P)
}

is_under_or_equal() {
  local path="$1"
  local base="$2"

  [[ "$path" == "$base" || "$path" == "$base/"* ]]
}

validate_archive_dir() {
  local archive_abs=""
  local archive_parent=""
  local archive_parent_real=""
  local archive_base=""
  local archive_real=""
  local tmp_root_real=""
  local root_real=""

  [[ -d "$TMP_ROOT" ]] || die "missing harness tmp root: $TMP_ROOT"
  tmp_root_real="$(cd "$TMP_ROOT" && pwd -P)"
  root_real="$(canonical_existing_dir "--root" "$root_input")"
  is_under_or_equal "$root_real" "$tmp_root_real" \
    || die "--root must be inside $tmp_root_real"

  archive_abs="$(to_project_abs "$archive_input")"
  archive_abs="$(strip_trailing_slashes "$archive_abs")"
  [[ "$archive_abs" != "/" ]] || die "--archive-dir cannot be /"
  reject_symlink_path_components "--archive-dir" "$archive_input"
  [[ ! -L "$archive_abs" ]] || die "--archive-dir cannot be a symlink: $archive_input"

  archive_parent="$(dirname "$archive_abs")"
  archive_parent_real="$(canonical_existing_dir "--archive-dir parent" "$archive_parent")"
  is_under_or_equal "$archive_parent_real" "$root_real" \
    || die "--archive-dir parent must be inside selected root"

  archive_base="$(basename "$archive_abs")"
  [[ -n "$archive_base" && "$archive_base" != "." && "$archive_base" != ".." ]] \
    || die "unsafe --archive-dir: $archive_input"

  archive_real="$archive_parent_real/$archive_base"
  if [[ -e "$archive_abs" || -L "$archive_abs" ]]; then
    archive_real="$(canonical_existing_dir "--archive-dir" "$archive_abs")"
  fi
  [[ "$archive_real" != "$root_real" ]] || die "--archive-dir cannot equal --root"
  is_under_or_equal "$archive_real" "$root_real" \
    || die "--archive-dir must be inside selected root"
  is_under_or_equal "$archive_real" "$PROJECT_ROOT_REAL" \
    || die "--archive-dir must be inside repository"
}

validated_root_real() {
  local tmp_root_real=""
  local root_real=""

  [[ -d "$TMP_ROOT" ]] || die "missing harness tmp root: $TMP_ROOT"
  tmp_root_real="$(cd "$TMP_ROOT" && pwd -P)"
  root_real="$(canonical_existing_dir "--root" "$root_input")"
  is_under_or_equal "$root_real" "$tmp_root_real" \
    || die "--root must be inside $tmp_root_real"
  printf '%s\n' "$root_real"
}

run_pruner_dry_json() {
  bash "$PRUNER" \
    --root "$root_input" \
    --keep-latest "$keep_latest" \
    --max-age-days "$max_age_days" \
    --json
}

run_pruner_dry_text() {
  bash "$PRUNER" \
    --root "$root_input" \
    --keep-latest "$keep_latest" \
    --max-age-days "$max_age_days"
}

json_enrich() {
  local janitor_command="$1"
  local archive_enabled="$2"
  local pruner_json="$3"
  local root_real=""
  local extensions_json=""

  root_real="$(printf '%s\n' "$pruner_json" | jq -r '.root')"
  extensions_json="$(collect_janitor_extensions "$root_real")"

  printf '%s\n' "$pruner_json" | jq -c \
    --arg schema_version "rev-harness-janitor/v1" \
    --arg janitor_command "$janitor_command" \
    --arg protected_evidence "$PROTECTION_NOTE" \
    --argjson archive_enabled "$archive_enabled" \
    --argjson janitor_extensions "$extensions_json" \
    '. + {
      schema_version: $schema_version,
      janitor_command: $janitor_command,
      delete_enabled: false,
      archive_enabled: $archive_enabled,
      apply_enabled: false,
      protected_evidence: $protected_evidence,
      janitor_extensions: $janitor_extensions
    }'
}

collect_janitor_extensions() {
  local root_real="$1"
  local file=""
  local rel=""
  local findings_json="[]"
  local finding_json=""

  while IFS= read -r -d '' file; do
    rel="${file#"$root_real"/}"
    finding_json="$(jq -c \
      --arg path "$rel" \
      '
        (.schema_version // "") as $schema_version
        | ((.reviewer_capsule | type) == "object") as $has_reviewer_capsule
        | ((.owned_review_set | type) == "array") as $has_owned_review_set
        | (((.workers | type) == "array") and all(.workers[]; ((.artifact_paths | type) == "array"))) as $has_worker_artifact_paths
        | (
            if $schema_version == "rev-harness-evidence-manifest/v1" then "evidence_manifest"
            elif $schema_version == "rev-harness-dirty-surface/v1" then "dirty_surface_manifest"
            elif $schema_version == "rev-harness-worker-lifecycle/v1" then "worker_lifecycle_manifest"
            elif $has_reviewer_capsule then "reviewer_capsule_reference"
            else "" end
          ) as $residue_type
        | select($residue_type != "")
        | {
            path: $path,
            residue_type: $residue_type,
            schema_version: $schema_version,
            planned_action: "inspect-only",
            delete_enabled: false,
            archive_only_candidate: true,
            has_reviewer_capsule: $has_reviewer_capsule,
            has_owned_review_set: $has_owned_review_set,
            has_worker_artifact_paths: $has_worker_artifact_paths
          }
      ' "$file" 2>/dev/null || true)"
    [[ -n "$finding_json" ]] || continue

    findings_json="$(jq -c \
      --argjson findings "$findings_json" \
      --argjson finding "$finding_json" \
      '$findings + [$finding]' <<<"{}")"
  done < <(
    find "$root_real" -maxdepth 3 -type f \
      \( -name 'evidence-manifest.json' -o \
         -name 'dirty-surface.json' -o \
         -name 'worker-lifecycle.json' -o \
         -name 'final-reviewer-capsule.json' \) \
      -print0
  )

  jq -nc \
    --arg schema_version "rev-harness-janitor-extensions/v1" \
    --argjson findings "$findings_json" \
    '{
      schema_version: $schema_version,
      delete_enabled: false,
      apply_enabled: false,
      project_state_mutation_enabled: false,
      extension_points: [
        "stale evidence manifest residue detection",
        "dirty surface manifest residue detection",
        "worker lifecycle manifest residue detection",
        "final reviewer capsule reference detection"
      ],
      findings: $findings,
      finding_count: ($findings | length)
    }'
}

emit_extension_text() {
  local root_real="$1"
  local extensions_json=""

  extensions_json="$(collect_janitor_extensions "$root_real")"
  printf 'janitor_extension_schema: rev-harness-janitor-extensions/v1\n'
  printf 'janitor_extension_delete_enabled: false\n'
  printf 'janitor_extension_apply_enabled: false\n'
  printf 'janitor_extension_finding_count: %s\n' "$(printf '%s\n' "$extensions_json" | jq -r '.finding_count')"
  printf '%s\n' "$extensions_json" | jq -r '.findings[] | "janitor_extension_finding: \(.residue_type) \(.path) planned_action=\(.planned_action)"'
}

collect_tmp_size_bytes() {
  local root="$1"
  local size_kib=""
  local file=""
  local file_size=""
  local total=0

  if [[ "$full_tree_summary" == true ]]; then
    size_kib="$(du -sk "$root" | awk '{print $1}')"
    [[ "$size_kib" =~ ^[0-9]+$ ]] || die "could not determine tmp size for: $root"
    printf '%s\n' "$((size_kib * 1024))"
    return 0
  fi

  while IFS= read -r -d '' file; do
    if file_size="$(stat -c '%s' "$file" 2>/dev/null)" && [[ "$file_size" =~ ^[0-9]+$ ]]; then
      total=$((total + file_size))
      continue
    fi
    if file_size="$(stat -f '%z' "$file" 2>/dev/null)" && [[ "$file_size" =~ ^[0-9]+$ ]]; then
      total=$((total + file_size))
      continue
    fi
    die "could not determine file size for: $file"
  done < <(find "$root" -maxdepth 2 -type f -print0)

  printf '%s\n' "$total"
}

collect_tmp_file_count() {
  local root="$1"

  if [[ "$full_tree_summary" == true ]]; then
    find "$root" -type f -print | awk 'END {print NR + 0}'
    return 0
  fi

  find "$root" -maxdepth 2 -type f -print | awk 'END {print NR + 0}'
}

emit_inspect() {
  local pruner_json=""
  local root_real=""
  local tmp_size_bytes=""
  local tmp_file_count=""
  local candidate_count=""
  local action_count=""
  local root_real_for_extensions=""

  pruner_json="$(run_pruner_dry_json)"
  root_real="$(printf '%s\n' "$pruner_json" | jq -r '.root')"
  tmp_size_bytes="$(collect_tmp_size_bytes "$root_real")"
  tmp_file_count="$(collect_tmp_file_count "$root_real")"
  candidate_count="$(printf '%s\n' "$pruner_json" | jq -r '.candidate_count // "unknown"')"
  action_count="$(printf '%s\n' "$pruner_json" | jq -r '.action_count // "unknown"')"

  if [[ "$json" == true ]]; then
    json_enrich "inspect" false "$pruner_json" \
      | jq -c \
        --argjson tmp_size_bytes "$tmp_size_bytes" \
        --argjson tmp_file_count "$tmp_file_count" \
        --arg tmp_summary_scope "$([[ "$full_tree_summary" == true ]] && printf 'full-tree' || printf 'bounded-depth-2')" \
        '. + {
          tmp_size_bytes: $tmp_size_bytes,
          tmp_file_count: $tmp_file_count,
          tmp_summary_scope: $tmp_summary_scope
        }'
    return 0
  fi

  printf 'janitor_command: inspect\n'
  printf 'root: %s\n' "$root_real"
  printf 'mode: dry-run\n'
  printf 'delete_enabled: false\n'
  printf 'archive_enabled: false\n'
  printf 'tmp_summary_scope: %s\n' "$([[ "$full_tree_summary" == true ]] && printf 'full-tree' || printf 'bounded-depth-2')"
  printf 'tmp_size_bytes: %s\n' "$tmp_size_bytes"
  printf 'tmp_file_count: %s\n' "$tmp_file_count"
  printf 'candidate_count: %s\n' "$candidate_count"
  printf 'action_count: %s\n' "$action_count"
  printf 'protected_evidence: %s\n' "$PROTECTION_NOTE"
  root_real_for_extensions="$(validated_root_real)"
  emit_extension_text "$root_real_for_extensions"
}

emit_plan() {
  local pruner_json=""

  if [[ "$json" == true ]]; then
    pruner_json="$(run_pruner_dry_json)"
    json_enrich "plan" false "$pruner_json"
    return 0
  fi

  printf 'janitor_command: plan\n'
  printf 'delete_enabled: false\n'
  printf 'archive_enabled: false\n'
  printf 'protected_evidence: %s\n' "$PROTECTION_NOTE"
  emit_extension_text "$(validated_root_real)"
  run_pruner_dry_text
}

emit_archive() {
  local pruner_json=""

  if [[ "$json" == true ]]; then
    pruner_json="$(run_pruner_dry_json)"
    json_enrich "archive" false "$pruner_json"
    return 0
  fi

  printf 'janitor_command: archive\n'
  printf 'delete_enabled: false\n'
  printf 'archive_enabled: false\n'
  if [[ "$archive_dir_set" == true ]]; then
    printf 'archive_dir: %s\n' "$archive_input"
  else
    printf 'archive_dir: none\n'
  fi
  printf 'note: archive command is dry-run/report-only in this slice; live movement requires a reviewed authorization manifest.\n'
  printf 'protected_evidence: %s\n' "$PROTECTION_NOTE"
  emit_extension_text "$(validated_root_real)"
  run_pruner_dry_text
}

if [[ "$#" -lt 1 ]]; then
  usage
  exit 2
fi

command="$1"
shift

case "$command" in
  inspect|plan|archive) ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    die "unknown command: $command"
    ;;
esac

root_input=".claude/tmp"
keep_latest=20
max_age_days=14
json=false
archive_input=""
archive_dir_set=false
full_tree_summary=false

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --root)
      [[ "$#" -ge 2 ]] || die "--root requires a value"
      root_input="$2"
      shift 2
      ;;
    --keep-latest)
      [[ "$#" -ge 2 ]] || die "--keep-latest requires a value"
      keep_latest="$2"
      shift 2
      ;;
    --max-age-days)
      [[ "$#" -ge 2 ]] || die "--max-age-days requires a value"
      max_age_days="$2"
      shift 2
      ;;
    --archive-dir)
      [[ "$#" -ge 2 ]] || die "--archive-dir requires a value"
      archive_input="$2"
      archive_dir_set=true
      shift 2
      ;;
    --json)
      json=true
      shift
      ;;
    --dry-run)
      shift
      ;;
    --full-tree-summary)
      full_tree_summary=true
      shift
      ;;
    --execute)
      die "--execute is not accepted by this wrapper; use 'archive --archive-dir <path>' or call harness-active-artifact-pruner.sh directly"
      ;;
    --apply)
      die "apply is not supported"
      ;;
    --delete|--force-delete|--remove|--rm)
      die "delete is not supported"
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

require_pruner

if [[ "$archive_dir_set" == true && -z "$archive_input" ]]; then
  die "--archive-dir requires a non-empty value"
fi

if [[ "$archive_dir_set" == true && "$command" != "archive" ]]; then
  die "--archive-dir is only valid with the archive command"
fi

if [[ "$archive_dir_set" == true ]]; then
  validate_archive_dir
fi

case "$command" in
  inspect) emit_inspect ;;
  plan) emit_plan ;;
  archive) emit_archive ;;
esac
