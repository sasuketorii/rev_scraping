#!/usr/bin/env bash
set -euo pipefail

HARNESS_EXCLUDED_DIRS=(
  ".git"
  ".github"
  ".agent"
  ".claude"
  ".codex"
  ".agent_rules"
  ".shared"
  "scripts"
  "test"
  "tests"
  "docs"
  "artifacts"
  "evidence"
  "tmp"
)

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-src-promote.sh plan --target <dir> [--source src] [--output <file>] [--allow-target-project-root]
  scripts/rev-harness-src-promote.sh apply --plan <file>

Build a dry-run promotion plan for product payload files under source root.
The apply command is intentionally disabled until copy safety is implemented.

Environment:
  REV_HARNESS_SRC_PROMOTE_PROJECT_ROOT  Override project root for tests or wrappers.
EOF
}

die() {
  printf 'rev-harness-src-promote: %s\n' "$*" >&2
  exit 1
}

case_fold_ascii() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

project_root_from_env_or_cwd() {
  local root="${REV_HARNESS_SRC_PROMOTE_PROJECT_ROOT:-$(pwd -P)}"
  [[ -d "$root" ]] || die "project root is not a directory: $root"
  (cd "$root" && pwd -P) || die "cannot resolve project root: $root"
}

PROJECT_ROOT="$(project_root_from_env_or_cwd)"

absolutize_from_project_root() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$PROJECT_ROOT" "$path"
  fi
}

canonical_dir() {
  local label="$1"
  local path="$2"
  [[ -d "$path" ]] || die "$label must be an existing directory: $path"
  (cd "$path" && pwd -P) || die "cannot resolve $label: $path"
}

canonical_parent_dir() {
  local label="$1"
  local path="$2"
  local parent
  parent="$(dirname "$path")"
  [[ -d "$parent" ]] || die "$label parent must be an existing directory: $parent"
  (cd "$parent" && pwd -P) || die "cannot resolve $label parent: $parent"
}

