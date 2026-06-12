#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=scripts/_canonical-guard.sh
source "$SCRIPT_DIR/_canonical-guard.sh"
rev_harness_assert_canonical_root rev-harness-adopter-setup

TARGET_ARG=""
TARGET_ROOT=""
PROJECT_ROOT=""
STATE_FILE=""
PATHS_FILE=""
LEGACY_SHARED_STATE=""
LEGACY_REGISTRY_STATE=""
SNAPSHOT_ROOT=""
SCHEMA="rev-harness-state/v1"
PATHS_SCHEMA="rev-harness-paths/v1"
REPORT_SCHEMA="rev-harness-adopter-setup-report/v1"
# `semantic_node` is retained as the stable legacy state key/exit-code slot.
# The command it runs is now Rust-only semantic-bootstrap.sh, and it is
# executed only when the semantic addon is explicitly enabled.
CORE_PHASES="init hooks doctor"
SEMANTIC_ADDON_PHASES="init semantic_node semantic_rust hooks doctor"

DRY_RUN=false
JSON_OUTPUT=false
VERBOSE=false
STRICT=false
RESUME=false
ROLLBACK=""
SUBCOMMAND=""
RUN_ID=""
EXIT_CODE=0
WITH_MCP_WIRE=false
WITH_SEMANTIC_ADDON=false
export REVHARNESS_PARALLEL_QUIESCE="${REVHARNESS_PARALLEL_QUIESCE:-1}"
[[ "${REV_HARNESS_WITH_MCP_WIRE:-0}" == "1" ]] && WITH_MCP_WIRE=true
[[ "${REVHARNESS_ENABLE_SEMANTIC_ADDON:-0}" == "1" ]] && WITH_SEMANTIC_ADDON=true

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-adopter-setup.sh <subcommand> [options]

Subcommands:
  init      Run init phase only (.shared/project_id creation)
  setup     Run core phases: init -> hooks -> doctor
  verify    Run harness-doctor only
  resume    Resume from the first failed or pending phase
  status    Display .shared/rev-harness-adopter-setup.state.json

Options:
  --dry-run             Log planned phase events; do not write state or run phases
  --json                Print final machine-readable report
  --verbose             Print phase commands to stderr
  --strict              Run doctor in strict mode
  --target <path>       Install into the adopter project at <path>
  --with-semantic-addon Run semantic_node and semantic_rust addon phases
  --with-mcp-wire       Enable semantic addon and merge semantic-mcp into <target>/.mcp.json after setup
  --resume              Resume within setup/init/verify
  --rollback <step>|all Restore owner-token files from a pre-step snapshot
  --help, -h            Show this help

Exit codes:
  0 success
  2 prerequisite missing or CLI misuse
  10 phase_init failed
  11 phase_semantic_node failed (only when semantic addon was explicitly enabled)
  12 phase_semantic_rust failed (only when semantic addon was explicitly enabled)
  13 phase_hooks failed
  14 phase_doctor failed
  15 state.json corruption
  16 resume requested but no state.json
  70 vendoring detected by canonical guard
  71 lease timeout
  72 self-install refused
EOF
}

log() { [[ "$JSON_OUTPUT" == true ]] || printf '[rev-harness-adopter-setup] %s\n' "$*" >&2; }
vlog() { [[ "$VERBOSE" == true ]] && printf '[rev-harness-adopter-setup] %s\n' "$*" >&2 || true; }

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
new_run_id() { date -u +"%Y%m%dT%H%M%SZ"; }

phase_exit_code() {
  case "$1" in
    init) printf '10' ;;
    semantic_node) printf '11' ;;
    semantic_rust) printf '12' ;;
    hooks) printf '13' ;;
    doctor) printf '14' ;;
    *) printf '2' ;;
  esac
}

hash_file() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    printf 'MISSING'
  elif [[ ! -f "$path" ]]; then
    printf 'NONREGULAR'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

phase_owner_paths() {
  case "$1" in
    init) printf '.gitignore\n.shared/project_id\n' ;;
    hooks) printf '.claude/settings.local.json\n.git/hooks/pre-commit\n' ;;
    *) return 0 ;;
  esac
}

