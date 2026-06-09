#!/usr/bin/env bash
set -euo pipefail

SCHEMA_ID="rev-harness-mcp-settings-rewrite/v1"
EVENT_LOG=".agent/metrics/mcp_settings_rewrite_events.jsonl"
usage() { printf '%s\n' 'usage: scripts/install-rev-harness-mcp.sh [--settings <path>] [--harness-root <path>] [--run-id <id>] [--dry-run] [--verbose] [--self-test] [--output-fixture <path>]' >&2; }
diag() { printf '[mcp-settings-rewrite] %s\n' "$1" >&2; }
now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
redact_path() { local v="${1:-}"; printf '%s' "${v/#${HOME}/\~}"; }
require_jq() { command -v jq >/dev/null 2>&1 || { diag "error: jq is required"; exit 2; }; }
rm_if_exists() { [[ ! -e "$1" ]] || /bin/rm -f "$1"; }
abs_path() { local d b; d="$(dirname "$1")"; b="$(basename "$1")"; printf '%s/%s' "$(cd "$d" && pwd -P)" "$b"; }
abs_dir() { cd "$1" && pwd -P; }

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else diag "error: sha256 tool missing"; exit 2; fi
}

sha256_file() { [[ -e "$1" ]] || { printf ''; return 0; }; sha256_stdin < "$1"; }

write_output_fixture() {
  local harness="$1" output="$2" output_dir tmp launcher
  [[ -n "$output" ]] || { diag "error: --output-fixture requires a value"; return 2; }
  harness="$(abs_dir "$harness")"
  launcher="$harness/scripts/launch-semantic-mcp.sh"
  output_dir="$(dirname "$output")"
  [[ -d "$output_dir" ]] || { diag "error: output fixture directory missing: $(redact_path "$output_dir")"; return 2; }
  output="$(abs_path "$output")"
  output_dir="$(dirname "$output")"
  tmp="$(mktemp "$output_dir/.mcp-fixture.XXXXXX")" || { diag "error: failed to create output fixture temp file"; return 2; }
  if ! jq -cn --arg command "$launcher" \
    '{"mcpServers":{"semantic-mcp":{"command":$command,"args":[],"env":{}}}}' > "$tmp"; then
    rm_if_exists "$tmp"
    diag "error: failed to render output fixture"
    return 2
  fi
  mv "$tmp" "$output"
}

emit_event() {
  local action="$1" result="$2" settings="$3" bak="$4" before="$5" after="$6" run_id="$7" adopter_bak="$8"
  mkdir -p "$(dirname "$EVENT_LOG")"
  jq -cn --arg ts "$(now_utc)" --arg schema_id "$SCHEMA_ID" \
    --arg event "mcp_settings_rewrite" --arg action "$action" --arg result "$result" \
    --arg settings_path "$(redact_path "$settings")" --arg bak_path "$(redact_path "$bak")" \
    --arg adopter_script_bak "$(redact_path "$adopter_bak")" --arg sha256_before "$before" \
    --arg sha256_after "$after" --arg run_id "$run_id" \
    '{ts:$ts,schema_id:$schema_id,event:$event,action:$action,result:$result,settings_path:$settings_path,bak_path:$bak_path,adopter_script_bak:$adopter_script_bak,sha256_before:$sha256_before,sha256_after:$sha256_after,run_id:$run_id}' >> "$EVENT_LOG"
}

validate_settings() {
  [[ -f "$1" ]] || { diag "error: settings missing: $(redact_path "$1")"; return 2; }
  jq -e . "$1" >/dev/null 2>&1 || { diag "error: invalid JSON: $(redact_path "$1")"; return 2; }
}

rewrite_count() {
  jq --arg target "$2" '[.mcpServers? // {} | to_entries[]
    | select((.value.command? | type) == "string")
    | select(.value.command | test("(^|/)launch-semantic-mcp[.]sh$"))
    | select(.value.command != $target)] | length' "$1"
}

write_rewrite_tmp() {
  jq --arg target "$3" 'def r: if ((.command? | type) == "string") and
    (.command | test("(^|/)launch-semantic-mcp[.]sh$")) then .command = $target else . end;
    if (.mcpServers? | type) == "object"
    then .mcpServers |= with_entries(.value |= (if type == "object" then r else . end))
    else . end' "$1" > "$2"
}

cleanup_adopter_copy() {
  local adopter="$1" canonical="$2" run_id="$3" dry_run="$4" bak
  [[ -f "$adopter" ]] || { printf ''; return 0; }
  if [[ -e "$canonical" && "$(abs_path "$adopter")" == "$(abs_path "$canonical")" ]]; then printf ''; return 0; fi
  bak="${adopter}.bak.${run_id}"
  [[ "$dry_run" == "1" ]] || { cp "$adopter" "$bak"; /bin/rm -f "$adopter"; }
  printf '%s' "$bak"
}

