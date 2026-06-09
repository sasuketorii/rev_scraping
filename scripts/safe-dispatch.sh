#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'Usage: scripts/safe-dispatch.sh --task-id <id> --owner-tokens "path1,path2,..." --wrapper <wrapper_path> [--wrapper-args "<args>"] -- "<prompt>"' >&2
}

die() {
  echo "safe-dispatch: $*" >&2
  exit 2
}

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_string_array() {
  local joined=${1-}
  local item first=1
  printf '['
  if [ -n "$joined" ]; then
    while IFS= read -r item; do
      if [ "$first" -eq 0 ]; then
        printf ','
      fi
      first=0
      printf '"%s"' "$(json_escape "$item")"
    done <<EOF_ITEMS
$joined
EOF_ITEMS
  fi
  printf ']'
}

hash_path() {
  local path=$1
  local hash_output
  if [ ! -e "$path" ]; then
    printf 'MISSING'
    return 0
  fi
  if [ ! -f "$path" ]; then
    die "owner token exists but is not a regular file: $path"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    hash_output=$(sha256sum "$path")
  elif command -v shasum >/dev/null 2>&1; then
    hash_output=$(shasum -a 256 "$path")
  else
    die "required command not found: sha256sum or shasum"
  fi
  printf '%s' "${hash_output%% *}"
}

write_snapshot() {
  local task_id=$1 suffix=$2
  local output=".agent/state/locks/${task_id}.${suffix}.sha256"
  local tmp="$tmpdir/${task_id}.${suffix}.sha256.tmp"
  local path
  : > "$tmp"
  for path in "${owner_paths[@]}"; do
    printf '%s  %s\n' "$(hash_path "$path")" "$path" >> "$tmp"
  done
  mkdir -p .agent/state/locks
  mv "$tmp" "$output"
}

snapshot_hash_for_path() {
  local snapshot=$1 wanted=$2
  local hash path
  while IFS= read -r line || [ -n "$line" ]; do
    hash=${line%%  *}
    path=${line#*  }
    if [ "$path" = "$wanted" ]; then
      printf '%s' "$hash"
      return 0
    fi
  done < "$snapshot"
  return 1
}

compute_changed_paths() {
  local before=".agent/state/locks/${task_id}.before.sha256"
  local after=".agent/state/locks/${task_id}.after.sha256"
  local path before_hash after_hash changed=""
  for path in "${owner_paths[@]}"; do
    before_hash=$(snapshot_hash_for_path "$before" "$path" || printf '')
    after_hash=$(snapshot_hash_for_path "$after" "$path" || printf '')
    if [ "$before_hash" != "$after_hash" ]; then
      if [ -n "$changed" ]; then
        changed="${changed}"$'\n'
      fi
      changed="${changed}${path}"
    fi
  done
  printf '%s' "$changed"
  return 0
}

append_event() {
  local event_exit_code=$1 changed_paths=$2
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  mkdir -p .agent/metrics
  printf '{"ts":"%s","event":"safe_dispatch","task_id":"%s","wrapper":"%s","exit_code":%s,"owner_paths":%s,"changed_paths":%s}\n' \
    "$(json_escape "$ts")" \
    "$(json_escape "$task_id")" \
    "$(json_escape "$wrapper")" \
    "$event_exit_code" \
    "$(json_string_array "$owner_paths_joined")" \
    "$(json_string_array "$changed_paths")" \
    >> .agent/metrics/dispatch_events.jsonl
}

task_id= owner_tokens= wrapper= wrapper_args= prompt= prompt_seen=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task-id)
      [ "$#" -ge 2 ] || die "missing value for --task-id"; task_id=$2; shift 2
      ;;
    --owner-tokens)
      [ "$#" -ge 2 ] || die "missing value for --owner-tokens"; owner_tokens=$2; shift 2
      ;;
    --wrapper)
      [ "$#" -ge 2 ] || die "missing value for --wrapper"; wrapper=$2; shift 2
      ;;
    --wrapper-args)
      [ "$#" -ge 2 ] || die "missing value for --wrapper-args"; wrapper_args=$2; shift 2
      ;;
    --)
      shift; prompt=$*; prompt_seen=1; break
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$task_id" ] || die "--task-id is required"
[ -n "$owner_tokens" ] || die "--owner-tokens is required"
[ -n "$wrapper" ] || die "--wrapper is required"
[ "$prompt_seen" -eq 1 ] || die "prompt separator -- is required"

case "$task_id" in
  *[!A-Za-z0-9._-]*|*/*) die "task-id may contain only A-Z a-z 0-9 . _ - and no path separators" ;;
esac

[ -d .git ] || [ -d .agent ] || die "cwd must be a repo root with .git or .agent"

tmpdir=$(mktemp -d)
trap '/bin/rm -rf "$tmpdir" || true' EXIT HUP INT TERM

IFS=',' read -r -a owner_paths <<< "$owner_tokens"
[ "${#owner_paths[@]}" -gt 0 ] || die "--owner-tokens produced no paths"

owner_paths_joined=
for owner_path in "${owner_paths[@]}"; do
  [ -n "$owner_path" ] || die "owner token list contains an empty path"
  [ -z "$owner_paths_joined" ] || owner_paths_joined="${owner_paths_joined}"$'\n'
  owner_paths_joined="${owner_paths_joined}${owner_path}"
done

wrapper_argv=()
[ -z "$wrapper_args" ] || read -r -a wrapper_argv <<< "$wrapper_args"

prompt_file="$tmpdir/prompt.txt"
printf '%s\n' "$prompt" > "$prompt_file"

write_snapshot "$task_id" before

set +e
REVHARNESS_PARALLEL_QUIESCE=1 REVHARNESS_TASK_ID="$task_id" \
  "$wrapper" "${wrapper_argv[@]}" < "$prompt_file"
wrapper_exit_code=$?
set -e

write_snapshot "$task_id" after
changed_paths=$(compute_changed_paths)
append_event "$wrapper_exit_code" "$changed_paths"

exit "$wrapper_exit_code"
