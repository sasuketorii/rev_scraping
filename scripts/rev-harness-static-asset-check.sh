#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JSON_OUTPUT="NO"
FILES=()
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-static-asset-check.XXXXXX")"
CHECKS_TSV="$TMP_DIR/checks.tsv"
ERRORS_TSV="$TMP_DIR/errors.tsv"
trap '/bin/rm -rf "$TMP_DIR"' EXIT

: > "$CHECKS_TSV"
: > "$ERRORS_TSV"

die() {
  printf 'rev-harness-static-asset-check: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: scripts/rev-harness-static-asset-check.sh [--json] <file>...

Checks dependency-free static app artifacts:
  - .html files are non-empty and local href/src links resolve inside the repo
  - .css files are non-empty and have balanced braces; this is not a full CSS lint
  - .js files pass `node --check`
  - .json files pass `jq empty`
USAGE
}

normalize_path() {
  local path="$1"
  case "$path" in
    "$PROJECT_ROOT"/*) path="${path#"$PROJECT_ROOT"/}" ;;
    ./*) path="${path#./}" ;;
  esac
  case "$path" in
    ""|.|..|../*|*/../*) die "unsafe or non-repo path: $1" ;;
    /*) die "path is outside project root: $1" ;;
  esac
  printf '%s\n' "$path"
}

record_check() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CHECKS_TSV"
}

record_error() {
  printf '%s\t%s\n' "$1" "$2" >> "$ERRORS_TSV"
}

check_nonempty() {
  local file="$1"
  if [[ ! -s "$PROJECT_ROOT/$file" ]]; then
    record_error "$file" "file is missing or empty"
    return 1
  fi
  return 0
}

check_js() {
  local file="$1"
  command -v node >/dev/null 2>&1 || die "node is required for JavaScript syntax checks"
  if node --check "$PROJECT_ROOT/$file" >/dev/null 2>&1; then
    record_check "$file" "javascript" "node --check"
  else
    record_error "$file" "node --check failed"
  fi
}

check_json() {
  local file="$1"
  command -v jq >/dev/null 2>&1 || die "jq is required for JSON syntax checks"
  if jq empty "$PROJECT_ROOT/$file" >/dev/null 2>&1; then
    record_check "$file" "json" "jq empty"
  else
    record_error "$file" "jq empty failed"
  fi
}

check_css() {
  local file="$1"
  local open_count=""
  local close_count=""
  check_nonempty "$file" || return 0
  open_count="$(tr -cd '{' < "$PROJECT_ROOT/$file" | wc -c | tr -d '[:space:]')"
  close_count="$(tr -cd '}' < "$PROJECT_ROOT/$file" | wc -c | tr -d '[:space:]')"
  if [[ "$open_count" != "$close_count" ]]; then
    record_error "$file" "unbalanced CSS braces: open=$open_count close=$close_count"
    return 0
  fi
  record_check "$file" "css" "non-empty and balanced braces"
}

check_html() {
  local file="$1"
  local refs_file="$TMP_DIR/html-refs.txt"
  local error_count_before=""
  local error_count_after=""
  local ref=""
  local resolved=""
  check_nonempty "$file" || return 0
  error_count_before="$(wc -l < "$ERRORS_TSV" | tr -d '[:space:]')"
  node - "$PROJECT_ROOT/$file" "$PROJECT_ROOT" > "$refs_file" <<'NODE'
const fs = require("fs");
const path = require("path");
const file = process.argv[2];
const root = process.argv[3];
const html = fs.readFileSync(file, "utf8");
const refs = [];
const attrPattern = /\b(?:href|src)=["']([^"']+)["']/gi;
for (const match of html.matchAll(attrPattern)) {
  const value = match[1].trim();
  if (
    !value ||
    value.startsWith("#") ||
    value.startsWith("//") ||
    /^[a-z][a-z0-9+.-]*:/i.test(value)
  ) {
    continue;
  }
  const resolved = path.resolve(path.dirname(file), value.split("#")[0].split("?")[0]);
  if (!resolved.startsWith(root + path.sep)) {
    console.log(`OUTSIDE\t${value}`);
  } else {
    console.log(`LOCAL\t${path.relative(root, resolved)}`);
  }
}
NODE
  while IFS=$'\t' read -r kind ref || [[ -n "${kind:-}" ]]; do
    [[ -n "${kind:-}" ]] || continue
    if [[ "$kind" == "OUTSIDE" ]]; then
      record_error "$file" "HTML reference escapes repo: $ref"
      continue
    fi
    resolved="$PROJECT_ROOT/$ref"
    if [[ ! -f "$resolved" ]]; then
      record_error "$file" "missing local HTML reference: $ref"
    fi
  done < "$refs_file"
  error_count_after="$(wc -l < "$ERRORS_TSV" | tr -d '[:space:]')"
  if [[ "$error_count_before" == "$error_count_after" ]]; then
    record_check "$file" "html" "non-empty and local references resolved"
  fi
}

emit_json() {
  jq -Rn \
    --slurpfile checked <(jq -Rn '
      [inputs | select(length > 0) | split("\t") | {
        path: .[0],
        kind: .[1],
        check: .[2]
      }]
    ' < "$CHECKS_TSV") \
    --slurpfile errors <(jq -Rn '
      [inputs | select(length > 0) | split("\t") | {
        path: .[0],
        error: .[1]
      }]
    ' < "$ERRORS_TSV") \
    '{
      schema_version: "rev-harness-static-asset-check/v1",
      status: (if (($errors[0] | length) == 0) then "PASS" else "FAIL" end),
      checked_files: $checked[0],
      errors: $errors[0]
    }'
}

emit_text() {
  if [[ -s "$ERRORS_TSV" ]]; then
    printf 'FAIL: rev_harness_static_asset_check\n'
    awk -F '\t' '{ printf "- %s: %s\n", $1, $2 }' "$ERRORS_TSV"
    return 1
  fi
  printf 'PASS: rev_harness_static_asset_check\n'
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUTPUT="YES"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      FILES+=("$(normalize_path "$1")")
      shift
      ;;
  esac
done

[[ "${#FILES[@]}" -gt 0 ]] || die "at least one file path is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

for file in "${FILES[@]}"; do
  if [[ ! -f "$PROJECT_ROOT/$file" ]]; then
    record_error "$file" "file does not exist"
    continue
  fi
  case "$file" in
    *.html|*.htm) check_html "$file" ;;
    *.css) check_css "$file" ;;
    *.js|*.mjs|*.cjs) check_js "$file" ;;
    *.json) check_json "$file" ;;
    *) check_nonempty "$file" && record_check "$file" "file" "non-empty" ;;
  esac
done

if [[ "$JSON_OUTPUT" == "YES" ]]; then
  emit_json
else
  emit_text
fi

[[ ! -s "$ERRORS_TSV" ]]
