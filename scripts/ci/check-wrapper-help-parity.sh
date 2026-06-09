#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="both"
STRICT=false
UPDATE=false
SHA_TOOL=""
TMP_FILES=()
usage() {
  cat <<'USAGE'
Usage: scripts/ci/check-wrapper-help-parity.sh [options]

Compare live wrapper --help output with pinned golden files.

Options:
  --wrapper <codex|claude|both>  Wrapper help to check (default: both)
  --strict                       Print truncated unified diff on drift
  --update                       Overwrite golden help text and sha256 files
  -h, --help                     Show this help
USAGE
}
die_usage() {
  printf 'ERROR: %s\n' "$*" >&2
  usage >&2
  exit 2
}
cleanup() {
  local file=""
  for file in "${TMP_FILES[@]}"; do
    rm -f "$file" || true
  done
}
trap cleanup EXIT
detect_sha_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    SHA_TOOL="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    SHA_TOOL="shasum"
  else
    printf 'ERROR: sha256sum or shasum is required\n' >&2
    exit 2
  fi
}
sha256_file() {
  if [[ "$SHA_TOOL" == "sha256sum" ]]; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --wrapper)
        [[ "$#" -ge 2 ]] || die_usage "--wrapper requires a value"
        case "$2" in codex|claude|both) WRAPPER="$2" ;; *) die_usage "unknown wrapper: $2" ;; esac
        shift 2
        ;;
      --strict) STRICT=true; shift ;;
      --update) UPDATE=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die_usage "unknown flag: $1" ;;
    esac
  done
}
require_file() {
  local rel="$1"
  [[ -f "$PROJECT_ROOT/$rel" ]] || {
    printf 'ERROR: missing golden file: %s\n' "$rel" >&2
    exit 2
  }
}
golden_sha() {
  awk '{print $1; exit}' "$PROJECT_ROOT/test/golden/$1-wrapper-help.sha256"
}
strict_diff() {
  local wrapper="$1"
  local captured="$2"
  local golden_rel="test/golden/${wrapper}-wrapper-help.txt"
  local diff_output=""
  diff_output="$(diff -u --label "$golden_rel" --label "captured/${wrapper}-wrapper-help.txt" \
    "$PROJECT_ROOT/$golden_rel" "$captured" 2>&1 || true)"
  [[ -z "$diff_output" ]] || printf '%s\n' "$diff_output" | sed -n '1,80p'
}
update_golden() {
  local wrapper="$1"
  local captured="$2"
  local sha="$3"
  local txt_rel="test/golden/${wrapper}-wrapper-help.txt"
  local sha_rel="test/golden/${wrapper}-wrapper-help.sha256"
  printf 'WARNING: --update will overwrite %s and %s from live wrapper output\n' \
    "$txt_rel" "$sha_rel" >&2
  cp "$captured" "$PROJECT_ROOT/$txt_rel"
  printf '%s  %s\n' "$sha" "$txt_rel" >"$PROJECT_ROOT/$sha_rel"
}
check_one() {
  local wrapper="$1"
  local txt_rel="test/golden/${wrapper}-wrapper-help.txt"
  local sha_rel="test/golden/${wrapper}-wrapper-help.sha256"
  local captured=""
  local got=""
  local expected=""
  require_file "$txt_rel"
  require_file "$sha_rel"
  captured="$(mktemp "${TMPDIR:-/tmp}/wrapper-help-${wrapper}.XXXXXX")"
  TMP_FILES+=("$captured")
  if ! (cd "$PROJECT_ROOT" && bash "scripts/${wrapper}-wrapper.sh" --help >"$captured" 2>&1); then
    printf 'FAIL: %s help command failed\n' "$wrapper"
    return 1
  fi
  got="$(sha256_file "$captured")"
  expected="$(golden_sha "$wrapper")"
  if [[ "$UPDATE" == "true" ]]; then
    update_golden "$wrapper" "$captured" "$got"
    expected="$got"
  fi
  if [[ "$got" == "$expected" ]]; then
    printf 'PASS: %s help matches golden (sha=%s)\n' "$wrapper" "${got:0:8}"
    return 0
  fi
  printf 'FAIL: %s help drifted (got=%s, golden=%s)\n' "$wrapper" "$got" "$expected"
  [[ "$STRICT" != "true" ]] || strict_diff "$wrapper" "$captured"
  return 1
}
main() {
  local selected=""
  local name=""
  local total=0
  local failed=0
  parse_args "$@"
  detect_sha_tool
  [[ "$WRAPPER" == "both" ]] && selected="codex claude" || selected="$WRAPPER"
  for name in $selected; do
    total=$((total + 1))
    check_one "$name" || failed=$((failed + 1))
  done
  if [[ "$failed" -eq 0 ]]; then
    printf 'OK: %s/%s wrappers match\n' "$total" "$total"
    exit 0
  fi
  printf 'DRIFT: %s/%s wrappers drifted\n' "$failed" "$total"
  exit 1
}
main "$@"
