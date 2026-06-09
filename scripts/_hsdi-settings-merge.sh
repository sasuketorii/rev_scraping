#!/usr/bin/env bash
set -euo pipefail

SCHEMA_ID="rev-harness-hsdi-wire/v1"
EVENT_LOG="${HSDI_WIRE_EVENT_LOG:-.agent/metrics/hsdi_wire_events.jsonl}"
IDS_JSON='["hsdi-snapshot-pre","hsdi-snapshot-post","hsdi-path-leak-advise","hsdi-snapshot-stop"]'

usage() {
  cat >&2 <<'USAGE'
usage: scripts/_hsdi-settings-merge.sh <merge|verify|rollback> --config <path>
       --harness-root <path> [--run-id <id>] [--dry-run] [--force-wire]
USAGE
}

diag() { printf '[hsdi-settings-merge] %s\n' "$1" >&2; }
redact_path() { local v="${1:-}"; printf '%s' "${v/#${HOME}/\~}"; }
now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
require_jq() { command -v jq >/dev/null 2>&1 || { diag "error: jq is required"; exit 2; }; }
rm_if_exists() { [[ ! -e "$1" ]] || /bin/rm -f "$1"; }
sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else diag "error: sha256 tool missing"; exit 2
  fi
}
sha256_file() { [[ -e "$1" ]] && sha256_stdin < "$1" || printf ''; }

emit_event() {
  local action="$1" status="$2" config="$3" bak="$4" before="$5" after="$6" run_id="$7"
  mkdir -p "$(dirname "$EVENT_LOG")"
  jq -cn --arg ts "$(now_utc)" --arg schema_id "$SCHEMA_ID" --arg event "hsdi_wire" \
    --arg action "$action" --arg status "$status" --arg config_path "$(redact_path "$config")" \
    --arg bak_path "$(redact_path "$bak")" --arg sha256_before "$before" \
    --arg sha256_after "$after" --arg run_id "$run_id" \
    '{ts:$ts,schema_id:$schema_id,event:$event,action:$action,status:$status,config_path:$config_path,bak_path:$bak_path,sha256_before:$sha256_before,sha256_after:$sha256_after,run_id:$run_id}' >> "$EVENT_LOG"
}

validate_config() {
  [[ -f "$1" ]] || { diag "error: config missing: $(redact_path "$1")"; return 2; }
  jq -e . "$1" >/dev/null 2>&1 || { diag "error: invalid JSON: $(redact_path "$1")"; return 2; }
}

managed_hooks() {
  jq -cn --arg root "$1" --argjson ids "$IDS_JSON" \
    '{PreToolUse:[{matcher:"Edit|Write|MultiEdit|NotebookEdit",hooks:[{command:($root + "/.claude/hooks/snapshot-pre.sh")}]}],
      PostToolUse:[{matcher:"Edit|Write|MultiEdit|NotebookEdit",hooks:[{command:($root + "/.claude/hooks/snapshot-post.sh")},{command:($root + "/.claude/hooks/path-leak-advise.sh")}]}],
      Stop:[{hooks:[{command:($root + "/.claude/hooks/snapshot-stop.sh")}]}],
      _managed_ids:$ids}'
}

has_all_ids() {
  jq -e --argjson ids "$IDS_JSON" '(.hooks._managed_ids // []) as $have | all($ids[]; $have | index(.))' "$1" >/dev/null
}

