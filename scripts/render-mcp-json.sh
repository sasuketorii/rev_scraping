#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: scripts/render-mcp-json.sh --harness-root <abs-path> [--output <dest>] [--force]
USAGE
}

die() { printf 'render-mcp-json: error: %s\n' "$1" >&2; exit 2; }
require_jq() { command -v jq >/dev/null 2>&1 || die "jq is required"; }

canonicalize_dir() {
  local path="$1"
  case "$path" in
    /*) ;;
    *) die "--harness-root must be an absolute path: $path" ;;
  esac
  [[ -d "$path" ]] || die "--harness-root does not exist or is not a directory: $path"
  (cd "$path" && pwd -P) || die "failed to resolve --harness-root: $path"
}

absolute_output_path() {
  local path="$1" dir base
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  [[ -d "$dir" ]] || die "--output directory does not exist: $dir"
  printf '%s/%s' "$(cd "$dir" && pwd -P)" "$base"
}

main() {
  require_jq

  local harness_root="" output="$PWD/.mcp.json" force=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --harness-root)
        [[ "$#" -ge 2 ]] || die "--harness-root requires a value"
        harness_root="$2"
        shift 2
        ;;
      --output)
        [[ "$#" -ge 2 ]] || die "--output requires a value"
        output="$2"
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        usage
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$harness_root" ]] || die "--harness-root is required"
  harness_root="$(canonicalize_dir "$harness_root")"

  local template="$harness_root/.mcp.json.template"
  local launcher_name="launch-semantic-mcp.sh" # rev-harness-i13: allow
  local launcher="$harness_root/scripts/$launcher_name"
  [[ -f "$template" ]] || die "template missing: $template"
  [[ -x "$launcher" ]] || die "semantic MCP launcher missing or not executable: $launcher"

  output="$(absolute_output_path "$output")"
  if [[ -e "$output" && "$force" != "1" ]]; then
    die "output already exists (use --force to overwrite): $output"
  fi

  local out_dir tmp rendered_command
  out_dir="$(dirname "$output")"
  tmp="$(mktemp "$out_dir/.mcp.json.tmp.XXXXXX")" || die "failed to create temporary output"
  trap 'rm -f "$tmp" >/dev/null 2>&1 || true' EXIT

  jq --arg root "$harness_root" \
    '.mcpServers."semantic-mcp".command = "\($root)/scripts/launch-semantic-mcp.sh"' \
    < "$template" > "$tmp" || die "failed to render template with jq"

  jq empty "$tmp" >/dev/null || die "rendered output is not valid JSON"
  rendered_command="$(jq -r '.mcpServers."semantic-mcp".command // empty' "$tmp")"
  case "$rendered_command" in
    /*) ;;
    *) die "rendered command is not absolute: $rendered_command" ;;
  esac
  [[ -x "$rendered_command" ]] || die "rendered command is not executable: $rendered_command"

  mv "$tmp" "$output"
  trap - EXIT
}

main "$@"
