#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: scripts/ci/mcp-wire-contract-check.sh [--quick] [--strict] [--adopter <path>]
USAGE
}

die() { printf 'mcp-wire-contract-check: error: %s\n' "$1" >&2; exit 2; }
warn_line() { printf 'WARN: %s\n' "$1" >&2; }
error_line() { printf 'ERROR: %s\n' "$1" >&2; }
require_jq() { command -v jq >/dev/null 2>&1 || die "jq is required"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LAUNCHER_BASENAME="launch-semantic-mcp.sh" # rev-harness-i13: allow
LAUNCHER_PATH="$HARNESS_ROOT/scripts/$LAUNCHER_BASENAME"
[[ -x "$LAUNCHER_PATH" ]] || die "harness root resolution failed: $HARNESS_ROOT"

strict=0
quick=0
adopter_path=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --quick) quick=1; shift ;;
    --strict) strict=1; shift ;;
    --adopter)
      [[ "$#" -ge 2 ]] || die "--adopter requires a value"
      adopter_path="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

require_jq
findings_file="$(mktemp "${TMPDIR:-/tmp}/mcp-wire-findings.XXXXXX")"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/mcp-wire-contract.XXXXXX")"
trap 'rm -f "$findings_file" >/dev/null 2>&1 || true; rm -rf "$tmp_root" >/dev/null 2>&1 || true' EXIT

record_finding() {
  local emitter_id="$1" file="$2" line="$3" expected="$4" actual="$5"
  jq -cn \
    --arg emitter_id "$emitter_id" \
    --arg file "$file" \
    --argjson line "$line" \
    --arg expected_fragment "$expected" \
    --arg actual_fragment "$actual" \
    '{emitter_id:$emitter_id,file:$file,line:$line,expected_fragment:$expected_fragment,actual_fragment:$actual_fragment}' \
    >> "$findings_file"
}