phase_input_sha() {
  local phase="$1" rel data=""
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    data="${data}$(hash_file "$PROJECT_ROOT/$rel")  $rel"$'\n'
  done <<EOF
$(phase_owner_paths "$phase")
EOF
  [[ -n "$data" ]] || data="NONE  $phase"
  printf '%s' "$data" | shasum -a 256 | awk '{print $1}'
}

event() {
  local event_name="$1" phase="$2" status="$3" code="${4:-0}" input="${5:-}"
  printf '{"schema":"adopter_setup/v1","event":"%s","run_id":"%s","phase":"%s","status":"%s","exit_code":%s,"input_sha256":"%s","ts":"%s"}\n' \
    "$(json_escape "$event_name")" "$(json_escape "$RUN_ID")" "$(json_escape "$phase")" \
    "$(json_escape "$status")" "$code" "$(json_escape "$input")" "$(now_iso)"
}

require_tools() {
  local missing=""
  for tool in git jq awk shasum; do
    command -v "$tool" >/dev/null 2>&1 || missing="${missing} ${tool}"
  done
  [[ -z "$missing" ]] || { printf 'rev-harness-adopter-setup: missing required tools:%s\n' "$missing" >&2; exit 2; }
}

resolve_setup_roots() {
  TARGET_ROOT="$(resolve_target_root "$TARGET_ARG")" || exit $?
  PROJECT_ROOT="$TARGET_ROOT"
  STATE_FILE="$TARGET_ROOT/.rev-harness-state/state.json"
  PATHS_FILE="$TARGET_ROOT/.rev-harness-state/paths.json"
  LEGACY_SHARED_STATE="$TARGET_ROOT/.shared/rev-harness-adopter-setup.state.json"
  LEGACY_REGISTRY_STATE="$TARGET_ROOT/.agent/registry/rev_harness_adoption_state.json"
  SNAPSHOT_ROOT="$TARGET_ROOT/.rev-harness-state/snapshots"
  export PROJECT_ROOT
}

initial_state_json() {
  local ts="$1"
  jq -nc --arg schema "$SCHEMA" --arg run_id "$RUN_ID" --arg ts "$ts" --argjson semantic_enabled "$WITH_SEMANTIC_ADDON" '
    {
      schema: $schema,
      run_id: $run_id,
      semantic_addon_enabled: $semantic_enabled,
      phase: "init",
      current_phase: "init",
      phases: {
        init: {status:"pending", exit_code:0, started_at:null, ended_at:null, input_sha256:null},
        semantic_node: {status:(if $semantic_enabled then "pending" else "skipped" end), exit_code:0, started_at:null, ended_at:null, input_sha256:null},
        semantic_rust: {status:(if $semantic_enabled then "pending" else "skipped" end), exit_code:0, started_at:null, ended_at:null, input_sha256:null},
        hooks: {status:"pending", exit_code:0, started_at:null, ended_at:null, input_sha256:null},
        doctor: {status:"pending", exit_code:0, started_at:null, ended_at:null, input_sha256:null}
      },
      history: [],
      last_install_at: null,
      started_at: $ts,
      last_updated: $ts
    }'
}

