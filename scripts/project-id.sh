#!/bin/bash
set -euo pipefail

readonly PROJECT_ID_MAX_LENGTH=64
readonly PROJECT_ID_FORBIDDEN_LITERAL="agent_base"
readonly PROJECT_ID_ARTIFACT_RELATIVE_PATH=".shared/project_id"

die() {
  echo "[project-id] ERROR: $*" >&2
  exit 1
}

script_dir() {
  local source_path="${BASH_SOURCE[0]}"
  case "$source_path" in
    */*)
      cd "${source_path%/*}" && pwd -P
      ;;
    *)
      pwd -P
      ;;
  esac
}

script_repo_root() {
  canonicalize_dir "$(script_dir)/.."
}

canonicalize_dir() {
  local dir_path="${1:-}"
  [[ -n "$dir_path" ]] || die "directory path is required"
  [[ -d "$dir_path" ]] || die "directory does not exist: $dir_path"
  (
    cd "$dir_path" && pwd -P
  )
}

trim_trailing_slash() {
  local path_value="${1:-}"
  while [[ "$path_value" != "/" && "$path_value" == */ ]]; do
    path_value="${path_value%/}"
  done
  printf '%s\n' "$path_value"
}

path_parent_dir() {
  local path_value="${1:-}"
  local parent_dir=""

  [[ -n "$path_value" ]] || die "path is required"
  path_value="$(trim_trailing_slash "$path_value")"
  if [[ "$path_value" == "/" ]]; then
    printf '/\n'
    return 0
  fi

  case "$path_value" in
    */*)
      parent_dir="${path_value%/*}"
      [[ -n "$parent_dir" ]] || parent_dir="/"
      printf '%s\n' "$parent_dir"
      ;;
    *)
      printf '.\n'
      ;;
  esac
}

path_leaf_name() {
  local path_value="${1:-}"

  [[ -n "$path_value" ]] || die "path is required"
  path_value="$(trim_trailing_slash "$path_value")"
  if [[ "$path_value" == "/" ]]; then
    printf '/\n'
    return 0
  fi

  case "$path_value" in
    */*)
      printf '%s\n' "${path_value##*/}"
      ;;
    *)
      printf '%s\n' "$path_value"
      ;;
  esac
}

resolve_existing_path() {
  local path="${1:-}"
  [[ -n "$path" ]] || die "path is required"

  local parent_dir
  parent_dir="$(path_parent_dir "$path")"
  local base_name
  base_name="$(path_leaf_name "$path")"
  local canonical_parent
  canonical_parent="$(canonicalize_dir "$parent_dir")"

  [[ -e "$canonical_parent/$base_name" ]] || die "path does not exist: $path"
  printf '%s/%s\n' "$canonical_parent" "$base_name"
}

path_within_root() {
  local candidate="${1:-}"
  local root="${2:-}"
  [[ -n "$candidate" && -n "$root" ]] || return 1
  [[ "$candidate" == "$root" || "$candidate" == "$root/"* ]]
}

assert_no_symlink_components() {
  local root="${1:-}"
  local path="${2:-}"
  [[ -n "$root" && -n "$path" ]] || die "root and path are required"

  local normalized_root
  normalized_root="$(canonicalize_dir "$root")"
  [[ "$path" == "$normalized_root" || "$path" == "$normalized_root/"* ]] \
    || die "path escapes repo-local identity root: $path"

  local relative_path="${path#$normalized_root}"
  relative_path="${relative_path#/}"

  local current="$normalized_root"
  local component=""
  local -a path_components=()
  IFS='/' read -r -a path_components < <(printf '%s\n' "$relative_path")
  for component in "${path_components[@]}"; do
    [[ -n "$component" ]] || continue
    [[ "$component" != "." && "$component" != ".." ]] \
      || die "project_id path must not contain traversal components: $path"
    current="$current/$component"
    if [[ -L "$current" ]]; then
      die "project_id path contains symlink component: $current"
    fi
  done
}

repo_root() {
  if [[ -n "${PROJECT_ID_REPO_ROOT:-}" ]]; then
    canonicalize_dir "$PROJECT_ID_REPO_ROOT"
    return 0
  fi

  script_repo_root
}

exec_repo_root() {
  local canonical_root
  canonical_root="$(script_repo_root)"

  if [[ -z "${PROJECT_ID_REPO_ROOT:-}" ]]; then
    printf '%s\n' "$canonical_root"
    return 0
  fi

  local override_root
  override_root="$(canonicalize_dir "$PROJECT_ID_REPO_ROOT")"
  if [[ "$override_root" != "$canonical_root" ]]; then
    die "PROJECT_ID_REPO_ROOT override is forbidden for exec-mcp-server; canonical repo-local helper root is required: $canonical_root"
  fi

  printf '%s\n' "$canonical_root"
}

