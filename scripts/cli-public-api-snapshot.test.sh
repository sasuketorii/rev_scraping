#!/usr/bin/env bash
# Lane I R2 — fixture tests for the MCP schema breaking-change detector.
#
# We do not exercise `cli-public-api-snapshot.sh` end-to-end (that requires
# a built rev-stealth + tools.rs). Instead we feed
# `scripts/mcp-schema-breaking.sh` synthetic BASE and LIVE snapshot blobs
# constructed inline (schema_version = 3) and assert the script's exit
# code + stderr signal across three fixture scenarios:
#
#   1. additive   — new tool added, all existing tools unchanged → rc=0
#   2. breaking   — required-arg tightened OR enum narrowed → rc=2
#   3. drift      — script execution failure (malformed JSON) → rc != 0,2
#
# Implementation detail: the production script reads the base snapshot from
# `git show $BASE_REF:.agent/v1.3/cli-public-api.snapshot.json`. We stand
# up a throwaway git repo under $TMPDIR, commit each base fixture as a
# single isolated repo state, then point the script at it via BASE_REF +
# CWD swap. This keeps the test hermetic from the host repo's actual
# snapshot history.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/mcp-schema-breaking.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "[fixture-test] cannot find $SCRIPT" >&2
  exit 1
fi

fail() {
  echo "::error::[fixture-test] $*" >&2
  exit 1
}

pass_count=0
fail_count=0

# write_fixture <case-dir> <base-json> <live-json>
#   sets up a git repo with BASE committed on `main` and LIVE in the
#   working tree, then echoes the dir.
write_fixture() {
  local case_dir="$1"
  local base_json="$2"
  local live_json="$3"
  mkdir -p "$case_dir/.agent/v1.3"
  mkdir -p "$case_dir/scripts"
  mkdir -p "$case_dir/crates/stealth-mcp/src"
  # Minimal `tools.rs` — the script reads it via SNAPSHOT_PATH path-only;
  # the file itself is only consulted by cli-public-api-snapshot.sh, not by
  # mcp-schema-breaking.sh. Touch it for completeness.
  : > "$case_dir/crates/stealth-mcp/src/tools.rs"

  # 1. Commit BASE.
  (
    cd "$case_dir"
    git init -q -b main
    git config user.email fixture@example.invalid
    git config user.name fixture
    printf '%s\n' "$base_json" > .agent/v1.3/cli-public-api.snapshot.json
    git add .
    git commit -qm base
  )
  # 2. Overwrite with LIVE in working tree (uncommitted).
  printf '%s\n' "$live_json" > "$case_dir/.agent/v1.3/cli-public-api.snapshot.json"
}

# run_case <case-dir> <expected-rc-equal-or-not> <description>
#   expected-rc is the literal numeric rc we expect.
run_case() {
  local case_dir="$1"
  local expected_rc="$2"
  local desc="$3"
  local got_rc=0
  (
    cd "$case_dir"
    # Set BASE_REF to local main so the script's `git show main:...` resolves.
    MCP_SCHEMA_BREAKING_REPO_ROOT="$(pwd)" BASE_REF=main bash "$SCRIPT" --check
  ) >"$case_dir/out" 2>"$case_dir/err" || got_rc=$?
  if [[ "$got_rc" == "$expected_rc" ]]; then
    pass_count=$((pass_count + 1))
    echo "[fixture-test] PASS: $desc (rc=$got_rc)"
  else
    fail_count=$((fail_count + 1))
    echo "::error::[fixture-test] FAIL: $desc — expected rc=$expected_rc got rc=$got_rc" >&2
    echo "--- stdout ---" >&2; cat "$case_dir/out" >&2
    echo "--- stderr ---" >&2; cat "$case_dir/err" >&2
  fi
}

