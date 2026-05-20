#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$PROJECT_ROOT/.agent/registry/rev_harness_distribution_manifest.json"

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-upgrade.sh inspect --target <dir> [--json]
  scripts/rev-harness-upgrade.sh plan --target <dir> --source-ref <ref> [--output <file>]
  scripts/rev-harness-upgrade.sh apply --target <dir> --source-ref <ref>

Inspect and plan are read-only. Apply is intentionally not implemented in this
foundation and fails closed.
EOF
}

die() {
  printf 'rev-harness-upgrade: %s\n' "$*" >&2
  exit 2
}

require_dependencies() {
  command -v jq >/dev/null 2>&1 || die "required command not found: jq"
  command -v git >/dev/null 2>&1 || die "required command not found: git"
  command -v find >/dev/null 2>&1 || die "required command not found: find"
  command -v grep >/dev/null 2>&1 || die "required command not found: grep"
  [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die "missing manifest: $MANIFEST"
  jq empty "$MANIFEST" >/dev/null 2>&1 || die "manifest is not valid JSON: $MANIFEST"
}

json_bool() {
  if [[ "${1:-false}" == "true" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

json_array_from_lines() {
  local lines="$1"
  printf '%s\n' "$lines" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique'
}

json_records_from_tab_lines() {
  local lines="$1"
  printf '%s\n' "$lines" | jq -Rsc '
    split("\n")
    | map(select(length > 0) | split("\t"))
    | map(select(length >= 3))
    | map({path: .[0], source: .[1], match: .[2]})
    | sort_by(.path, .source, .match)
    | unique_by(.path, .source, .match)
  '
}

absolute_target() {
  local target="$1"
  local target_lexical_abs=""

  [[ -d "$target" ]] || die "target is not a directory: $target"
  target_lexical_abs="$(normalize_abs_path "$target")"
  reject_symlink_components "$target_lexical_abs" "false" "target"
  (cd "$target" && pwd -P)
}

normalize_abs_path() {
  local path="$1"
  local abs="" component="" out="" joined=""
  local -a parts=() stack=()

  case "$path" in
    /*)
      abs="$path"
      ;;
    *)
      abs="$(pwd -P)/$path"
      ;;
  esac

  IFS='/' read -r -a parts <<< "$abs"
  for component in "${parts[@]}"; do
    case "$component" in
      ""|.)
        ;;
      ..)
        if [[ "${#stack[@]}" -gt 0 ]]; then
          unset 'stack[${#stack[@]}-1]'
        fi
        ;;
      *)
        stack+=("$component")
        ;;
    esac
  done

  for component in "${stack[@]}"; do
    joined+="/$component"
  done
  out="${joined:-/}"
  if [[ "$out" == /tmp/* && -L /tmp && -d /private/tmp ]]; then
    out="/private/tmp/${out#/tmp/}"
  elif [[ "$out" == /var/* && -L /var && -d /private/var ]]; then
    out="/private/var/${out#/var/}"
  fi
  printf '%s\n' "$out"
}

dirname_abs() {
  local path="${1%/}"
  local dir=""

  if [[ "$path" == "/" ]]; then
    printf '/\n'
    return 0
  fi

  dir="${path%/*}"
  [[ -n "$dir" ]] || dir="/"
  printf '%s\n' "$dir"
}

reject_symlink_components() {
  local path="$1"
  local allow_missing_leaf="${2:-false}"
  local label="${3:-path}"
  local component="" current="" index=0 total=0
  local -a parts=()

  [[ "$path" == /* ]] || die "$label must be absolute after normalization: $path"
  IFS='/' read -r -a parts <<< "$path"
  total="${#parts[@]}"

  for component in "${parts[@]}"; do
    index=$((index + 1))
    [[ -n "$component" ]] || continue
    current="$current/$component"
    if [[ -L "$current" ]]; then
      die "refusing $label with symlink component: $current"
    fi
    if [[ ! -e "$current" ]]; then
      if [[ "$allow_missing_leaf" == "true" && "$index" -eq "$total" ]]; then
        return 0
      fi
      die "$label component does not exist: $current"
    fi
  done
}

collect_git_json() {
  local target="$1"
  local root="" branch=""

  if git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    root="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
    branch="$(git -C "$target" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    jq -nc \
      --arg root "$root" \
      --arg branch "$branch" \
      '{is_repo: true, work_tree_root: $root, branch: (if $branch == "" then null else $branch end)}'
  else
    jq -nc '{is_repo: false, work_tree_root: null, branch: null}'
  fi
}

collect_presence_json() {
  local target="$1"
  local agents="false" agent_dir="false" claude_dir="false" codex_dir="false" project_id="false"

  [[ -e "$target/AGENTS.md" ]] && agents="true"
  [[ -d "$target/.agent" ]] && agent_dir="true"
  [[ -d "$target/.claude" ]] && claude_dir="true"
  [[ -d "$target/.codex" ]] && codex_dir="true"
  [[ -e "$target/.shared/project_id" ]] && project_id="true"

  jq -nc \
    --argjson agents "$(json_bool "$agents")" \
    --argjson agent_dir "$(json_bool "$agent_dir")" \
    --argjson claude_dir "$(json_bool "$claude_dir")" \
    --argjson codex_dir "$(json_bool "$codex_dir")" \
    --argjson project_id "$(json_bool "$project_id")" \
    '{
      agents_md: $agents,
      agent_dir: $agent_dir,
      claude_dir: $claude_dir,
      codex_dir: $codex_dir,
      shared_project_id: $project_id
    }'
}

collect_project_id_json() {
  local target="$1"
  local rel=".shared/project_id"
  local path="$target/$rel"
  local present="false" readable="false" value=""

  [[ -e "$path" ]] && present="true"
  if [[ -f "$path" && ! -L "$path" ]]; then
    readable="true"
    IFS= read -r value < "$path" || value=""
  fi

  jq -nc \
    --arg path "$rel" \
    --arg value "$value" \
    --argjson present "$(json_bool "$present")" \
    --argjson readable "$(json_bool "$readable")" \
    '{path: $path, present: $present, readable: $readable, value: (if $readable then $value else null end)}'
}

collect_install_state_json() {
  local target="$1"
  local rel=".harness/agent-base/install.json"
  local path="$target/$rel"
  local name="" version="" payload="null"

  if [[ ! -e "$path" ]]; then
    jq -nc --arg path "$rel" '{path: $path, present: false, json_valid: null, name: null, version: null, payload: null}'
    return 0
  fi

  if [[ ! -f "$path" || -L "$path" ]]; then
    jq -nc --arg path "$rel" '{path: $path, present: true, json_valid: false, name: null, version: null, payload: null}'
    return 0
  fi

  if ! jq empty "$path" >/dev/null 2>&1; then
    jq -nc --arg path "$rel" '{path: $path, present: true, json_valid: false, name: null, version: null, payload: null}'
    return 0
  fi

  name="$(jq -r '.name // empty' "$path")"
  version="$(jq -r '.version // empty' "$path")"
  payload="$(jq -c '.' "$path")"

  jq -nc \
    --arg path "$rel" \
    --arg name "$name" \
    --arg version "$version" \
    --argjson payload "$payload" \
    '{
      path: $path,
      present: true,
      json_valid: true,
      name: (if $name == "" then null else $name end),
      version: (if $version == "" then null else $version end),
      payload: $payload
    }'
}

collect_legacy_hits_json() {
  local target="$1"
  local records="" entry rel match

  while IFS= read -r -d '' entry; do
    rel="${entry#"$target"/}"
    case "$rel" in
      *agent_base*)
        records+="$rel"$'\tpath\tagent_base\n'
        ;;
    esac
    case "$rel" in
      *agent-base*)
        records+="$rel"$'\tpath\tagent-base\n'
        ;;
    esac
  done < <(find "$target" \( -path "$target/.git" -o -path "$target/.git/*" \) -prune -o -mindepth 1 -print0)

  while IFS= read -r -d '' entry; do
    rel="${entry#"$target"/}"
    match="$(LC_ALL=C grep -I -E -m 1 -o 'agent_base|agent-base' "$entry" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$match" ]]; then
      records+="$rel"$'\tcontent\t'"$match"$'\n'
    fi
  done < <(find "$target" \( -path "$target/.git" -o -path "$target/.git/*" \) -prune -o -type f -print0)

  json_records_from_tab_lines "$records"
}

manifest_array_json() {
  local key="$1"
  jq -c --arg key "$key" '.[$key] // []' "$MANIFEST"
}

resolve_manifest_paths_json() {
  local target="$1"
  local key="$2"
  local lines="" pattern match
  local -a patterns=()
  local -a safe_patterns=()

  mapfile -t patterns < <(jq -r --arg key "$key" '.[$key][]' "$MANIFEST")

  lines="$(
    cd "$target"
    shopt -s nullglob globstar dotglob
    for pattern in "${patterns[@]}"; do
      case "$pattern" in
        ""|/*|../*|*/../*|*/..|.|..)
          continue
          ;;
      esac
      safe_patterns+=("$pattern")
      for match in $pattern; do
        [[ -e "$match" || -L "$match" ]] || continue
        printf '%s\n' "${match#./}"
      done
    done
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ "${#safe_patterns[@]}" -gt 0 ]]; then
      git ls-files -- "${safe_patterns[@]}"
      if git rev-parse --verify HEAD >/dev/null 2>&1; then
        git ls-tree -r --name-only HEAD -- "${safe_patterns[@]}"
      fi
    fi
  )"

  json_array_from_lines "$lines"
}