canonicalize_state_json() {
  local json="$1" ts
  ts="$(now_iso)"
  jq -c --arg schema "$SCHEMA" --arg run_id "$RUN_ID" --arg ts "$ts" '
    .schema = $schema
    | .run_id = (.run_id // $run_id)
    | .semantic_addon_enabled = (.semantic_addon_enabled // false)
    | .phase = (.phase // .current_phase // "init")
    | .current_phase = .phase
    | .phases = (.phases // {})
    | .history = (if (.history // []) | type == "array" then (.history // [])[-50:] else [] end)
    | .last_install_at = (.last_install_at // null)
    | .started_at = (.started_at // $ts)
    | .last_updated = (.last_updated // $ts)' <<<"$json"
}

replace_with_relative_symlink() {
  local path="$1" target="$2" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$path.$$.$RANDOM.tmp"
  /bin/rm -f "$tmp"
  ln -s "$target" "$tmp"
  mv -f "$tmp" "$path"
}

ensure_state_legacy_symlinks() {
  replace_with_relative_symlink "$LEGACY_SHARED_STATE" "../.rev-harness-state/state.json"
  replace_with_relative_symlink "$LEGACY_REGISTRY_STATE" "../../.rev-harness-state/state.json"
}

write_state_json() {
  local json="$1" tmp
  mkdir -p "$(dirname "$STATE_FILE")"
  json="$(canonicalize_state_json "$json")"
  tmp="$STATE_FILE.$$.$RANDOM.tmp"
  printf '%s\n' "$json" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  ensure_state_legacy_symlinks
}

migrate_legacy_state_json() {
  local legacy="" json
  [[ ! -f "$STATE_FILE" ]] || return 0
  if [[ -f "$LEGACY_SHARED_STATE" && ! -L "$LEGACY_SHARED_STATE" ]]; then
    legacy="$LEGACY_SHARED_STATE"
  elif [[ -f "$LEGACY_REGISTRY_STATE" && ! -L "$LEGACY_REGISTRY_STATE" ]]; then
    legacy="$LEGACY_REGISTRY_STATE"
  fi
  [[ -n "$legacy" ]] || return 0
  jq empty "$legacy" >/dev/null 2>&1 || exit 15
  json="$(cat "$legacy")"
  RUN_ID="$(jq -r '.run_id // empty' "$legacy")"
  [[ -n "$RUN_ID" ]] || RUN_ID="$(new_run_id)"
  write_state_json "$json"
}

load_state_json() {
  migrate_legacy_state_json
  if [[ ! -f "$STATE_FILE" ]]; then
    [[ "$RESUME" == true ]] && exit 16
    RUN_ID="$(new_run_id)"
    initial_state_json "$(now_iso)"
    return 0
  fi
  jq -e --arg schema "$SCHEMA" '.schema == $schema and (.phases | type == "object") and .phase == .current_phase' "$STATE_FILE" >/dev/null 2>&1 || exit 15
  RUN_ID="$(jq -r '.run_id' "$STATE_FILE")"
  cat "$STATE_FILE"
}

state_update_phase() {
  local state="$1" phase="$2" status="$3" code="$4" input="${5:-}" ts
  ts="$(now_iso)"
  jq -c --arg p "$phase" --arg s "$status" --arg ts "$ts" --arg input "$input" --argjson code "$code" '
    .phase = (if $s == "ok" and $p == "doctor" then "done" else $p end)
    | .current_phase = .phase
    | .last_updated = $ts
    | .phases[$p].status = $s
    | .phases[$p].exit_code = $code
    | .phases[$p].input_sha256 = (if $input == "" then .phases[$p].input_sha256 else $input end)
    | if $s == "running" then .phases[$p].started_at = $ts else .phases[$p].ended_at = $ts end' <<<"$state"
}

project_id_value() {
  local file="$PROJECT_ROOT/.shared/project_id"
  [[ -f "$file" && ! -L "$file" ]] && sed -n '1p' "$file" || true
}

rust_db_path_for_project() {
  local project_id="$1" data_home
  case "$(uname -s)" in
    Darwin)
      printf '%s/Library/Application Support/Revharness/semantic-mcp/v1/%s/semantic.db' "$HOME" "$project_id"
      ;;
    Linux)
      data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
      printf '%s/Revharness/semantic-mcp/v1/%s/semantic.db' "$data_home" "$project_id"
      ;;
    *)
      data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
      printf '%s/Revharness/semantic-mcp/v1/%s/semantic.db' "$data_home" "$project_id"
      ;;
  esac
}

emit_paths_manifest() {
  local project_id semantic_db rust_db tmp
  [[ "$WITH_SEMANTIC_ADDON" == true ]] || return 0
  project_id="$(project_id_value)"
  [[ -n "$project_id" ]] || return 0
  rust_db="$(rust_db_path_for_project "$project_id")"
  semantic_db="$rust_db"
  mkdir -p "$(dirname "$PATHS_FILE")"
  tmp="$PATHS_FILE.$$.$RANDOM.tmp"
  jq -nc \
    --arg schema "$PATHS_SCHEMA" \
    --arg project_id "$project_id" \
    --arg semantic_db "$semantic_db" \
    --arg rust_db "$rust_db" \
    '{
      schema: $schema,
      project_id: $project_id,
      backend: "rust",
      semantic_db: $semantic_db,
      rust_db: $rust_db,
      separation_rationale: "Rust semantic-mcp is the only supported semantic backend; legacy Node semantic DB paths are not used.",
      platform_notes: "macOS = ~/Library/Application Support, Linux = ~/.local/share"
    }' > "$tmp"
  mv "$tmp" "$PATHS_FILE"
}

snapshot_phase() {
  local phase="$1" rel dest backup safe owners
  [[ "$DRY_RUN" == false ]] || return 0
  [[ "$phase" != "doctor" ]] || return 0
  owners="$(phase_owner_paths "$phase" || true)"
  [[ -n "$owners" ]] || return 0
  mkdir -p "$SNAPSHOT_ROOT/$RUN_ID/files/$phase"
  dest="$SNAPSHOT_ROOT/$RUN_ID/pre-$phase.sha256"
  : > "$dest"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    safe="${rel//\//__}"
    backup="MISSING"
    if [[ -f "$PROJECT_ROOT/$rel" && ! -L "$PROJECT_ROOT/$rel" ]]; then
      backup="$SNAPSHOT_ROOT/$RUN_ID/files/$phase/$safe"
      cp "$PROJECT_ROOT/$rel" "$backup"
    fi
    printf '%s  %s  %s\n' "$(hash_file "$PROJECT_ROOT/$rel")" "$rel" "$backup" >> "$dest"
  done <<EOF
$(phase_owner_paths "$phase")
EOF
}

rollback_phase() {
  local phase="$1" manifest hash rel backup current state owners
  manifest="$SNAPSHOT_ROOT/$RUN_ID/pre-$phase.sha256"
  owners="$(phase_owner_paths "$phase" || true)"
  if [[ ! -f "$manifest" ]]; then
    if [[ -n "$owners" ]]; then
      printf 'rollback snapshot not found: %s\n' "$manifest" >&2
      exit 15
    fi
    state="$(load_state_json)"
    state="$(jq -c --arg p "$phase" --arg ts "$(now_iso)" '
      .phase = $p
      | .current_phase = .phase
      | .last_updated = $ts
      | .phases[$p] = {status:"pending", exit_code:0, started_at:null, ended_at:null, input_sha256:null}' <<<"$state")"
    write_state_json "$state"
    return 0
  fi
  while IFS='  ' read -r hash rel backup; do
    [[ -n "$rel" ]] || continue
    current="$(hash_file "$PROJECT_ROOT/$rel")"
    if [[ "$hash" == "MISSING" ]]; then
      [[ ! -e "$PROJECT_ROOT/$rel" ]] || /bin/rm -f "$PROJECT_ROOT/$rel"
    else
      [[ -f "$backup" ]] || { printf 'rollback backup not found: %s\n' "$backup" >&2; exit 15; }
      mkdir -p "$(dirname "$PROJECT_ROOT/$rel")"
      cp "$backup" "$PROJECT_ROOT/$rel"
      [[ "$(hash_file "$PROJECT_ROOT/$rel")" == "$hash" ]] || exit 15
    fi
    vlog "rollback $phase: $rel $current -> $hash"
  done < "$manifest"
  state="$(load_state_json)"
  state="$(jq -c --arg p "$phase" --arg ts "$(now_iso)" '
    .phase = $p
    | .current_phase = .phase
    | .last_updated = $ts
    | .phases[$p] = {status:"pending", exit_code:0, started_at:null, ended_at:null, input_sha256:null}' <<<"$state")"
  write_state_json "$state"
}

run_phase_command() {
  local phase="$1"
  case "$phase" in
    init) (cd "$TARGET_ROOT" && PROJECT_ROOT="$TARGET_ROOT" HARNESS_ROOT="$HARNESS_ROOT" REVHARNESS_PARALLEL_QUIESCE=1 bash "$HARNESS_ROOT/scripts/init-project.sh" adopter) ;;
    semantic_node)
      if [[ "${REV_HARNESS_SMOKE_SKIP_HEAVY:-0}" == "1" ]]; then
        log "skip heavy phase semantic_node/Rust bootstrap (REV_HARNESS_SMOKE_SKIP_HEAVY=1)"
        return 0
      fi
      (cd "$TARGET_ROOT" && PROJECT_ROOT="$TARGET_ROOT" HARNESS_ROOT="$HARNESS_ROOT" REVHARNESS_PARALLEL_QUIESCE=1 bash "$HARNESS_ROOT/scripts/semantic-bootstrap.sh")
      ;;
    semantic_rust)
      if [[ "${REV_HARNESS_SMOKE_SKIP_HEAVY:-0}" == "1" ]]; then
        log "skip heavy phase semantic_rust (REV_HARNESS_SMOKE_SKIP_HEAVY=1)"
        return 0
      fi
      if [[ ! -d "$TARGET_ROOT/harness-rust" ]]; then
        log "skip phase semantic_rust: target has no harness-rust workspace"
        return 0
      fi
      (cd "$TARGET_ROOT/harness-rust" && PROJECT_ROOT="$TARGET_ROOT" HARNESS_ROOT="$HARNESS_ROOT" REVHARNESS_PARALLEL_QUIESCE=1 cargo build --release -p semantic-mcp)
      ;;
    hooks) (cd "$TARGET_ROOT" && PROJECT_ROOT="$TARGET_ROOT" HARNESS_ROOT="$HARNESS_ROOT" REVHARNESS_PARALLEL_QUIESCE=1 bash "$HARNESS_ROOT/scripts/install-rev-harness-hooks.sh" install --adopter-root "$TARGET_ROOT" --harness-root "$HARNESS_ROOT") ;;
    doctor)
      if [[ "$STRICT" == true ]]; then
        (cd "$TARGET_ROOT" && PROJECT_ROOT="$TARGET_ROOT" HARNESS_ROOT="$HARNESS_ROOT" REVHARNESS_PARALLEL_QUIESCE=1 bash "$HARNESS_ROOT/scripts/harness-doctor.sh" --quick --strict --json)
      else
        (cd "$TARGET_ROOT" && PROJECT_ROOT="$TARGET_ROOT" HARNESS_ROOT="$HARNESS_ROOT" REVHARNESS_PARALLEL_QUIESCE=1 bash "$HARNESS_ROOT/scripts/harness-doctor.sh" --quick --json)
      fi
      ;;
  esac
}

