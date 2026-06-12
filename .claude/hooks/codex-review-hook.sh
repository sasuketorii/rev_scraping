#!/bin/sh
# shellcheck shell=bash
if [ "${1-}" != "--__codex-review-hook-bash__" ]; then
  unset BASH_ENV ENV
  exec /bin/bash --noprofile --norc "$0" --__codex-review-hook-bash__ "$@"
fi
shift
#
# codex-review-hook.sh - shell adapter for review-queue hook ingress
#
# The caller-facing hook path remains a shell adapter ingress for Claude Code
# compatibility. P3 moved PostToolUse pre-filtering into this shell adapter so
# skipped files do not require Rust toolchain work.
# Hook ingress pins the core review queue backend: inherited
# REVHARNESS_REVIEW_QUEUE_BACKEND is unset before invoking the queue helper.
#
set -euo pipefail

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

log_hook() {
  echo "[review-hook] $*" >&2
}

die_hook() {
  log_hook "ERROR: $*"
  exit 1
}

SCRIPT_DIR="$(script_dir)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
QUEUE_FILE="${REPO_ROOT}/.claude/tmp/review_queue.json"
QUEUE_HELPER="${REPO_ROOT}/scripts/semantic-review-queue.sh"
JQ_BIN="${JQ_BIN:-}"

resolve_jq() {
  if [[ -n "$JQ_BIN" ]]; then
    [[ -x "$JQ_BIN" ]] || die_hook "jq not executable: $JQ_BIN"
    printf '%s\n' "$JQ_BIN"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || die_hook "jq is required for hook input parsing"
  command -v jq
}

trim_trailing_slash() {
  local path_value="${1:-}"
  while [[ "$path_value" != "/" && "$path_value" == */ ]]; do
    path_value="${path_value%/}"
  done
  printf '%s\n' "$path_value"
}

dirname_shell() {
  local path_value="${1:-}"
  path_value="$(trim_trailing_slash "$path_value")"
  case "$path_value" in
    */*)
      path_value="${path_value%/*}"
      [[ -n "$path_value" ]] || path_value="/"
      printf '%s\n' "$path_value"
      ;;
    *)
      printf '.\n'
      ;;
  esac
}

path_extension() {
  local path_value="${1:-}"
  local base_name=""

  base_name="${path_value##*/}"
  case "$base_name" in
    ""|.*)
      if [[ "$base_name" != *.* || "$base_name" == .* && "${base_name#*.}" != *.* ]]; then
        printf '\n'
        return 0
      fi
      ;;
  esac
  [[ "$base_name" == *.* ]] || {
    printf '\n'
    return 0
  }
  printf '%s\n' "${base_name##*.}"
}

is_code_file() {
  local path_value="${1:-}"
  local ext=""

  ext="$(path_extension "$path_value")"
  case "$ext" in
    sh|py|js|ts|tsx|rs|go|java|rb|php|c|cpp|h|hpp)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

path_starts_with_root() {
  local path_value="${1:-}"
  local root="${2:-}"
  [[ "$path_value" == "$root" || "$path_value" == "$root/"* ]]
}

