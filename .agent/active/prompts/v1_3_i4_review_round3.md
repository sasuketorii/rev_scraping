# Review v1.3 I.4 (Round 3)

R2 BLOCK addressed:

1. **`### Conventions` violated declared vocabulary.** The preamble declared the allowed `### <Section>` set as keep-a-changelog standard (`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`, `Breaking Changes`). My added `### Conventions` was outside that set. Moved the label conventions OUT of `[Unreleased]` and into the preamble paragraph itself — no new `###` heading needed.

2. **`1.0.0` lacked any `### <Section>`.** Wrapped the initial-release one-liner in `### Added` so it now matches the contract (every release has at least one `### <Section>` subsection).

## Files touched (delta)
- `CHANGELOG.rev_scraping.md`:
  - Removed `### Conventions` section under `[Unreleased]`.
  - Inlined the label vocabulary into the preamble paragraph (still discoverable, no new heading).
  - Added `### Added` to the 1.0.0 release.

## Gates PASS
- All `##` headings now match exactly: `## [Unreleased]`, `## [1.2.0] - 2026-05-22`, `## [1.1.0] - 2026-04-30`, `## [1.0.0] - 2026-03-31`.
- All `###` headings inside release sections are members of the declared vocabulary set.

## Verify (3)
1. `grep -nE '^### ' CHANGELOG.rev_scraping.md` returns only `Added`, `Security` — both members of the declared vocabulary.
2. Every `##` release section has at least one `###` subsection (including 1.0.0).
3. PR label conventions remain documented + parseable by release-please (now in the preamble paragraph, not behind a sub-heading).

Return: `verdict: LGTM` or `verdict: BLOCK: <reason>`.