phase_sequence() {
  case "$SUBCOMMAND" in
    init) printf 'init\n' ;;
    setup|resume)
      if [[ "$WITH_SEMANTIC_ADDON" == true ]]; then
        printf '%s\n' $SEMANTIC_ADDON_PHASES
      else
        printf '%s\n' $CORE_PHASES
      fi
      ;;
    verify) printf 'doctor\n' ;;
  esac
}

should_skip_phase() {
  local state="$1" phase="$2" recorded current
  [[ "$RESUME" == true ]] || return 1
  [[ "$(jq -r --arg p "$phase" '.phases[$p].status' <<<"$state")" == "ok" ]] || return 1
  recorded="$(jq -r --arg p "$phase" '.phases[$p].input_sha256 // empty' <<<"$state")"
  current="$(phase_input_sha "$phase")"
  [[ -n "$recorded" && "$recorded" == "$current" ]]
}

run_phases() {
  local state phase input rc phase_code
  state="$(load_state_json)"
  RUN_ID="$(jq -r '.run_id' <<<"$state")"
  if [[ "$RESUME" == true && "$(jq -r '.semantic_addon_enabled // false' <<<"$state")" == "true" ]]; then
    WITH_SEMANTIC_ADDON=true
  fi
  for phase in $(phase_sequence); do
    if [[ "$DRY_RUN" == true ]]; then
      input="$(phase_input_sha "$phase")"
      event phase_started "$phase" running 0 "$input"
      event phase_ok "$phase" ok 0 "$input"
      continue
    fi
    if should_skip_phase "$state" "$phase"; then
      input="$(phase_input_sha "$phase")"
      event verified-skip "$phase" ok 0 "$input"
      continue
    fi
    if [[ "$WITH_SEMANTIC_ADDON" == true && "$phase" == "doctor" && ! -f "$PATHS_FILE" ]]; then
      emit_paths_manifest
    fi
    input="$(phase_input_sha "$phase")"
    snapshot_phase "$phase"
    event phase_started "$phase" running 0 "$input"
    state="$(state_update_phase "$state" "$phase" running 0 "$input")"; write_state_json "$state"
    vlog "running phase=$phase"
    set +e
    run_phase_command "$phase"
    rc=$?
    set -e
    input="$(phase_input_sha "$phase")"
    if [[ "$rc" -eq 0 ]]; then
      state="$(state_update_phase "$state" "$phase" ok 0 "$input")"; write_state_json "$state"
      [[ "$phase" != "init" || "$WITH_SEMANTIC_ADDON" != true ]] || emit_paths_manifest
      event phase_ok "$phase" ok 0 "$input"
    else
      phase_code="$(phase_exit_code "$phase")"
      state="$(state_update_phase "$state" "$phase" failed "$rc" "$input")"; write_state_json "$state"
      event phase_failed "$phase" failed "$rc" "$input"
      EXIT_CODE="$phase_code"
      return "$phase_code"
    fi
  done
  if [[ "$DRY_RUN" == false && "$SUBCOMMAND" != "verify" ]]; then
    state="$(load_state_json)"
    state="$(jq -c --arg ts "$(now_iso)" '.last_install_at = $ts | .last_updated = $ts' <<<"$state")"
    write_state_json "$state"
  fi
  return 0
}

