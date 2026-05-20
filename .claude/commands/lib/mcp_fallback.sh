#!/usr/bin/env bash
# mcp_fallback.sh - MCP wrappers with fail-closed CLI fallback
#
# `sem.capsule` is Rust-authoritative; CLI fallback intentionally disabled.
# New tools `sem.context.top_k` / `sem.admin.gc` are MCP-only. Use skill
# `revharness-semantic-mcp-usage`.
#
# JSON-RPC over stdio (outline only):
#   Request : {"jsonrpc":"2.0","id":"<id>","method":"tools/call","params":{"name":"sem.health","arguments":{...}}}
#   Response: {"jsonrpc":"2.0","id":"<id>","result":{...}} or {"jsonrpc":"2.0","id":"<id>","error":{...}}
# Actual transport wiring is intentionally left as a stub in this phase.
set -euo pipefail

MCP_FALLBACK_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MCP_FALLBACK_CONTEXT_ANALYSIS="$MCP_FALLBACK_LIB_DIR/context_analysis.sh"
MCP_FALLBACK_CONTEXT_CAPSULE="$MCP_FALLBACK_LIB_DIR/context_capsule.sh"

_mcp_fallback_log_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$@"
  else
    echo "[WARN] $*" >&2
  fi
}

_mcp_fallback_die() {
  if declare -F die >/dev/null 2>&1; then
    die "$@"
  else
    echo "[ERROR] $*" >&2
    exit 1
  fi
}

_mcp_fallback_ensure_jq() {
  if declare -F ensure_cmd >/dev/null 2>&1; then
    ensure_cmd jq
  elif ! command -v jq >/dev/null 2>&1; then
    _mcp_fallback_die "jq not found. Please install jq."
  fi
}

_mcp_fallback_json_quote() {
  local raw="${1:-}"
  jq -nr --arg v "$raw" '$v | @json'
}

_mcp_fallback_is_json() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || return 1
  jq -e . >/dev/null 2>&1 <<< "$payload"
}

