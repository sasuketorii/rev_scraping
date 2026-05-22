# Lane I — Dual Scoring Convergence Record (round 2)

| Scorer | R1 | R2-v1 | R2-v2 (final) | Verdict |
|--------|----|-----:|--------------:|---------|
| Opus 4.7-xhigh | 9.08 | — | (pending orchestrator) | (target ≥ 9.0) |
| Codex gpt-5.5-xhigh | 7.79 | 8.77 | **9.10** | **PASS** |
| Gap (Codex side closure) | +1.31 R1→R2-v2 | | | |

R2 Codex breakdown (final):

| 軸 | R1 | R2-v2 | Δ |
|---|---:|---:|---:|
| A surface-coverage | 7.6 | 9.30 | +1.70 |
| B CI enforcement | 8.0 | 9.15 | +1.15 |
| C semver lifecycle clarity | 8.2 | 9.25 | +1.05 |
| D PR-level intent | 7.4 | 8.65 | +1.25 |
| E forward-compat hygiene | 7.7 | 9.10 | +1.40 |
| F test depth | 7.5 | 9.20 | +1.70 |
| G doc/CI fidelity | 8.4 | 9.05 | +0.65 |

## Deltas absorbed (R1 source → R2 implementation)

1. **cargo-public-api hard gate, label-required** — `.github/workflows/ci.yml::cargo-public-api-diff`. Two-pass smoke/deny invocation per crate; payload-based label parse with dual-label rejection; auto-enumerated to 13 lib crates via `scripts/workspace-lib-crates.py` + 3-stage error checking.
2. **MCP base-vs-head with enum + output diff** — `scripts/mcp-schema-breaking.sh`. Detects tool removal/rename, required-arg tightening, input enum narrowing, output property removal, output enum narrowing. 3-valued exit code (0/2/other) distinguishes intentional breaking from script execution failure. `MCP_SCHEMA_BREAKING_REPO_ROOT` env override.
3. **release-please ↔ CHANGELOG alignment** — `release-please-config.json::changelog-path` → `CHANGELOG.rev_scraping.md`. New CI job `changelog-lint` via `scripts/changelog-keepachangelog-lint.py`. Vocabulary synced with release-please-emitted section names.
4. **Snapshot v3 + fixture tests** — `scripts/cli-public-api-snapshot.sh` ($schema_version 2→3) adds `input_enums`, output schema summary (recursive enum walk), 26 ErrorKind variants, deprecated_attrs index. `scripts/cli-public-api-snapshot.test.sh` covers 8 fixture cases (additive, 5× breaking shapes, stale baseline, drift).
5. **removal_target_version** — `crates/stealth-cli/tests/deprecated_completeness.rs`. Two source sites accepted (inline note OR comment-above). Semver validation. 3 new smoke cases.
6. **docs/compat.md worked examples** — 7-row classification table + 3-case walkthrough + "drift always fails" CLI row update.

## Post-R2-scoring hardening (after 8.77)

* `cli-public-api-snapshot` step rewritten as HARD; labels never waive snapshot drift.
* cargo-public-api crate list auto-discovered (was 6 hand-listed → 13 from cargo metadata).
* Fixture coverage extended: tool removal + input enum narrowing + stale-snapshot baseline.
* docs/compat.md CLI row updated.

## Round-by-round review history

| Round | Sub-phase | Codex verdict | Fixes applied |
|-------|-----------|---------------|---------------|
| 1 | A (CI hard-gate + label) | NEEDS_FIXES (5 findings) | YAML python multi-line; `$?` after if/fi; cargo public-api exec-vs-diff; release-please vocabulary sync |
| 2 | A | NEEDS_FIXES (3 findings) | `--deny=all` placement; cargo-public-api two-pass; mcp-schema-breaking 3-valued exit code |
| 3 | A | NEEDS_FIXES (1 doc nit) | header comment updated to rc=2 |
| 1 | B+C (snapshot v3 + removal_target + compat docs) | NEEDS_FIXES (2 findings) | fixture-test explicit exit 0; compat.md stale at-a-glance row |
| 2 | B+C | NEEDS_FIXES (1 finding) | EXIT trap preserves status under set -e |
| 3 | B+C | **LGTM** | — |
| 1 | post-R2-scoring hardening | NEEDS_FIXES (1 finding) | process-substitution exit-status race in mapfile |
| 2 | post-R2-scoring hardening | **LGTM** | — |

## Workspace impact

* `cargo test --workspace --no-fail-fast`: 791 (R1 baseline) → 800 (R2-v2 final), 0 failures.
* fixture tests: 5 → 8 cases, all PASS, rc=0 deterministic.
* MCP detector exit-code contract: 0 / 2 / other (vs R1: 0 / 1 collapsed).
* cargo-public-api coverage: 6 → 13 lib crates.

## Files touched

* `.github/workflows/ci.yml`
* `release-please-config.json`
* `scripts/cli-public-api-snapshot.sh`
* `scripts/mcp-schema-breaking.sh`
* `scripts/cli-public-api-snapshot.test.sh` (new)
* `scripts/changelog-keepachangelog-lint.py` (new)
* `scripts/workspace-lib-crates.py` (new)
* `.agent/v1.3/cli-public-api.snapshot.json` (regenerated at v3)
* `crates/stealth-cli/tests/deprecated_completeness.rs`
* `docs/compat.md`

## Known gaps for ≥9.5 (R3 territory, not blocking PASS)

Per Codex final commentary:

1. A label-enforcing CLI-only public-surface classifier (would classify a snapshot diff that is purely CLI-only — no MCP / cargo-public-api change — into `api-additive` vs `api-breaking` automatically rather than relying on the human reviewer).
2. Workflow-level label permutation fixtures.
3. Snapshot extractor type-shape diff detection (the docs/compat.md Case 3 limitation: type widening from free-string to closed enum is detector-blind when the base lacked the enum).

These were not in the R1 deltas-to-absorb list; deferred to a future R3 or v1.4 lane.