# ----- Shared base snapshot (16 mock tools, schema_version=3) -----
make_base_json() {
  python3 - <<'PY'
import json
base = {
    "$schema_version": 3,
    "binary_name": "rev-stealth",
    "version_string": "rev-stealth fixture",
    "env_vars": [],
    "exit_codes": {},
    "global": {"usage": "", "flags": [], "subcommands": []},
    "commands": {},
    "mcp_tools": {
        "count": 2,
        "names": ["spider", "recipe_show"],
        "schemas": {
            "spider": {
                "required": ["url"],
                "input_enums": {"mobile_preset": ["iphone", "pixel"]},
                "output": {
                    "properties": ["ok", "operation", "result"],
                    "required": ["ok"],
                    "enums": {
                        "operation": ["spider", "spider_fast"]
                    },
                },
            },
            "recipe_show": {
                "required": ["domain"],
                "input_enums": {},
                "output": {
                    "properties": ["domain", "status", "endpoints"],
                    "required": ["domain", "status"],
                    "enums": {"status": ["Active", "Pending", "Retired"]},
                },
            },
        },
    },
    "error_kinds": {"count": 0, "variants": []},
    "deprecated_attrs": [],
    "_notes": [],
}
print(json.dumps(base, indent=2, sort_keys=True))
PY
}

BASE_DIR_BASE="$(mktemp -d -t mcp-fixture-base.XXXXXX)"
# Trap MUST preserve the script's intended exit status. Under `set -e` a
# failing cleanup (e.g. `rm -rf` racing with another tool, or a leftover
# .git/objects pack with bad permissions) would otherwise overwrite the
# pass/fail status with the trap's own rc. We capture $? first, disable
# `-e` for the duration of the cleanup, then re-exit with the captured
# status. (Codex round-2 Sub-phase B+C finding.)
cleanup() {
  local status=$?
  set +e
  rm -rf "$BASE_DIR_BASE"
  exit "$status"
}
trap cleanup EXIT

BASE_JSON="$(make_base_json)"

# ============================================================
# Case 1: additive — new tool `new_tool` appears, nothing else
# changes. Expected rc=0.
# ============================================================
case1_live="$(printf '%s' "$BASE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["mcp_tools"]["count"] = 3
d["mcp_tools"]["names"] = sorted(d["mcp_tools"]["names"] + ["new_tool"])
d["mcp_tools"]["schemas"]["new_tool"] = {
    "required": [], "input_enums": {},
    "output": {"properties": [], "required": [], "enums": {}},
}
print(json.dumps(d, indent=2, sort_keys=True))
')"
CASE1="$BASE_DIR_BASE/case1-additive"
write_fixture "$CASE1" "$BASE_JSON" "$case1_live"
run_case "$CASE1" 0 "additive: new MCP tool added"

# ============================================================
# Case 2: breaking — recipe_show.status enum loses "Pending"
# (a previously-emitted value vanishes from output). Expected rc=2.
# ============================================================
case2_live="$(printf '%s' "$BASE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["mcp_tools"]["schemas"]["recipe_show"]["output"]["enums"]["status"] = ["Active", "Retired"]
print(json.dumps(d, indent=2, sort_keys=True))
')"
CASE2="$BASE_DIR_BASE/case2-breaking-enum"
write_fixture "$CASE2" "$BASE_JSON" "$case2_live"
run_case "$CASE2" 2 "breaking: output enum narrowing (Pending removed)"

# ============================================================
# Case 2b: breaking — required-arg tightening (spider gains a new
# required arg `timeout_ms`). Expected rc=2.
# ============================================================
case2b_live="$(printf '%s' "$BASE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["mcp_tools"]["schemas"]["spider"]["required"] = sorted(d["mcp_tools"]["schemas"]["spider"]["required"] + ["timeout_ms"])
print(json.dumps(d, indent=2, sort_keys=True))
')"
CASE2B="$BASE_DIR_BASE/case2b-breaking-required"
write_fixture "$CASE2B" "$BASE_JSON" "$case2b_live"
run_case "$CASE2B" 2 "breaking: required-arg tightening (timeout_ms added)"

# ============================================================
# Case 2c: breaking — output property removal (recipe_show.endpoints
# disappears from response). Expected rc=2.
# ============================================================
case2c_live="$(printf '%s' "$BASE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
props = d["mcp_tools"]["schemas"]["recipe_show"]["output"]["properties"]
d["mcp_tools"]["schemas"]["recipe_show"]["output"]["properties"] = [p for p in props if p != "endpoints"]
print(json.dumps(d, indent=2, sort_keys=True))
')"
CASE2C="$BASE_DIR_BASE/case2c-breaking-output-prop"
write_fixture "$CASE2C" "$BASE_JSON" "$case2c_live"
run_case "$CASE2C" 2 "breaking: output property removed (recipe_show.endpoints)"