resolve_path_from_base() {
  local base_dir="$1"
  local candidate_path="$2"

  if [[ "$candidate_path" == /* ]]; then
    printf '%s\n' "$candidate_path"
    return 0
  fi

  printf '%s/%s\n' "$base_dir" "$candidate_path"
}

read_single_logical_line_file() {
  local path="$1"
  local label="$2"
  local line=""
  local extra_line=""

  [[ ! -L "$path" ]] || die "${label} must not be a symlink: $path"
  [[ -f "$path" ]] || die "${label} is invalid: $path"

  exec 3< "$path"
  IFS= read -r line <&3 || true
  if IFS= read -r extra_line <&3; then
    exec 3<&-
    die "${label} is invalid: $path"
  fi
  exec 3<&-

  [[ -n "$line" ]] || die "${label} is invalid: $path"
  printf '%s\n' "$line"
}

resolve_git_dir() {
  local root="$1"
  local git_metadata_path="${root}/.git"
  local git_dir_raw=""

  [[ ! -L "$git_metadata_path" ]] || die ".git metadata path must not be a symlink: $git_metadata_path"

  if [[ -d "$git_metadata_path" ]]; then
    canonicalize_dir "$git_metadata_path"
    return 0
  fi

  if [[ -f "$git_metadata_path" ]]; then
    git_dir_raw="$(read_single_logical_line_file "$git_metadata_path" "git metadata file")"
    case "$git_dir_raw" in
      "gitdir: "*)
        git_dir_raw="${git_dir_raw#gitdir: }"
        [[ -n "$git_dir_raw" ]] || die "git metadata file is invalid: $git_metadata_path"
        ;;
      *)
        die "git metadata file is invalid: $git_metadata_path"
        ;;
    esac
    canonicalize_dir "$(resolve_path_from_base "$root" "$git_dir_raw")"
    return 0
  fi

  [[ ! -e "$git_metadata_path" ]] || die ".git metadata path must be a file or directory: $git_metadata_path"
  return 1
}

resolve_common_git_dir() {
  local root="$1"
  local git_dir=""
  local commondir_path=""
  local commondir_raw=""

  git_dir="$(resolve_git_dir "$root")" || return 1
  commondir_path="${git_dir}/commondir"

  if [[ -e "$commondir_path" ]]; then
    commondir_raw="$(read_single_logical_line_file "$commondir_path" "git commondir file")"
    canonicalize_dir "$(resolve_path_from_base "$git_dir" "$commondir_raw")"
    return 0
  fi

  printf '%s\n' "$git_dir"
}

resolve_linked_worktree_identity_root() {
  local root="$1"
  local git_dir="$2"
  local common_git_dir="$3"
  local git_metadata_path="${root}/.git"
  local worktrees_dir=""
  local backref_path=""
  local backref_raw=""
  local expected_git_file=""
  local resolved_backref=""

  [[ "$common_git_dir" == */.git ]] \
    || die "git common dir must resolve to a .git directory: $common_git_dir"
  [[ ! -L "$git_metadata_path" ]] \
    || die "linked worktree proof requires a regular .git file: $git_metadata_path"
  [[ -f "$git_metadata_path" ]] \
    || die "linked worktree proof requires .git file metadata: $git_metadata_path"

  worktrees_dir="${common_git_dir}/worktrees"
  [[ "$(path_parent_dir "$git_dir")" == "$worktrees_dir" ]] \
    || die "linked worktree gitdir must be a direct child of ${worktrees_dir}: $git_dir"

  backref_path="${git_dir}/gitdir"
  backref_raw="$(read_single_logical_line_file "$backref_path" "linked worktree gitdir back-reference")"
  expected_git_file="$(resolve_existing_path "$git_metadata_path")"
  resolved_backref="$(resolve_existing_path "$(resolve_path_from_base "$git_dir" "$backref_raw")")"
  [[ "$resolved_backref" == "$expected_git_file" ]] \
    || die "linked worktree gitdir back-reference mismatch: expected ${expected_git_file} got ${resolved_backref}"

  canonicalize_dir "${common_git_dir%/.git}"
}

project_identity_root() {
  local root
  root="$(repo_root)"
  local git_dir=""
  local common_git_dir=""

  if ! git_dir="$(resolve_git_dir "$root")"; then
    printf '%s\n' "$root"
    return 0
  fi

  common_git_dir="$(resolve_common_git_dir "$root")"
  if [[ "$git_dir" == "${root}/.git" && "$common_git_dir" == "${root}/.git" ]]; then
    printf '%s\n' "$root"
    return 0
  fi

  resolve_linked_worktree_identity_root "$root" "$git_dir" "$common_git_dir"
}

