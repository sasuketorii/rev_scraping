#!/usr/bin/env bash
set -euo pipefail

BASELINE_FREEZE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.claude/commands/lib/utils.sh
# shellcheck disable=SC1091
source "$BASELINE_FREEZE_LIB_DIR/utils.sh"

_baseline_freeze_usage() {
  cat <<'EOF'
Usage:
  baseline_freeze.sh snapshot <evidence_dir>
  baseline_freeze.sh verify <evidence_dir> [--exclude <path> ...]
  baseline_freeze.sh pretouch <path>
  baseline_freeze.sh --self-test
EOF
}

_baseline_freeze_dependencies_ok() {
  local cmd=""
  local missing=()

  for cmd in git shasum find; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "baseline_freeze missing required commands: ${missing[*]}"
  fi
}

_baseline_freeze_repo_root() {
  local repo_root=""

  if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    die "baseline_freeze must run inside a git repository"
  fi

  printf '%s\n' "$repo_root"
}

_baseline_freeze_snapshot_file() {
  local evidence_dir="$1"
  printf '%s/baseline_freeze.txt\n' "$evidence_dir"
}

_baseline_freeze_normalize_path() {
  local repo_root="$1"
  local path="$2"

  if [[ -z "$path" ]]; then
    return 1
  fi

  if [[ "$path" == "$repo_root" ]]; then
    printf '.\n'
    return 0
  fi

  if [[ "$path" == "$repo_root/"* ]]; then
    path="${path#"$repo_root"/}"
  fi

  path="${path#./}"
  printf '%s\n' "$path"
}

_baseline_freeze_is_excluded() {
  local candidate="$1"
  shift || true

  local excluded=""
  for excluded in "$@"; do
    if [[ "$candidate" == "$excluded" ]]; then
      return 0
    fi
  done

  return 1
}

_baseline_freeze_status_path() {
  local status="$1"
  local raw_path="$2"

  case "$status" in
    R*|C*)
      printf '%s\n' "${raw_path##* -> }"
      ;;
    *)
      printf '%s\n' "$raw_path"
      ;;
  esac
}

_baseline_freeze_collect() {
  local repo_root="$1"
  local output_file="$2"
  shift 2 || true

  local status_output=""
  local line=""
  local status=""
  local raw_path=""
  local rel_path=""
  local file_sha=""
  local abs_path=""
  local tmp_output=""

  tmp_output="$(create_temp_file baseline_freeze_collect)"

  status_output="$(git -C "$repo_root" status --porcelain=v1 -uall)"
  if [[ -z "$status_output" ]]; then
    : > "$tmp_output"
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue

      status="${line:0:2}"
      raw_path="${line:3}"
      raw_path="$(_baseline_freeze_status_path "$status" "$raw_path")"
      rel_path="$(_baseline_freeze_normalize_path "$repo_root" "$raw_path")"

      if _baseline_freeze_is_excluded "$rel_path" "$@"; then
        continue
      fi

      abs_path="$repo_root/$rel_path"
      if [[ -f "$abs_path" ]]; then
        file_sha="$(shasum -a 256 "$abs_path" | awk '{print $1}')"
      else
        file_sha="MISSING"
      fi

      printf '%s\t%s\t%s\n' "$status" "$file_sha" "$rel_path" >> "$tmp_output"
    done <<< "$status_output"
  fi

  LC_ALL=C sort "$tmp_output" > "$output_file"
  /bin/rm -f "$tmp_output"
}

baseline_freeze_snapshot() {
  local evidence_dir="${1:-}"
  local repo_root=""
  local snapshot_file=""
  local snapshot_data=""

  [[ -n "$evidence_dir" ]] || die "baseline_freeze_snapshot requires <evidence_dir>"

  _baseline_freeze_dependencies_ok
  repo_root="$(_baseline_freeze_repo_root)"
  ensure_dir "$evidence_dir"

  snapshot_file="$(_baseline_freeze_snapshot_file "$evidence_dir")"
  snapshot_data="$(create_temp_file baseline_freeze_snapshot)"

  _baseline_freeze_collect "$repo_root" "$snapshot_data"

  {
    printf '# baseline_freeze_version=1\n'
    printf '# repo_root=%s\n' "$repo_root"
    printf '# generated_at=%s\n' "$(get_timestamp)"
    cat "$snapshot_data"
  } > "$snapshot_file"
  /bin/rm -f "$snapshot_data"

  log_info "baseline_freeze snapshot saved: $snapshot_file"
}