normalize_candidate_path() {
  local candidate="${1:-}"
  local canonical_repo_root="${2:-}"
  local depth="${3:-0}"
  local current=""
  local remaining=""
  local component=""
  local target=""
  local target_path=""

  [[ -n "$candidate" ]] || die_hook "path is required"
  [[ "$candidate" == /* ]] || die_hook "absolute path is required for normalization: $candidate"
  (( depth <= 40 )) || die_hook "too many symlink expansions while normalizing: $candidate"

  current="/"
  remaining="${candidate#/}"
  while [[ -n "$remaining" ]]; do
    if [[ "$remaining" == */* ]]; then
      component="${remaining%%/*}"
      remaining="${remaining#*/}"
    else
      component="$remaining"
      remaining=""
    fi

    case "$component" in
      ""|.)
        continue
        ;;
      ..)
        if [[ "$current" != "/" ]]; then
          current="${current%/*}"
          [[ -n "$current" ]] || current="/"
        fi
        continue
        ;;
    esac

    if [[ "$current" == "/" ]]; then
      current="/$component"
    else
      current="$current/$component"
    fi

    if [[ -L "$current" ]]; then
      target="$(/usr/bin/readlink "$current")" \
        || die_hook "failed to read symlink: $current"
      if [[ "$target" == /* ]]; then
        target_path="$target"
      else
        target_path="$(dirname_shell "$current")/$target"
      fi
      current="$(normalize_candidate_path "$target_path" "$canonical_repo_root" "$((depth + 1))")"
    elif [[ -e "$current" ]]; then
      :
    else
      # Match the old Rust hook: missing suffixes stay lexical so newly
      # created files can still be normalized before they exist.
      :
    fi
  done

  printf '%s\n' "$(trim_trailing_slash "$current")"
}

normalize_file_path() {
  local raw_path="${1:-}"
  local canonical_repo_root="${2:-}"
  local candidate=""
  local normalized=""
  local relative=""

  [[ -n "$raw_path" ]] || die_hook "path is required"
  [[ -n "$canonical_repo_root" ]] || die_hook "repo root is required"

  if [[ "$raw_path" == /* ]]; then
    candidate="$raw_path"
  else
    candidate="${canonical_repo_root}/${raw_path}"
  fi

  normalized="$(normalize_candidate_path "$candidate" "$canonical_repo_root")"
  if ! path_starts_with_root "$normalized" "$canonical_repo_root"; then
    printf 'outside:%s\n' "$raw_path"
    return 0
  fi

  relative="${normalized#"$canonical_repo_root"}"
  relative="${relative#/}"
  printf 'relative:%s\n' "$relative"
}

ensure_queue_helper_executable() {
  [[ -f "$QUEUE_HELPER" && -x "$QUEUE_HELPER" ]] \
    || die_hook "queue helper not found or not executable: $QUEUE_HELPER"
}

parse_duplicate_flag() {
  local output="${1:-}"
  local jq_bin="$2"

  if "$jq_bin" -e '.duplicate == true' >/dev/null 2>&1 <<< "$output"; then
    return 0
  fi
  return 1
}

enqueue_file() {
  local file_path="$1"
  local jq_bin="$2"
  local enqueue_output=""

  ensure_queue_helper_executable
  if ! enqueue_output="$(/usr/bin/env -u REVHARNESS_REVIEW_QUEUE_BACKEND \
    "$QUEUE_HELPER" enqueue \
    --repo-root "$REPO_ROOT" \
    --file-path "$file_path" \
    --source hook \
    --export-json "$QUEUE_FILE")"; then
    die_hook "Failed to enqueue DB review queue item for: $file_path"
  fi

  if parse_duplicate_flag "$enqueue_output" "$jq_bin"; then
    log_hook "Already pending in DB review queue: $file_path"
  else
    log_hook "Queued for review via DB authority: $file_path"
  fi
}

main() {
  local jq_bin=""
  local input=""
  local tool_name=""
  local raw_file_path=""
  local normalized_result=""
  local normalized_kind=""
  local normalized_path=""

  jq_bin="$(resolve_jq)"
  input="$(cat)"
  input="${input#"${input%%[!$' \t\r\n']*}"}"
  input="${input%"${input##*[!$' \t\r\n']}"}"
  [[ -n "$input" ]] || return 0

  tool_name="$("$jq_bin" -er '.tool_name // empty' 2>/dev/null <<< "$input" || true)"
  [[ -n "$tool_name" ]] || return 0
  case "$tool_name" in
    Edit|Write)
      ;;
    *)
      return 0
      ;;
  esac

  raw_file_path="$("$jq_bin" -er '.tool_input.file_path // empty' 2>/dev/null <<< "$input" || true)"
  [[ -n "$raw_file_path" ]] || return 0

  normalized_result="$(normalize_file_path "$raw_file_path" "$REPO_ROOT")"
  normalized_kind="${normalized_result%%:*}"
  normalized_path="${normalized_result#*:}"
  case "$normalized_kind" in
    outside)
      log_hook "Skipping file outside repo: $normalized_path"
      return 0
      ;;
    relative)
      ;;
    *)
      die_hook "internal normalization error for: $raw_file_path"
      ;;
  esac

  is_code_file "$normalized_path" || return 0
  enqueue_file "$normalized_path" "$jq_bin"
}

main "$@"