run_mcp_wire_if_requested() {
  [[ "$WITH_MCP_WIRE" == true ]] || return 0
  [[ "$DRY_RUN" == false ]] || { log "skip mcp wire merge (dry-run)"; return 0; }
  local config="$TARGET_ROOT/.mcp.json"
  mkdir -p "$(dirname "$config")"
  [[ -e "$config" ]] || printf '{}\n' > "$config"
  (cd "$TARGET_ROOT" && bash "$HARNESS_ROOT/scripts/rev-harness-mcp-wire.sh" merge --config "$config")
}

render_report() {
  local status="$1" code="$2" state phase_json
  if [[ -f "$STATE_FILE" && "$DRY_RUN" == false ]]; then
    state="$(cat "$STATE_FILE")"
    phase_json="$(jq -c '.phases' <<<"$state")"
    printf '{"schema_version":"%s","status":"%s","run_id":"%s","current_phase":"%s","phases":%s,"exit_code":%s}\n' \
      "$REPORT_SCHEMA" "$status" "$(jq -r '.run_id' <<<"$state")" "$(jq -r '.current_phase' <<<"$state")" "$phase_json" "$code"
  else
    printf '{"schema_version":"%s","status":"%s","run_id":"%s","current_phase":"%s","phases":{},"exit_code":%s}\n' \
      "$REPORT_SCHEMA" "$status" "$RUN_ID" "${SUBCOMMAND:-status}" "$code"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    init|setup|verify|resume|status) SUBCOMMAND="$1"; [[ "$1" == "resume" ]] && RESUME=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --strict) STRICT=true; shift ;;
    --target) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; TARGET_ARG="$2"; shift 2 ;;
    --with-semantic-addon) WITH_SEMANTIC_ADDON=true; shift ;;
    --with-mcp-wire) WITH_MCP_WIRE=true; WITH_SEMANTIC_ADDON=true; shift ;;
    --resume) RESUME=true; shift ;;
    --rollback) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; ROLLBACK="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ -n "$SUBCOMMAND" ]] || { usage >&2; exit 2; }
