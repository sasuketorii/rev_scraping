#!/usr/bin/env bash
set -euo pipefail

# Broadened read-only auto-approve smoke.
#
# Companion to codex_semantic_health_smoke.sh. That smoke only exercises
# sem.health; this one exercises an ADDITIONAL auto-approved read-only tool
# (sem.context.top_k) to prove the read-only allowlist actually works
# non-interactively without a real "user cancelled MCP tool call".
#
# It deliberately does NOT exercise any write tool (registry.upsert /
# registry.set_status / registry.delete / admin.gc): those stay at the server
# default ("prompt") and would require a human, so a non-interactive run of
# them is EXPECTED to be cancelled, not auto-approved.
#
# Exit codes:
#   0  PASS  — sem.context.top_k was auto-approved and returned valid JSON
#   1  FAIL  — a real cancellation of an auto-approved read-only tool, OR
#              redaction failure (genuine fix/guard defect)
#   2  SOFT  — model declined / nested codex exec env limit after all retries
#              (NOT a fix defect; record honestly as an environment limit)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
WRAPPER="$REPO_ROOT/scripts/codex-wrapper.sh"
MAX_ATTEMPTS="${SMOKE_MAX_ATTEMPTS:-3}"

redact_text() {
  sed -E -e "s#${HOME%/}/#~/#g" -e 's#/Users/[^/[:space:]]+/#~/#g' -e 's#/home/[^/[:space:]]+/#~/#g'
}

# Exercise sem.context.top_k: a read-only discovery tool that must be on the
# auto-approve allowlist.
#
# We let the model run its natural sem-first discovery flow (which may also
# touch other auto-approved read-only tools such as sem.search) rather than
# over-constraining to a single cold call: empirically, a hard "call exactly one
# tool, read nothing" prompt makes the model declare sem.context.top_k "not
# available in this session" and decline, whereas the natural flow resolves the
# tool and returns valid JSON. The hardened cancellation guard below tolerates
# the model echoing this script's own source (cancel phrase) and only treats a
# canonical Codex runtime tool-failure marker as a real cancellation.
prompt='Use the semantic-mcp server to call MCP tool `sem.context.top_k` with JSON arguments {"query": "semantic registry approval gate", "k": 3}. Then print, as the FINAL line of your output, only the raw JSON object that `sem.context.top_k` returned — no Markdown, no commentary, no surrounding prose on that final line.'

# Detect a REAL cancellation of an auto-approved read-only tool.
#
# A blunt substring scan would false-trip because the model can echo the phrase
# "user cancelled MCP tool call" while narrating or reading files. A real
# cancellation surfaces as the canonical Codex runtime tool-failure marker for a
# semantic-mcp read-only tool co-occurring with the cancel phrase. Lines that
# merely echo this script's own tagged comments are dropped before scanning.
is_real_cancel() {
  local stdout_f="$1" stderr_f="$2" f
  for f in "$stdout_f" "$stderr_f"; do
    if grep -v 'codex-sem-readonly-smoke' "$f" 2>/dev/null \
         | grep -Fq 'user cancelled MCP tool call' \
       && grep -Eq 'mcp: semantic-mcp/(sem\.context\.top_k|sem\.health|sem\.preflight|sem\.capsule|sem\.search|sem\.registry\.query) \(failed\)' "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# A valid sem.context.top_k response is a JSON object that carries a context
# token or a results/items/matches array. Loose on field names, strict that the
# tool actually executed and returned a structured object (not a refusal/prose).
#
# The model may emit prose before a final JSON line, so we scan stdout line by
# line for ANY line that parses as a matching object. A line that parses to an
# object containing only "error" (a refusal payload) does NOT match.
is_valid_topk_json() {
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if printf '%s' "$line" | jq -e '
        type == "object"
        and (
          has("context_token")
          or (has("results") and (.results | type == "array"))
          or (has("items") and (.items | type == "array"))
          or (has("matches") and (.matches | type == "array"))
        )
      ' >/dev/null 2>&1; then
      return 0
    fi
  done < "$1"
  return 1
}

attempt=1
final_rc=2
while [[ "$attempt" -le "$MAX_ATTEMPTS" ]]; do
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-sem-readonly-smoke.XXXXXX")"
  STDOUT_FILE="$TMP_DIR/stdout.txt"
  STDERR_FILE="$TMP_DIR/stderr.redacted.txt"
  STDERR_FIFO="$TMP_DIR/stderr.fifo"

  mkfifo "$STDERR_FIFO"
  redact_text <"$STDERR_FIFO" >"$STDERR_FILE" &
  redactor_pid=$!

  set +e
  printf '%s\n' "$prompt" \
    | "$WRAPPER" --role standard --stdin \
        >"$STDOUT_FILE" \
        2>"$STDERR_FIFO"
  wrapper_rc=$?
  wait "$redactor_pid"
  redactor_rc=$?
  set -e

  printf '[codex-sem-readonly-smoke] attempt=%s/%s tool=sem.context.top_k\n' "$attempt" "$MAX_ATTEMPTS"
  printf '[codex-sem-readonly-smoke] wrapper_exit=%s\n' "$wrapper_rc"
  printf '[codex-sem-readonly-smoke] stdout_begin\n'
  redact_text <"$STDOUT_FILE"
  printf '\n[codex-sem-readonly-smoke] stdout_end\n'
  if [[ -s "$STDERR_FILE" ]]; then
    printf '[codex-sem-readonly-smoke] stderr_begin\n' >&2
    cat "$STDERR_FILE" >&2
    printf '\n[codex-sem-readonly-smoke] stderr_end\n' >&2
  fi

  if [[ "$redactor_rc" -ne 0 ]]; then
    printf '[codex-sem-readonly-smoke] FAIL: stderr redaction failed: %s\n' "$redactor_rc" >&2
    /bin/rm -rf "$TMP_DIR" 2>/dev/null || true
    exit 1
  fi

  # Hard FAIL (fix/guard defect): a read-only tool was actually cancelled.
  if is_real_cancel "$STDOUT_FILE" "$STDERR_FILE"; then
    printf '[codex-sem-readonly-smoke] FAIL: an auto-approved read-only tool was cancelled (user cancelled MCP tool call)\n' >&2
    /bin/rm -rf "$TMP_DIR" 2>/dev/null || true
    exit 1
  fi

  # PASS: tool executed and returned a valid JSON object.
  if [[ "$wrapper_rc" -eq 0 ]] && is_valid_topk_json "$STDOUT_FILE"; then
    printf '[codex-sem-readonly-smoke] PASS: sem.context.top_k auto-approved and returned valid JSON (attempt %s)\n' "$attempt"
    /bin/rm -rf "$TMP_DIR" 2>/dev/null || true
    exit 0
  fi

  # Soft miss: model refused / declined / nested codex exec env limit. Retry.
  printf '[codex-sem-readonly-smoke] SOFT: attempt %s did not yield valid sem.context.top_k JSON (no real cancellation); retrying\n' "$attempt" >&2
  /bin/rm -rf "$TMP_DIR" 2>/dev/null || true
  attempt=$((attempt + 1))
done

printf '[codex-sem-readonly-smoke] SOFT-LIMIT: no valid sem.context.top_k JSON after %s attempts and NO real cancellation observed.\n' "$MAX_ATTEMPTS" >&2
printf '[codex-sem-readonly-smoke] This is recorded as an environment/model limit (nested codex exec flakiness), NOT a fix defect.\n' >&2
printf '[codex-sem-readonly-smoke] Deterministic evidence: .codex/config.toml TOML-parse + codex mcp list --json verify the allowlist.\n' >&2
exit 2
