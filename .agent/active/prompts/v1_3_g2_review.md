# v1.3 Lane G.2 Reviewer (round 1)

You are the Codex reviewer for Lane G.2 — CLI --help dictionary quality. G.1 LGTM. Read-only.

## Spec
Every `rev-stealth` sub-command --help must carry 3 sections:
- `EXAMPLES:` — 1..5 `$ rev-stealth ...` lines
- `EXIT CODES:` — subset of ExitCode variants, sourced from `.agent/v1.3/cli-surface.json`
- `ENV:` — env vars consumed (may be `(none ...)`)

Locked by `crates/stealth-cli/tests/help_dictionary_quality.rs` which walks the surface JSON and asserts headers + example count [1..5] + EXIT CODES set match.

ExitCode variants used: 0 Ok / 1 UserError / 2 TransientError / 3 PermanentError / 4 AuthExpired / 7 Leak.

## Changes
```
git diff 81e2a180 -- crates/stealth-cli/src/{main.rs,captcha_cmd.rs,browser_cmd.rs,vpn_cmd.rs,commands/auth.rs,commands/config_cli.rs,commands/hermes.rs} crates/stealth-cli/tests/help_dictionary_quality.rs
```
Non-test files add `#[command(long_about=..., after_help=...)]` to clap derives. Test file is the CI lint.

## Verify

1. **Coverage**: every node in `.agent/v1.3/cli-surface.json` (root excluded) has all 3 sections.
2. **Exit-code alignment**: codes in each --help match cli-surface.json. Spot-check `spider` (0/1/2/3/4/7), `vpn rotate` (0/1/2/3/7), `auth login` (0/1/3/4), `doctor` (0/1/7).
3. **Example sanity**: examples reference real flags (no fictitious args).
4. **Lint rigor**: `help_dictionary_quality.rs` parses EXIT CODES block correctly + would fail a future drift (e.g. surface.json adds 4 to a command missing it).
5. **No behavior change**: only `long_about` + `after_help` added. No clap arg id renames, no runtime path.

## Baseline
Pre-change: 781 PASS / 0 FAIL. Post-change: 791 PASS / 0 FAIL (2 mine + 8 from concurrent Lane K test files in worktree).

## Result Format
```
METRIC: lane=G.2 round=1 verdict=<LGTM|NEEDS_CHANGES> coverage=<n>/<total> drift=<count> issues=<count>
```
Then enumerate issues. LGTM = explicit. NEEDS_CHANGES = narrow actionable list.
