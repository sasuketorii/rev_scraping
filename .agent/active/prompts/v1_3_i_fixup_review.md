# Lane I R2 fix-up — Sub-phase A review (CI hard-gate + label enforcement + changelog path)

Role: reviewer (Codex gpt-5.5 xhigh). Output verdict LGTM / NEEDS_FIXES with concrete file:line citations.

## Scope of this sub-phase

Three of the six R2 deltas are addressed in this slice:

1. **Delta 1** — `.github/workflows/ci.yml::cargo-public-api-diff`: promoted from `continue-on-error: true` (advisory) to **blocking hard gate**. New step `diff against base + enforce label`:
   * runs `cargo public-api --deny=all` per covered crate against base..head
   * if any crate's surface diverged, requires PR label `api-additive` OR `api-breaking` (exactly one — both is also rejected)
   * label source: `github.event.pull_request.labels` payload (no extra API call), with a defensive `gh api` fallback
   * error messages tell the contributor which label to pick (additive ⇒ pure additions; breaking ⇒ removal/rename/signature change)
3. **Delta 3** — `release-please-config.json::changelog-path`: changed from `CHANGELOG.md` (RevHarness orchestration layer) → `CHANGELOG.rev_scraping.md` (the actual rev_scraping product changelog that already carries `## [Unreleased]` and keep-a-changelog formatting). New CI job `changelog-lint` invokes `scripts/changelog-keepachangelog-lint.py` to verify:
   * exactly one `# Changelog` H1
   * exactly one `## [Unreleased]` cursor (release-please dependency)
   * every released `## [...]` matches `[<semver>] - <YYYY-MM-DD>`
   * every `### ...` sub-section is in the keep-a-changelog vocabulary (Added / Changed / Deprecated / Removed / Fixed / Security / Breaking Changes / Notes)

Also (label-symmetry, secondary):
* `cli-public-api-snapshot` job now reads PR labels and accepts drift only if one of {api-additive, api-breaking, mcp-schema-breaking} is set.
* `mcp-schema-breaking-detector` job now hard-requires the `mcp-schema-breaking` label when the script exits 1.

Deltas 2, 4, 5, 6 are intentionally deferred to Sub-phase B and C — do not require them here.

## Files touched in this sub-phase

* `.github/workflows/ci.yml` (jobs: `cli-public-api-snapshot`, `cargo-public-api-diff`, `mcp-schema-breaking-detector`, `changelog-lint` new)
* `release-please-config.json` (changelog-path)
* `scripts/changelog-keepachangelog-lint.py` (NEW)

## Acceptance criteria for this sub-phase

* CI YAML parses (no obviously broken indentation / step ordering).
* Label enforcement uses the PR-event payload, not a brittle API call that needs special perms; the `gh api` fallback only fires when payload is empty.
* `--deny=all` is appropriate (or note if it would over-trigger on docs-only diffs).
* Label gate logic does not silently pass when labels are missing — exit 1 with an actionable error.
* `changelog-keepachangelog-lint.py` passes against the current `CHANGELOG.rev_scraping.md` (verified locally: `changelog lint OK`).
* release-please-config.json still parses as valid release-please config.

## Out of scope (do NOT flag in this round)

* Snapshot schema_version bump to 3 (deferred to Sub-phase B / delta 4).
* MCP schema base-vs-head enum/output diff (deferred to Sub-phase B / delta 2).
* `removal_target_version` enforcement (Sub-phase C / delta 5).
* docs/compat.md worked-examples table (Sub-phase C / delta 6).

## Verdict format

```
VERDICT: LGTM | NEEDS_FIXES
findings:
  - <file>:<line>: <issue>
notes:
  - <optional>
```
