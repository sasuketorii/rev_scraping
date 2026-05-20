#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT_REAL="$(cd "$PROJECT_ROOT" && pwd -P)"
TMP_ROOT="$PROJECT_ROOT/.claude/tmp"

usage() {
  cat <<'EOF'
Usage:
  scripts/harness-active-artifact-pruner.sh [--root <path>] [--keep-latest <N>] [--max-age-days <D>] [--json]
  scripts/harness-active-artifact-pruner.sh --execute --archive-dir <path> [--root <path>] [--keep-latest <N>] [--max-age-days <D>] [--json]

Dry-run is the default. Execute mode archives selected run directories instead of deleting them.
Candidates include timestamp-shaped run directories, named mktemp scratch directories,
and directories containing artifact-lifecycle-manifest.json. Unmanifested legacy
artifacts are never safe-delete candidates.
EOF
}

die() {
  printf 'harness-active-artifact-pruner: %s\n' "$*" >&2
  exit 1
}

is_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
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
  local -a parts=()

  abs="$(to_project_abs "$input")"
  abs="$(strip_trailing_slashes "$abs")"
  [[ "$abs" == /* ]] || die "$label must resolve to an absolute path: $input"

  rel="${abs#/}"
  [[ -n "$rel" ]] || return 0

  IFS='/' read -r -a parts <<<"$rel"
  current=""
  for part in "${parts[@]}"; do
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

relative_under_base() {
  local path="$1"
  local base="$2"

  if [[ "$path" == "$base" ]]; then
    printf '\n'
    return 0
  fi

  case "$path" in
    "$base"/*)
      printf '%s\n' "${path:$(( ${#base} + 1 ))}"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

mtime_epoch() {
  local path="$1"
  local output=""

  if output="$(stat -c '%Y' "$path" 2>/dev/null)" && is_nonnegative_integer "$output"; then
    printf '%s\n' "$output"
    return 0
  fi

  if output="$(stat -f '%m' "$path" 2>/dev/null)" && is_nonnegative_integer "$output"; then
    printf '%s\n' "$output"
    return 0
  fi

  die "could not determine integer mtime for path: $path"
}

matches_run_dir_name() {
  local name="$1"

  [[ "$name" =~ ^[0-9]{8}([_-][0-9]{4,6})?([_-].*)?$ ]] && return 0
  [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] && return 0
  [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z_[0-9]+$ ]] && return 0
  [[ "$name" =~ ^packet_[0-9]{8}_[0-9]{4,6}.*$ ]] && return 0
  [[ "$name" =~ ^current-slice-[0-9]{8}T[0-9]{6}Z$ ]] && return 0

  return 1
}

matches_named_scratch_dir_name() {
  local name="$1"

  [[ "$name" =~ ^[A-Za-z0-9._-]+\.[A-Za-z0-9]{6,}$ ]] && return 0
  return 1
}

manifest_value() {
  local manifest="$1"
  local field="$2"

  jq -r --arg field "$field" '.[$field] // "none"' "$manifest" 2>/dev/null || printf 'none\n'
}

manifest_archive_eligible() {
  local dir="$1"
  local manifest="$dir/artifact-lifecycle-manifest.json"
  local schema_version=""
  local state=""
  local latest_pointer=""
  local pinned_baseline=""
  local run_disposable=""
  local superseded_by=""
  local safe_delete_class=""

  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1

  schema_version="$(manifest_value "$manifest" schema_version)"
  state="$(manifest_value "$manifest" state)"
  latest_pointer="$(manifest_value "$manifest" latest_pointer)"
  pinned_baseline="$(manifest_value "$manifest" pinned_baseline)"
  run_disposable="$(manifest_value "$manifest" run_disposable)"
  superseded_by="$(manifest_value "$manifest" superseded_by)"
  safe_delete_class="$(manifest_value "$manifest" safe_delete_class)"

  [[ "$schema_version" == "artifact-lifecycle/v1" ]] || return 1
  [[ "$run_disposable" == "YES" ]] || return 1
  [[ "$latest_pointer" == "none" ]] || return 1
  [[ "$pinned_baseline" == "none" ]] || return 1

  case "$state" in
    superseded)
      [[ -n "$superseded_by" && "$superseded_by" != "none" ]] || return 1
      ;;
    legacy-unclassified) ;;
    *) return 1 ;;
  esac

  case "$safe_delete_class" in
    scratch|archived-managed-run|classified-legacy) return 0 ;;
    *) return 1 ;;
  esac
}

candidate_kind_for_dir() {
  local dir="$1"
  local base=""

  base="$(basename "$dir")"
  if [[ -f "$dir/artifact-lifecycle-manifest.json" ]]; then
    if manifest_archive_eligible "$dir"; then
      printf 'manifest-managed\n'
    else
      printf 'manifest-protected\n'
    fi
    return 0
  fi

  if matches_run_dir_name "$base"; then
    printf 'timestamp-legacy\n'
    return 0
  fi

  if matches_named_scratch_dir_name "$base"; then
    printf 'named-scratch-legacy\n'
    return 0
  fi

  return 1
}

candidate_has_no_tracked_files() {
  local dir="$1"
  local rel=""

  rel="$(relative_under_base "$dir" "$PROJECT_ROOT_REAL")" || return 0
  if [[ -n "${TRACKED_PATHS_UNDER_ROOT:-}" && -f "$TRACKED_PATHS_UNDER_ROOT" ]]; then
    if awk -v prefix="$rel/" 'index($0, prefix) == 1 { found = 1; exit } END { exit found ? 0 : 1 }' "$TRACKED_PATHS_UNDER_ROOT"; then
      return 1
    fi
    return 0
  fi
  [[ -z "$(git -C "$PROJECT_ROOT" ls-files -- "$rel/")" ]]
}

append_candidate_dir() {
  local dir="$1"
  local real_dir=""

  [[ -d "$dir" && ! -L "$dir" ]] || return 0
  real_dir="$(cd "$dir" && pwd -P)" || return 0
  is_under_or_equal "$real_dir" "$ROOT_REAL" || return 0
  printf '%s\n' "$real_dir" >>"$DISCOVERED_DIRS_FILE"
}

discover_candidate_dirs() {
  local runs_dir=""
  local manifest=""
  local child=""

  : >"$DISCOVERED_DIRS_FILE"

  # Known direct scratch/run roots keep legacy fixture behavior without walking
  # every descendant directory as a candidate.
  while IFS= read -r -d '' child; do
    append_candidate_dir "$child"
  done < <(find "$ROOT_REAL" -mindepth 1 -maxdepth 1 -type d -print0)

  # Legacy task-scoped runs use one grouping directory, for example
  # task-a/20200101_000001. Keep discovery bounded to this established shape.
  while IFS= read -r -d '' child; do
    append_candidate_dir "$child"
  done < <(find "$ROOT_REAL" -mindepth 2 -maxdepth 2 -type d -print0)

  # Harness runs are conventionally direct children of directories named runs.
  while IFS= read -r -d '' runs_dir; do
    while IFS= read -r -d '' child; do
      append_candidate_dir "$child"
    done < <(find "$runs_dir" -mindepth 1 -maxdepth 1 -type d -print0)
  done < <(find "$ROOT_REAL" -mindepth 1 -maxdepth 6 -type d -name runs -print0)

  # Manifest-managed directories are discovered by the manifest filename, not
  # by treating every directory under .claude/tmp as a possible candidate.
  while IFS= read -r -d '' manifest; do
    append_candidate_dir "$(dirname "$manifest")"
  done < <(find "$ROOT_REAL" -mindepth 2 -maxdepth 8 -type f -name artifact-lifecycle-manifest.json -print0)

  LC_ALL=C sort -u "$DISCOVERED_DIRS_FILE"
}

preflight_destination_parent_chain() {
  local dest="$1"
  local parent=""
  local rel_parent=""
  local current=""
  local part=""
  local -a parts=()

  parent="$(dirname "$dest")"
  is_under_or_equal "$parent" "$ARCHIVE_REAL" \
    || die "archive destination parent escaped archive dir: $parent"

  rel_parent="$(relative_under_base "$parent" "$ARCHIVE_REAL")"
  rel_parent="${rel_parent#/}"
  [[ -n "$rel_parent" ]] || return 0

  IFS='/' read -r -a parts <<<"$rel_parent"
  current="$ARCHIVE_REAL"
  for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != "." && "$part" != ".." ]] \
      || die "unsafe archive destination parent: $parent"
    current="$current/$part"
    if [[ -e "$current" || -L "$current" ]]; then
      [[ -d "$current" && ! -L "$current" ]] \
        || die "archive destination parent is not a directory: $current"
    fi
  done
}

root_input=".claude/tmp"
keep_latest=20
max_age_days=14
execute=false
json=false
archive_input=""

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
      shift 2
      ;;
    --execute)
      execute=true
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

is_nonnegative_integer "$keep_latest" || die "--keep-latest must be a non-negative integer"
is_nonnegative_integer "$max_age_days" || die "--max-age-days must be a non-negative integer"
[[ -d "$TMP_ROOT" ]] || die "missing harness tmp root: $TMP_ROOT"

TMP_ROOT_REAL="$(cd "$TMP_ROOT" && pwd -P)"
ROOT_REAL="$(canonical_existing_dir "--root" "$root_input")"

is_under_or_equal "$ROOT_REAL" "$TMP_ROOT_REAL" \
  || die "--root must be inside $TMP_ROOT_REAL"

ARCHIVE_REAL=""
if [[ "$execute" == true ]]; then
  [[ -n "$archive_input" ]] || die "--execute requires --archive-dir"
  archive_abs="$(to_project_abs "$archive_input")"
  archive_abs="$(strip_trailing_slashes "$archive_abs")"
  [[ "$archive_abs" != "/" ]] || die "--archive-dir cannot be /"
  [[ ! -L "$archive_abs" ]] || die "--archive-dir cannot be a symlink: $archive_input"
  archive_parent="$(dirname "$archive_abs")"
  archive_parent_real="$(canonical_existing_dir "--archive-dir parent" "$archive_parent")"
  is_under_or_equal "$archive_parent_real" "$ROOT_REAL" \
    || die "--archive-dir parent must be inside selected root"
  archive_base="$(basename "$archive_abs")"
  [[ -n "$archive_base" && "$archive_base" != "." && "$archive_base" != ".." ]] \
    || die "unsafe --archive-dir: $archive_input"
  ARCHIVE_REAL="$archive_parent_real/$archive_base"
  if [[ -e "$archive_abs" || -L "$archive_abs" ]]; then
    ARCHIVE_REAL="$(canonical_existing_dir "--archive-dir" "$archive_abs")"
  fi
  [[ "$ARCHIVE_REAL" != "$ROOT_REAL" ]] || die "--archive-dir cannot equal --root"
  is_under_or_equal "$ARCHIVE_REAL" "$ROOT_REAL" \
    || die "--archive-dir must be inside selected root"
fi

now_epoch="$(date +%s)"
cutoff_epoch=$((now_epoch - max_age_days * 86400))
SCAN_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/harness-active-artifact-pruner.XXXXXX")"
DISCOVERED_DIRS_FILE="$SCAN_TMP_DIR/discovered-dirs.txt"
TRACKED_PATHS_UNDER_ROOT="$SCAN_TMP_DIR/tracked-paths-under-root.txt"
trap '/bin/rm -rf "$SCAN_TMP_DIR"' EXIT

if root_rel="$(relative_under_base "$ROOT_REAL" "$PROJECT_ROOT_REAL")"; then
  git -C "$PROJECT_ROOT" ls-files -- "$root_rel/" >"$TRACKED_PATHS_UNDER_ROOT"
else
  : >"$TRACKED_PATHS_UNDER_ROOT"
fi

declare -a sorted_candidates=()
declare -a candidate_dirs=()
declare -a candidate_kinds=()
while IFS= read -r dir; do
  kind="$(candidate_kind_for_dir "$dir")" || continue
  [[ "$kind" != "manifest-protected" ]] || continue
  if [[ -n "$ARCHIVE_REAL" ]] && is_under_or_equal "$dir" "$ARCHIVE_REAL"; then
    continue
  fi
  if ((${#candidate_dirs[@]} > 0)); then
    for candidate_dir in "${candidate_dirs[@]}"; do
      if [[ "$dir" == "$candidate_dir/"* ]]; then
        continue 2
      fi
    done
  fi
  candidate_dirs+=("$dir")
  candidate_kinds+=("$kind")
  rel="$(relative_under_base "$dir" "$ROOT_REAL")" || continue
  sorted_candidates+=("$(mtime_epoch "$dir")"$'\t'"$rel"$'\t'"$dir"$'\t'"$kind")
done < <(discover_candidate_dirs)

if [[ "${#sorted_candidates[@]}" -gt 0 ]]; then
  mapfile -t sorted_candidates < <(printf '%s\n' "${sorted_candidates[@]}" | sort -t $'\t' -k1,1nr -k2,2)
fi

candidate_count="${#sorted_candidates[@]}"
if [[ "$execute" == true ]]; then
  if ((${#candidate_dirs[@]} > 0)); then
    for candidate_dir in "${candidate_dirs[@]}"; do
      is_under_or_equal "$ARCHIVE_REAL" "$candidate_dir" \
        && die "--archive-dir cannot be inside a candidate: $ARCHIVE_REAL"
    done
  fi
  mkdir -p "$archive_abs"
  ARCHIVE_REAL="$(canonical_existing_dir "--archive-dir" "$archive_abs")"
fi

kept_latest_count=0
old_enough_count=0
protected_count=0
action_count=0
declare -a actions=()
declare -a action_sources=()
declare -a action_destinations=()
declare -a action_kinds=()
actions_json="[]"

for idx in "${!sorted_candidates[@]}"; do
  IFS=$'\t' read -r mtime rel dir kind <<<"${sorted_candidates[$idx]}"

  if (( idx < keep_latest )); then
    kept_latest_count=$((kept_latest_count + 1))
    continue
  fi

  if (( mtime > cutoff_epoch )); then
    continue
  fi
  old_enough_count=$((old_enough_count + 1))

  if ! candidate_has_no_tracked_files "$dir"; then
    protected_count=$((protected_count + 1))
    continue
  fi

  action_count=$((action_count + 1))
  actions+=("$rel")
  action_sources+=("$dir")
  action_kinds+=("$kind")

  if [[ "$execute" == true ]]; then
    action_destinations+=("$ARCHIVE_REAL/$rel")
  fi
done

if [[ "$execute" == true ]]; then
  declare -A seen_destinations=()

  for idx in "${!action_sources[@]}"; do
    dir="${action_sources[$idx]}"
    dest="${action_destinations[$idx]}"
    [[ -d "$dir" && ! -L "$dir" ]] || die "candidate changed before archive: $dir"
    [[ ! -e "$dest" && ! -L "$dest" ]] || die "archive destination already exists: $dest"
    [[ -z "${seen_destinations[$dest]:-}" ]] || die "duplicate archive destination: $dest"
    seen_destinations[$dest]=1

    if ((${#action_destinations[@]} > 0)); then
      for other_idx in "${!action_destinations[@]}"; do
        [[ "$other_idx" != "$idx" ]] || continue
        other_dest="${action_destinations[$other_idx]}"
        if is_under_or_equal "$dest" "$other_dest" || is_under_or_equal "$other_dest" "$dest"; then
          die "archive destinations overlap: $dest"
        fi
      done
    fi

    if ((${#candidate_dirs[@]} > 0)); then
      for candidate_dir in "${candidate_dirs[@]}"; do
        is_under_or_equal "$dest" "$candidate_dir" \
          && die "archive destination cannot be inside a candidate: $dest"
      done
    fi

    preflight_destination_parent_chain "$dest"
  done

  for idx in "${!action_sources[@]}"; do
    dir="${action_sources[$idx]}"
    dest="${action_destinations[$idx]}"

    mkdir -p "$(dirname "$dest")"
    mv "$dir" "$dest"
  done
fi

mode="dry-run"
[[ "$execute" == false ]] || mode="archive"

if [[ "$json" == true ]]; then
  if [[ "${#actions[@]}" -gt 0 ]]; then
    actions_json="$(printf '%s\n' "${actions[@]}" | jq -R . | jq -s .)"
  fi

  jq -n \
    --arg root "$ROOT_REAL" \
    --arg archive_dir "$ARCHIVE_REAL" \
    --arg mode "$mode" \
    --argjson dry_run "$([[ "$execute" == true ]] && printf 'false' || printf 'true')" \
    --argjson keep_latest "$keep_latest" \
    --argjson max_age_days "$max_age_days" \
    --argjson candidate_count "$candidate_count" \
    --argjson kept_latest_count "$kept_latest_count" \
    --argjson old_enough_count "$old_enough_count" \
    --argjson protected_count "$protected_count" \
    --argjson action_count "$action_count" \
    --argjson actions "$actions_json" \
    '$ARGS.named'
  exit 0
fi

printf 'root: %s\n' "$ROOT_REAL"
printf 'mode: %s\n' "$mode"
printf 'keep_latest: %s\n' "$keep_latest"
printf 'max_age_days: %s\n' "$max_age_days"
printf 'candidate_count: %s\n' "$candidate_count"
printf 'kept_latest_count: %s\n' "$kept_latest_count"
printf 'old_enough_count: %s\n' "$old_enough_count"
printf 'protected_count: %s\n' "$protected_count"
printf 'action_count: %s\n' "$action_count"

if ((${#actions[@]} > 0)); then
  for idx in "${!actions[@]}"; do
    rel="${actions[$idx]}"
    kind="${action_kinds[$idx]}"
    if [[ "$execute" == true ]]; then
      printf 'archived: %s -> %s (%s)\n' "$rel" "$ARCHIVE_REAL/$rel" "$kind"
    else
      printf 'would_archive: %s (%s)\n' "$rel" "$kind"
    fi
  done
fi
