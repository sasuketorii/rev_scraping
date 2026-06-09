#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="rev-harness-model-io-guard"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SAFE_QUARANTINE_ROOT="$REPO_ROOT/.claude/tmp/call-invoke-guard"
DEFAULT_PROMPT_MAX_BYTES="${REV_HARNESS_MODEL_IO_PROMPT_MAX_BYTES:-262144}"
DEFAULT_PROMPT_WARN_BYTES="${REV_HARNESS_MODEL_IO_PROMPT_WARN_BYTES:-196608}"
DEFAULT_ROLLOVER_MAX_TRANSCRIPT_BYTES="${REV_HARNESS_USER_PROMPT_SUBMIT_MAX_TRANSCRIPT_BYTES:-1500000}"
DEFAULT_ROLLOVER_WARN_TRANSCRIPT_BYTES="${REV_HARNESS_USER_PROMPT_SUBMIT_WARN_TRANSCRIPT_BYTES:-1000000}"
DEFAULT_ROLLOVER_MAX_EVENTS="${REV_HARNESS_USER_PROMPT_SUBMIT_MAX_EVENTS:-20000}"
DEFAULT_ROLLOVER_MAX_TOOL_EVENTS="${REV_HARNESS_USER_PROMPT_SUBMIT_MAX_TOOL_EVENTS:-4000}"
DEFAULT_ROLLOVER_POLICY="${REV_HARNESS_USER_PROMPT_SUBMIT_POLICY:-warn}"

usage() {
  cat <<'EOF'
Usage:
  rev-harness-model-io-guard prompt-budget --file PATH --label LABEL [--max-bytes N] [--warn-bytes N]
  rev-harness-model-io-guard scan-output --file PATH --label LABEL --quarantine-dir DIR
  rev-harness-model-io-guard user-prompt-submit --stdin-json
  rev-harness-model-io-guard --self-test

Defaults:
  REV_HARNESS_MODEL_IO_PROMPT_MAX_BYTES=262144
  REV_HARNESS_MODEL_IO_PROMPT_WARN_BYTES=196608
  REV_HARNESS_USER_PROMPT_SUBMIT_MAX_TRANSCRIPT_BYTES=1500000
  REV_HARNESS_USER_PROMPT_SUBMIT_WARN_TRANSCRIPT_BYTES=1000000
  REV_HARNESS_USER_PROMPT_SUBMIT_MAX_EVENTS=20000
  REV_HARNESS_USER_PROMPT_SUBMIT_MAX_TOOL_EVENTS=4000
  REV_HARNESS_USER_PROMPT_SUBMIT_POLICY=warn

Reports intentionally include metadata only: labels, counts, thresholds, marker
IDs, offsets, timestamps, and hashes. Prompt, transcript, tool-argument, and raw
model-output content is never emitted.
EOF
}

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 2
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

