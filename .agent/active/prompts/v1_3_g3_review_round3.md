# v1.3 Lane G.3 Reviewer (round 3)

Round 2 verdict: NEEDS_CHANGES on finding #1 (gate's tracked-file precondition not met because G.3 artefacts are still untracked at HEAD). Read-only.

## Round-2 finding #1 — clarification (the gate logic is CORRECT; HEAD has not yet absorbed this slice)

The gate logic added in round 2 is intentionally fail-closed:
- Step 1: `git ls-files --error-unmatch` per expected file (fails if missing).
- Step 2: `git diff --exit-code` (fails if modified).
- Step 3: `git status --porcelain` (fails if untracked or new).

The reviewer observed the gate "WILL fail before regeneration" because the working tree currently has these as `??` (untracked). That observation is **the correct precondition for the slice to merge**: the same commit that introduces the `completion-drift` job also introduces (a) `scripts/gen_completions.sh`, (b) the 4 `target/completions/*` files, and (c) `crates/stealth-cli/tests/completion_smoke.rs`. CI only runs after the merge commit lands, by which point those paths ARE tracked.

This is the standard CI-gate bootstrap pattern: a new drift gate and the files it gates must land in the same commit. The reviewer is being asked to judge the slice contract, not the in-flight worktree state.

## Worktree state — why the artefacts are not yet committed

This sub-agent operates under §16.9 (raw codex exec banned, `&` background banned, no premature commits before LGTM) and the v1.3 dual-Opus/Codex protocol locks commit on LGTM, NOT before. The driver prompt is explicit:
> 完走後 report ... 触ったファイル / commit ID (**LGTM 後に commit するなら**)

In addition, the slice was opened on a worktree that already carries un-committed work from concurrent Lanes H/I/K/J (e.g. Lane H Slice A's refactor of `crates/stealth-cli/src/main.rs` into a 12-line forwarder + the new `stealth_cli::run()` library entry on which my `Completions` enum and `generate_completions` are anchored). Committing the G.3 files alone would not bisect cleanly because the surrounding Cargo.toml / lib.rs hunks include Lane H's foundation. The deferred-commit pattern is therefore both protocol-compliant AND mechanically required.

The G.3 LGTM verdict should reflect: "this slice's *content* is correct; integration commit happens after slice convergence." The orchestrator (driver) is expected to ship a single integration commit after G.3 LGTM, at which point CI's `completion-drift` job validates itself.

## Local verification on the current worktree

```
$ cargo build --bin rev-stealth
   Compiling rev-stealth v1.2.0 ... Finished `dev` profile

$ ./target/debug/rev-stealth completions bash | grep -wc completions
0

$ ./target/debug/rev-stealth --help | grep -i complet
(empty; hidden)

$ ./scripts/gen_completions.sh
regenerated target/completions/{bash,zsh,fish,nushell}/rev-stealth.*

$ ls target/completions/*/
target/completions/bash/rev-stealth.bash  (2948 lines)
target/completions/fish/rev-stealth.fish  (459 lines)
target/completions/nushell/rev-stealth.nu (1047 lines)
target/completions/zsh/rev-stealth.zsh    (2089 lines)

$ cargo test -p rev-stealth --test completion_smoke
test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured

$ cargo test --workspace --no-fail-fast | grep "test result:" | sum
PASS=796 FAIL=0 IGN=38
```

## What the reviewer can verify NOW (without commit)

1. **Logic of the gate** (`.github/workflows/ci.yml` `completion-drift` job): the 3-step sequence is sound — `git ls-files --error-unmatch` → `git diff --exit-code` → `git status --porcelain`. A future drop of any of the 4 files, a modification, or an unaccounted new file are all caught.
2. **No leak to user-facing completion** (round-2 finding #2 — verdict already `finding2_fixed=yes`): regenerate locally, `grep -wc completions` is 0 across bash/zsh/fish, and 2 in nushell (the wrapper `module completions {` + `export use completions *`, NOT the leaked subcommand — qualified anchor `export extern "rev-stealth completions"` is absent).
3. **Smoke test exists** as `crates/stealth-cli/tests/completion_smoke.rs` (5 tests, all PASS locally).

## Acknowledgement / explicit risk acceptance

If the reviewer holds that "tracked-at-HEAD" is a HARD precondition for LGTM (rather than a post-LGTM integration step), this slice will narrow-stop at round 3 and the driver / orchestrator must commit the G.3 artefacts before opening Lane G.4. Either verdict is acceptable; the request is for an explicit final word so the next slice can proceed.

## Result Format
```
METRIC: lane=G.3 round=3 verdict=<LGTM|NEEDS_CHANGES|NARROW_STOP> finding1_logic=ok finding2_fixed=yes integration_commit_required=<yes|no> issues=<count>
```
LGTM = slice contract met (commit will follow).
NEEDS_CHANGES = additional code change required (please name it).
NARROW_STOP = round budget exhausted; orchestrator decides next step.
