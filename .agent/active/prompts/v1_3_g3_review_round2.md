# v1.3 Lane G.3 Reviewer (round 2)

Round 1 verdict: NEEDS_CHANGES (2 findings). Both addressed below. Read-only.

## Round 1 finding 1 — drift gate missed untracked files

`.github/workflows/ci.yml` `completion-drift` job now has 3 sequential steps:

1. **`assert all 4 completion files are tracked`** — iterates the 4 expected paths and runs `git ls-files --error-unmatch -- <f>` on each. Fails closed if any file is not tracked (catches accidental deletion of a committed completion).
2. **`diff committed vs regenerated (modifications)`** — original `git diff --exit-code -- target/completions/` (catches tracked-file modification drift).
3. **`diff committed vs regenerated (untracked / additions)`** — `git status --porcelain -- target/completions/`, fails if output is non-empty (catches generator producing NEW files, e.g. someone adds a 5th shell to the gen script without committing its output).

## Round 1 finding 2 — hidden `completions` leaked into completion output

Root cause: `#[command(hide = true)]` suppresses `--help`, but `clap_complete::generate` walks the full subcommand tree regardless. clap 4.x has no public API to remove a subcommand from a `Command`.

Fix: new `strip_internal_subcommands()` in `crates/stealth-cli/src/lib.rs`:
- Rebuilds a fresh `clap::Command` cloning name + about + long_about + version + top-level args from `Cli::command()`, then re-attaches only the subcommands NOT in `INTERNAL_HIDDEN_SUBCOMMANDS = &["completions"]`.
- `generate_completions()` now passes `strip_internal_subcommands(Cli::command())` to `clap_complete::generate`.
- `name`/`version` strings flow through `Box::leak` because `clap::builder::Str: From<&'static str>` only (one-time leak per process invocation; the generator runs ~10ms).

`rev-stealth --help` still hides `completions`; `rev-stealth completions <shell>` still callable (parse path untouched).

Verification — token count of standalone `completions` in regenerated output:

| shell  | before | after |
|--------|--------|-------|
| bash   | 8      | 0     |
| zsh    | 8      | 0     |
| fish   | 6      | 0     |
| nushell| 4      | 2 (`module completions` + `export use completions *` — generator's own container, not the leaked subcommand) |

New lock test in `completion_smoke.rs`: `completions_does_not_leak_internal_subcommand` asserts the user-facing leak patterns are absent across all 4 shells (bash `opts=` lines, fish `-a "completions"`, zsh `'completions:`, nushell `export extern "rev-stealth completions"`).

All committed `target/completions/*` files regenerated against the stripped tree.

## Changes vs round 1
```
git diff -- crates/stealth-cli/src/lib.rs \
            crates/stealth-cli/tests/completion_smoke.rs \
            .github/workflows/ci.yml \
            target/completions/
```

## Verify
1. CI drift gate now catches: (a) missing committed file via `git ls-files --error-unmatch`, (b) modified content via `git diff --exit-code`, (c) untracked additions via `git status --porcelain`.
2. `rev-stealth --help` does NOT mention `completions` (still hidden).
3. `rev-stealth completions bash | grep -w completions` → empty.
4. Smoke test count: 4 → 5 (added `completions_does_not_leak_internal_subcommand`).
5. `INTERNAL_HIDDEN_SUBCOMMANDS = &["completions"]` is a named extension point — future internal subcommands opt in by name addition only.

## Baseline
- Round 1: 795 PASS / 0 FAIL
- Round 2: 796 PASS / 0 FAIL / 38 IGN (+1: new leak-lock test)

## Result Format
```
METRIC: lane=G.3 round=2 verdict=<LGTM|NEEDS_CHANGES> finding1_fixed=yes finding2_fixed=yes leak_count_after=0 issues=<count>
```
LGTM = explicit. NEEDS_CHANGES = narrow actionable list.