merge_json() {
  local managed
  managed="$(managed_hooks "$3")"
  jq --argjson managed "$managed" '
    def commands($entries): [$entries[]?.hooks[]?.command];
    def prune($entry; $seen):
      ($entry.hooks // []) as $hooks
      | ($hooks | map(select(.command as $cmd | ($seen | index($cmd) | not)))) as $new
      | if ($new | length) > 0 then $entry + {hooks:$new} else empty end;
    def merge_entries($current; $incoming):
      ($current // []) as $cur | commands($cur) as $seen | $cur + ($incoming | map(prune(.; $seen)));
    .hooks = (.hooks // {})
    | .hooks.PreToolUse = merge_entries(.hooks.PreToolUse; $managed.PreToolUse)
    | .hooks.PostToolUse = merge_entries(.hooks.PostToolUse; $managed.PostToolUse)
    | .hooks.Stop = merge_entries(.hooks.Stop; $managed.Stop)
    | .hooks._managed_ids = (((.hooks._managed_ids // []) + $managed._managed_ids) | unique)
  ' "$1" > "$2"
}

verify_commands() {
  jq -e --arg root "$2" '
    [($root + "/.claude/hooks/snapshot-pre.sh"),($root + "/.claude/hooks/snapshot-post.sh"),
     ($root + "/.claude/hooks/path-leak-advise.sh"),($root + "/.claude/hooks/snapshot-stop.sh")] as $need
    | [.hooks.PreToolUse[]?.hooks[]?.command,.hooks.PostToolUse[]?.hooks[]?.command,.hooks.Stop[]?.hooks[]?.command] as $have
    | all($need[]; . as $cmd | $have | index($cmd))
  ' "$1" >/dev/null
}

do_merge() {
  local config="$1" root="$2" run_id="$3" dry_run="$4" force_wire="$5" before bak tmp current after
  if ! validate_config "$config"; then emit_event merge error "$config" "" "" "" "$run_id"; return 2; fi
  before="$(sha256_file "$config")"
  if [[ "$force_wire" != "1" ]] && has_all_ids "$config"; then emit_event merge noop "$config" "" "$before" "$before" "$run_id"; return 0; fi
  bak="${config}.bak.${run_id}"; tmp="${config}.tmp.${run_id}"
  if [[ "$dry_run" == "1" ]]; then emit_event merge ok "$config" "$bak" "$before" "$before" "$run_id"; return 0; fi
  cp "$config" "$bak"; rm_if_exists "$tmp"
  if ! merge_json "$bak" "$tmp" "$root"; then rm_if_exists "$tmp"; emit_event merge error "$config" "$bak" "$before" "$before" "$run_id"; return 2; fi
  current="$(sha256_file "$config")"
  if [[ "$current" != "$before" ]]; then rm_if_exists "$tmp"; cp "$bak" "$config"; emit_event merge conflict "$config" "$bak" "$before" "$current" "$run_id"; return 3; fi
  mv "$tmp" "$config"; after="$(sha256_file "$config")"
  emit_event merge ok "$config" "$bak" "$before" "$after" "$run_id"
}

do_verify() {
  local config="$1" root="$2" run_id="$3" before
  if ! validate_config "$config"; then emit_event verify error "$config" "" "" "" "$run_id"; return 2; fi
  before="$(sha256_file "$config")"
  if verify_commands "$config" "$root"; then emit_event verify ok "$config" "" "$before" "$before" "$run_id"; return 0; fi
  emit_event verify missing "$config" "" "$before" "$before" "$run_id"; return 1
}

do_rollback() {
  local config="$1" run_id="$2" dry_run="$3" bak="${config}.bak.${run_id}" tmp="${config}.tmp.${run_id}" before after
  [[ -f "$bak" ]] || { diag "error: backup missing: $(redact_path "$bak")"; emit_event rollback error "$config" "$bak" "$(sha256_file "$config")" "" "$run_id"; return 2; }
  before="$(sha256_file "$config")"
  if [[ "$dry_run" == "1" ]]; then emit_event rollback ok "$config" "$bak" "$before" "$before" "$run_id"; return 0; fi
  cp "$bak" "$tmp"; mv "$tmp" "$config"; after="$(sha256_file "$config")"
  emit_event rollback ok "$config" "$bak" "$before" "$after" "$run_id"
}

main() {
  require_jq
  local sub="${1:-}" config="" root="" run_id="" dry_run=0 force_wire=0
  [[ -n "$sub" ]] || { usage; return 2; }; shift || true
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --config) config="${2:-}"; shift 2 ;;
      --harness-root) root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --force-wire) force_wire=1; shift ;;
      *) diag "error: unknown argument: $1"; usage; return 2 ;;
    esac
  done
  [[ -n "$run_id" ]] || run_id="$(date -u +"%Y%m%dT%H%M%SZ")-$$"
  [[ -n "$config" ]] || { diag "error: --config is required"; return 2; }
  case "$sub" in merge|verify) [[ -n "$root" ]] || { diag "error: --harness-root is required"; return 2; } ;; esac
  case "$sub" in
    merge) do_merge "$config" "$root" "$run_id" "$dry_run" "$force_wire" ;;
    verify) do_verify "$config" "$root" "$run_id" ;;
    rollback) do_rollback "$config" "$run_id" "$dry_run" ;;
    *) diag "error: unknown subcommand: $sub"; usage; return 2 ;;
  esac
}
main "$@"
