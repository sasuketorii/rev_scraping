# Lane I R2 fix-up — Sub-phase A review (ROUND 2)

Role: reviewer (Codex gpt-5.5 xhigh). Round 1 verdict was NEEDS_FIXES with 5 findings. All 5 have been addressed.

## Round 1 → Round 2 deltas

1. **YAML parses now.** The multi-line `python3 -c '…\n…\n…'` literal that was unindented inside `run: |` (rejected by YAML scanner — confirmed locally with `yaml.safe_load`) has been collapsed to a single-line `python3 -c '...'` invocation in all three call sites:
   * `cli-public-api-snapshot` step
   * `cargo-public-api-diff` step
   * `mcp-schema-breaking-detector` step
   Verified: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` → succeeds.

2. **`$?` after `if/fi` bug fixed in both jobs.** Replaced the `if cmd; then …; fi; rc=$?` pattern (which captures the if-statement's rc, not the command's rc — bash returns 0 from the un-taken branch) with `rc=0; cmd || rc=$?` in:
   * `cli-public-api-snapshot::regenerate + check snapshot (label-aware)` — line ~488
   * `mcp-schema-breaking-detector::mcp-schema-breaking diff vs base` — line ~672

3. **cargo-public-api exec-failure vs surface-diff distinction.** The label gate now only fires when `cargo public-api` exits **rc=1** (real diff). rc≥2 (tool/build/range failure) fails the gate unconditionally with a dedicated error — labels cannot waive a broken invocation. Per-crate stdout/stderr is captured to `$tmpdir/<crate>.{out,err}` and re-emitted so logs survive grouping.

4. **release-please ↔ lint vocabulary aligned.** `scripts/changelog-keepachangelog-lint.py::ALLOWED_SUBSECTIONS` extended with the 10 section names release-please emits per `release-please-config.json::changelog-sections` (Features, Bug Fixes, Performance, Dependencies, Documentation, Refactoring, Tests, Continuous Integration, Build System, Chores). Both files are tagged "keep in sync".

## Local validation

```
$ python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo YAML OK
YAML OK
$ python3 scripts/changelog-keepachangelog-lint.py CHANGELOG.rev_scraping.md
changelog lint OK
$ python3 -m json.tool release-please-config.json >/dev/null && echo JSON OK
JSON OK
```

## Files touched (cumulative for Sub-phase A)

* `.github/workflows/ci.yml`
* `release-please-config.json`
* `scripts/changelog-keepachangelog-lint.py`

## Re-review focus

* Confirm the YAML literal-block indentation is correct end-to-end (no remaining unindented continuation lines).
* Confirm the `|| rc=$?` pattern correctly captures the real exit code (vs the if-fi anti-pattern of round 1).
* Confirm the cargo-public-api rc-switch (`case "$rc"`) is correct — `rc=0` no-diff, `rc=1` diff, `rc>=2` exec failure.
* Confirm the label CSV extraction handles `null` payload (workflow_dispatch / push events) without crashing.

Out of scope (Sub-phase B/C still to come): MCP base-vs-head enum/output diff, CLI snapshot v3 expansion, removal_target_version, compat.md worked examples.

## Verdict format

```
VERDICT: LGTM | NEEDS_FIXES
findings:
  - <file>:<line>: <issue>
notes:
  - <optional>
```