[[ "$WITH_MCP_WIRE" != true ]] || WITH_SEMANTIC_ADDON=true
resolve_setup_roots
require_tools

if [[ "$SUBCOMMAND" == "status" ]]; then
  RUN_ID="$(new_run_id)"
  if [[ "$JSON_OUTPUT" == true ]]; then
    render_report ok 0
  elif [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    printf 'no state file: %s\n' "$STATE_FILE"
  fi
  exit 0
fi

if [[ -n "$ROLLBACK" ]]; then
  [[ "$DRY_RUN" == false ]] || exit 0
  state="$(load_state_json)"
  RUN_ID="$(jq -r '.run_id' <<<"$state")"
  if [[ "$ROLLBACK" == "all" ]]; then
    for p in doctor hooks semantic_rust semantic_node init; do rollback_phase "$p"; done
  else
    rollback_phase "$ROLLBACK"
  fi
  render_report ok 0
  exit 0
fi

if run_phases; then
  set +e
  run_mcp_wire_if_requested
  wire_rc=$?
  set -e
  if [[ "$wire_rc" -ne 0 ]]; then
    event run_summary "" failed "$wire_rc" ""
    [[ "$JSON_OUTPUT" == true ]] && render_report failed "$wire_rc"
    exit "$wire_rc"
  fi
  event run_summary "" ok 0 ""
  [[ "$JSON_OUTPUT" == true ]] && render_report ok 0
  exit 0
else
  code="$EXIT_CODE"
  event run_summary "" failed "$code" ""
  [[ "$JSON_OUTPUT" == true ]] && render_report failed "$code"
  exit "$code"
fi