# ============================================================
# Case 2d: breaking — input enum narrowing. spider.mobile_preset
# drops the `pixel` value, so old callers that pass it will fail.
# Expected rc=2.
# ============================================================
case2d_live="$(printf '%s' "$BASE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
d["mcp_tools"]["schemas"]["spider"]["input_enums"] = {"mobile_preset": ["iphone"]}
print(json.dumps(d, indent=2, sort_keys=True))
')"
CASE2D="$BASE_DIR_BASE/case2d-breaking-input-enum"
write_fixture "$CASE2D" "$BASE_JSON" "$case2d_live"
run_case "$CASE2D" 2 "breaking: input enum narrowing (spider.mobile_preset drops pixel)"

# ============================================================
# Case 2e: breaking — tool removal. recipe_show vanishes from
# the names list AND the schemas map. Expected rc=2.
# ============================================================
case2e_live="$(printf '%s' "$BASE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
names = [n for n in d["mcp_tools"]["names"] if n != "recipe_show"]
d["mcp_tools"]["count"] = len(names)
d["mcp_tools"]["names"] = names
d["mcp_tools"]["schemas"].pop("recipe_show", None)
print(json.dumps(d, indent=2, sort_keys=True))
')"
CASE2E="$BASE_DIR_BASE/case2e-breaking-tool-removal"
write_fixture "$CASE2E" "$BASE_JSON" "$case2e_live"
run_case "$CASE2E" 2 "breaking: tool removal (recipe_show)"

# ============================================================
# Case 2f: stale-snapshot bypass attempt. The contributor mutated
# real source (which would show in the regenerator's output) but
# committed an unchanged snapshot AND did not regenerate. The
# mcp-schema-breaking detector compares stale base vs stale live
# — both identical — so it reports "no change". The fixture
# verifies this by feeding identical snapshots; the GATE that
# catches this scenario is `cli-public-api-snapshot --check` (the
# regenerator + drift check in the workflow), NOT this detector.
# This case documents the intended division of labor — the
# detector is INTENTIONALLY blind to stale-snapshot bypass; the
# snapshot regeneration step is the gate that catches it. We
# assert here only that the detector reports rc=0 on identical
# blobs (no false positive). The actual stale-snapshot defense
# lives in the workflow step `regenerate + check snapshot (HARD)`,
# which fails closed on any drift without a waiver.
# ============================================================
CASE2F="$BASE_DIR_BASE/case2f-stale-snapshot-identical"
write_fixture "$CASE2F" "$BASE_JSON" "$BASE_JSON"
run_case "$CASE2F" 0 "stale-snapshot baseline: identical base==live ⇒ rc=0 (detector by design; bypass is caught by the snapshot drift gate, not here)"

# ============================================================
# Case 3: drift — malformed JSON in the LIVE snapshot. The script
# must NOT report rc=0 OR rc=2 (silently passing OR pretending it's
# a real breaking diff). We assert rc is neither 0 nor 2; the
# specific value depends on the failing stage.
# ============================================================
malformed='{ this is not valid json'
CASE3="$BASE_DIR_BASE/case3-drift-malformed"
write_fixture "$CASE3" "$BASE_JSON" "$malformed"
got3=0
(
  cd "$CASE3"
  MCP_SCHEMA_BREAKING_REPO_ROOT="$(pwd)" BASE_REF=main bash "$SCRIPT" --check
) >"$CASE3/out" 2>"$CASE3/err" || got3=$?
if [[ "$got3" -eq 0 || "$got3" -eq 2 ]]; then
  fail_count=$((fail_count + 1))
  echo "::error::[fixture-test] FAIL: drift case must NOT exit 0 or 2 (got $got3 — script silently accepted malformed JSON)" >&2
  cat "$CASE3/err" >&2
else
  pass_count=$((pass_count + 1))
  echo "[fixture-test] PASS: drift (malformed JSON → rc=$got3, neither 0 nor 2)"
fi

echo ""
echo "[fixture-test] results: $pass_count passed, $fail_count failed"
# Explicit exit codes so the script status is deterministic. (Without this
# `exit 0`, `set -euo pipefail` causes the falsey `[[ ... ]]` test to
# propagate as exit 1 — Codex round-2 finding.)
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
exit 0
