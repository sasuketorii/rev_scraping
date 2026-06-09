#!/usr/bin/env bash
set -euo pipefail

SCHEMA_ID="rev-harness-mcp-wire/v1"
EVENT_LOG=".agent/metrics/mcp_wire_events.jsonl"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/rev-harness-mcp-wire.sh <merge|rollback|verify> [--config <path>]
       [--force-wire] [--run-id <id>] [--dry-run] [--json] [--verbose] [--self-test]
       [--output-fixture <path>]
USAGE
}

redact_path() { local value="${1:-}"; printf '%s' "${value/#${HOME}/\~}"; }
diag() { printf '[mcp-wire] %s\n' "$1" >&2; }
now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    diag "error: sha256 tool missing"
    exit 2
  fi
}

sha256_file() {
  local path="$1"
  [[ -e "$path" ]] || { printf ''; return 0; }
  sha256_stdin < "$path"
}

rm_if_exists() { [[ ! -e "$1" ]] || /bin/rm -f "$1"; }
require_jq() { command -v jq >/dev/null 2>&1 || { diag "error: jq is required"; exit 2; }; }
managed_entry() { jq -cn --arg command "$HARNESS_ROOT/scripts/launch-semantic-mcp.sh" '{"command":$command,"args":[],"env":{}}'; }
entry_sha() { jq -cS . | sha256_stdin; }

abs_path() {
  local dir base
  dir="$(dirname "$1")"
  base="$(basename "$1")"
  printf '%s/%s' "$(cd "$dir" && pwd -P)" "$base"
}

write_output_fixture() {
  local output="$1" output_dir tmp managed
  [[ -n "$output" ]] || { diag "error: --output-fixture requires a value"; return 2; }
  output_dir="$(dirname "$output")"
  [[ -d "$output_dir" ]] || { diag "error: output fixture directory missing: $(redact_path "$output_dir")"; return 2; }
  output="$(abs_path "$output")"
  output_dir="$(dirname "$output")"
  tmp="$(mktemp "$output_dir/.mcp-fixture.XXXXXX")" || { diag "error: failed to create output fixture temp file"; return 2; }
  managed="$(managed_entry)"
  if ! jq -cn --argjson managed "$managed" '{"mcpServers":{"semantic-mcp":$managed}}' > "$tmp"; then
    rm_if_exists "$tmp"
    diag "error: failed to render output fixture"
    return 2
  fi
  mv "$tmp" "$output"
}

emit_event() {
  local action="$1" result="$2" config_path="$3" bak_path="$4" before="$5" after="$6" run_id="$7"
  mkdir -p "$(dirname "$EVENT_LOG")"
  local safe_config safe_bak
  safe_config="$(redact_path "$config_path")"
  safe_bak="$(redact_path "$bak_path")"
  jq -cn \
    --arg ts "$(now_utc)" \
    --arg schema_id "$SCHEMA_ID" \
    --arg event "mcp_wire" \
    --arg action "$action" \
    --arg result "$result" \
    --arg config_path "$safe_config" \
    --arg bak_path "$safe_bak" \
    --arg sha256_before "$before" \
    --arg sha256_after "$after" \
    --arg run_id "$run_id" \
    '{ts:$ts,schema_id:$schema_id,event:$event,action:$action,result:$result,config_path:$config_path,bak_path:$bak_path,sha256_before:$sha256_before,sha256_after:$sha256_after,run_id:$run_id}' >> "$EVENT_LOG"
}

validate_config() {
  local config="$1"
  if [[ ! -f "$config" ]]; then
    diag "error: config missing: $(redact_path "$config")"
    return 2
  fi
  if ! jq -e . "$config" >/dev/null 2>&1; then
    diag "error: config is not valid JSON: $(redact_path "$config")"
    return 2
  fi
}

current_entry() { jq -cS '.mcpServers["semantic-mcp"] // empty' "$1"; }

atomic_write_merge() {
  local config="$1" tmp="$2"
  local managed
  managed="$(managed_entry)"
  jq --argjson managed "$managed" \
    '.mcpServers = (.mcpServers // {}) | .mcpServers["semantic-mcp"] = $managed' \
    "$config" > "$tmp"
  mv "$tmp" "$config"
}

do_merge() {
  local config="$1" run_id="$2" force_wire="$3" dry_run="$4" verbose="$5"
  validate_config "$config" || {
    emit_event merge error "$config" "" "" "" "$run_id"
    return 2
  }

  local before managed_hash existing existing_hash bak tmp after
  before="$(sha256_file "$config")"
  managed_hash="$(managed_entry | entry_sha)"
  existing="$(current_entry "$config")"

  if [[ -n "$existing" ]]; then
    existing_hash="$(printf '%s' "$existing" | entry_sha)"
    if [[ "$existing_hash" == "$managed_hash" ]]; then
      emit_event merge ok "$config" "" "$before" "$before" "$run_id"
      return 0
    fi
    if [[ "$force_wire" != "1" ]]; then
      diag "conflict: existing semantic-mcp entry differs in $(redact_path "$config"); use --force-wire to override"
      emit_event merge conflict "$config" "" "$before" "$before" "$run_id"
      return 3
    fi
  fi

  bak="${config}.bak.${run_id}"
  tmp="${config}.tmp.${run_id}"
  if [[ "$dry_run" == "1" ]]; then
    [[ "$verbose" == "1" ]] && diag "dry-run: would update $(redact_path "$config")"
    emit_event merge ok "$config" "$bak" "$before" "$before" "$run_id"
    return 0
  fi

  cp "$config" "$bak"
  rm_if_exists "$tmp"
  if ! atomic_write_merge "$config" "$tmp"; then
    rm_if_exists "$tmp"
    emit_event merge error "$config" "$bak" "$before" "$before" "$run_id"
    return 2
  fi
  after="$(sha256_file "$config")"
  emit_event merge ok "$config" "$bak" "$before" "$after" "$run_id"
}

