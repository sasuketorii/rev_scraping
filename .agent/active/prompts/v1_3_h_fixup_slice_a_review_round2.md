# Lane H Fix-up Slice A — Reviewer Prompt (Round 2)

## Round 1 verdict

`BLOCK high`: live CI/scripts still invoked the removed package id
`stealth-cli`. Six call sites listed:

- `.github/workflows/ci.yml:316-317` and `:475-476`
  (`cargo build -p stealth-cli`)
- `.github/workflows/e2e-manual.yml:106`, `:140`, `:163`
  (`cargo test -p stealth-cli`)
- `scripts/cli-public-api-snapshot.sh:43`
  (`cargo build -p stealth-cli`)

The unrelated `captcha-bypass` registry-miss was correctly identified as
Slice B handoff and not part of the block.

## Round 1 → Round 2 fixes

Driver swept every `-p stealth-cli` invocation to `-p rev-stealth`:

```sh
$ grep -rn -- '-p stealth-cli' .github/ scripts/
(no matches)
```

Affected files:

- `.github/workflows/ci.yml` (2 sites)
- `.github/workflows/e2e-manual.yml` (3 sites)
- `scripts/cli-public-api-snapshot.sh` (1 site)

Path-string references like `crates/stealth-cli/**` (release.yml path
filter) and `crates/stealth-cli/tests/...` (ci.yml comment) are
deliberately preserved — the workspace directory keeps its name
`crates/stealth-cli/`; only the cargo package id changed.

Smoke checks after the sweep:

```
$ cargo build -p stealth-cli
error: package ID specification `stealth-cli` did not match any packages
help: a package with a similar name exists: `stealth-cf`

$ cargo build -p rev-stealth --quiet
(succeeds)

$ cargo test --workspace --no-fail-fast | grep -E '^test result' | awk '{p+=$4} END {print p}'
795
```

## Re-verify

Please confirm:

1. Every `cargo build|test|publish|package -p stealth-cli` is now
   `-p rev-stealth` in CI/scripts.
2. Workspace test count is still 795 (was 791 pre-slice — +4 from new
   doctests on `run` / `run_async`).
3. The captcha-bypass dry-run blocker remains the documented Slice B
   handoff (do not re-block on it).

## Verdict request

```
LGTM | LGTM with nit: ... | BLOCK <severity>: <reason>
```

Refer to the round-1 prompt at
`.agent/active/prompts/v1_3_h_fixup_slice_a_review.md` for the full
Slice A acceptance criteria.
