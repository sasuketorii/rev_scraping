# v1.3 Lane G.3 Reviewer (round 1)

You are the Codex reviewer for Lane G.3 — shell-completion auto-gen + CI drift gate. G.1/G.2 LGTM. Read-only.

## Spec
- Wire `clap_complete` (+ `clap_complete_nushell`) into `rev-stealth`.
- Hidden `rev-stealth completions <shell>` drives `clap_complete::generate` off `Cli::command()` (CommandFactory directly — NOT by spawning `target/debug/`).
- Shells: `bash`, `zsh`, `fish`, `nushell`.
- `scripts/gen_completions.sh` → `target/completions/{bash,zsh,fish,nushell}/rev-stealth.{bash,zsh,fish,nu}` (committed).
- CI `completion-drift` job: regen + `git diff --exit-code`.

Lane H Slice A moved CLI to `crates/stealth-cli/src/lib.rs::run()`; my additions land there.

## Changes
```
git diff 9bed4df -- \
  Cargo.toml crates/stealth-cli/Cargo.toml \
  crates/stealth-cli/src/lib.rs \
  scripts/gen_completions.sh .gitignore .github/workflows/ci.yml \
  crates/stealth-cli/tests/completion_smoke.rs
git status target/completions/   # 4 new files
```

## Verify
1. **CommandFactory direct**: `generate_completions` uses `Cli::command()`. No spawn of `target/debug/rev-stealth`. `gen_completions.sh` uses `cargo run -q` (same library).
2. **Hidden**: `Completions(...)` has `#[command(hide=true)]`. NOT in `.agent/v1.3/cli-surface.json` — G.2 dictionary lint still passes.
3. **Shells**: bash/zsh/fish via `clap_complete::shells::*`, nushell via `clap_complete_nushell::Nushell`. Extensions `.bash/.zsh/.fish/.nu`.
4. **Determinism**: `cargo run -q ... 2>/dev/null` — no cargo chatter in output. Re-running yields empty `git diff` (verified locally).
5. **.gitignore**: `/target` replaced by `/target/*` so `!/target/completions/` can un-include. Old `**/target/` glob removed (it shadowed the carve-out). `git check-ignore target/completions/...` → exit 1; `git check-ignore target/debug/` → exit 0.
6. **CI gate**: `completion-drift` job placed between `# I.6:` comment and `changelog-lint`. `ubuntu-22.04` + `Swatinem/rust-cache@v2` consistent with siblings.
7. **Smoke test**: `completion_smoke.rs` covers 4 shells via `cargo run --quiet --bin rev-stealth -- completions <shell>`. Asserts bash `_rev-stealth` + `complete -F`, zsh `#compdef rev-stealth`, fish `complete -c rev-stealth`, nushell `module completions` + `export extern rev-stealth [`.
8. **No regression**: 791 → 795 PASS / 0 FAIL (+4 mine). fmt/clippy clean for files I touched. Pre-existing `deprecated_completeness.rs:54` clippy::manual_contains is from commit 7c700a0b (NOT this slice).

## Baseline
- Pre-G.3: 791 PASS / 0 FAIL
- Post-G.3: 795 PASS / 0 FAIL / 38 IGN

## Result Format
```
METRIC: lane=G.3 round=1 verdict=<LGTM|NEEDS_CHANGES> shells=4 drift_gate=yes smoke_tests=4 issues=<count>
```
LGTM = explicit. NEEDS_CHANGES = narrow actionable list.
