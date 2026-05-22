# Lane I R2 fix-up — Sub-phase B+C review (ROUND 2)

Role: reviewer (Codex gpt-5.5 xhigh). Round-1 verdict was NEEDS_FIXES with 2 findings. Both addressed:

## Round 1 → Round 2 deltas

1. **`scripts/cli-public-api-snapshot.test.sh` exit-code determinism.** Codex reproduction exited rc=1 on a clean run (`set -euo pipefail` + final falsey `[[ ... ]]` test propagates the test's own exit code). Added an explicit `exit 0` after the `fail_count > 0` branch so the script status is deterministic regardless of bash version. Verified locally: `bash scripts/cli-public-api-snapshot.test.sh >/dev/null; echo rc=$?` → `rc=0`.

2. **`docs/compat.md` at-a-glance row was stale.** The "MCP tool schema" row still described enum/output narrowing as v1.4 / policy-only / reviewer-manual, contradicting the v3 detector and the new "Worked Examples" section below. Rewrote both the MCP row AND the `cargo-public-api-diff` row (which still said "advisory in v1.3, hardened in v1.4") to match the R2 state:
   * MCP row now lists all four breaking shapes the detector covers via base-vs-head snapshot diff at `$schema_version >= 3`, mentions the 3-valued exit code, and points to the fixture-tests script.
   * cargo-public-api row updated to "R2: HARD GATE, label-required" and notes the gate fails closed without an explicit label.

## Local validation

```
$ bash scripts/cli-public-api-snapshot.test.sh >/dev/null; echo rc=$?
rc=0
$ cargo test --workspace --no-fail-fast 2>&1 | grep "^test result" | awk '{s+=$4;f+=$6} END {print s, f}'
796 0
$ ./scripts/mcp-schema-breaking.sh --check; echo rc=$?
[mcp-schema-breaking] MCP surface unchanged vs origin/main (16 tools, identical required-args; base snapshot pre-v3 — enum/output diff skipped).
rc=0
```

## Re-review focus

* Fixture-test exit code is now `0` deterministically on PASS.
* `docs/compat.md` at-a-glance table no longer contradicts the worked-examples section below or the actual detector behavior.
* No regressions in the four R1 fixes (`$?` after `if/fi`, `--deny=all` placement, cargo two-pass exec-vs-diff, 3-valued mcp-schema-breaking exit code).

## Verdict format

```
VERDICT: LGTM | NEEDS_FIXES
findings:
  - <file>:<line>: <issue>
```
