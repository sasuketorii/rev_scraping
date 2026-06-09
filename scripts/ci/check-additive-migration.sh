#!/usr/bin/env bash
set -euo pipefail
#
# check-additive-migration.sh - Destructive SQL detection for migrations
#
# 目的:
#   harness-rust/crates/semantic-mcp/migrations/ 配下の SQL migration が
#   additive-only (CREATE IF NOT EXISTS / ADD COLUMN) であり、Tier 1
#   byte-stable invariant (capsules / file_parse_cache / tree_sitter_*) を
#   破壊しないことを CI で機械検証する。
#
# 使用方法:
#   scripts/ci/check-additive-migration.sh
#   scripts/ci/check-additive-migration.sh --dir path/to/migrations
#   scripts/ci/check-additive-migration.sh --report-only
script_dir() {
  local src="${BASH_SOURCE[0]}"
  case "${src}" in
    */*) (cd "${src%/*}" && pwd -P) ;;
    *) pwd -P ;;
  esac
}

usage() {
  cat <<'USAGE'
Usage: scripts/ci/check-additive-migration.sh [--dir <migrations dir>] [--strict|--report-only] [--help]

Default dir: harness-rust/crates/semantic-mcp/migrations/
--strict is the default and exits 1 on fatal findings.
--report-only logs fatal findings but exits 0.

Forbidden patterns are checked case-insensitively with grep -iE:
  \bDROP[[:space:]]+TABLE\b
  \bDROP[[:space:]]+INDEX\b
  \bDROP[[:space:]]+COLUMN\b
  \bALTER[[:space:]]+TABLE[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+DROP\b
  \bALTER[[:space:]]+TABLE[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+RENAME\b
  \bTRUNCATE\b
  \bDELETE[[:space:]]+FROM\b

Warning-only pattern:
  REPLACE[[:space:]]+INTO

Tier 1 protected tables:
  capsules
  file_parse_cache
  tree_sitter_*

Allowed additive patterns for reference only:
  CREATE TABLE IF NOT EXISTS
  CREATE INDEX IF NOT EXISTS
  ALTER TABLE <t> ADD (COLUMN)?
  CREATE VIEW
  INSERT INTO ... ON CONFLICT
USAGE
}

PROJECT_ROOT="$(cd "$(script_dir)/../.." && pwd -P)"
DEFAULT_DIR="harness-rust/crates/semantic-mcp/migrations"
MIGRATIONS_DIR="${DEFAULT_DIR}"
MODE="strict"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dir)
      [[ "$#" -ge 2 ]] || { echo "FAIL: --dir requires a value" >&2; exit 2; }
      MIGRATIONS_DIR="$2"
      shift 2
      ;;
    --strict) MODE="strict"; shift ;;
    --report-only) MODE="report-only"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "FAIL: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "${MIGRATIONS_DIR}" in
  /*) SCAN_DIR="${MIGRATIONS_DIR}"; DISPLAY_DIR="${MIGRATIONS_DIR}" ;;
  *) SCAN_DIR="${PROJECT_ROOT}/${MIGRATIONS_DIR}"; DISPLAY_DIR="${MIGRATIONS_DIR}" ;;
esac

fatal_findings=0
file_count=0
IDENT="[A-Za-z_][A-Za-z0-9_]*"
LB="(^|[^A-Za-z0-9_])"
RB="([^A-Za-z0-9_]|$)"

preview_line() {
  local preview
  preview="$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g')"
  [[ "${#preview}" -le 160 ]] || preview="${preview:0:157}..."
  printf '%s' "${preview}"
}

display_file_for() {
  case "$1" in
    "${SCAN_DIR}"/*) printf '%s/%s' "${DISPLAY_DIR%/}" "${1#"${SCAN_DIR}/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

emit_finding() {
  printf 'FINDING: %s:%s: %s: %s\n' \
    "$(display_file_for "$1")" "$2" "$3" "$(preview_line "$4")" >&2
}

grep_line() {
  printf '%s\n' "$1" | grep -iqE "$2"
}

fatal_if_match() {
  local file="$1" lineno="$2" line="$3" category="$4" pattern="$5"
  if grep_line "${line}" "${pattern}"; then
    emit_finding "${file}" "${lineno}" "${category}" "${line}"
    fatal_findings=$((fatal_findings + 1))
  fi
}

warn_if_match() {
  local file="$1" lineno="$2" line="$3" category="$4" pattern="$5"
  if grep_line "${line}" "${pattern}"; then
    emit_finding "${file}" "${lineno}" "${category}" "${line}"
  fi
}

scan_line() {
  local file="$1" lineno="$2" line="$3"
  fatal_if_match "${file}" "${lineno}" "${line}" "destructive DROP TABLE" "${LB}DROP[[:space:]]+TABLE${RB}"
  fatal_if_match "${file}" "${lineno}" "${line}" "destructive DROP INDEX" "${LB}DROP[[:space:]]+INDEX${RB}"
  fatal_if_match "${file}" "${lineno}" "${line}" "destructive DROP COLUMN" "${LB}DROP[[:space:]]+COLUMN${RB}"
  fatal_if_match "${file}" "${lineno}" "${line}" "destructive ALTER TABLE DROP" "${LB}ALTER[[:space:]]+TABLE[[:space:]]+${IDENT}[[:space:]]+DROP${RB}"
  fatal_if_match "${file}" "${lineno}" "${line}" "destructive ALTER TABLE RENAME" "${LB}ALTER[[:space:]]+TABLE[[:space:]]+${IDENT}[[:space:]]+RENAME${RB}"
  fatal_if_match "${file}" "${lineno}" "${line}" "destructive TRUNCATE" "${LB}TRUNCATE${RB}"
  fatal_if_match "${file}" "${lineno}" "${line}" "destructive DELETE FROM" "${LB}DELETE[[:space:]]+FROM${RB}"
  fatal_if_match "${file}" "${lineno}" "${line}" "Tier 1 violation protected table capsules" "${LB}capsules${RB}"
  fatal_if_match "${file}" "${lineno}" "${line}" "Tier 1 violation protected table file_parse_cache" "${LB}file_parse_cache${RB}"
  fatal_if_match "${file}" "${lineno}" "${line}" "Tier 1 violation protected table tree_sitter_*" "${LB}tree_sitter_[A-Za-z0-9_]*${RB}"
  warn_if_match "${file}" "${lineno}" "${line}" "warning REPLACE INTO" "${LB}REPLACE[[:space:]]+INTO${RB}"
}

scan_file() {
  local row lineno line
  while IFS= read -r row; do
    lineno="${row%%:*}"
    line="${row#*:}"
    scan_line "$1" "${lineno}" "${line}"
  done < <(grep -n -v -E '^[[:space:]]*--' "$1" || true)
}

if [[ ! -d "${SCAN_DIR}" ]]; then
  echo "OK: 0 migration files in ${DISPLAY_DIR}"
  exit 0
fi

while IFS= read -r sql_file; do
  [[ -n "${sql_file}" ]] || continue
  file_count=$((file_count + 1))
  scan_file "${sql_file}"
done < <(find "${SCAN_DIR}" -type f -name '*.sql' | sort)

if [[ "${file_count}" -eq 0 ]]; then
  echo "OK: 0 migration files in ${DISPLAY_DIR}"
elif [[ "${fatal_findings}" -eq 0 ]]; then
  echo "OK: ${file_count} migration files additive-only"
elif [[ "${MODE}" == "report-only" ]]; then
  echo "REPORT: ${fatal_findings} finding(s) across ${file_count} file(s) (informational)"
else
  echo "FAIL: ${fatal_findings} finding(s) across ${file_count} file(s)" >&2
  exit 1
fi