collect_dirty_managed_blockers_json() {
  local target="$1"
  local managed_paths_json="$2"
  local records="" status_output="" line status path
  local -a managed_paths=()

  if ! git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    jq -nc '[]'
    return 0
  fi

  mapfile -t managed_paths < <(printf '%s\n' "$managed_paths_json" | jq -r '.[]')
  if [[ "${#managed_paths[@]}" -eq 0 ]]; then
    jq -nc '[]'
    return 0
  fi

  status_output="$(git -C "$target" status --porcelain=v1 --untracked-files=all -- "${managed_paths[@]}")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    status="${line:0:2}"
    path="${line:3}"
    [[ -n "$path" ]] || continue
    records+="$path"$'\t'"$status"$'\tdirty_managed_path\n'
  done <<< "$status_output"

  printf '%s\n' "$records" | jq -Rsc '
    split("\n")
    | map(select(length > 0) | split("\t"))
    | map(select(length >= 3))
    | map({
        code: .[2],
        path: .[0],
        git_status: .[1],
        message: "managed candidate path has uncommitted changes"
      })
    | sort_by(.path, .git_status)
    | unique_by(.path, .git_status, .code)
  '
}

build_inspect_json() {
  local target="$1"
  local git_json presence_json project_id_json install_json legacy_hits_json manifest_json

  git_json="$(collect_git_json "$target")"
  presence_json="$(collect_presence_json "$target")"
  project_id_json="$(collect_project_id_json "$target")"
  install_json="$(collect_install_state_json "$target")"
  legacy_hits_json="$(collect_legacy_hits_json "$target")"
  manifest_json="$(jq -c '{canonical, legacy_aliases, source_url, preserve_globs_semantics, client_distribution}' "$MANIFEST")"

  jq -nc \
    --arg target "$target" \
    --argjson git "$git_json" \
    --argjson presence "$presence_json" \
    --argjson project_id "$project_id_json" \
    --argjson install_state "$install_json" \
    --argjson legacy_name_hits "$legacy_hits_json" \
    --argjson manifest "$manifest_json" \
    '{
      schema_version: "rev-harness-upgrade-inspect/v1",
      target: $target,
      git: $git,
      presence: $presence,
      project_id: $project_id,
      install_state: $install_state,
      legacy_name_hits: $legacy_name_hits,
      distribution: $manifest
    }'
}