reject_symlink_components() {
  local label="$1"
  local absolute_path="$2"
  local trimmed="${absolute_path%/}"
  local current="/"
  local rest
  local component
  local -a components=()

  [[ "$trimmed" == /* ]] || die "$label must resolve to an absolute path: $absolute_path"
  [[ "$trimmed" == "/" ]] && return 0

  rest="${trimmed#/}"
  IFS='/' read -r -a components <<<"$rest"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != "." ]] || continue
    if [[ "$current" == "/" ]]; then
      current="/$component"
    else
      current="$current/$component"
    fi
    if [[ -L "$current" ]]; then
      die "$label contains a symlink path component: $current"
    fi
  done
}

path_has_git_component() {
  local path="$1"
  local trimmed="${path%/}"
  local folded

  folded="$(case_fold_ascii "$trimmed")"
  [[ "$folded" == ".git" || "$folded" == */.git || "$folded" == */.git/* ]]
}

path_is_within_dir() {
  local path="$1"
  local dir="$2"

  [[ "$path" == "$dir" || "$path" == "$dir/"* ]]
}

is_harness_excluded_top_dir() {
  local name="$1"
  local folded_name
  local excluded
  local folded_excluded

  folded_name="$(case_fold_ascii "$name")"
  for excluded in "${HARNESS_EXCLUDED_DIRS[@]}"; do
    folded_excluded="$(case_fold_ascii "$excluded")"
    [[ "$folded_name" == "$folded_excluded" ]] && return 0
  done
  return 1
}

is_dangerous_source_component() {
  local name="$1"
  is_harness_excluded_top_dir "$name"
}

reject_dangerous_source_components() {
  local rel="$1"
  local component
  local -a components=()

  IFS='/' read -r -a components <<<"$rel"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || continue
    if is_dangerous_source_component "$component"; then
      die "source path contains a dangerous path component: $component"
    fi
  done
}

reject_dangerous_target_components() {
  local target_root="$1"
  local rel
  local component
  local -a components=()

  if [[ "$target_root" == "$PROJECT_ROOT" ]]; then
    return 0
  fi

  path_is_within_dir "$target_root" "$PROJECT_ROOT" || return 0
  rel="${target_root#"$PROJECT_ROOT"/}"

  IFS='/' read -r -a components <<<"$rel"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || continue
    if is_harness_excluded_top_dir "$component"; then
      die "target contains a dangerous path component: $component"
    fi
  done
}

reject_source_root() {
  local source_root="$1"
  local rel

  [[ "$source_root" != "$PROJECT_ROOT" ]] \
    || die "source root must not equal project root; use --source src or another product payload directory"

  path_is_within_dir "$source_root" "$PROJECT_ROOT" \
    || die "source root must be inside project root: $source_root"

  rel="${source_root#"$PROJECT_ROOT"/}"
  reject_dangerous_source_components "$rel"

  if [[ "$rel" != "src" && "$rel" != src/* ]]; then
    die "source root must be src or inside src for this foundation slice: $source_root"
  fi
}

reject_target_root() {
  local target_arg_abs="$1"
  local target_root="$2"
  local source_root="$3"
  local allow_target_project_root="$4"
  local git_root=""

  if path_has_git_component "$target_arg_abs"; then
    die "target must not be inside a .git directory: $target_arg_abs"
  fi

  if [[ -d "$PROJECT_ROOT/.git" ]]; then
    git_root="$(cd "$PROJECT_ROOT/.git" && pwd -P)"
    if path_is_within_dir "$target_root" "$git_root"; then
      die "target must not be inside project .git directory: $target_root"
    fi
  fi

  reject_dangerous_target_components "$target_root"

  if [[ "$target_root" == "$PROJECT_ROOT" && "$allow_target_project_root" != "true" ]]; then
    die "target must not equal project root without --allow-target-project-root"
  fi

  if path_is_within_dir "$target_root" "$source_root"; then
    die "target must not be source root or inside source root: $target_root"
  fi
}

build_json_array_file() {
  local output_file="$1"
  shift
  local item

  : >"$output_file"
  for item in "$@"; do
    jq -cn --arg value "$item" '$value' >>"$output_file"
  done
}

write_plan() {
  local plan_json="$1"
  local output="$2"
  local output_abs
  local output_lexical_parent
  local output_parent
  local tmp_output

  if [[ -z "$output" ]]; then
    printf '%s\n' "$plan_json"
    return 0
  fi

  output_abs="$(absolutize_from_project_root "$output")"
  if path_has_git_component "$output_abs"; then
    die "output must not be inside a .git directory: $output_abs"
  fi
  output_lexical_parent="$(dirname "$output_abs")"
  [[ -d "$output_lexical_parent" ]] || die "output parent must be an existing directory: $output_lexical_parent"
  reject_symlink_components "output parent" "$output_lexical_parent"
  output_parent="$(canonical_parent_dir "output" "$output_abs")"
  reject_symlink_components "output parent" "$output_parent"
  [[ ! -L "$output_abs" ]] || die "refusing to write through symlink output: $output_abs"
  [[ ! -d "$output_abs" ]] || die "output path is a directory: $output_abs"

  tmp_output="$(mktemp "${output_parent}/.$(basename "$output_abs").tmp.XXXXXX")" \
    || die "cannot create temporary output file under: $output_parent"
  printf '%s\n' "$plan_json" >"$tmp_output"
  mv "$tmp_output" "$output_abs"
}

run_plan() {
  local source_arg="src"
  local target_arg=""
  local output_arg=""
  local allow_target_project_root="false"
  local source_arg_abs
  local target_arg_abs
  local source_root
  local target_root
  local tmp_dir
  local records_file
  local warnings_file
  local excluded_file
  local file
  local rel
  local sha256
  local size
  local file_count
  local tree_hash
  local plan_json

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --source)
        [[ "$#" -ge 2 ]] || die "--source requires a value"
        source_arg="$2"
        shift 2
        ;;
      --target)
        [[ "$#" -ge 2 ]] || die "--target requires a value"
        target_arg="$2"
        shift 2
        ;;
      --output)
        [[ "$#" -ge 2 ]] || die "--output requires a value"
        output_arg="$2"
        shift 2
        ;;
      --allow-target-project-root)
        allow_target_project_root="true"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown plan argument: $1"
        ;;
    esac
  done

  [[ -n "$source_arg" ]] || die "--source cannot be empty"
  [[ -n "$target_arg" ]] || die "plan requires --target <dir>"

  source_arg_abs="$(absolutize_from_project_root "$source_arg")"
  target_arg_abs="$(absolutize_from_project_root "$target_arg")"
  reject_symlink_components "source" "$source_arg_abs"
  reject_symlink_components "target" "$target_arg_abs"

  source_root="$(canonical_dir "source" "$source_arg_abs")"
  target_root="$(canonical_dir "target" "$target_arg_abs")"

  reject_source_root "$source_root"
  reject_target_root "$target_arg_abs" "$target_root" "$source_root" "$allow_target_project_root"

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-src-promote.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' EXIT
  records_file="$tmp_dir/files.jsonl"
  warnings_file="$tmp_dir/warnings.jsonl"
  excluded_file="$tmp_dir/excluded.jsonl"
  : >"$records_file"
  : >"$warnings_file"

  build_json_array_file "$excluded_file" "${HARNESS_EXCLUDED_DIRS[@]}"

  while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    rel="${file#"$source_root"/}"
    reject_dangerous_source_components "$rel"
    sha256="$(shasum -a 256 "$file" | awk '{print $1}')"
    size="$(wc -c <"$file" | tr -d '[:space:]')"
    jq -cn \
      --arg path "$rel" \
      --arg source "$file" \
      --arg target "$target_root/$rel" \
      --arg sha256 "$sha256" \
      --argjson size "$size" \
      '{path: $path, source: $source, target: $target, sha256: $sha256, size: $size}' \
      >>"$records_file"
  done < <(find "$source_root" -type f -print0 | LC_ALL=C sort -z)

  file_count="$(jq -s 'length' "$records_file")"
  if [[ "$file_count" == "0" ]]; then
    jq -cn \
      --arg source_root "$source_root" \
      '{code: "empty_source", message: "source root contains no files to promote", source_root: $source_root}' \
      >>"$warnings_file"
  fi

  if [[ "$target_root" == "$PROJECT_ROOT" && "$allow_target_project_root" == "true" ]]; then
    jq -cn \
      '{code: "target_equals_project_root_allowed_for_plan_only", message: "target equals project root; apply remains disabled"}' \
      >>"$warnings_file"
  fi

  tree_hash="$(jq -cs 'map({path: .path, sha256: .sha256, size: .size})' "$records_file" | shasum -a 256 | awk '{print $1}')"

  plan_json="$(
    jq -n -c \
      --arg project_root "$PROJECT_ROOT" \
      --arg source_root "$source_root" \
      --arg target_root "$target_root" \
      --arg source_tree_hash "$tree_hash" \
      --slurpfile file_plan "$records_file" \
      --slurpfile warnings "$warnings_file" \
      --slurpfile excluded_harness_dirs "$excluded_file" \
      '{
        schema_version: 1,
        command: "plan",
        project_root: $project_root,
        source_root: $source_root,
        target_root: $target_root,
        included_files: ($file_plan | map(.path)),
        excluded_harness_dirs: $excluded_harness_dirs,
        source_tree: {
          hash: $source_tree_hash,
          files: ($file_plan | map({path: .path, sha256: .sha256, size: .size}))
        },
        file_plan: $file_plan,
        warnings: $warnings
      }'
  )"

  write_plan "$plan_json" "$output_arg"
  rm -rf "$tmp_dir"
  trap - EXIT
}

run_apply() {
  local plan_arg=""
  local plan_abs

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --plan)
        [[ "$#" -ge 2 ]] || die "--plan requires a value"
        plan_arg="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown apply argument: $1"
        ;;
    esac
  done

  [[ -n "$plan_arg" ]] || die "apply requires --plan <file>"
  plan_abs="$(absolutize_from_project_root "$plan_arg")"
  [[ -r "$plan_abs" ]] || die "plan file is not readable: $plan_abs"
  jq empty "$plan_abs" >/dev/null || die "plan file is not valid JSON: $plan_abs"

  die "apply is intentionally disabled in this foundation; review plan JSON and implement copy safety before enabling"
}

main() {
  local command="${1:-}"

  [[ -n "$command" ]] || die "command is required: plan or apply"
  shift || true

  case "$command" in
    plan)
      run_plan "$@"
      ;;
    apply)
      run_apply "$@"
      ;;
    --help|-h)
      usage
      ;;
    *)
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
