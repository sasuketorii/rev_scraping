#!/bin/bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage:' \
    '  resolve-semantic-project-id.sh [--repo-root PATH] [--print]' \
    '  resolve-semantic-project-id.sh [--repo-root PATH] --path' \
    '  resolve-semantic-project-id.sh [--repo-root PATH] --health' \
    '  resolve-semantic-project-id.sh [--repo-root PATH] --bootstrap SEED' \
    '' \
    'Options:' \
    '  --repo-root PATH   Override the repository root used for artifact resolution.' \
    '  --print            Print the resolved project_id. This is the default action.' \
    '  --path             Print the canonical .shared/project_id artifact path.' \
    '  --health           Print project_id drift classification JSON.' \
    '  --bootstrap SEED   Create the canonical artifact if missing using SEED + random suffix.'
}

die() {
  printf 'resolve-semantic-project-id.sh: %s\n' "$*" >&2
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

resolve_repo_root() {
  if [[ -n "$REPO_ROOT_OVERRIDE" ]]; then
    [[ -d "$REPO_ROOT_OVERRIDE" ]] || die "repo root does not exist: $REPO_ROOT_OVERRIDE"
    (
      cd "$REPO_ROOT_OVERRIDE" && pwd -P
    )
    return 0
  fi

  printf '%s\n' "$(cd "$(script_dir)/.." && pwd -P)"
}

project_id_script() {
  if [[ -n "${PROJECT_ID_SCRIPT:-}" ]]; then
    die "PROJECT_ID_SCRIPT override is forbidden; canonical repo-local helper is required"
  fi

  printf '%s\n' "$(script_dir)/project-id.sh"
}

ensure_project_id_script() {
  local project_id_tool="$1"
  [[ -x "$project_id_tool" ]] || die "project_id helper not found or not executable: $project_id_tool"
}

run_project_id() {
  local project_id_tool="$1"
  local repo_root="$2"
  shift 2

  ensure_project_id_script "$project_id_tool"
  PROJECT_ID_REPO_ROOT="$repo_root" /bin/bash "$project_id_tool" "$@"
}

ACTION="print"
BOOTSTRAP_SEED=""
REPO_ROOT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 ]] || die "--repo-root requires a value"
      REPO_ROOT_OVERRIDE="$2"
      shift 2
      ;;
    --path)
      ACTION="path"
      shift
      ;;
    --health)
      ACTION="health"
      shift
      ;;
    --bootstrap)
      [[ $# -ge 2 ]] || die "--bootstrap requires a seed value"
      ACTION="bootstrap"
      BOOTSTRAP_SEED="$2"
      shift 2
      ;;
    --print)
      ACTION="print"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

REPO_ROOT="$(resolve_repo_root)"
PROJECT_ID_TOOL="$(project_id_script)"

case "$ACTION" in
  path)
    run_project_id "$PROJECT_ID_TOOL" "$REPO_ROOT" artifact-path
    ;;
  health)
    run_project_id "$PROJECT_ID_TOOL" "$REPO_ROOT" health
    ;;
  bootstrap)
    run_project_id "$PROJECT_ID_TOOL" "$REPO_ROOT" bootstrap "$BOOTSTRAP_SEED"
    ;;
  print)
    run_project_id "$PROJECT_ID_TOOL" "$REPO_ROOT" read
    ;;
  *)
    die "unsupported action: $ACTION"
    ;;
esac
