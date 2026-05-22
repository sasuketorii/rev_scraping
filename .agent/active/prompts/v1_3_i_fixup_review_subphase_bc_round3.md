# Lane I R2 fix-up — Sub-phase B+C review (ROUND 3)

Role: reviewer (Codex gpt-5.5 xhigh). Round-2 caught a deeper bug: the EXIT trap on the fixture-test script ran `rm -rf` under `set -e`, and if cleanup hits even a transient error the trap propagates a non-zero status that overwrites the intended `exit 0` from a PASS. Fixed.

## Round 2 → Round 3 delta

`scripts/cli-public-api-snapshot.test.sh`:

```diff
-BASE_DIR_BASE="$(mktemp -d -t mcp-fixture-base.XXXXXX)"
-trap 'rm -rf "$BASE_DIR_BASE"' EXIT
+BASE_DIR_BASE="$(mktemp -d -t mcp-fixture-base.XXXXXX)"
+cleanup() {
+  local status=$?
+  set +e
+  rm -rf "$BASE_DIR_BASE"
+  exit "$status"
+}
+trap cleanup EXIT
```

The trap now: captures `$?` first, disables `-e` for the duration of the cleanup, runs `rm -rf`, then re-exits with the captured status. Pass status is preserved across an aggressive `rm -rf` of the fixture's nested `.git/objects` tree.

Verified locally:

```
$ bash scripts/cli-public-api-snapshot.test.sh >/dev/null; echo rc=$?
rc=0
$ bash scripts/cli-public-api-snapshot.test.sh | tail -1
[fixture-test] results: 5 passed, 0 failed
```

No code or docs touched outside this one script.

## Verdict format

```
VERDICT: LGTM | NEEDS_FIXES
findings:
  - <file>:<line>: <issue>
```
