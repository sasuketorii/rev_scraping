#!/usr/bin/env bash
# Lane I.5 — MCP tool-schema breaking-change detector.
#
# Drift model: a tool is "in the surface" if it appears in the BASE branch's
# committed snapshot (e.g. main). A removal/rename only becomes invisible if
# the contributor regenerates the snapshot in their PR — so a meaningful
# detector MUST compare the live (PR head) tool list against the BASE
# branch's `.agent/v1.3/cli-public-api.snapshot.json`, not against the
# PR's own (potentially regenerated) copy.
#
# Behavior:
#   - removed-or-renamed tool ⇒ exit 1 ⇒ PR must carry `mcp-schema-breaking`.
#   - added tool ⇒ exit 0 ⇒ PR carries `api-additive`.
#   - unchanged ⇒ exit 0.
#
# Modes:
#   ./scripts/mcp-schema-breaking.sh           # human-readable
#   ./scripts/mcp-schema-breaking.sh --check   # exit-coded for CI
#
# CI usage: the workflow fetches the PR base ref, then invokes this script
# with `BASE_REF=origin/<base>` in the environment. Local invocation defaults
# to comparing against `origin/main` (or `main` when origin is absent).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SNAPSHOT_PATH=".agent/v1.3/cli-public-api.snapshot.json"
BASE_REF="${BASE_REF:-origin/main}"

# Resolve the base-branch snapshot. If the base ref is unavailable (fresh
# fork checkout, first commit on a branch), fall back to local HEAD~1; this
# still catches "remove a tool in a single PR" within a feature branch's
# own history. If even that fails, exit 0 with an info note.
resolve_base_snapshot() {
  local ref="$1"
  if git show "$ref:$SNAPSHOT_PATH" >/dev/null 2>&1; then
    git show "$ref:$SNAPSHOT_PATH"
    return 0
  fi
  return 1
}

base_blob=""
if resolved=$(resolve_base_snapshot "$BASE_REF" 2>/dev/null); then
  base_blob="$resolved"
elif resolved=$(resolve_base_snapshot "HEAD~1" 2>/dev/null); then
  base_blob="$resolved"
  echo "[mcp-schema-breaking] note: base ref $BASE_REF unreachable; using HEAD~1" >&2
else
  echo "[mcp-schema-breaking] note: no base snapshot reachable; skipping diff (first PR introducing the snapshot, or shallow checkout)." >&2
  if [[ "${1:-}" == "--check" ]]; then
    exit 0
  fi
  exit 0
fi

# Compare via the live (PR head) snapshot, which already captures
# names, required-arg lists, and per-tool input-schema slots. This is broader
# than a tool-name diff: a tightened `required` array (e.g. adding a previously
# optional arg to the required list) is a breaking change too, per
# docs/compat.md. We delegate the full per-tool comparison to Python so the
# diff is structured.

live_blob="$(cat "$SNAPSHOT_PATH")"

diff_report="$(python3 - "$base_blob" "$live_blob" <<'PY'
import json, sys

base = json.loads(sys.argv[1])
live = json.loads(sys.argv[2])

base_tools = set(base["mcp_tools"]["names"])
live_tools = set(live["mcp_tools"]["names"])
added = sorted(live_tools - base_tools)
removed = sorted(base_tools - live_tools)

# Per-tool required-arg comparison. A required arg that exists in BASE but
# disappears in LIVE is harmless (relaxing). A required arg that appears in
# LIVE but not BASE is BREAKING (tightening — old callers will fail).
base_schemas = base.get("mcp_tools", {}).get("schemas", {})
live_schemas = live.get("mcp_tools", {}).get("schemas", {})
tightened = []  # list of (tool, newly-required-arg)
relaxed = []    # list of (tool, removed-required-arg)
for tool in sorted(live_tools & base_tools):
    base_req = set(base_schemas.get(tool, {}).get("required", []) or [])
    live_req = set(live_schemas.get(tool, {}).get("required", []) or [])
    for arg in sorted(live_req - base_req):
        tightened.append((tool, arg))
    for arg in sorted(base_req - live_req):
        relaxed.append((tool, arg))

print(json.dumps({
    "added": added,
    "removed": removed,
    "tightened": tightened,
    "relaxed": relaxed,
}))
PY
)"

added_count="$(echo "$diff_report" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['added']))")"
removed_count="$(echo "$diff_report" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['removed']))")"
tightened_count="$(echo "$diff_report" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['tightened']))")"
relaxed_count="$(echo "$diff_report" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['relaxed']))")"

mode="${1:-}"
exit_code=0

if [[ "$removed_count" -gt 0 ]]; then
  echo "[mcp-schema-breaking] BREAKING vs $BASE_REF: removed/renamed tool(s):" >&2
  echo "$diff_report" | python3 -c "
import json, sys
for t in json.load(sys.stdin)['removed']:
    print(f'    - {t}', file=sys.stderr)
" >&2
  exit_code=1
fi

if [[ "$tightened_count" -gt 0 ]]; then
  echo "[mcp-schema-breaking] BREAKING vs $BASE_REF: tightened required-args" >&2
  echo "    (an arg that was optional is now required — old callers will fail):" >&2
  echo "$diff_report" | python3 -c "
import json, sys
for tool, arg in json.load(sys.stdin)['tightened']:
    print(f'    - {tool}.{arg}', file=sys.stderr)
" >&2
  exit_code=1
fi

if [[ "$exit_code" -ne 0 ]]; then
  echo "" >&2
  echo "Action: apply PR label \`mcp-schema-breaking\` and bump the MCP" >&2
  echo "        schema version per docs/compat.md (2-major guarantee)." >&2
fi

if [[ "$added_count" -gt 0 ]]; then
  echo "[mcp-schema-breaking] additive vs $BASE_REF: new tool(s):"
  echo "$diff_report" | python3 -c "
import json, sys
for t in json.load(sys.stdin)['added']:
    print(f'    + {t}')
"
  echo "Action: apply PR label \`api-additive\`."
fi

if [[ "$relaxed_count" -gt 0 ]]; then
  echo "[mcp-schema-breaking] relaxed (non-breaking) required-args:"
  echo "$diff_report" | python3 -c "
import json, sys
for tool, arg in json.load(sys.stdin)['relaxed']:
    print(f'    - {tool}.{arg} (was required, now optional)')
"
fi

if [[ "$added_count" -eq 0 && "$removed_count" -eq 0 \
      && "$tightened_count" -eq 0 && "$relaxed_count" -eq 0 ]]; then
  live_count="$(python3 -c "import json; print(len(json.load(open('$SNAPSHOT_PATH'))['mcp_tools']['names']))")"
  echo "[mcp-schema-breaking] MCP surface unchanged vs $BASE_REF ($live_count tools, identical required-args)."
fi

# Note on enums + output fields:
# v1.3 snapshot schema captures tool names + required-arg arrays. Per-property
# enums and output-schema fields are NOT yet in the snapshot ($schema_version
# = 2) — extending the snapshot to cover those is tracked for v1.4 (see
# docs/compat.md). For v1.3, enum/output-field breaks are caught by the
# existing `mcp-schema-lint` job (`gen_reference --check`) which diffs the
# rendered docs/MCP_REFERENCE.md.

if [[ "$mode" == "--check" ]]; then
  exit $exit_code
fi
exit 0