build_plan_json() {
  local target="$1"
  local source_ref="$2"
  local inspect_json preserve_globs_json client_distribution_json managed_globs_json preserve_paths_json managed_paths_json blockers_json
  local from_version="unknown" detected_version=""
  local legacy_count install_present

  inspect_json="$(build_inspect_json "$target")"
  preserve_globs_json="$(manifest_array_json preserve_globs)"
  client_distribution_json="$(jq -c '.client_distribution // null' "$MANIFEST")"
  managed_globs_json="$(manifest_array_json managed_candidate_globs)"
  preserve_paths_json="$(resolve_manifest_paths_json "$target" preserve_globs)"
  managed_paths_json="$(resolve_manifest_paths_json "$target" managed_candidate_globs)"
  blockers_json="$(collect_dirty_managed_blockers_json "$target" "$managed_paths_json")"

  legacy_count="$(printf '%s\n' "$inspect_json" | jq '.legacy_name_hits | length')"
  install_present="$(printf '%s\n' "$inspect_json" | jq -r '.install_state.present')"
  detected_version="$(printf '%s\n' "$inspect_json" | jq -r '.install_state.version // empty')"
  if [[ "$install_present" == "true" || "$legacy_count" -gt 0 ]]; then
    from_version="legacy"
  fi

  jq -nc \
    --arg target "$target" \
    --arg source_ref "$source_ref" \
    --arg from_version "$from_version" \
    --arg detected_version "$detected_version" \
    --argjson inspect "$inspect_json" \
    --argjson preserve_globs "$preserve_globs_json" \
    --argjson client_distribution "$client_distribution_json" \
    --argjson managed_globs "$managed_globs_json" \
    --argjson preserve_paths "$preserve_paths_json" \
    --argjson managed_paths "$managed_paths_json" \
    --argjson blockers "$blockers_json" \
    --arg source_url "$(jq -r '.source_url' "$MANIFEST")" \
    --arg to_display "$(jq -r '.canonical.display_name' "$MANIFEST")" \
    --arg to_name "$(jq -r '.canonical.machine_name' "$MANIFEST")" \
    '{
      schema_version: "rev-harness-upgrade-plan/v1",
      target: $target,
      source_ref: $source_ref,
      source_url: $source_url,
      from_version: $from_version,
      detected_legacy_version: (if $detected_version == "" then null else $detected_version end),
      to_name: $to_name,
      to_display_name: $to_display,
      inspect: $inspect,
      preserve_globs: $preserve_globs,
      client_distribution: $client_distribution,
      preserve_paths: $preserve_paths,
      managed_candidate_globs: $managed_globs,
      managed_candidate_paths: $managed_paths,
      blockers: $blockers,
      apply: {
        implemented: false,
        allowed: false,
        command: null,
        reason: "foundation supports inspect and plan only"
      }
    }'
}