do_verify() {
  local config="$1" run_id="$2"
  validate_config "$config" || {
    emit_event verify error "$config" "" "" "" "$run_id"
    return 2
  }

  local before managed_hash existing existing_hash
  before="$(sha256_file "$config")"
  managed_hash="$(managed_entry | entry_sha)"
  existing="$(current_entry "$config")"
  if [[ -z "$existing" ]]; then
    diag "absent: semantic-mcp entry missing in $(redact_path "$config")"
    emit_event verify error "$config" "" "$before" "$before" "$run_id"
    return 1
  fi
  existing_hash="$(printf '%s' "$existing" | entry_sha)"
  if [[ "$existing_hash" != "$managed_hash" ]]; then
    diag "drift: semantic-mcp entry differs in $(redact_path "$config")"
    emit_event verify conflict "$config" "" "$before" "$before" "$run_id"
    return 3
  fi
  emit_event verify ok "$config" "" "$before" "$before" "$run_id"
}

do_rollback() {
  local config="$1" run_id="$2" dry_run="$3"
  local bak="${config}.bak.${run_id}" tmp="${config}.tmp.${run_id}" before after
  if [[ ! -f "$bak" ]]; then
    diag "error: backup missing: $(redact_path "$bak")"
    emit_event rollback error "$config" "$bak" "$(sha256_file "$config")" "" "$run_id"
    return 2
  fi
  before="$(sha256_file "$config")"
  if [[ "$dry_run" == "1" ]]; then
    emit_event rollback ok "$config" "$bak" "$before" "$before" "$run_id"
    return 0
  fi
  cp "$bak" "$tmp"
  mv "$tmp" "$config"
  after="$(sha256_file "$config")"
  emit_event rollback ok "$config" "$bak" "$before" "$after" "$run_id"
}

self_test() {
  require_jq
  local root config run_id script_path launcher
  root="$(mktemp -d)"
  run_id="selftest"
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  (
    cd "$root"
    mkdir -p home/.config
    export HOME="$root/home"
    config="$HOME/.config/mcp.json"
    launcher="$HARNESS_ROOT/scripts/launch-semantic-mcp.sh"
    printf '{}\n' > "$config"
    bash "$script_path" merge --config "$config" --run-id "$run_id" >/dev/null
    jq -e --arg command "$launcher" '.mcpServers["semantic-mcp"].command == $command' "$config" >/dev/null
    bash "$script_path" rollback --config "$config" --run-id "$run_id" >/dev/null
    jq -e '. == {}' "$config" >/dev/null
  )
  /bin/rm -rf "$root"
  printf 'PASS: mcp_wire::self_test\n'
}

main() {
  require_jq
  local self_test_mode=0 output_fixture="" args=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --self-test)
        self_test_mode=1
        shift
        ;;
      --output-fixture)
        [[ "$#" -ge 2 ]] || { diag "error: --output-fixture requires a value"; return 2; }
        output_fixture="$2"
        shift 2
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  if [[ -n "$output_fixture" ]]; then
    write_output_fixture "$output_fixture"
    return $?
  fi
  if [[ "$self_test_mode" == "1" ]]; then
    self_test
    return 0
  fi

  set -- "${args[@]}"
  local subcommand="${1:-}" config="" run_id="" force_wire=0 dry_run=0 verbose=0 json=0
  if [[ -z "$subcommand" ]]; then
    usage
    return 2
  fi
  shift || true

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --config) config="${2:-}"; shift 2 ;;
      --force-wire) force_wire=1; shift ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --json) json=1; shift ;;
      --verbose) verbose=1; shift ;;
      *)
        if [[ "$subcommand" == "rollback" && -z "$run_id" ]]; then
          run_id="$1"
          shift
        else
          diag "error: unknown argument: $1"
          usage
          return 2
        fi
        ;;
    esac
  done
  : "$json"

  if [[ -z "$run_id" ]]; then
    run_id="$(date -u +"%Y%m%dT%H%M%SZ")-$$"
  fi
  if [[ -z "$config" ]]; then
    diag "error: --config is required"
    return 2
  fi

  case "$subcommand" in
    merge) do_merge "$config" "$run_id" "$force_wire" "$dry_run" "$verbose" ;;
    verify) do_verify "$config" "$run_id" ;;
    rollback) do_rollback "$config" "$run_id" "$dry_run" ;;
    *) diag "error: unknown subcommand: $subcommand"; usage; return 2 ;;
  esac
}

main "$@"
