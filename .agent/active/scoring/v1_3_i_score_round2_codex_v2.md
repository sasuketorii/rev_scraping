# Lane I R2 dual scoring — Codex prompt (after post-scoring hardening)

Role: strict scorer (Codex gpt-5.5 xhigh). You scored R2 v1 at 8.77 FAIL. The fix-up driver addressed all three concerns. Re-score the same 7-axis rubric.

R1 = 7.79 FAIL.
R2-v1 = 8.77 FAIL (your previous score).
Target: ≥ 9.0 PASS.

## Concerns you raised → fixes delivered

1. **"snapshot drift waiveable by label → stale-snapshot bypass risk"**
   → Step rewritten as `./scripts/cli-public-api-snapshot.sh --check` only. Drift always fails. Labels classify the *regenerated* diff at the cargo-public-api / mcp-schema-breaking gates only. `.github/workflows/ci.yml::cli-public-api-snapshot::regenerate + check snapshot (HARD — drift always fails)`.

2. **"cargo-public-api coverage = 6 hand-listed crates, not workspace"**
   → Auto-discovered via `cargo metadata --no-deps` → `scripts/workspace-lib-crates.py` (new helper). 13 lib crates covered (was 6). Three-stage explicit error checking on metadata invocation, helper invocation, and empty-list guard — process-substitution race fixed (Codex round-1 finding on this very hardening).

3. **"fixture coverage gaps: tool removal, input enum narrowing, stale-snapshot bypass"**
   → Three new cases in `scripts/cli-public-api-snapshot.test.sh`:
     - Case 2d input enum narrowing (spider.mobile_preset drops pixel) → rc=2 PASS
     - Case 2e tool removal (recipe_show vanishes) → rc=2 PASS
     - Case 2f stale-snapshot baseline (identical base==live) → rc=0 PASS with inline comment documenting the intended division of labor (the snapshot-drift workflow step catches stale-snapshot bypass; the detector is intentionally blind so the test asserts the no-false-positive baseline).
   → 8 fixture cases total (was 5), 0 failed, rc=0 deterministic.

`docs/compat.md` CLI row updated to read "**HARD — drift always fails; labels classify but do not waive**".

## Workspace impact

* `cargo test --workspace --no-fail-fast`: 800 / 0 fail (was 791 R1 baseline → 796 R2-v1 → 800 R2-v2).
* `bash scripts/cli-public-api-snapshot.test.sh`: 8 passed, 0 failed, rc=0.
* YAML parses; changelog lint OK; cargo metadata → workspace-lib-crates discovers 13 crates.

## Files touched in the post-R2-scoring round

* `.github/workflows/ci.yml` (cli-public-api-snapshot HARD; cargo-public-api auto-discovery + 3-stage error checking)
* `scripts/workspace-lib-crates.py` (new helper)
* `scripts/cli-public-api-snapshot.test.sh` (3 new fixture cases)
* `docs/compat.md` (CLI row)

## Scoring rubric (same 7 axes)

A. surface-coverage completeness
B. CI enforcement strength
C. semver lifecycle clarity
D. PR-level intent capture
E. forward-compatibility hygiene
F. test depth
G. doc/CI fidelity

Compute overall as arithmetic mean. PASS ≥ 9.0.

Return:

```
| 軸 | スコア | 根拠 |
|---|---|---|
...
overall = X.XX PASS/FAIL
```

Then one paragraph on residual risk (if any) and what is needed to push above 9.5.