_mcp_fallback_is_jsonrpc_error_object() {
  local payload="${1:-}"
  _mcp_fallback_is_json "$payload" || return 1

  jq -e '
    type == "object"
    and ((.jsonrpc // "") | tostring) == "2.0"
    and (.error | type == "object")
  ' >/dev/null 2>&1 <<< "$payload"
}

_mcp_fallback_wrapped_json_text() {
  local payload="${1:-}"
  _mcp_fallback_is_json "$payload" || return 1

  jq -r '
    if type == "object" then
      .result.content[0].text
      // (if (.result | type) == "string" then .result else empty end)
      // empty
    else
      empty
    end
  ' <<< "$payload"
}

_mcp_fallback_is_jsonrpc_error_payload() {
  local payload="${1:-}"
  local wrapped_payload=""

  if _mcp_fallback_is_jsonrpc_error_object "$payload"; then
    return 0
  fi

  wrapped_payload="$(_mcp_fallback_wrapped_json_text "$payload" 2>/dev/null || true)"
  [[ -n "$wrapped_payload" ]] || return 1

  _mcp_fallback_is_jsonrpc_error_object "$wrapped_payload"
}

_mcp_fallback_jsonrpc_error_message() {
  local payload="${1:-}"
  local candidate=""
  local wrapped_payload=""

  wrapped_payload="$(_mcp_fallback_wrapped_json_text "$payload" 2>/dev/null || true)"

  for candidate in "$payload" "$wrapped_payload"; do
    [[ -n "$candidate" ]] || continue
    if _mcp_fallback_is_jsonrpc_error_object "$candidate"; then
      jq -r '.error.message // empty' <<< "$candidate"
      return 0
    fi
  done

  return 1
}

_mcp_fallback_run_context_analysis() {
  local subcommand="${1:-}"
  shift || true

  [[ -n "$subcommand" ]] || _mcp_fallback_die "_mcp_fallback_run_context_analysis: subcommand is required"
  [[ -f "$MCP_FALLBACK_CONTEXT_ANALYSIS" ]] || _mcp_fallback_die "context_analysis.sh not found: $MCP_FALLBACK_CONTEXT_ANALYSIS"

  bash "$MCP_FALLBACK_CONTEXT_ANALYSIS" "$subcommand" "$@"
}

_mcp_fallback_extract_semantic_id() {
  local payload="${1:-}"
  local semantic_id=""

  if _mcp_fallback_is_json "$payload"; then
    if jq -e 'type == "object"' >/dev/null 2>&1 <<< "$payload"; then
      semantic_id="$(jq -r '.semantic_id // .logical_id // empty' <<< "$payload")"
    elif jq -e 'type == "string"' >/dev/null 2>&1 <<< "$payload"; then
      semantic_id="$(jq -r '.' <<< "$payload")"
    fi
  else
    semantic_id="$payload"
  fi

  echo "$semantic_id"
}

_mcp_fallback_registry_mutator_requires_mcp() {
  local tool_name="${1:-}"
  case "$tool_name" in
    "sem.registry.upsert"|"sem.registry.set_status"|"sem.registry.delete")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_mcp_fallback_tool_requires_mcp() {
  local tool_name="${1:-}"
  case "$tool_name" in
    "sem.context.top_k"|"sem.admin.gc")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_mcp_fallback_fail_closed_registry_tool() {
  local tool_name="${1:-sem.registry.*}"
  _mcp_fallback_die "${tool_name} blocked: Phase 3 partial cutover disables CLI JSONL registry fallback; full DB-backed registry mutator replacement remains pending and is out of scope for this slice"
}

_mcp_fallback_fail_closed_mcp_only_tool() {
  local tool_name="${1:-sem.*}"
  _mcp_fallback_die "${tool_name} CLI fallback not implemented, use MCP path"
}

# Safe default stub: if no real MCP transport is loaded yet, mcp_call returns failure.
# A concrete transport layer can override this function later.
if ! declare -F mcp_call >/dev/null 2>&1; then
  mcp_call() {
    local tool_name="${1:-}"
    shift || true
    _mcp_fallback_log_warn "mcp_call stub: MCP transport is not connected (tool=${tool_name})"
    return 1
  }
fi

# MCP health check
# Returns:
#   0 => MCP reachable
#   1 => MCP unavailable
mcp_check_health() {
  # Optional hard switch for forcing CLI fallback in tests or degraded mode.
  if [[ "${MCP_FORCE_CLI_FALLBACK:-0}" == "1" ]]; then
    return 1
  fi

  if ! declare -F mcp_call >/dev/null 2>&1; then
    return 1
  fi

  local health_output=""
  if ! health_output="$(mcp_call "sem.health" "{}" 2>/dev/null)"; then
    return 1
  fi

  if _mcp_fallback_is_jsonrpc_error_payload "$health_output"; then
    return 1
  fi

  # Accept both direct payload and JSON-RPC-shaped payloads.
  # MCP tools/call responses may wrap tool output as JSON string in result.content[0].text.
  if _mcp_fallback_is_json "$health_output"; then
    if jq -e '
      (.result.content[0].text // .result // .) as $raw
      | (
          if ($raw | type) == "string" then
            (try ($raw | fromjson) catch $raw)
          else
            $raw
          end
        ) as $parsed
      | (
          if ($parsed | type) == "object" then
            ((($parsed.status // "") | tostring | ascii_downcase) | contains("ok"))
            or ((($parsed.result.status // "") | tostring | ascii_downcase) | contains("ok"))
            or ($parsed.ok == true)
          elif ($parsed | type) == "string" then
            (($parsed | ascii_downcase) | contains("ok"))
          else
            false
          end
        )
    ' >/dev/null 2>&1 <<< "$health_output"; then
      return 0
    fi
  fi

  return 1
}

# Wrapper with automatic CLI fallback
# Usage: mcp_or_fallback <tool_name> [input_json]
mcp_or_fallback() {
  local tool_name="${1:-}"
  shift || true

  [[ -n "$tool_name" ]] || _mcp_fallback_die "mcp_or_fallback: tool_name is required"

  local mcp_output=""
  local mcp_error_mode=""
  local jsonrpc_error_message=""

  if mcp_check_health; then
    if mcp_output="$(mcp_call "$tool_name" "$@")"; then
      if _mcp_fallback_is_jsonrpc_error_payload "$mcp_output"; then
        mcp_error_mode="jsonrpc_error"
        jsonrpc_error_message="$(_mcp_fallback_jsonrpc_error_message "$mcp_output" 2>/dev/null || true)"
      else
        if [[ -n "$mcp_output" ]]; then
          printf '%s\n' "$mcp_output"
        fi
        return 0
      fi
    else
      mcp_error_mode="shell_error"
    fi
    if _mcp_fallback_registry_mutator_requires_mcp "$tool_name"; then
      _mcp_fallback_fail_closed_registry_tool "$tool_name"
    fi
    if _mcp_fallback_tool_requires_mcp "$tool_name"; then
      _mcp_fallback_fail_closed_mcp_only_tool "$tool_name"
    fi
    if [[ "$mcp_error_mode" == "jsonrpc_error" ]]; then
      if [[ -n "$jsonrpc_error_message" ]]; then
        _mcp_fallback_log_warn "MCP call returned JSON-RPC error, falling back to CLI: $tool_name ($jsonrpc_error_message)"
      else
        _mcp_fallback_log_warn "MCP call returned JSON-RPC error, falling back to CLI: $tool_name"
      fi
    else
      _mcp_fallback_log_warn "MCP call failed, falling back to CLI: $tool_name"
    fi
  else
    if _mcp_fallback_registry_mutator_requires_mcp "$tool_name"; then
      _mcp_fallback_fail_closed_registry_tool "$tool_name"
    fi
    if _mcp_fallback_tool_requires_mcp "$tool_name"; then
      _mcp_fallback_fail_closed_mcp_only_tool "$tool_name"
    fi
    _mcp_fallback_log_warn "MCP unavailable, falling back to CLI: $tool_name"
  fi

  case "$tool_name" in
    "sem.registry.upsert")
      _fallback_registry_upsert "$@"
      ;;
    "sem.registry.query")
      _fallback_registry_query "$@"
      ;;
    "sem.registry.set_status")
      _fallback_registry_set_status "$@"
      ;;
    "sem.registry.delete")
      _fallback_registry_delete "$@"
      ;;
    "sem.preflight")
      _fallback_preflight "$@"
      ;;
    "sem.capsule")
      _fallback_capsule "$@"
      ;;
    "sem.context.top_k"|"sem.admin.gc")
      _mcp_fallback_fail_closed_mcp_only_tool "$tool_name"
      ;;
    *)
      _mcp_fallback_die "Unknown MCP tool: $tool_name"
      ;;
  esac
}

# sem.registry.upsert
# Phase 3 partial cutover: direct CLI JSONL fallback is blocked.
_fallback_registry_upsert() {
  _mcp_fallback_fail_closed_registry_tool "sem.registry.upsert"
}

# sem.registry.query
# Input:
#   - MCP JSON payload (preferred), or
#   - raw jq filter string
# Output: {"items":[],"total":n,"capsule":"..."}
# Phase 3 partial cutover: conservative empty compatibility output only.
_fallback_registry_query() {
  local payload="${1:-}"
  if [[ -z "$payload" ]]; then
    payload='{}'
  fi
  _mcp_fallback_ensure_jq

  local filter="true"
  local limit=8
  local offset=0

  if _mcp_fallback_is_json "$payload"; then
    if jq -e 'type == "object"' >/dev/null 2>&1 <<< "$payload"; then
      local kind=""
      local path_prefix=""
      local name_partial=""
      local semantic_id=""
      local limit_raw=""
      local offset_raw=""

      kind="$(jq -r '.kind // empty' <<< "$payload")"
      path_prefix="$(jq -r '.path_prefix // .pathPrefix // .path // empty' <<< "$payload")"
      name_partial="$(jq -r '.name_partial // .name // .symbol // empty' <<< "$payload")"
      semantic_id="$(jq -r '.semantic_id // .logical_id // empty' <<< "$payload")"

      limit_raw="$(jq -r '
        if (.limit // null) == null then
          ""
        elif (.limit | type) == "number" then
          (.limit | floor | tostring)
        elif (.limit | type) == "string" then
          .limit
        else
          ""
        end
      ' <<< "$payload")"
      if [[ "$limit_raw" =~ ^[0-9]+$ ]]; then
        limit="$limit_raw"
      fi
      (( limit < 1 )) && limit=1
      (( limit > 25 )) && limit=25

      offset_raw="$(jq -r '
        if (.offset // null) == null then
          ""
        elif (.offset | type) == "number" then
          (.offset | floor | tostring)
        elif (.offset | type) == "string" then
          .offset
        else
          ""
        end
      ' <<< "$payload")"
      if [[ "$offset_raw" =~ ^[0-9]+$ ]]; then
        offset="$offset_raw"
      fi
      (( offset < 0 )) && offset=0
      (( offset > 10000 )) && offset=10000

      local parts=()
      if [[ -n "$kind" ]]; then
        parts+=("(.kind == $(_mcp_fallback_json_quote "$kind"))")
      fi
      if [[ -n "$path_prefix" ]]; then
        parts+=("((.file // .module // \"\") | startswith($(_mcp_fallback_json_quote "$path_prefix")))")
      fi
      if [[ -n "$name_partial" ]]; then
        parts+=("((.name // \"\") | contains($(_mcp_fallback_json_quote "$name_partial")))")
      fi
      if [[ -n "$semantic_id" ]]; then
        local sid_q
        sid_q="$(_mcp_fallback_json_quote "$semantic_id")"
        parts+=("((.semantic_id // .logical_id // \"\") == ${sid_q})")
      fi

      local statuses=()
      while IFS= read -r status_item; do
        [[ -n "$status_item" ]] || continue
        statuses+=("$status_item")
      done < <(jq -r '
        if (.statuses? | type) == "array" then
          .statuses[]
        elif (.status? | type) == "array" then
          .status[]
        elif (.statuses? | type) == "string" then
          .statuses
        elif (.status? | type) == "string" then
          .status
        else
          empty
        end
      ' <<< "$payload")

      if [[ "${#statuses[@]}" -gt 0 ]]; then
        local status_expr=""
        local status_item=""
        for status_item in "${statuses[@]}"; do
          local normalized_status=""
          normalized_status="$(printf '%s' "$status_item" | tr '[:upper:]' '[:lower:]')"
          [[ -n "$normalized_status" ]] || continue
          if [[ -n "$status_expr" ]]; then
            status_expr+=" or "
          fi
          status_expr+="((((.status // ._status // \"active\") | tostring | ascii_downcase) == ($(_mcp_fallback_json_quote "$normalized_status") | ascii_downcase)))"
        done
        [[ -n "$status_expr" ]] && parts+=("$status_expr")
      fi

      local part=""
      for part in "${parts[@]}"; do
        filter="${filter} and (${part})"
      done
    elif jq -e 'type == "string"' >/dev/null 2>&1 <<< "$payload"; then
      filter="$(jq -r '.' <<< "$payload")"
      [[ -n "$filter" ]] || filter="true"
    fi
  elif [[ -n "$payload" ]]; then
    filter="$payload"
  fi

  jq -nc \
    --argjson limit "$limit" \
    --argjson offset "$offset" \
    '{
      items: [],
      total: 0,
      capsule: (
        "matched:0 returned:0"
        + (if $offset > 0 or $limit < 8 then " truncated:true" else "" end)
        + " compatibility:blocked"
      )
    }'
}

# sem.registry.set_status
# Phase 3 partial cutover: direct CLI JSONL fallback is blocked.
_fallback_registry_set_status() {
  _mcp_fallback_fail_closed_registry_tool "sem.registry.set_status"
}

# sem.registry.delete
# Phase 3 partial cutover: direct CLI JSONL fallback is blocked.
_fallback_registry_delete() {
  _mcp_fallback_fail_closed_registry_tool "sem.registry.delete"
}

# sem.preflight conservative fallback
# Phase 3 partial cutover: this path is DB-authoritative and must fail closed
# when MCP is unavailable or explicitly forced off.
_fallback_preflight() {
  _mcp_fallback_log_warn "preflight CLI fallback blocked: DB-authoritative MCP path is required"
  jq -nc \
    '{
      verdict: "BLOCK",
      conflicts: [
        {
          semantic_id: "sem.preflight",
          reason: "blocked: DB-authoritative MCP path required; CLI fallback disabled in semantic_registry_export_compatibility"
        }
      ],
      delete_impacts_summary: "authority:blocked fallback:disabled reason:db_authoritative_required",
      capsule: "PREFLIGHT=BLOCK authority=db_required fallback=disabled reason=semantic_registry_export_compatibility"
    }'
}

# sem.capsule stub fallback
_fallback_capsule() {
  _mcp_fallback_die "sem.capsule CLI fallback not implemented, use MCP path"
}