do_install() {
  local settings="$1" harness="$2" run_id="$3" dry_run="$4" verbose="$5"
  validate_settings "$settings" || { emit_event rewrite error "$settings" "" "" "" "$run_id" ""; return 2; }
  settings="$(abs_path "$settings")"; harness="$(abs_dir "$harness")"
  local target="$harness/scripts/launch-semantic-mcp.sh" settings_dir adopter_root adopter_script
  local before count bak tmp live after adopter_bak
  settings_dir="$(dirname "$settings")"; adopter_root="$(cd "$settings_dir/.." && pwd -P)"
  adopter_script="$adopter_root/scripts/launch-semantic-mcp.sh"
  before="$(sha256_file "$settings")"; count="$(rewrite_count "$settings" "$target")"
  bak="${settings}.bak.${run_id}"; tmp="${settings}.tmp.${run_id}"
  if [[ "$count" == "0" && ! -f "$adopter_script" ]]; then
    emit_event rewrite ok "$settings" "" "$before" "$before" "$run_id" ""; return 0
  fi
  if [[ "$dry_run" == "1" ]]; then
    [[ "$verbose" == "1" ]] && diag "dry-run: would rewrite $count MCP command(s)"
    emit_event rewrite ok "$settings" "$bak" "$before" "$before" "$run_id" "$adopter_script"; return 0
  fi
  if [[ "$count" != "0" ]]; then
    cp "$settings" "$bak"; rm_if_exists "$tmp"; write_rewrite_tmp "$bak" "$tmp" "$target"
    live="$(sha256_file "$settings")"
    if [[ "$live" != "$before" ]]; then
      cp "$bak" "$settings"; rm_if_exists "$tmp"
      emit_event rewrite conflict "$settings" "$bak" "$before" "$(sha256_file "$settings")" "$run_id" ""; return 3
    fi
    mv "$tmp" "$settings"
  fi
  adopter_bak="$(cleanup_adopter_copy "$adopter_script" "$target" "$run_id" "$dry_run")"
  after="$(sha256_file "$settings")"
  emit_event rewrite ok "$settings" "$bak" "$before" "$after" "$run_id" "$adopter_bak"
}

self_test() {
  local root settings harness script
  root="$(mktemp -d)"; trap '[[ -z "${root:-}" ]] || /bin/rm -rf "$root"' RETURN
  settings="$root/adopter/.claude/settings.json"; harness="$root/harness"
  mkdir -p "$(dirname "$settings")" "$harness/scripts"
  harness="$(abs_dir "$harness")"
  jq -cn --arg command "$root/adopter/scripts/launch-semantic-mcp.sh" \
    '{"mcpServers":{"semantic-mcp":{"command":$command,"args":[],"env":{}}}}' > "$settings"
  script="$(abs_path "${BASH_SOURCE[0]}")"
  bash "$script" --settings "$settings" --harness-root "$harness" --run-id selftest >/dev/null
  jq -e --arg cmd "$harness/scripts/launch-semantic-mcp.sh" '
    .mcpServers["semantic-mcp"].command == $cmd
    and (.mcpServers["semantic-mcp"].args // []) == []
    and (.mcpServers["semantic-mcp"].env // {}) == {}
  ' "$settings" >/dev/null
  printf 'PASS: mcp_settings_rewrite::self_test\n'
}

main() {
  require_jq
  local settings="${PWD}/.claude/settings.json" harness="" run_id="" dry_run=0 verbose=0 self_test_mode=0 output_fixture=""
  while [[ "$#" -gt 0 ]]; do case "$1" in
    --settings) [[ "$#" -ge 2 ]] || { diag "error: --settings requires a value"; return 2; }; settings="${2:-}"; shift 2 ;;
    --harness-root) [[ "$#" -ge 2 ]] || { diag "error: --harness-root requires a value"; return 2; }; harness="${2:-}"; shift 2 ;;
    --run-id) [[ "$#" -ge 2 ]] || { diag "error: --run-id requires a value"; return 2; }; run_id="${2:-}"; shift 2 ;;
    --output-fixture) [[ "$#" -ge 2 ]] || { diag "error: --output-fixture requires a value"; return 2; }; output_fixture="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --verbose) verbose=1; shift ;; --self-test) self_test_mode=1; shift ;;
    -h|--help) usage; return 0 ;; *) diag "error: unknown argument: $1"; usage; return 2 ;;
  esac; done
  [[ -n "$run_id" ]] || run_id="$(date -u +"%Y%m%dT%H%M%SZ")-$$"
  [[ -n "$harness" ]] || harness="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  if [[ -n "$output_fixture" ]]; then
    write_output_fixture "$harness" "$output_fixture"
    return $?
  fi
  if [[ "$self_test_mode" == "1" ]]; then
    self_test
    return 0
  fi
  do_install "$settings" "$harness" "$run_id" "$dry_run" "$verbose"
}

main "$@"
