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
# Behavior (R2 contract — 3-valued exit code):
#   - removed-or-renamed tool / tightened required-args ⇒ exit 2 ⇒
#     INTENTIONAL breaking diff ⇒ PR must carry `mcp-schema-breaking`.
#   - added tool ⇒ exit 0 ⇒ PR carries `api-additive`.
#   - unchanged ⇒ exit 0.
#   - any other nonzero ⇒ script execution failure (bash/python/jq/etc.);
#     the CI wrapper MUST NOT honor a label waiver in that case.
#
# Modes:
#   ./scripts/mcp-schema-breaking.sh           # human-readable
#   ./scripts/mcp-schema-breaking.sh --check   # exit-coded for CI
#
# CI usage: the workflow fetches the PR base ref, then invokes this script
# with `BASE_REF=origin/<base>` in the environment. Local invocation defaults
# to comparing against `origin/main` (or `main` when origin is absent).

set -euo pipefail

# Repo-root resolution. Default: this script's parent directory (the
# rev_scraping checkout that ships it). Override via
# MCP_SCHEMA_BREAKING_REPO_ROOT for fixture / dry-run scenarios where the
# caller wants to point the detector at a synthetic snapshot tree (see
# scripts/cli-public-api-snapshot.test.sh).
REPO_ROOT="${MCP_SCHEMA_BREAKING_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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

# Compare via the live (PR head) snapshot. R2 widens the diff to cover four
# breaking-change kinds:
#   1. tool removal/rename
#   2. tightened required-args (was optional, now required)
#   3. input-schema enum NARROWING (a previously-accepted value vanishes)
#   4. output-schema property removal (a documented response field vanishes,
#      so existing callers that read it will break) AND output enum narrowing
# Plus the additive/relaxed signals for advisory output. Snapshot
# `$schema_version` >= 3 carries the input_enums/output blocks; we fall back
# to the v2-compatible name+required diff when the base snapshot predates v3.

live_blob="$(cat "$SNAPSHOT_PATH")"

diff_report="$(python3 - "$base_blob" "$live_blob" <<'PY'
import json, sys

base = json.loads(sys.argv[1])
live = json.loads(sys.argv[2])

base_tools = set(base["mcp_tools"]["names"])
live_tools = set(live["mcp_tools"]["names"])
added = sorted(live_tools - base_tools)
removed = sorted(base_tools - live_tools)

base_schemas = base.get("mcp_tools", {}).get("schemas", {})
live_schemas = live.get("mcp_tools", {}).get("schemas", {})
tightened = []          # list of [tool, newly-required-arg]
relaxed = []            # list of [tool, removed-required-arg]
input_enum_narrowed = [] # [tool, prop, removed_value]
output_prop_removed = []  # [tool, removed_property]
output_enum_narrowed = []  # [tool, path, removed_value]

def _required(schemas, tool):
    return set(schemas.get(tool, {}).get("required", []) or [])

def _input_enums(schemas, tool):
    return schemas.get(tool, {}).get("input_enums", {}) or {}

def _output(schemas, tool):
    return schemas.get(tool, {}).get("output", {}) or {}

base_schema_version = base.get("$schema_version", 1)
live_schema_version = live.get("$schema_version", 1)
schema_v3 = base_schema_version >= 3 and live_schema_version >= 3

for tool in sorted(live_tools & base_tools):
    base_req = _required(base_schemas, tool)
    live_req = _required(live_schemas, tool)
    for arg in sorted(live_req - base_req):
        tightened.append([tool, arg])
    for arg in sorted(base_req - live_req):
        relaxed.append([tool, arg])

    if schema_v3:
        # Input enum narrowing: a value present in BASE but absent in LIVE
        # ⇒ a caller that previously sent that value will now be rejected.
        b_in = _input_enums(base_schemas, tool)
        l_in = _input_enums(live_schemas, tool)
        for prop in sorted(set(b_in) & set(l_in)):
            bvals = set(b_in[prop] or [])
            lvals = set(l_in[prop] or [])
            for v in sorted(bvals - lvals):
                input_enum_narrowed.append([tool, prop, v])

        # Output property removal: a documented response field disappears.
        b_out = _output(base_schemas, tool)
        l_out = _output(live_schemas, tool)
        b_props = set(b_out.get("properties", []) or [])
        l_props = set(l_out.get("properties", []) or [])
        for prop in sorted(b_props - l_props):
            output_prop_removed.append([tool, prop])

        # Output enum narrowing: a value previously emitted may now be
        # impossible, but callers built `if x in {…}` against the old set
        # will silently miss the now-removed branch. We treat this as
        # breaking conservatively.
        b_oe = b_out.get("enums", {}) or {}
        l_oe = l_out.get("enums", {}) or {}
        for path in sorted(set(b_oe) & set(l_oe)):
            bvals = set(b_oe[path] or [])
            lvals = set(l_oe[path] or [])
            for v in sorted(bvals - lvals):
                output_enum_narrowed.append([tool, path, v])

