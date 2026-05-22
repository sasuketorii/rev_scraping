# Lane I R2 fix-up — Sub-phase A review (ROUND 3)

Role: reviewer (Codex gpt-5.5 xhigh). Round 2 verdict NEEDS_FIXES (3 findings). All addressed:

## Round 2 → Round 3 deltas

1. **`--deny=all` placement (round 2 finding #1).** Moved AFTER the `diff` subcommand: `cargo public-api --package <crate> diff --deny=all <range>`. cargo-public-api 0.39.0 defines `--deny` as a `diff` option, not a top-level option (verified by Codex's scratch-repo reproduction → bad order returns rc=2 `unexpected argument '--deny'`).

2. **cargo-public-api exec-fail vs surface-diff discriminator (round 2 finding #2).** Two-pass invocation per crate:
   * Pass 1: `cargo public-api -p <crate> diff <range>` — no `--deny`. The tool returns 0 even on a real diff in this mode; non-zero ⇒ rustdoc/build/range failure ⇒ `exec_fail=1`, fail closed, labels do not waive.
   * Pass 2: `cargo public-api -p <crate> diff --deny=all <range>`. Non-zero here, given pass 1 passed, is a true surface diff ⇒ `diff_seen=1`, label gate applies.
   Implemented at `.github/workflows/ci.yml::cargo-public-api-diff`.

3. **mcp-schema-breaking script — 3-valued exit code (round 2 finding #3).** Previously rc=1 covered both "breaking diff" AND `set -e`/python/snapshot failure. Now:
   * rc=0 — surface unchanged
   * rc=2 — INTENTIONAL breaking diff (label waiver applies)
   * any other nonzero — script execution failure (NEVER waiveable)
   `scripts/mcp-schema-breaking.sh::exit_code` updated to 2 on breaking detection; the CI wrapper explicitly checks `[[ $rc -ne 2 ]]` before considering the label gate. Verified locally: `./scripts/mcp-schema-breaking.sh --check` → rc=0 (no diff on current main).

## Local validation

```
$ python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo YAML OK
YAML OK
$ ./scripts/mcp-schema-breaking.sh --check; echo rc=$?
[mcp-schema-breaking] MCP surface unchanged vs origin/main (16 tools, identical required-args).
rc=0
$ python3 scripts/changelog-keepachangelog-lint.py CHANGELOG.rev_scraping.md
changelog lint OK
```

## Re-review focus

* Pass 1 of cargo-public-api genuinely returns 0 on a real diff (no `--deny`). Confirm.
* Pass 2 with `--deny=all` after `diff` parses correctly in clap 0.39.
* mcp-schema-breaking.sh's `exit_code=2` cannot be accidentally overwritten elsewhere in the script (it's only assigned from breaking-detection branches; check end-of-file `exit $exit_code` reaches it).
* The CI wrapper's `[[ "$rc" -ne 2 ]]` branch correctly fails closed on rc=1/126/127/etc.

Out of scope (Sub-phase B/C still to come): MCP base-vs-head enum/output diff, CLI snapshot v3 expansion, removal_target_version, compat.md worked examples.

## Verdict format

```
VERDICT: LGTM | NEEDS_FIXES
findings:
  - <file>:<line>: <issue>
```
