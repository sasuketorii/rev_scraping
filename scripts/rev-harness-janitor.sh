#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -n "${REVHARNESS_JANITOR_PROJECT_ROOT:-}" ]]; then
  PROJECT_ROOT="$(cd "$REVHARNESS_JANITOR_PROJECT_ROOT" && pwd)"
  SCRIPT_DIR="$PROJECT_ROOT/scripts"
fi
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
    '  scripts/rev-harness-janitor.sh stash-gc [--apply] [--max-age-days <D>] [--repo <path>]' \
    '  scripts/rev-harness-janitor.sh build-cleanup [--dry-run] [--apply --ack-rebuild-cost] [--max-age-days <N>] [--json]' \
    '' \
    'Commands:' \
    '  inspect   Read-only bounded summary of tmp size, file count, candidate count, and planned action count.' \
    '  plan      Dry-run candidate plan using harness-active-artifact-pruner.sh.' \
    '  archive   Dry-run report only. This extension slice does not move files.' \
    '  stash-gc  Garbage-collect old graceful-shutdown bail stashes (refs/stash entries whose message starts with revharness-bail- and are older than 14 days). Dry-run by default; --apply opts in to drop. The most recent matching stash is always preserved as a safety net.' \
    '  build-cleanup  Inspect or delete old rebuildable artifacts. Dry-run by default; --apply requires --ack-rebuild-cost.' \
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