baseline_freeze_verify() {
  local evidence_dir="${1:-}"
  shift || true

  [[ -n "$evidence_dir" ]] || die "baseline_freeze_verify requires <evidence_dir>"

  _baseline_freeze_dependencies_ok

  local repo_root=""
  local snapshot_file=""
  local current_file=""
  local expected_file=""
  local diff_output=""
  local exclude_paths=()
  local normalized_exclude=""
  local excludes_payload=""

  repo_root="$(_baseline_freeze_repo_root)"
  snapshot_file="$(_baseline_freeze_snapshot_file "$evidence_dir")"
  ensure_file "$snapshot_file"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exclude)
        [[ $# -ge 2 ]] || die "--exclude requires <path>"
        normalized_exclude="$(_baseline_freeze_normalize_path "$repo_root" "$2")"
        exclude_paths+=("$normalized_exclude")
        shift 2
        ;;
      *)
        die "Unknown argument for baseline_freeze_verify: $1"
        ;;
    esac
  done

  current_file="$(create_temp_file baseline_freeze_current)"
  expected_file="$(create_temp_file baseline_freeze_expected)"

  if [[ "${#exclude_paths[@]}" -gt 0 ]]; then
    _baseline_freeze_collect "$repo_root" "$current_file" "${exclude_paths[@]}"
    excludes_payload="$(printf '%s\n' "${exclude_paths[@]}")"
  else
    _baseline_freeze_collect "$repo_root" "$current_file"
  fi

  awk -F '\t' -v excludes="$excludes_payload" '
    BEGIN {
      split(excludes, exclude_lines, "\n")
      for (i in exclude_lines) {
        if (exclude_lines[i] != "") {
          excluded[exclude_lines[i]] = 1
        }
      }
    }
    /^#/ { next }
    NF >= 3 {
      path = $3
      if (!(path in excluded)) {
        print
      }
    }
  ' "$snapshot_file" | LC_ALL=C sort > "$expected_file"

  if cmp -s "$expected_file" "$current_file"; then
    /bin/rm -f "$current_file" "$expected_file"
    log_info "baseline_freeze verify passed"
    return 0
  fi

  log_warn "baseline_freeze verify failed: snapshot differs from current state"
  diff_output="$(diff -u "$expected_file" "$current_file" || true)"
  if [[ -n "$diff_output" ]]; then
    printf '%s\n' "$diff_output" >&2
  fi
  /bin/rm -f "$current_file" "$expected_file"
  return 1
}

baseline_freeze_pretouch() {
  local target_path="${1:-}"

  [[ -n "$target_path" ]] || die "baseline_freeze_pretouch requires <path>"

  ensure_dir "$(dirname "$target_path")"
  touch "$target_path"
  log_info "baseline_freeze pretouch complete: $target_path"
}

_baseline_freeze_self_test() {
  _baseline_freeze_dependencies_ok

  local temp_dir="/tmp/baseline_freeze_selftest_$$"
  /bin/rm -rf "$temp_dir"
  mkdir -p "$temp_dir"

  baseline_freeze_snapshot "$temp_dir"
  baseline_freeze_verify "$temp_dir"
  /bin/rm -rf "$temp_dir"

  printf 'PASS\n'
}

baseline_freeze_main() {
  local subcommand="${1:-}"

  case "$subcommand" in
    snapshot)
      shift
      baseline_freeze_snapshot "$@"
      ;;
    verify)
      shift
      baseline_freeze_verify "$@"
      ;;
    pretouch)
      shift
      baseline_freeze_pretouch "$@"
      ;;
    --self-test)
      _baseline_freeze_self_test
      ;;
    -h|--help|help)
      _baseline_freeze_usage
      ;;
    "")
      _baseline_freeze_usage
      exit 1
      ;;
    *)
      die "Unknown subcommand: $subcommand"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  baseline_freeze_main "$@"
fi
