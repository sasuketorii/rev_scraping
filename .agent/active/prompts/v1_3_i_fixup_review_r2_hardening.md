# Lane I R2 fix-up — post-R2-scoring hardening review

Role: reviewer (Codex gpt-5.5 xhigh). R2 dual scoring returned 8.77 (FAIL — target ≥9.0) with three specific concerns. All three addressed:

## Codex R2 scoring deltas

1. **`cli-public-api-snapshot` drift is now non-waiveable.** Previously labels (api-additive/api-breaking/mcp-schema-breaking) could waive the snapshot regeneration requirement. That let a stale-snapshot PR slip through: the mcp-schema-breaking detector reads the BASE branch's committed snapshot, so if both base and live are stale, the detector reports "no change" and the gate passes incorrectly. New behavior: the step is just `./scripts/cli-public-api-snapshot.sh --check` — drift fails closed unconditionally. Labels still classify the *regenerated* diff via the mcp-schema-breaking-detector + cargo-public-api-diff gates downstream.

2. **cargo-public-api crate list auto-discovered.** Previously 6 hand-listed crates. Now `cargo metadata --no-deps` piped to `scripts/workspace-lib-crates.py` (new helper) yields all 13 workspace crates with at least one `lib`/`rlib`/`proc-macro` target. Verified locally: `captcha-bypass`, `mobile-fp`, `obscura-bridge`, `rev-stealth`, `stealth-agent-contracts`, `stealth-auth`, `stealth-cf`, `stealth-core`, `stealth-mcp`, `stealth-parse`, `stealth-sanitize`, `stealth-sites`, `vpn-rotate`.

3. **Fixture tests now cover the three gaps Codex called out.** New cases in `scripts/cli-public-api-snapshot.test.sh`:
   * Case 2d — **input enum narrowing** (`spider.mobile_preset` drops `pixel`) → rc=2 ✓
   * Case 2e — **tool removal** (`recipe_show` vanishes) → rc=2 ✓
   * Case 2f — **stale-snapshot baseline** (identical base==live) → rc=0 ✓ with an inline comment documenting the intended division of labor: the mcp-schema-breaking detector is INTENTIONALLY blind to stale-snapshot bypass; the workflow's `regenerate + check snapshot (HARD)` step is the gate that catches it.

   Total: 8 fixture cases pass (5 → 8), 0 failed, exit rc=0 deterministic.

## Other docs touched

* `docs/compat.md` — the CLI row in the at-a-glance table now says "**HARD — drift always fails; labels classify but do not waive**" with the canonical PR flow command.

## YAML cleanliness

The previous multi-line `python3 -c '...'` problem (Codex Sub-phase A R1 finding) recurred when I first inlined the workspace-crate discovery. Fixed by moving the Python into `scripts/workspace-lib-crates.py` and calling it from CI as a plain script. Verified `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` → YAML OK.

## Local validation

```
$ bash scripts/cli-public-api-snapshot.test.sh | tail -3
[fixture-test] results: 8 passed, 0 failed

$ python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo YAML OK
YAML OK

$ cargo metadata --no-deps --format-version=1 | python3 scripts/workspace-lib-crates.py | wc -l
13

$ cargo test --workspace --no-fail-fast | grep "^test result" | awk '{s+=$4;f+=$6} END {print s, f}'
800 0
```

## Re-review focus

* Snapshot drift is now a hard fail regardless of labels — confirm.
* `WORKSPACE_LIBS` array is correctly populated (no `set -e` race when cargo metadata is slow).
* Fixture tests pass deterministically (exit 0 + status-preserving trap).
* docs/compat.md CLI row no longer permits a label-waivable snapshot drift.
* No regressions in earlier round fixes (`$?` after if/fi, `--deny=all` placement, two-pass cargo public-api, 3-valued mcp-schema-breaking, EXIT trap preserving status).

## Verdict format

```
VERDICT: LGTM | NEEDS_FIXES
findings:
  - <file>:<line>: <issue>
```