assert_repo_local_artifact_path() {
  local artifact_path="$1"
  local identity_root
  identity_root="$(project_identity_root)"
  assert_no_symlink_components "$identity_root" "$artifact_path"

  local parent_dir
  parent_dir="$(path_parent_dir "$artifact_path")"
  if [[ -e "$parent_dir" ]]; then
    local resolved_parent
    resolved_parent="$(canonicalize_dir "$parent_dir")"
    if ! path_within_root "$resolved_parent" "$identity_root"; then
      die "project_id artifact directory escapes repo-local identity root: $resolved_parent"
    fi
  fi

  if [[ -e "$artifact_path" ]]; then
    [[ ! -L "$artifact_path" ]] || die "project_id artifact path must not be a symlink: $artifact_path"
    [[ -f "$artifact_path" ]] || die "project_id artifact path must be a regular file: $artifact_path"
    local resolved_artifact
    resolved_artifact="$(resolve_existing_path "$artifact_path")"
    if ! path_within_root "$resolved_artifact" "$identity_root"; then
      die "project_id artifact path escapes repo-local identity root: $resolved_artifact"
    fi
  fi
}

project_id_artifact_path() {
  local artifact_path
  artifact_path="$(project_identity_root)/$PROJECT_ID_ARTIFACT_RELATIVE_PATH"
  assert_repo_local_artifact_path "$artifact_path"
  printf '%s\n' "$artifact_path"
}