render_inspect_text() {
  local json="$1"
  printf '%s\n' "$json" | jq -r '
    "target: \(.target)",
    "git_repo: \(.git.is_repo)",
    "AGENTS.md: \(.presence.agents_md)",
    ".agent: \(.presence.agent_dir)",
    ".claude: \(.presence.claude_dir)",
    ".codex: \(.presence.codex_dir)",
    ".shared/project_id: \(.presence.shared_project_id)",
    "install_state: \(.install_state.present)",
    "legacy_name_hits: \(.legacy_name_hits | length)"
  '
}

resolve_output_path() {
  local target="$1"
  local output="$2"
  local output_abs="" parent=""

  [[ -n "$output" ]] || die "--output requires a non-empty path"

  case "$output" in
    /*)
      output_abs="$(normalize_abs_path "$output")"
      ;;
    *)
      output_abs="$(normalize_abs_path "$target/$output")"
      ;;
  esac

  case "$output_abs" in
    "$target"/*)
      ;;
    *)
      die "output path must be under target: $output"
      ;;
  esac

  parent="$(dirname_abs "$output_abs")"
  [[ -d "$parent" ]] || die "output parent is not a directory: $parent"
  reject_symlink_components "$output_abs" "true" "output path"
  [[ ! -d "$output_abs" ]] || die "output path is a directory: $output_abs"
  [[ ! -L "$output_abs" ]] || die "refusing to write through symlink output: $output_abs"

  printf '%s\n' "$output_abs"
}

write_output_file() {
  local target="$1"
  local output="$2"
  local body="$3"
  local tmp=""
  local output_abs=""

  output_abs="$(resolve_output_path "$target" "$output")"

  tmp="$(mktemp "${output_abs}.XXXXXX")" || die "failed to create temp output near: $output_abs"
  printf '%s\n' "$body" > "$tmp"
  mv "$tmp" "$output_abs"
}

cmd_inspect() {
  local target="" json_only="false" target_abs="" inspect_json=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --target)
        [[ "$#" -ge 2 ]] || die "--target requires a value"
        target="$2"
        shift 2
        ;;
      --json)
        json_only="true"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown inspect option: $1"
        ;;
    esac
  done

  [[ -n "$target" ]] || die "inspect requires --target <dir>"
  target_abs="$(absolute_target "$target")"
  inspect_json="$(build_inspect_json "$target_abs")"

  if [[ "$json_only" == "true" ]]; then
    printf '%s\n' "$inspect_json"
  else
    render_inspect_text "$inspect_json"
  fi
}

cmd_plan() {
  local target="" source_ref="" output="" target_abs="" plan_json=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --target)
        [[ "$#" -ge 2 ]] || die "--target requires a value"
        target="$2"
        shift 2
        ;;
      --source-ref)
        [[ "$#" -ge 2 ]] || die "--source-ref requires a value"
        source_ref="$2"
        shift 2
        ;;
      --output)
        [[ "$#" -ge 2 ]] || die "--output requires a value"
        output="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown plan option: $1"
        ;;
    esac
  done

  [[ -n "$target" ]] || die "plan requires --target <dir>"
  [[ -n "$source_ref" ]] || die "plan requires --source-ref <ref>"
  target_abs="$(absolute_target "$target")"
  plan_json="$(build_plan_json "$target_abs" "$source_ref")"

  if [[ -n "$output" ]]; then
    write_output_file "$target_abs" "$output" "$plan_json"
  else
    printf '%s\n' "$plan_json"
  fi
}

cmd_apply() {
  die "apply is not implemented; use inspect or plan for this fail-closed foundation"
}

main() {
  local command="${1:-}"

  require_dependencies

  case "$command" in
    inspect)
      shift
      cmd_inspect "$@"
      ;;
    plan)
      shift
      cmd_plan "$@"
      ;;
    apply)
      shift
      cmd_apply "$@"
      ;;
    --help|-h|"")
      usage
      [[ -n "$command" ]] || exit 2
      ;;
    *)
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