canonical_entry() {
  jq -cS --arg root "$HARNESS_ROOT" '
    .mcpServers."semantic-mcp".command = "\($root)/scripts/launch-semantic-mcp.sh"
    | .mcpServers."semantic-mcp"
    | {command:(.command // null), args:(.args // []), env:(.env // {})}
  ' "$HARNESS_ROOT/.mcp.json.template"
}

entry_from_json_file() {
  local file="$1"
  jq -cS '.mcpServers."semantic-mcp" | {command:(.command // null), args:(.args // []), env:(.env // {})}' "$file"
}

harness_self_entry_from_json_file() {
  local file="$1"
  jq -cS --arg root "$HARNESS_ROOT" '
    .mcpServers."semantic-mcp"
    | {command:(.command // null), args:(.args // []), env:(.env // {})}
    | if .command == "./scripts/launch-semantic-mcp.sh"
      then .command = "\($root)/scripts/launch-semantic-mcp.sh"
      else .
      end
  ' "$file"
}

compare_json_mcp_file() {
  local emitter_id="$1" file="$2" canonical="$3" actual
  if [[ ! -f "$file" ]]; then
    record_finding "$emitter_id" "$file" 0 "$canonical" "missing file"
    return 0
  fi
  if ! jq empty "$file" >/dev/null 2>&1; then
    record_finding "$emitter_id" "$file" 0 "valid JSON" "invalid JSON"
    return 0
  fi
  if ! actual="$(entry_from_json_file "$file" 2>/dev/null)"; then
    record_finding "$emitter_id" "$file" 0 "$canonical" "missing mcpServers.semantic-mcp"
    return 0
  fi
  if [[ "$actual" != "$canonical" ]]; then
    record_finding "$emitter_id" "$file" 0 "$canonical" "$actual"
  fi
}

compare_harness_self_json_file() {
  local emitter_id="$1" file="$2" canonical="$3" actual
  if [[ ! -f "$file" ]]; then
    record_finding "$emitter_id" "$file" 0 "$canonical" "missing file"
    return 0
  fi
  if ! jq empty "$file" >/dev/null 2>&1; then
    record_finding "$emitter_id" "$file" 0 "valid JSON" "invalid JSON"
    return 0
  fi
  if ! actual="$(harness_self_entry_from_json_file "$file" 2>/dev/null)"; then
    record_finding "$emitter_id" "$file" 0 "$canonical" "missing mcpServers.semantic-mcp"
    return 0
  fi
  if [[ "$actual" != "$canonical" ]]; then
    record_finding "$emitter_id" "$file" 0 "$canonical" "$actual"
  fi
}

compare_codex_toml() {
  local file="$1" canonical="$2" command args actual
  if [[ ! -f "$file" ]]; then
    record_finding "harness-self-codex" "$file" 0 "$canonical" "missing file"
    return 0
  fi

  command="$(awk '
    /^\[mcp_servers\."semantic-mcp"\]$/ || /^\[mcp_servers\.semantic-mcp\]$/ {in_section=1; next}
    /^\[/ {in_section=0}
    in_section && /^[[:space:]]*command[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$file")"
  if [[ "$command" == "./scripts/launch-semantic-mcp.sh" ]]; then
    command="$HARNESS_ROOT/scripts/launch-semantic-mcp.sh"
  fi
  args="$(awk '
    /^\[mcp_servers\."semantic-mcp"\]$/ || /^\[mcp_servers\.semantic-mcp\]$/ {in_section=1; next}
    /^\[/ {in_section=0}
    in_section && /^[[:space:]]*args[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      print
      exit
    }
  ' "$file")"
  [[ -n "$args" ]] || args="[]"
  actual="$(jq -cn --arg command "$command" --argjson args "$args" '{command:($command | if . == "" then null else . end),args:$args,env:{}}' 2>/dev/null || printf '{}')"
  actual="$(printf '%s\n' "$actual" | jq -cS '.')"
  if [[ "$actual" != "$canonical" ]]; then
    record_finding "harness-self-codex" "$file" 0 "$canonical" "$actual"
  fi
}

run_emitter_capture() {
  local canonical="$1" emitter="$2" fixture="$3"
  shift 3
  if [[ ! -x "$HARNESS_ROOT/$emitter" ]]; then
    record_finding "$emitter" "$HARNESS_ROOT/$emitter" 0 "executable emitter" "missing or not executable"
    return 0
  fi
  if ! (cd "$HARNESS_ROOT" && bash "$emitter" "$@" --output-fixture "$fixture") >/dev/null 2>"$fixture.stderr"; then
    record_finding "$emitter" "$HARNESS_ROOT/$emitter" 0 "self-test --output-fixture succeeds" "$(sed -n '1p' "$fixture.stderr")"
    return 0
  fi
  compare_json_mcp_file "$emitter" "$fixture" "$canonical"
}

check_init_negative() {
  local target="$tmp_root/init-project-target"
  mkdir -p "$target"
  if [[ ! -x "$HARNESS_ROOT/scripts/init-project.sh" ]]; then
    record_finding "scripts/init-project.sh" "$HARNESS_ROOT/scripts/init-project.sh" 0 "executable emitter" "missing or not executable"
    return 0
  fi
  if ! (cd "$HARNESS_ROOT" && bash scripts/init-project.sh --target "$target" --self-test) >/dev/null 2>"$tmp_root/init.stderr"; then
    record_finding "scripts/init-project.sh" "$HARNESS_ROOT/scripts/init-project.sh" 0 "self-test succeeds without MCP stub" "$(sed -n '1p' "$tmp_root/init.stderr")"
    return 0
  fi
  if [[ -f "$target/.claude/settings.json" ]] && ! jq -e '.mcpServers // {} | has("semantic-mcp") | not' "$target/.claude/settings.json" >/dev/null 2>&1; then
    record_finding "scripts/init-project.sh" "$target/.claude/settings.json" 0 "no semantic-mcp stub" "init-project still writes mcpServers stub"
  fi
}

is_allowlisted() {
  local rel="$1" line="$2"
  case "$line" in
    *"# rev-harness-i13: allow"*) return 0 ;;
  esac
  case "$rel" in
    .mcp.json.template|*/.mcp.json.template) return 0 ;;
    test/*|*/test/*) return 0 ;;
    .agents/skills/*|*/.agents/skills/*|.claude/skills/*|*/.claude/skills/*) return 0 ;;
    .claude/CLAUDE-LOCAL.md|*/.claude/CLAUDE-LOCAL.md) return 0 ;;
    migrations/*|*/migrations/*|migrate-*.sh|*/migrate-*.sh|migrate_*.sh|*/migrate_*.sh) return 0 ;;
    CHANGELOG.md|*/CHANGELOG.md|docs/*|*/docs/*) return 0 ;;
    docs/canonical-invariants.md|*/docs/canonical-invariants.md|AGENTS.md|*/AGENTS.md|README.md|*/README.md) return 0 ;;
    .agent/active/*|*/.agent/active/*|.agent/archive/*|*/.agent/archive/*|.agent/metrics/*|*/.agent/metrics/*|.agent/registry/*|*/.agent/registry/*) return 0 ;;
    .agent/PROJECT_CONTEXT.md|*/.agent/PROJECT_CONTEXT.md|.agent_rules/*|*/.agent_rules/*|.rev-harness-state/*|*/.rev-harness-state/*) return 0 ;;
    .claude/tmp/*|*/.claude/tmp/*) return 0 ;;
    .codex/sessions/*|*/.codex/sessions/*|.claude/projects/*|*/.claude/projects/*) return 0 ;;
    .claude/settings.json|*/.claude/settings.json|.codex/config.toml|*/.codex/config.toml) return 0 ;;
    scripts/render-mcp-json.sh|*/scripts/render-mcp-json.sh) return 0 ;;
    scripts/ci/mcp-wire-contract-check.sh|*/scripts/ci/mcp-wire-contract-check.sh) return 0 ;;
    scripts/install-rev-harness-mcp.sh|*/scripts/install-rev-harness-mcp.sh) return 0 ;;
    scripts/rev-harness-mcp-wire.sh|*/scripts/rev-harness-mcp-wire.sh) return 0 ;;
    scripts/rev-harness-repair.sh|*/scripts/rev-harness-repair.sh) return 0 ;;
    scripts/audit-adopter-0.0.24.sh|*/scripts/audit-adopter-0.0.24.sh) return 0 ;;
    scripts/harness-governance-classifier.sh|*/scripts/harness-governance-classifier.sh) return 0 ;;
    scripts/launch-semantic-mcp.sh|*/scripts/launch-semantic-mcp.sh) return 0 ;;
    harness-rust/*|*/harness-rust/*) return 0 ;;
  esac
  return 1
}

rel_path() {
  local path="$1"
  case "$path" in
    "$HARNESS_ROOT"/*) printf '%s' "${path#"$HARNESS_ROOT"/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

scan_match_for_forbidden_patterns() {
  local file="$1" line_no="$2" line="$3" rel token
  rel="$(rel_path "$file")"
  if is_allowlisted "$rel" "$line"; then
    return 0
  fi
  if printf '%s\n' "$line" | grep -Eq '"semantic"[[:space:]]*:[[:space:]]*\{'; then
    record_finding "forbidden-pattern:P1" "$rel" "$line_no" 'no legacy "semantic" MCP server key' "$line"
  fi
  if printf '%s\n' "$line" | grep -Fq 'SEMANTIC_MCP_PROJECT_ID'; then # rev-harness-i13: allow
    record_finding "forbidden-pattern:P3" "$rel" "$line_no" "no SEMANTIC_MCP_PROJECT_ID env entry" "$line" # rev-harness-i13: allow
  fi
  printf '%s\n' "$line" | grep -oE '[A-Za-z0-9_.$~/-]*launch-semantic-mcp[.]sh' | while IFS= read -r token; do # rev-harness-i13: allow
    case "$token" in
      /*) ;;
      *) record_finding "forbidden-pattern:P2" "$rel" "$line_no" "absolute path to launch-semantic-mcp.sh" "$token" ;; # rev-harness-i13: allow
    esac
  done || true
}

scan_tree_for_forbidden_patterns() {
  local root="$1" match file rest line_no line
  local forbidden_regex='"semantic"[[:space:]]*:[[:space:]]*\{|SEMANTIC_MCP_PROJECT_ID|launch-semantic-mcp[.]sh' # rev-harness-i13: allow
  [[ -d "$root" ]] || return 0
  find "$root" \
    \( -path "$root/.git" -o -path "$root/.git/*" \
       -o -path "$root/harness-rust/target" -o -path "$root/harness-rust/target/*" \
       -o -path "$root/.agent/active" -o -path "$root/.agent/active/*" \
       -o -path "$root/.agent/archive" -o -path "$root/.agent/archive/*" \
       -o -path "$root/.claude/tmp" -o -path "$root/.claude/tmp/*" \
       -o -path "$root/.codex/sessions" -o -path "$root/.codex/sessions/*" \
       -o -path "$root/.claude/projects" -o -path "$root/.claude/projects/*" \
       -o -path "$root/test" -o -path "$root/test/*" \
       -o -path "$root/migrations" -o -path "$root/migrations/*" \) -prune \
    -o -type f -print0 \
    | xargs -0 grep -InE "$forbidden_regex" 2>/dev/null \
    | while IFS= read -r match; do # rev-harness-i13: allow
      file="${match%%:*}"
      rest="${match#*:}"
      line_no="${rest%%:*}"
      line="${rest#*:}"
      scan_match_for_forbidden_patterns "$file" "$line_no" "$line"
    done || true
}

canonical="$(canonical_entry)"
if [[ "$quick" != "1" ]]; then
  check_init_negative
  run_emitter_capture "$canonical" "scripts/install-rev-harness-mcp.sh" "$tmp_root/install-mcp.fixture.json" --self-test
  run_emitter_capture "$canonical" "scripts/rev-harness-mcp-wire.sh" "$tmp_root/wire.fixture.json" --self-test
fi
compare_harness_self_json_file "harness-self-claude" "$HARNESS_ROOT/.claude/settings.json" "$canonical"
compare_codex_toml "$HARNESS_ROOT/.codex/config.toml" "$canonical"
if [[ -n "$adopter_path" ]]; then
  adopter_path="$(cd "$adopter_path" && pwd -P)"
  compare_json_mcp_file "adopter-.mcp.json" "$adopter_path/.mcp.json" "$canonical"
  compare_json_mcp_file "adopter-claude-settings" "$adopter_path/.claude/settings.json" "$canonical"
fi
scan_tree_for_forbidden_patterns "$HARNESS_ROOT"

jq -s '.' "$findings_file"

finding_count="$(wc -l < "$findings_file" | tr -d ' ')"
if [[ "$finding_count" -gt 0 ]]; then
  if [[ "$strict" == "1" ]]; then
    while IFS= read -r finding; do
      error_line "$(printf '%s\n' "$finding" | jq -r '"\(.emitter_id): \(.file):\(.line): expected \(.expected_fragment), actual \(.actual_fragment)"')"
    done < "$findings_file"
    exit 1
  fi
  while IFS= read -r finding; do
    warn_line "$(printf '%s\n' "$finding" | jq -r '"\(.emitter_id): \(.file):\(.line): expected \(.expected_fragment), actual \(.actual_fragment). Run bash scripts/audit-adopter-0.0.24.sh to inventory drift."')"
  done < "$findings_file"
fi

exit 0