trusted_system_binary_path() {
  local binary_name="${1:-}"
  local candidate=""

  [[ "$binary_name" =~ ^[A-Za-z0-9._+-]+$ ]] || die "trusted system binary name is invalid: $binary_name"

  for candidate in "/usr/bin/$binary_name" "/bin/$binary_name"; do
    [[ -x "$candidate" && -f "$candidate" && ! -L "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

require_trusted_system_binary_path() {
  local binary_name="${1:-}"
  local binary_path=""

  binary_path="$(trusted_system_binary_path "$binary_name" || true)"
  [[ -n "$binary_path" ]] || die "trusted system ${binary_name} binary is required"
  printf '%s\n' "$binary_path"
}

assert_valid_project_id_artifact_bytes() {
  local artifact_path="$1"
  local -a bytes=()
  local byte=""
  local byte_value=0
  local content_length=0
  local index=0
  local last_index=0
  local od_bin=""

  od_bin="$(trusted_system_binary_path od || true)"
  [[ -n "$od_bin" ]] || die "trusted od binary is required to validate project_id artifact bytes"

  bytes=($(LC_ALL=C "$od_bin" -An -tx1 -v "$artifact_path"))
  [[ "${#bytes[@]}" -gt 0 ]] || die "project_id artifact must not be empty: $artifact_path"

  content_length="${#bytes[@]}"
  last_index=$((content_length - 1))
  if [[ "${bytes[$last_index]}" == "0a" ]]; then
    content_length=$((content_length - 1))
  fi

  [[ "$content_length" -gt 0 ]] || die "project_id artifact must not be empty: $artifact_path"

  for (( index=0; index<content_length; index++ )); do
    byte="${bytes[$index]}"
    if [[ "$byte" == "0a" ]]; then
      die "project_id artifact must contain exactly one logical line: $artifact_path"
    fi

    byte_value=$((16#$byte))
    if (( byte_value < 32 || byte_value == 127 )); then
      die "project_id artifact must not contain control bytes: $artifact_path"
    fi

    case "$byte" in
      2d|5f|30|31|32|33|34|35|36|37|38|39|41|42|43|44|45|46|47|48|49|4a|4b|4c|4d|4e|4f|50|51|52|53|54|55|56|57|58|59|5a|61|62|63|64|65|66|67|68|69|6a|6b|6c|6d|6e|6f|70|71|72|73|74|75|76|77|78|79|7a)
        ;;
      *)
        die "project_id must contain only letters, numbers, '_' or '-'"
        ;;
    esac
  done
}

validate_project_id() {
  local project_id
  project_id="${1:-}"

  if [[ -z "$project_id" ]]; then
    die "project_id must not be empty"
  fi

  if [[ ${#project_id} -gt "$PROJECT_ID_MAX_LENGTH" ]]; then
    die "project_id must be <= ${PROJECT_ID_MAX_LENGTH} characters"
  fi

  if [[ "$project_id" =~ [[:cntrl:]] ]]; then
    die "project_id must not contain control bytes"
  fi

  if [[ ! "$project_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    die "project_id must contain only letters, numbers, '_' or '-'"
  fi

  if [[ "$project_id" == "$PROJECT_ID_FORBIDDEN_LITERAL" ]]; then
    die "project_id literal '${PROJECT_ID_FORBIDDEN_LITERAL}' is forbidden; bootstrap a repo-local immutable id"
  fi

  printf '%s\n' "$project_id"
}

read_project_id_from_path() {
  local artifact_path="$1"
  assert_repo_local_artifact_path "$artifact_path"
  local raw_value=""

  assert_valid_project_id_artifact_bytes "$artifact_path"
  IFS= read -r raw_value < "$artifact_path" || true

  validate_project_id "$raw_value"
}

write_project_id_artifact() {
  local artifact_path="$1"
  local project_id="$2"
  local parent_dir=""
  local mkdir_bin=""
  local mktemp_bin=""
  local chmod_bin=""
  local mv_bin=""
  local rm_bin=""
  local tmp_file=""

  assert_repo_local_artifact_path "$artifact_path"
  parent_dir="$(path_parent_dir "$artifact_path")"
  mkdir_bin="$(require_trusted_system_binary_path mkdir)"
  mktemp_bin="$(require_trusted_system_binary_path mktemp)"
  chmod_bin="$(require_trusted_system_binary_path chmod)"
  mv_bin="$(require_trusted_system_binary_path mv)"
  rm_bin="$(require_trusted_system_binary_path rm)"

  "$mkdir_bin" -p "$parent_dir"
  assert_repo_local_artifact_path "$artifact_path"

  (
    trap 'if [[ -n "${tmp_file:-}" && -e "${tmp_file:-}" ]]; then "$rm_bin" -f "$tmp_file"; fi' EXIT

    tmp_file="$("$mktemp_bin" "$parent_dir/.project_id.tmp.XXXXXX")"
    [[ -n "$tmp_file" ]] || die "failed to allocate project_id temp artifact"
    assert_repo_local_artifact_path "$tmp_file"
    "$chmod_bin" 600 "$tmp_file"
    printf '%s\n' "$project_id" > "$tmp_file"
    "$mv_bin" "$tmp_file" "$artifact_path"
    tmp_file=""
  )

  assert_repo_local_artifact_path "$artifact_path"
}

sanitize_project_name() {
  local raw_name="${1:-}"
  local normalized=""
  local tr_bin=""
  local lowered=""
  local character=""
  local invalid_run_open=0
  local index=0
  local lowered_length=0

  tr_bin="$(require_trusted_system_binary_path tr)"
  lowered="$(printf '%s' "$raw_name" | LC_ALL=C "$tr_bin" '[:upper:]' '[:lower:]')"
  lowered_length="${#lowered}"

  for (( index=0; index<lowered_length; index++ )); do
    character="${lowered:index:1}"
    case "$character" in
      [a-z0-9_-])
        normalized+="$character"
        invalid_run_open=0
        ;;
      *)
        if [[ "$invalid_run_open" -eq 0 ]]; then
          normalized+="-"
          invalid_run_open=1
        fi
        ;;
    esac
  done

  while [[ "$normalized" == -* ]]; do
    normalized="${normalized#-}"
  done
  while [[ "$normalized" == *- ]]; do
    normalized="${normalized%-}"
  done

  if [[ -z "$normalized" ]]; then
    normalized="repo"
  fi

  printf '%s\n' "$normalized"
}

random_suffix() {
  local uuidgen_bin=""
  local od_bin=""
  local tr_bin=""
  local uuid_value=""
  local od_value=""

  uuidgen_bin="$(trusted_system_binary_path uuidgen || true)"
  tr_bin="$(trusted_system_binary_path tr || true)"
  if [[ -n "$uuidgen_bin" ]]; then
    uuid_value="$("$uuidgen_bin")"
    [[ -n "$tr_bin" ]] || die "trusted tr binary is required to normalize uuidgen output"
    uuid_value="$(printf '%s' "$uuid_value" | "$tr_bin" '[:upper:]' '[:lower:]')"
    uuid_value="${uuid_value//-/}"
    printf '%s\n' "${uuid_value:0:12}"
    return 0
  fi

  od_bin="$(trusted_system_binary_path od || true)"
  if [[ -n "$od_bin" ]]; then
    od_value="$(LC_ALL=C "$od_bin" -An -N6 -tx1 /dev/urandom 2>/dev/null)"
    od_value="${od_value//[[:space:]]/}"
    printf '%s\n' "$od_value"
    return 0
  fi

  die "uuidgen or od is required to generate project_id"
}

generate_project_id() {
  local project_name="${1:-}"
  local prefix
  prefix="$(sanitize_project_name "$project_name")"

  local suffix
  suffix="$(random_suffix)"

  local max_prefix_length=$((PROJECT_ID_MAX_LENGTH - ${#suffix} - 1))
  if [[ "$max_prefix_length" -lt 1 ]]; then
    die "internal error: invalid project_id prefix budget"
  fi

  prefix="${prefix:0:$max_prefix_length}"
  validate_project_id "${prefix}-${suffix}"
}

read_project_id() {
  local artifact_path
  artifact_path="$(project_id_artifact_path)"

  if [[ -f "$artifact_path" ]]; then
    read_project_id_from_path "$artifact_path"
    return 0
  fi

  die "missing project_id artifact: $artifact_path"
}

project_id_file_value_or_status() {
  local path="$1"
  local label="$2"
  local value=""

  if [[ ! -e "$path" ]]; then
    printf 'missing\t%s\t\n' "$label"
    return 0
  fi
  if [[ -L "$path" || ! -f "$path" ]]; then
    printf 'invalid\t%s\t\n' "$label"
    return 0
  fi

  if value="$(read_project_id_from_path "$path" 2>/dev/null)"; then
    printf 'valid\t%s\t%s\n' "$label" "$value"
  else
    printf 'invalid\t%s\t\n' "$label"
  fi
}

project_id_health() {
  local root=""
  root="$(project_identity_root)"
  local shared_path="$root/.shared/project_id"
  local legacy_path="$root/.agent/project_id"
  local shared_status=""
  local legacy_status=""
  local shared_value=""
  local legacy_value=""
  local shared_line=""
  local legacy_line=""
  local classification=""

  shared_line="$(project_id_file_value_or_status "$shared_path" ".shared/project_id")"
  legacy_line="$(project_id_file_value_or_status "$legacy_path" ".agent/project_id")"
  IFS=$'\t' read -r shared_status _ shared_value < <(printf '%s\n' "$shared_line")
  IFS=$'\t' read -r legacy_status _ legacy_value < <(printf '%s\n' "$legacy_line")

  if [[ "$shared_status" == "valid" && ( "$legacy_status" == "missing" || "$legacy_value" == "$shared_value" ) ]]; then
    classification="aligned"
  elif [[ "$shared_status" == "valid" && "$legacy_status" == "valid" && "$legacy_value" != "$shared_value" ]]; then
    classification="warn-drift"
  else
    classification="block-authority-ambiguous"
  fi

  jq -n \
    --arg classification "$classification" \
    --arg shared_path "${shared_path#"$root"/}" \
    --arg shared_status "$shared_status" \
    --arg shared_value "$shared_value" \
    --arg legacy_path "${legacy_path#"$root"/}" \
    --arg legacy_status "$legacy_status" \
    --arg legacy_value "$legacy_value" \
    '{
      classification: $classification,
      canonical: {path: $shared_path, status: $shared_status, value: $shared_value},
      legacy: {path: $legacy_path, status: $legacy_status, value: $legacy_value}
    }'

  [[ "$classification" != "block-authority-ambiguous" ]]
}

active_artifact_audit() {
  local root=""
  root="$(repo_root)"
  local active_root="$root/.agent/active"
  local path=""
  local rel=""
  local classification=""
  local reason=""

  [[ -d "$active_root" ]] || die "active artifact root does not exist: $active_root"

  printf 'path\tclassification\treason\n'
  while IFS= read -r path; do
    rel="${path#"$root"/}"
    classification="active-evidence"
    reason="current active evidence"

    case "$rel" in
      .agent/active/sow/task-lineage-ledger.md)
        classification="active-truth"
        reason="authoritative task-lineage ledger"
        ;;
      .agent/active/prompts/*)
        classification="stale-prompt-candidate"
        reason="volatile prompt evidence; migration requires pointer integrity checks"
        ;;
      .agent/active/plan_*.md)
        if grep -Fq "historical over-ceiling BLOCK carrier" "$path" 2>/dev/null; then
          classification="superseded-plan"
          reason="predecessor block carrier; retain until archive migration integrity proof"
        elif grep -Eq "HOLD|KEEP|do not archive|do not move" "$path" 2>/dev/null; then
          classification="hold"
          reason="explicit hold marker"
        else
          classification="active-plan"
          reason="candidate current plan or retained active plan"
        fi
        ;;
      .agent/active/sow/*)
        classification="volatile-evidence-pointer"
        reason="SOW evidence; archive only after lineage and pointer verification"
        ;;
    esac

    printf '%s\t%s\t%s\n' "$rel" "$classification" "$reason"
  done < <(find "$active_root" -type f | sort)
}

bootstrap_project_id() {
  local project_name="${1:-$(path_leaf_name "$(repo_root)")}"
  local artifact_path
  artifact_path="$(project_id_artifact_path)"

  if [[ -f "$artifact_path" ]]; then
    read_project_id_from_path "$artifact_path"
    return 0
  fi

  local project_id
  project_id="$(generate_project_id "$project_name")"
  write_project_id_artifact "$artifact_path" "$project_id"

  printf '%s\n' "$project_id"
}

rust_semantic_manifest_path() {
  local workspace_root="${1:-}"
  [[ -n "$workspace_root" ]] || die "Rust workspace root is required"
  printf '%s\n' "$workspace_root/Cargo.toml"
}

resolve_rust_workspace_root_via_helper() {
  local repo_root="${1:-}"
  shift || true
  [[ -n "$repo_root" ]] || die "repo root is required"

  local helper_path=""
  helper_path="$(trusted_runtime_helper)"
  "$helper_path" __internal-rust-workspace-root --repo-root "$repo_root" "$@"
}

resolve_rust_workspace_root_if_present_via_helper() {
  local repo_root="${1:-}"
  [[ -n "$repo_root" ]] || die "repo root is required"
  local helper_path=""
  helper_path="$(trusted_runtime_helper_path)"
  [[ -x "$helper_path" ]] || return 3

  # Helper exits:
  #   0 = valid root printed on stdout
  #   3 = no candidate present (only when --allow-absent is set)
  #   other (typically 1 from die) = invalid / ambiguous / symlink / repo-external.
  # Invalid/ambiguous must NOT be silently treated as absent; propagate exit 4
  # so callers can fail-closed instead of degrading to shell fallback.
  local helper_output=""
  local helper_status=0
  helper_output="$("$helper_path" __internal-rust-workspace-root --repo-root "$repo_root" --allow-absent 2>&1)" || helper_status=$?
  case "$helper_status" in
    0)
      printf '%s\n' "$helper_output"
      return 0
      ;;
    3)
      return 3
      ;;
    *)
      if [[ -n "$helper_output" ]]; then
        printf '%s\n' "$helper_output" >&2
      fi
      return 4
      ;;
  esac
}

agent_core_workspace_root() {
  resolve_rust_workspace_root_via_helper "$(script_repo_root)"
}

agent_core_manifest_path() {
  printf '%s\n' "$(agent_core_workspace_root)/Cargo.toml"
}

agent_core_main_path() {
  printf '%s\n' "$(agent_core_workspace_root)/crates/agent-core/src/main.rs"
}

trusted_runtime_helper_path() {
  printf '%s\n' "$(script_dir)/semantic-review-queue.sh"
}

trusted_runtime_helper() {
  local helper_path=""
  helper_path="$(trusted_runtime_helper_path)"
  [[ -x "$helper_path" ]] || die "trusted runtime helper not found or not executable: $helper_path"
  printf '%s\n' "$helper_path"
}

trusted_runtime_available() {
  local binary_name="${1:-}"
  local repo_root="${2:-}"
  local helper_path=""

  [[ "$binary_name" == "cargo" || "$binary_name" == "node" ]] || return 1
  helper_path="$(trusted_runtime_helper)"
  if [[ -n "$repo_root" ]]; then
    "$helper_path" __internal-runtime-env --binary "$binary_name" --repo-root "$repo_root" >/dev/null 2>&1
  else
    "$helper_path" __internal-runtime-env --binary "$binary_name" >/dev/null 2>&1
  fi
}

run_with_trusted_runtime() {
  local binary_name="${1:-}"
  shift || true
  local repo_root=""
  local helper_path=""

  [[ "$binary_name" == "cargo" || "$binary_name" == "node" ]] || die "unsupported trusted runtime binary: $binary_name"
  if [[ $# -ge 2 && "$1" == "--repo-root" ]]; then
    repo_root="$(canonicalize_dir "$2")"
    shift 2
  fi
  helper_path="$(trusted_runtime_helper)"
  if [[ -n "$repo_root" ]]; then
    "$helper_path" __internal-run-runtime --binary "$binary_name" --repo-root "$repo_root" -- "$@"
  else
    "$helper_path" __internal-run-runtime --binary "$binary_name" -- "$@"
  fi
}

exec_with_trusted_runtime() {
  local binary_name="${1:-}"
  shift || true
  local repo_root=""
  local helper_path=""

  [[ "$binary_name" == "cargo" || "$binary_name" == "node" ]] || die "unsupported trusted runtime binary: $binary_name"
  if [[ $# -ge 2 && "$1" == "--repo-root" ]]; then
    repo_root="$(canonicalize_dir "$2")"
    shift 2
  fi
  helper_path="$(trusted_runtime_helper)"
  if [[ -n "$repo_root" ]]; then
    exec "$helper_path" __internal-run-runtime --binary "$binary_name" --repo-root "$repo_root" -- "$@"
  else
    exec "$helper_path" __internal-run-runtime --binary "$binary_name" -- "$@"
  fi
}

rust_semantic_workspace_root() {
  local root="${1:-}"
  [[ -n "$root" ]] || die "repo root is required"
  resolve_rust_workspace_root_via_helper "$root"
}

rust_semantic_main_path() {
  local workspace_root="${1:-}"
  [[ -n "$workspace_root" ]] || die "Rust workspace root is required"
  printf '%s\n' "$workspace_root/crates/semantic-mcp/src/main.rs"
}

is_repo_local_real_path() {
  local root="${1:-}"
  local candidate="${2:-}"
  [[ -n "$root" && -n "$candidate" ]] || return 1
  [[ -e "$candidate" ]] || return 1

  local normalized_root
  normalized_root="$(canonicalize_dir "$root")" || return 1
  [[ "$candidate" == "$normalized_root" || "$candidate" == "$normalized_root/"* ]] || return 1

  if ! (assert_no_symlink_components "$normalized_root" "$candidate") >/dev/null 2>&1; then
    return 1
  fi

  local resolved_candidate=""
  if [[ -d "$candidate" ]]; then
    resolved_candidate="$(canonicalize_dir "$candidate")" || return 1
  else
    resolved_candidate="$(resolve_existing_path "$candidate")" || return 1
  fi

  path_within_root "$resolved_candidate" "$normalized_root"
}

can_exec_rust_semantic_server() {
  local root="${1:-}"
  [[ -n "$root" ]] || die "repo root is required"

  local workspace_root=""
  if workspace_root="$(resolve_rust_workspace_root_if_present_via_helper "$root")"; then
    :
  else
    local resolver_status=$?
    case "$resolver_status" in
      3)
        return 1
        ;;
      4)
        die "Rust workspace resolver rejected candidate (invalid, ambiguous, symlink, or repo-external)"
        ;;
      *)
        return "$resolver_status"
        ;;
    esac
  fi
  local manifest_path
  manifest_path="$(rust_semantic_manifest_path "$workspace_root")"
  local main_path
  main_path="$(rust_semantic_main_path "$workspace_root")"

  [[ -d "$workspace_root" && -f "$manifest_path" && -f "$main_path" ]] || return 4
  is_repo_local_real_path "$root" "$workspace_root" || return 4
  is_repo_local_real_path "$root" "$manifest_path" || return 4
  is_repo_local_real_path "$root" "$main_path" || return 4
  trusted_runtime_available cargo || return 1
}

can_exec_agent_core_project_id() {
  local script_root
  script_root="$(script_repo_root)"

  local workspace_root=""
  if workspace_root="$(resolve_rust_workspace_root_if_present_via_helper "$script_root")"; then
    :
  else
    local resolver_status=$?
    case "$resolver_status" in
      3)
        return 1
        ;;
      4)
        die "Rust workspace resolver rejected candidate (invalid, ambiguous, symlink, or repo-external)"
        ;;
      *)
        return "$resolver_status"
        ;;
    esac
  fi
  local manifest_path
  manifest_path="$(agent_core_manifest_path)"
  local main_path
  main_path="$(agent_core_main_path)"

  [[ -d "$workspace_root" && -f "$manifest_path" && -f "$main_path" ]] || return 1
  is_repo_local_real_path "$script_root" "$workspace_root" || return 1
  is_repo_local_real_path "$script_root" "$manifest_path" || return 1
  is_repo_local_real_path "$script_root" "$main_path" || return 1
  trusted_runtime_available cargo || return 1
}

run_agent_core_project_id() {
  local repo_root="${1:-}"
  shift || true
  [[ -n "$repo_root" ]] || die "repo root is required"

  local manifest_path
  manifest_path="$(agent_core_manifest_path)"

  (
    unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE
    run_with_trusted_runtime \
      cargo \
      run \
      --quiet \
      --manifest-path "$manifest_path" \
      -p agent-core \
      -- \
      project-id \
      "$@" \
      --repo-root "$repo_root"
  )
}

prevalidate_authoritative_project_id() {
  local validated_project_id=""
  validated_project_id="$(read_project_id)"
  [[ -n "$validated_project_id" ]] || die "project_id pre-validation returned an empty value"
}

exec_rust_semantic_server() {
  local workspace_root="${1:-}"
  local project_id="${2:-}"
  shift 2 || true

  local manifest_path
  manifest_path="$(rust_semantic_manifest_path "$workspace_root")"

  exec_with_trusted_runtime \
    cargo \
    run \
    --quiet \
    --manifest-path "$manifest_path" \
    -p semantic-mcp \
    -- \
    --project-id "$project_id" \
    "$@"
}

assert_semantic_exec_env_overrides() {
  if [[ -n "${SEMANTIC_MCP_ENTRYPOINT:-}" ]]; then
    die "SEMANTIC_MCP_ENTRYPOINT override is forbidden; canonical repo-local entrypoint is required"
  fi
  if [[ -n "${SEMANTIC_MCP_NODE_BIN:-}" ]]; then
    die "SEMANTIC_MCP_NODE_BIN override is forbidden; canonical node runtime lookup is required"
  fi
}

exec_semantic_server() {
  local root
  root="$(exec_repo_root)"

  assert_semantic_exec_env_overrides

  local project_id=""
  local adopter_pwd_root=""
  local adopter_pwd_id=""
  # `identity_repo_root` is the worktree-resolved identity root that OWNS the
  # project_id we are about to serve. It is the SAME identity root that
  # project-id.sh uses to place the project_id artifact, and it MUST be passed
  # to the server as --repo-root so the server records the correct
  # projects.root_path (orphan-GC anchor) instead of falling back to a process
  # CWD that could later vanish and make the live DB look like an orphan
  # (BLOCKER #3a).
  local identity_repo_root=""
  if [[ -n "${PWD:-}" ]] \
    && adopter_pwd_root="$(canonicalize_dir "$PWD" 2>/dev/null)" \
    && [[ "$adopter_pwd_root" != "$root" && -f "$adopter_pwd_root/.shared/project_id" ]]; then
    if adopter_pwd_id="$(
      PROJECT_ID_REPO_ROOT="$adopter_pwd_root" \
        read_project_id_from_path "$adopter_pwd_root/.shared/project_id" 2>/dev/null
    )"; then
      if [[ -n "$adopter_pwd_id" && "$adopter_pwd_id" != "$(read_project_id)" ]]; then
        project_id="$adopter_pwd_id"
        # Identity root for the adopter project (worktree-resolved).
        identity_repo_root="$(
          PROJECT_ID_REPO_ROOT="$adopter_pwd_root" project_identity_root 2>/dev/null || true
        )"
      fi
    fi
  fi
  if [[ -z "$project_id" ]]; then
    project_id="$(read_project_id)"
    # Identity root for the canonical helper's own project.
    identity_repo_root="$(project_identity_root 2>/dev/null || true)"
  fi

  # Only pass --repo-root when we resolved a trustworthy absolute existing dir.
  # A blank/relative/missing identity root is deliberately NOT passed: the
  # server then leaves projects.root_path blank (safe age-TTL fallback) rather
  # than recording a wrong root. Blank is safe; wrong is catastrophic.
  local repo_root_args=()
  if [[ -n "$identity_repo_root" && "$identity_repo_root" == /* && -d "$identity_repo_root" ]]; then
    repo_root_args=(--repo-root "$identity_repo_root")
  fi

  local workspace_root=""
  if workspace_root="$(resolve_rust_workspace_root_if_present_via_helper "$root")"; then
    if can_exec_rust_semantic_server "$root"; then
      exec_rust_semantic_server "$workspace_root" "$project_id" "${repo_root_args[@]}" "$@"
    else
      local rust_server_status=$?
      case "$rust_server_status" in
        1)
          ;;
        *)
          return "$rust_server_status"
          ;;
      esac
    fi
  else
    local resolver_status=$?
    case "$resolver_status" in
      3)
        ;;
      4)
        die "Rust workspace resolver rejected candidate (invalid, ambiguous, symlink, or repo-external)"
        ;;
      *)
        return "$resolver_status"
        ;;
    esac
  fi

  # The Node semantic backend has been removed (de-overkill S3-B3). Rust is the
  # only supported backend. If we reached here the Rust workspace was not
  # resolvable; fail closed with a clear, actionable message. The legacy escape
  # env REV_HARNESS_ALLOW_NODE_SEMANTIC is now a no-op (the Node tree is gone)
  # and is called out explicitly so anyone still setting it understands why it
  # no longer takes effect.
  if [[ "${REV_HARNESS_ALLOW_NODE_SEMANTIC:-}" == "1" ]]; then
    die "Node backend removed; Rust required. REV_HARNESS_ALLOW_NODE_SEMANTIC is now a no-op (the Node tree was deleted in S3). Build the Rust backend with \`cargo build -p semantic-mcp\`."
  fi
  die "Rust semantic backend required; build with \`cargo build -p semantic-mcp\`. The Rust workspace (harness-rust/) could not be resolved."
}

usage() {
  printf '%s\n' \
    'Usage:' \
    '  scripts/project-id.sh artifact-path' \
    '  scripts/project-id.sh read' \
    '  scripts/project-id.sh health' \
    '  scripts/project-id.sh active-audit' \
    '  scripts/project-id.sh bootstrap [project_name]' \
    '  scripts/project-id.sh exec-mcp-server [extra args...]'
}

main() {
  local command="${1:-}"
  case "$command" in
    artifact-path)
      local artifact_repo_root
      artifact_repo_root="$(repo_root)"
      if can_exec_agent_core_project_id; then
        run_agent_core_project_id "$artifact_repo_root" artifact-path
      else
        local agent_core_status=$?
        case "$agent_core_status" in
          1)
            project_id_artifact_path
            ;;
          *)
            return "$agent_core_status"
            ;;
        esac
      fi
      ;;
    read)
      read_project_id
      ;;
    health)
      project_id_health
      ;;
    active-audit)
      active_artifact_audit
      ;;
    bootstrap)
      shift || true
      bootstrap_project_id "${1:-}"
      ;;
    exec-mcp-server)
      shift || true
      local exec_repo
      exec_repo="$(exec_repo_root)"
      assert_semantic_exec_env_overrides
      prevalidate_authoritative_project_id
      exec_semantic_server "$@"
      ;;
    *)
      usage >&2
      if [[ -n "$command" ]]; then
        die "unknown command: $command"
      fi
      exit 1
      ;;
  esac
}

main "$@"