print(json.dumps({
    "added": added,
    "removed": removed,
    "tightened": tightened,
    "relaxed": relaxed,
    "input_enum_narrowed": input_enum_narrowed,
    "output_prop_removed": output_prop_removed,
    "output_enum_narrowed": output_enum_narrowed,
    "schema_v3": schema_v3,
}))
PY
)"

count_field() { echo "$diff_report" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('$1', [])))"; }
added_count="$(count_field added)"
removed_count="$(count_field removed)"
tightened_count="$(count_field tightened)"
relaxed_count="$(count_field relaxed)"
input_enum_narrowed_count="$(count_field input_enum_narrowed)"
output_prop_removed_count="$(count_field output_prop_removed)"
output_enum_narrowed_count="$(count_field output_enum_narrowed)"

mode="${1:-}"
# R2 exit-code contract (distinguishes breaking-diff from script failure):
#   0 — surface unchanged (no diff)
#   2 — INTENTIONAL BREAKING DIFF detected (label gate may waive with
#       `mcp-schema-breaking`)
#   anything else (1, 126, 127, etc.) — script execution failure (bash/python/
#       set -e/jq/etc.); label gate MUST NOT waive these.
# This separation matters because previously rc=1 collapsed both meanings,
# which let a malformed snapshot pretend to be a "real" breaking change.
exit_code=0

if [[ "$removed_count" -gt 0 ]]; then
  echo "[mcp-schema-breaking] BREAKING vs $BASE_REF: removed/renamed tool(s):" >&2
  echo "$diff_report" | python3 -c "
import json, sys
for t in json.load(sys.stdin)['removed']:
    print(f'    - {t}', file=sys.stderr)
" >&2
  exit_code=2
fi

if [[ "$tightened_count" -gt 0 ]]; then
  echo "[mcp-schema-breaking] BREAKING vs $BASE_REF: tightened required-args" >&2
  echo "    (an arg that was optional is now required — old callers will fail):" >&2
  echo "$diff_report" | python3 -c "
import json, sys
for tool, arg in json.load(sys.stdin)['tightened']:
    print(f'    - {tool}.{arg}', file=sys.stderr)
" >&2
  exit_code=2
fi

if [[ "$input_enum_narrowed_count" -gt 0 ]]; then
  echo "[mcp-schema-breaking] BREAKING vs $BASE_REF: input enum narrowed" >&2
  echo "    (a value previously accepted is no longer accepted — old callers will fail):" >&2
  echo "$diff_report" | python3 -c "
import json, sys
for tool, prop, val in json.load(sys.stdin).get('input_enum_narrowed', []):
    print(f'    - {tool}.{prop}: removed \"{val}\" from accepted set', file=sys.stderr)
" >&2
  exit_code=2
fi

if [[ "$output_prop_removed_count" -gt 0 ]]; then
  echo "[mcp-schema-breaking] BREAKING vs $BASE_REF: output property removed" >&2
  echo "    (a documented response field disappeared — readers will see missing key):" >&2
  echo "$diff_report" | python3 -c "
import json, sys
for tool, prop in json.load(sys.stdin).get('output_prop_removed', []):
    print(f'    - {tool}: response no longer carries \"{prop}\"', file=sys.stderr)
" >&2
  exit_code=2
fi

if [[ "$output_enum_narrowed_count" -gt 0 ]]; then
  echo "[mcp-schema-breaking] BREAKING vs $BASE_REF: output enum narrowed" >&2
  echo "    (a value previously possible no longer appears — exhaustive-match callers will silently miss it):" >&2
  echo "$diff_report" | python3 -c "
import json, sys
for tool, path, val in json.load(sys.stdin).get('output_enum_narrowed', []):
    print(f'    - {tool}.{path}: removed \"{val}\"', file=sys.stderr)
" >&2
  exit_code=2
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
      && "$tightened_count" -eq 0 && "$relaxed_count" -eq 0 \
      && "$input_enum_narrowed_count" -eq 0 \
      && "$output_prop_removed_count" -eq 0 \
      && "$output_enum_narrowed_count" -eq 0 ]]; then
  live_count="$(python3 -c "import json; print(len(json.load(open('$SNAPSHOT_PATH'))['mcp_tools']['names']))")"
  schema_v3="$(echo "$diff_report" | python3 -c "import json,sys; print(json.load(sys.stdin).get('schema_v3', False))")"
  if [[ "$schema_v3" == "True" ]]; then
    echo "[mcp-schema-breaking] MCP surface unchanged vs $BASE_REF ($live_count tools, identical required-args + input enums + output schemas)."
  else
    echo "[mcp-schema-breaking] MCP surface unchanged vs $BASE_REF ($live_count tools, identical required-args; base snapshot pre-v3 — enum/output diff skipped)."
  fi
fi

# R2 coverage note: enum narrowing + output-property removal + output enum
# narrowing are now checked here whenever both snapshots are
# $schema_version >= 3. The existing `mcp-schema-lint` job
# (`gen_reference --check`) still serves as the rendered-doc backstop, but
# this detector is now the primary source-of-truth gate.

if [[ "$mode" == "--check" ]]; then
  exit $exit_code
fi
exit 0