json_quote() {
  if command -v jq >/dev/null 2>&1; then
    jq -Rn --arg value "${1:-}" '$value'
  else
    printf '"%s"' "$(printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

byte_count() {
  wc -c < "$1" | tr -d '[:space:]'
}

resolve_safe_quarantine_dir() {
  local requested="$1"
  local candidate=""
  local resolved_root=""

  [[ -n "$requested" ]] || requested="$SAFE_QUARANTINE_ROOT/quarantine"
  case "$requested" in
    /*) candidate="$requested" ;;
    *) candidate="$REPO_ROOT/$requested" ;;
  esac

  mkdir -p "$SAFE_QUARANTINE_ROOT" 2>/dev/null || return 1
  resolved_root="$(cd "$SAFE_QUARANTINE_ROOT" && pwd -P)" || return 1

  case "$candidate" in
    "$resolved_root"|"$resolved_root"/*) ;;
    *) return 2 ;;
  esac
  case "$candidate" in
    *"/../"*|*"/./"*|*/..|*/.)
      return 2
      ;;
  esac

  if [[ -L "$candidate" ]]; then
    return 3
  fi

  mkdir -p "$candidate" 2>/dev/null || return 1
  local resolved_candidate=""
  resolved_candidate="$(cd "$candidate" && pwd -P)" || return 1
  case "$resolved_candidate" in
    "$resolved_root"|"$resolved_root"/*)
      printf '%s\n' "$resolved_candidate"
      ;;
    *)
      return 2
      ;;
  esac
}

emit_json_line() {
  local status="$1"
  local label="$2"
  local bytes="$3"
  local max_bytes="$4"
  local warn_bytes="$5"
  printf '{"schema":"rev-harness-model-io-guard/v1","event":"prompt_budget","status":%s,"label":%s,"bytes":%s,"max_bytes":%s,"warn_bytes":%s,"timestamp":%s}\n' \
    "$(json_quote "$status")" \
    "$(json_quote "$label")" \
    "$bytes" \
    "$max_bytes" \
    "$warn_bytes" \
    "$(json_quote "$(now_utc)")"
}

cmd_prompt_budget() {
  local file=""
  local label=""
  local max_bytes="$DEFAULT_PROMPT_MAX_BYTES"
  local warn_bytes="$DEFAULT_PROMPT_WARN_BYTES"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) file="${2:-}"; shift 2 ;;
      --label) label="${2:-}"; shift 2 ;;
      --max-bytes) max_bytes="${2:-}"; shift 2 ;;
      --warn-bytes) warn_bytes="${2:-}"; shift 2 ;;
      *) die "unknown prompt-budget option: $1" ;;
    esac
  done

  [[ -n "$file" && -f "$file" ]] || die "prompt-budget file not found"
  [[ -n "$label" ]] || die "prompt-budget label is required"
  is_uint "$max_bytes" || die "prompt-budget max bytes must be numeric"
  is_uint "$warn_bytes" || die "prompt-budget warn bytes must be numeric"

  local bytes
  bytes="$(byte_count "$file")"
  if [[ "$bytes" -gt "$max_bytes" ]]; then
    emit_json_line "block" "$label" "$bytes" "$max_bytes" "$warn_bytes" >&2
    return 2
  fi
  if [[ "$bytes" -gt "$warn_bytes" ]]; then
    emit_json_line "warn" "$label" "$bytes" "$max_bytes" "$warn_bytes" >&2
    return 0
  fi
  emit_json_line "pass" "$label" "$bytes" "$max_bytes" "$warn_bytes" >&2
}

scan_markers_awk='
function emit(marker_id, family, start, end) {
  count[marker_id] += 1
  family_by_id[marker_id] = family
  if (!(marker_id in first_start) || start < first_start[marker_id]) first_start[marker_id] = start
  if (end > last_end[marker_id]) last_end[marker_id] = end
  found = 1
}
{
  line = $0
  line_start = offset
  opened_fence = 0
  if (line ~ /call[[:space:]]+<invoke/) emit("transport_xml_call_invoke", "xml", line_start, line_start + length(line))
  if (line ~ /<invoke([>[:space:]]|$)/) emit("transport_malformed_invoke_block", "xml", line_start, line_start + length(line))
  if (line ~ /<\/invoke>/) emit("transport_malformed_invoke_block", "xml", line_start, line_start + length(line))
  if (line ~ /<parameter[[:space:]]+name=/) emit("transport_malformed_invoke_block", "xml", line_start, line_start + length(line))
  if (line ~ /<tool_use([>[:space:]]|$)/) emit("transport_xml_tool_call", "xml", line_start, line_start + length(line))
  if (line ~ /<tool_result([>[:space:]]|$)/) emit("transport_xml_tool_result", "xml", line_start, line_start + length(line))
  if (line ~ /"type"[[:space:]]*:[[:space:]]*"tool_use"/ || line ~ /"name"[[:space:]]*:[[:space:]]*"tool_use"/) emit("transport_json_tool_call", "json", line_start, line_start + length(line))
  if (line ~ /"type"[[:space:]]*:[[:space:]]*"tool_result"/ || line ~ /"name"[[:space:]]*:[[:space:]]*"tool_result"/) emit("transport_json_tool_result", "json", line_start, line_start + length(line))
  if (line ~ /^[[:space:]]*```(json|xml)?[[:space:]]*$/ && !in_fence) {
    in_fence = 1
    opened_fence = 1
  }
  if (in_fence && (line ~ /<tool_use([>[:space:]]|$)/ || line ~ /"type"[[:space:]]*:[[:space:]]*"tool_use"/)) emit("transport_code_fence_tool_payload", "fence", line_start, line_start + length(line))
  if (line ~ /^[[:space:]]*```[[:space:]]*$/ && in_fence && !opened_fence) in_fence = 0
  if (line ~ /^[[:space:]]*<subagent_notification>/ || line ~ /^[[:space:]]*<\/subagent_notification>/) emit("transport_unknown_tool_marker", "transport", line_start, line_start + length(line))
  if (line ~ /"other_recipients"[[:space:]]*:/ || line ~ /"trigger_turn"[[:space:]]*:/) emit("transport_unknown_tool_marker", "transport", line_start, line_start + length(line))
  offset += length($0) + 1
}
END {
  if (!found) exit 1
  first = 1
  printf "["
  for (marker_id in count) {
    if (!first) printf ","
    first = 0
    printf "{\"marker_id\":\"%s\",\"family\":\"%s\",\"count\":%d,\"first_offset\":%d,\"last_offset\":%d}", marker_id, family_by_id[marker_id], count[marker_id], first_start[marker_id], last_end[marker_id]
  }
  printf "]\n"
}'

cmd_scan_output() {
  local file=""
  local label=""
  local quarantine_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) file="${2:-}"; shift 2 ;;
      --label) label="${2:-}"; shift 2 ;;
      --quarantine-dir) quarantine_dir="${2:-}"; shift 2 ;;
      *) die "unknown scan-output option: $1" ;;
    esac
  done

  [[ -n "$file" && -f "$file" ]] || die "scan-output file not found"
  [[ -n "$label" ]] || die "scan-output label is required"
  [[ -n "$quarantine_dir" ]] || die "scan-output quarantine dir is required"
  local safe_quarantine_dir=""
  if ! safe_quarantine_dir="$(resolve_safe_quarantine_dir "$quarantine_dir")"; then
    printf '{"schema":"rev-harness-model-io-guard/v1","event":"scan_output","status":"block","reason":"unsafe_quarantine_dir","label":%s,"timestamp":%s}\n' \
      "$(json_quote "$label")" "$(json_quote "$(now_utc)")" >&2
    return 4
  fi

  local markers_json=""
  if ! markers_json="$(LC_ALL=C awk "$scan_markers_awk" "$file")"; then
    printf '{"schema":"rev-harness-model-io-guard/v1","event":"scan_output","status":"pass","label":%s,"bytes":%s,"timestamp":%s}\n' \
      "$(json_quote "$label")" "$(byte_count "$file")" "$(json_quote "$(now_utc)")" >&2
    return 0
  fi

  local quarantine_name quarantine_file hash
  quarantine_name="model-io-$(date -u '+%Y%m%dT%H%M%SZ').$$.raw"
  quarantine_file="$safe_quarantine_dir/$quarantine_name"
  cp "$file" "$quarantine_file"
  chmod 600 "$quarantine_file" 2>/dev/null || true
  hash="$(sha256_file "$quarantine_file")"

  printf '{"schema":"rev-harness-model-io-guard/v1","event":"scan_output","status":"block","label":%s,"bytes":%s,"timestamp":%s,"sha256":%s,"markers":%s}\n' \
    "$(json_quote "$label")" \
    "$(byte_count "$file")" \
    "$(json_quote "$(now_utc)")" \
    "$(json_quote "$hash")" \
    "$markers_json" >&2
  return 3
}

count_transcript_metrics() {
  local transcript="$1"
  local bytes events users assistants tool_calls tool_results

  bytes=0
  events=0
  users=0
  assistants=0
  tool_calls=0
  tool_results=0

  if [[ -n "$transcript" && -f "$transcript" ]]; then
    bytes="$(byte_count "$transcript")"
    events="$(wc -l < "$transcript" | tr -d '[:space:]')"
    users="$(grep -Eoc '"role"[[:space:]]*:[[:space:]]*"user"' "$transcript" 2>/dev/null || true)"
    assistants="$(grep -Eoc '"role"[[:space:]]*:[[:space:]]*"assistant"' "$transcript" 2>/dev/null || true)"
    tool_calls="$(grep -Eoc '"type"[[:space:]]*:[[:space:]]*"tool_use"|<tool_use([>[:space:]]|$)' "$transcript" 2>/dev/null || true)"
    tool_results="$(grep -Eoc '"type"[[:space:]]*:[[:space:]]*"tool_result"|<tool_result([>[:space:]]|$)' "$transcript" 2>/dev/null || true)"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$bytes" "$events" "$users" "$assistants" "$tool_calls" "$tool_results"
}

cmd_user_prompt_submit() {
  [[ "${1:-}" == "--stdin-json" ]] || die "user-prompt-submit requires --stdin-json"
  local payload transcript_path prompt_chars
  payload="$(cat)"

  if ! command -v jq >/dev/null 2>&1; then
    printf '{"schema":"rev-harness-model-io-guard/v1","event":"user_prompt_submit","status":"fail_open","reason":"jq_unavailable","timestamp":%s}\n' "$(json_quote "$(now_utc)")" >&2
    return 0
  fi
  if ! jq -e . >/dev/null 2>&1 <<< "$payload"; then
    printf '{"schema":"rev-harness-model-io-guard/v1","event":"user_prompt_submit","status":"fail_open","reason":"malformed_hook_json","timestamp":%s}\n' "$(json_quote "$(now_utc)")" >&2
    return 0
  fi

  transcript_path="$(jq -r '.transcript_path // empty' <<< "$payload" 2>/dev/null || true)"
  prompt_chars="$(jq -r '(.prompt // "") | length' <<< "$payload" 2>/dev/null || echo 0)"
  if ! is_uint "$prompt_chars"; then
    prompt_chars=0
  fi

  local bytes events users assistants tool_calls tool_results
  IFS=$'\t' read -r bytes events users assistants tool_calls tool_results < <(count_transcript_metrics "$transcript_path")

  local status="pass"
  local reason="within_threshold"
  local tool_events=$((tool_calls + tool_results))
  if [[ "$bytes" -gt "$DEFAULT_ROLLOVER_MAX_TRANSCRIPT_BYTES" || "$events" -gt "$DEFAULT_ROLLOVER_MAX_EVENTS" || "$tool_events" -gt "$DEFAULT_ROLLOVER_MAX_TOOL_EVENTS" ]]; then
    status="warn"
    if [[ "$DEFAULT_ROLLOVER_POLICY" == "block" ]]; then
      status="block"
    fi
    reason="threshold_exceeded"
  elif [[ "$bytes" -gt "$DEFAULT_ROLLOVER_WARN_TRANSCRIPT_BYTES" ]]; then
    status="warn"
    reason="warn_threshold_exceeded"
  fi

  local evidence_root="${REV_HARNESS_USER_PROMPT_SUBMIT_EVIDENCE_DIR:-.claude/tmp/call-invoke-guard/rollover}"
  mkdir -p "$evidence_root" 2>/dev/null || {
    printf '{"schema":"rev-harness-model-io-guard/v1","event":"user_prompt_submit","status":"fail_open","reason":"evidence_dir_unavailable","timestamp":%s}\n' "$(json_quote "$(now_utc)")" >&2
    return 0
  }
  local evidence_file="$evidence_root/user-prompt-submit-$(date -u '+%Y%m%dT%H%M%SZ').$$.json"
  printf '{"schema":"rev-harness-user-prompt-submit/v1","status":%s,"reason":%s,"policy":%s,"prompt_chars":%s,"transcript_bytes":%s,"event_rows":%s,"user_messages":%s,"assistant_messages":%s,"tool_calls":%s,"tool_results":%s,"max_transcript_bytes":%s,"warn_transcript_bytes":%s,"max_events":%s,"max_tool_events":%s,"timestamp":%s}\n' \
    "$(json_quote "$status")" "$(json_quote "$reason")" "$(json_quote "$DEFAULT_ROLLOVER_POLICY")" \
    "$prompt_chars" "$bytes" "$events" "$users" "$assistants" "$tool_calls" "$tool_results" \
    "$DEFAULT_ROLLOVER_MAX_TRANSCRIPT_BYTES" "$DEFAULT_ROLLOVER_WARN_TRANSCRIPT_BYTES" "$DEFAULT_ROLLOVER_MAX_EVENTS" "$DEFAULT_ROLLOVER_MAX_TOOL_EVENTS" \
    "$(json_quote "$(now_utc)")" > "$evidence_file"
  chmod 600 "$evidence_file" 2>/dev/null || true
  cat "$evidence_file" >&2

  if [[ "$status" == "block" && "$DEFAULT_ROLLOVER_POLICY" == "block" ]]; then
    return 2
  fi
  return 0
}

self_test() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-model-io-guard.XXXXXX")"
  trap "/bin/rm -rf '$tmp'" RETURN
  printf 'safe prompt\n' > "$tmp/prompt.txt"
  cmd_prompt_budget --file "$tmp/prompt.txt" --label self-test --max-bytes 100 --warn-bytes 90 >/dev/null 2>&1
  printf 'raw marker <tool_use name="x">SECRET</tool_use>\n' > "$tmp/out.txt"
  if cmd_scan_output --file "$tmp/out.txt" --label self-test --quarantine-dir "$SAFE_QUARANTINE_ROOT/self-test" >/dev/null 2>"$tmp/scan.json"; then
    printf '%s\n' "self-test scan should have blocked" >&2
    return 1
  fi
  grep -Fq 'transport_xml_tool_call' "$tmp/scan.json"
  ! grep -Fq 'SECRET' "$tmp/scan.json"
  printf '{"role":"user","content":"TRANSCRIPT_SECRET"}\n' > "$tmp/transcript.jsonl"
  printf '{"prompt":"PROMPT_SECRET","transcript_path":"%s"}\n' "$tmp/transcript.jsonl" \
    | REV_HARNESS_USER_PROMPT_SUBMIT_EVIDENCE_DIR="$tmp/rollover" cmd_user_prompt_submit --stdin-json 2>"$tmp/rollover.json"
  ! grep -Fq 'PROMPT_SECRET' "$tmp/rollover.json"
  ! grep -Fq 'TRANSCRIPT_SECRET' "$tmp/rollover.json"
  printf 'PASS: rev-harness-model-io-guard self-test\n'
}

main() {
  case "${1:-}" in
    prompt-budget) shift; cmd_prompt_budget "$@" ;;
    scan-output) shift; cmd_scan_output "$@" ;;
    user-prompt-submit) shift; cmd_user_prompt_submit "$@" ;;
    --self-test) self_test ;;
    -h|--help|"") usage ;;
    *) die "unknown command: $1" ;;
  esac
}

main "$@"