emit_stash_gc() {
  local repo_input="${stash_repo_input:-$PROJECT_ROOT}"
  local repo_real=""
  local prefix="${GSD_BAIL_STASH_PREFIX:-revharness-bail-}"
  local age_days="$stash_max_age_days"
  local mode="dry_run"
  local override_days="${GSD_BAIL_STASH_AGE_OVERRIDE_DAYS:-}"
  local now_epoch
  local cutoff_epoch
  local entry_index
  local entry_message
  local entry_epoch
  local first_match_idx=""
  local candidates_csv=""
  local candidates_count=0
  local deleted_count=0

  [[ "$stash_apply" == true ]] && mode="apply"

  [[ -d "$repo_input" ]] || die "stash-gc repo not found: $repo_input"
  repo_real="$(cd "$repo_input" && pwd -P)"
  [[ -d "$repo_real/.git" || -f "$repo_real/.git" ]] || die "stash-gc repo is not a git repository: $repo_real"

  [[ "$age_days" =~ ^[0-9]+$ ]] || die "--max-age-days requires a non-negative integer"

  now_epoch="$(date +%s)"
  cutoff_epoch=$(( now_epoch - age_days * 86400 ))

  # Enumerate stash entries (oldest last; index increases for older).
  # Format: <index>\t<unix-epoch>\t<message>
  while IFS=$'\t' read -r entry_index entry_epoch entry_message; do
    [[ -n "$entry_index" ]] || continue
    # `git stash push -m` usually produces "On <branch>: <message>"; accept
    # either that form or a raw message beginning with the configured prefix.
    case "$entry_message" in
      *": $prefix"*) ;;
      "$prefix"*) ;;
      *) continue ;;
    esac

    # First match in list-order (newest by git's ordering): preserve.
    if [[ -z "$first_match_idx" ]]; then
      first_match_idx="$entry_index"
      continue
    fi

    # Age judgment with optional override for test isolation.
    if [[ -n "$override_days" ]]; then
      [[ "$override_days" =~ ^[0-9]+$ ]] || die "GSD_BAIL_STASH_AGE_OVERRIDE_DAYS must be a non-negative integer"
      :
    else
      [[ "$entry_epoch" =~ ^[0-9]+$ ]] || continue
      (( entry_epoch <= cutoff_epoch )) || continue
    fi

    candidates_count=$(( candidates_count + 1 ))
    if [[ -z "$candidates_csv" ]]; then
      candidates_csv="$entry_index"
    else
      candidates_csv="$candidates_csv,$entry_index"
    fi
  done < <(git -C "$repo_real" stash list --format='%gd%x09%ct%x09%gs' 2>/dev/null || true)

  printf 'janitor_command: stash-gc\n'
  printf 'repo: %s\n' "$repo_real"
  printf 'mode: %s\n' "$mode"
  printf 'bail_prefix: %s\n' "$prefix"
  printf 'max_age_days: %s\n' "$age_days"
  if [[ -n "$first_match_idx" ]]; then
    printf 'preserved_latest: %s\n' "$first_match_idx"
  else
    printf 'preserved_latest: none\n'
  fi
  printf 'candidate_count: %s\n' "$candidates_count"
  if [[ -n "$candidates_csv" ]]; then
    printf 'candidates: %s\n' "$candidates_csv"
  else
    printf 'candidates: none\n'
  fi

  if [[ "$stash_apply" == true && "$candidates_count" -gt 0 ]]; then
    # Drop from highest-index first to avoid re-numbering.
    local sorted=()
    IFS=',' read -r -a sorted <<<"$candidates_csv"
    local n
    local -a nums=()
    for entry_index in "${sorted[@]}"; do
      n="${entry_index#stash@\{}"
      n="${n%\}}"
      nums+=("$n")
    done
    local i j tmp
    for ((i = 0; i < ${#nums[@]}; i++)); do
      for ((j = i + 1; j < ${#nums[@]}; j++)); do
        if (( nums[j] > nums[i] )); then
          tmp="${nums[i]}"; nums[i]="${nums[j]}"; nums[j]="$tmp"
        fi
      done
    done
    for n in "${nums[@]}"; do
      if git -C "$repo_real" stash drop --quiet "stash@{$n}" >/dev/null 2>&1; then
        deleted_count=$(( deleted_count + 1 ))
        printf 'dropped: stash@{%s}\n' "$n"
      else
        printf 'drop_failed: stash@{%s}\n' "$n"
      fi
    done
  fi

  printf 'deleted_count: %s\n' "$deleted_count"

  # Write metrics inside the selected repo so isolated test runs do not touch
  # this harness checkout unless --repo points here.
  local metrics_dir="$repo_real/.agent/metrics"
  local metrics_file="$metrics_dir/wrapper_events.jsonl"
  if mkdir -p "$metrics_dir" 2>/dev/null; then
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"event":"janitor_gc","ts":"%s","mode":"%s","candidates":%s,"deleted":%s}\n' \
      "$ts" "$mode" "$candidates_count" "$deleted_count" \
      >> "$metrics_file" || true
  fi

  return 0
}

build_cleanup_path_mtime_epoch() {
  local path="$1"
  local mtime=""

  if mtime="$(stat -f '%m' "$path" 2>/dev/null)" && [[ "$mtime" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$mtime"
    return 0
  fi
  if mtime="$(stat -c '%Y' "$path" 2>/dev/null)" && [[ "$mtime" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$mtime"
    return 0
  fi
  printf '0\n'
}

build_cleanup_newest_mtime_epoch() {
  local path="$1"
  local newest=0
  local item=""
  local item_mtime=0

  newest="$(build_cleanup_path_mtime_epoch "$path")"
  while IFS= read -r -d '' item; do
    item_mtime="$(build_cleanup_path_mtime_epoch "$item")"
    (( item_mtime > newest )) && newest="$item_mtime"
  done < <(find "$path" -mindepth 1 -print0 2>/dev/null || true)

  printf '%s\n' "$newest"
}

build_cleanup_size_bytes() {
  local path="$1"
  local size_kib=""
  local size_bytes=""

  if size_bytes="$(du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}')" \
    && [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$size_bytes"
    return 0
  fi
  if size_kib="$(du -s -k "$path" 2>/dev/null | awk '{print $1}')" \
    && [[ "$size_kib" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$((size_kib * 1024))"
    return 0
  fi
  printf '0\n'
}

build_cleanup_iso_utc_from_epoch() {
  local epoch="$1"

  if date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
    return 0
  fi
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

build_cleanup_display_path() {
  local path="$1"

  case "$path" in
    "$PROJECT_ROOT_REAL") printf '.\n' ;;
    "$PROJECT_ROOT_REAL"/*) printf './%s\n' "${path#"$PROJECT_ROOT_REAL"/}" ;;
    "$HOME") printf '~\n' ;;
    "$HOME"/*) printf '~/%s\n' "${path#"$HOME"/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

build_cleanup_append_metrics() {
  local metrics_file="$1"
  local mode="$2"
  local target_count="$3"
  local freed_bytes="$4"
  local protected_skipped="$5"
  local age_threshold_days="$6"
  local ts_oldest_deleted="$7"
  local metrics_dir=""
  local ts=""

  metrics_dir="$(dirname "$metrics_file")"
  mkdir -p "$metrics_dir"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$ts_oldest_deleted" == "null" ]]; then
    jq -nc \
      --arg schema_version "rev-harness-build-cleanup/v1" \
      --arg ts "$ts" \
      --arg event "build_cleanup" \
      --arg mode "$mode" \
      --argjson target_count "$target_count" \
      --argjson freed_bytes "$freed_bytes" \
      --argjson protected_skipped "$protected_skipped" \
      --argjson age_threshold_days "$age_threshold_days" \
      '{
        schema_version: $schema_version,
        ts: $ts,
        event: $event,
        mode: $mode,
        target_count: $target_count,
        freed_bytes: $freed_bytes,
        protected_skipped: $protected_skipped,
        age_threshold_days: $age_threshold_days,
        ts_oldest_deleted: null
      }' >> "$metrics_file"
  else
    jq -nc \
      --arg schema_version "rev-harness-build-cleanup/v1" \
      --arg ts "$ts" \
      --arg event "build_cleanup" \
      --arg mode "$mode" \
      --argjson target_count "$target_count" \
      --argjson freed_bytes "$freed_bytes" \
      --argjson protected_skipped "$protected_skipped" \
      --argjson age_threshold_days "$age_threshold_days" \
      --arg ts_oldest_deleted "$ts_oldest_deleted" \
      '{
        schema_version: $schema_version,
        ts: $ts,
        event: $event,
        mode: $mode,
        target_count: $target_count,
        freed_bytes: $freed_bytes,
        protected_skipped: $protected_skipped,
        age_threshold_days: $age_threshold_days,
        ts_oldest_deleted: $ts_oldest_deleted
      }' >> "$metrics_file"
  fi
}

cmd_build_cleanup() {
  if [[ "${REVHARNESS_PARALLEL_QUIESCE:-0}" == "1" ]]; then
    echo "skip: PARALLEL_QUIESCE active" >&2
    exit 0
  fi

  local apply=false
  local ack=false
  local build_json=false
  local build_max_age_days=14
  local mode="dry_run"
  local on_stop=false
  local now_epoch=""
  local age_cutoff_seconds=0
  local shield_seconds=86400
  local target=""
  local target_real=""
  local target_mtime=0
  local target_age=0
  local target_size=0
  local target_count=0
  local protected_skipped=0
  local freed_bytes=0
  local oldest_deleted_epoch=0
  local ts_oldest_deleted="null"
  local metrics_file="$PROJECT_ROOT_REAL/.agent/metrics/build_cleanup.jsonl"
  local semantic_path=""
  local findings_text=""
  local action=""
  local rm_bin="rm"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)
        apply=false
        shift
        ;;
      --apply)
        apply=true
        shift
        ;;
      --ack-rebuild-cost)
        ack=true
        shift
        ;;
      --max-age-days)
        [[ "$#" -ge 2 ]] || die "--max-age-days requires a value"
        build_max_age_days="$2"
        shift 2
        ;;
      --json)
        build_json=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument for build-cleanup: $1"
        ;;
    esac
  done

  [[ "$build_max_age_days" =~ ^[0-9]+$ ]] || die "--max-age-days requires a non-negative integer"

  if [[ "${REVHARNESS_BUILD_CLEANUP_ON_STOP:-0}" == "1" ]]; then
    on_stop=true
    apply=false
    metrics_file="$PROJECT_ROOT_REAL/.agent/metrics/build_cleanup_hints.jsonl"
  fi

  if [[ "$apply" == true && "$ack" != true ]]; then
    die "build-cleanup --apply requires --ack-rebuild-cost"
  fi

  [[ "$apply" == true ]] && mode="apply"
  [[ -x /bin/rm ]] && rm_bin="/bin/rm"
  now_epoch="$(date +%s)"
  age_cutoff_seconds=$(( build_max_age_days * 86400 ))

  local targets=(
    "$PROJECT_ROOT_REAL/harness-rust/target/debug"
    "$PROJECT_ROOT_REAL/harness-rust/target/incremental"
    "$HOME/.cargo/registry/cache"
  )

  for target in "${targets[@]}"; do
    if [[ ! -e "$target" ]]; then
      protected_skipped=$(( protected_skipped + 1 ))
      continue
    fi
    if [[ -L "$target" ]]; then
      protected_skipped=$(( protected_skipped + 1 ))
      findings_text="${findings_text}protected symlink $(build_cleanup_display_path "$target")"$'\n'
      continue
    fi
    if [[ ! -d "$target" ]]; then
      protected_skipped=$(( protected_skipped + 1 ))
      findings_text="${findings_text}protected non-directory $(build_cleanup_display_path "$target")"$'\n'
      continue
    fi

    target_real="$(cd "$target" && pwd -P)"
    case "$target_real" in
      "$PROJECT_ROOT_REAL/.git"|"$PROJECT_ROOT_REAL/.git"/*|"$PROJECT_ROOT_REAL/.agent/active"|"$PROJECT_ROOT_REAL/.agent/active"*)
        protected_skipped=$(( protected_skipped + 1 ))
        findings_text="${findings_text}protected reserved $(build_cleanup_display_path "$target_real")"$'\n'
        continue
        ;;
      "$PROJECT_ROOT_REAL/harness-rust/target/criterion"|"$PROJECT_ROOT_REAL/harness-rust/target/criterion"*)
        protected_skipped=$(( protected_skipped + 1 ))
        findings_text="${findings_text}protected criterion $(build_cleanup_display_path "$target_real")"$'\n'
        continue
        ;;
    esac

    target_mtime="$(build_cleanup_newest_mtime_epoch "$target_real")"
    target_age=$(( now_epoch - target_mtime ))
    if (( target_age < shield_seconds )); then
      protected_skipped=$(( protected_skipped + 1 ))
      findings_text="${findings_text}protected recent $(build_cleanup_display_path "$target_real")"$'\n'
      continue
    fi
    if (( target_age < age_cutoff_seconds )); then
      protected_skipped=$(( protected_skipped + 1 ))
      findings_text="${findings_text}protected age-threshold $(build_cleanup_display_path "$target_real")"$'\n'
      continue
    fi

    target_size="$(build_cleanup_size_bytes "$target_real")"
    target_count=$(( target_count + 1 ))
    action="would_delete"
    if [[ "$apply" == true ]]; then
      "$rm_bin" -rf -- "$target_real"
      freed_bytes=$(( freed_bytes + target_size ))
      action="deleted"
      if [[ "$oldest_deleted_epoch" -eq 0 || "$target_mtime" -lt "$oldest_deleted_epoch" ]]; then
        oldest_deleted_epoch="$target_mtime"
      fi
    fi
    findings_text="${findings_text}${action} $(build_cleanup_display_path "$target_real") bytes=${target_size}"$'\n'
  done

  if [[ -d "$HOME/.semantic-mcp" ]]; then
    while IFS= read -r -d '' semantic_path; do
      printf 'delegating %s to semantic-mcp gc\n' "$(build_cleanup_display_path "$semantic_path")" >&2
    done < <(find "$HOME/.semantic-mcp" -type f \( -name 'semantic.db' -o -name '*.db' \) -print0 2>/dev/null || true)
  fi

  if [[ "$oldest_deleted_epoch" -gt 0 ]]; then
    ts_oldest_deleted="$(build_cleanup_iso_utc_from_epoch "$oldest_deleted_epoch")"
  fi

  build_cleanup_append_metrics \
    "$metrics_file" \
    "$mode" \
    "$target_count" \
    "$freed_bytes" \
    "$protected_skipped" \
    "$build_max_age_days" \
    "$ts_oldest_deleted"

  if [[ "$build_json" == true ]]; then
    tail -n 1 "$metrics_file"
    return 0
  fi

  printf 'janitor_command: build-cleanup\n'
  printf 'mode: %s\n' "$mode"
  printf 'target_count: %s\n' "$target_count"
  printf 'freed_bytes: %s\n' "$freed_bytes"
  printf 'protected_skipped: %s\n' "$protected_skipped"
  printf 'age_threshold_days: %s\n' "$build_max_age_days"
  if [[ "$on_stop" == true ]]; then
    printf 'hint_file: .agent/metrics/build_cleanup_hints.jsonl\n'
  else
    printf 'metrics_file: .agent/metrics/build_cleanup.jsonl\n'
  fi
  if [[ -n "$findings_text" ]]; then
    printf '%s' "$findings_text"
  fi
}

if [[ "$#" -lt 1 ]]; then
  usage
  exit 2
fi

command="$1"
shift

case "$command" in
  inspect|plan|archive|stash-gc|build-cleanup) ;;
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

stash_apply=false
stash_max_age_days=14
stash_repo_input=""

if [[ "$command" == "stash-gc" ]]; then
  if [[ "${REVHARNESS_PARALLEL_QUIESCE:-0}" == "1" ]]; then
    echo "janitor: stash-gc skipped (REVHARNESS_PARALLEL_QUIESCE=1)" >&2
    exit 0
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --apply)
        stash_apply=true
        shift
        ;;
      --dry-run)
        stash_apply=false
        shift
        ;;
      --max-age-days)
        [[ "$#" -ge 2 ]] || die "--max-age-days requires a value"
        stash_max_age_days="$2"
        shift 2
        ;;
      --repo)
        [[ "$#" -ge 2 ]] || die "--repo requires a value"
        stash_repo_input="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument for stash-gc: $1"
        ;;
    esac
  done
  emit_stash_gc
  exit 0
fi

if [[ "$command" == "build-cleanup" ]]; then
  cmd_build_cleanup "$@"
  exit 0
fi

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
  stash-gc) emit_stash_gc ;;
esac
