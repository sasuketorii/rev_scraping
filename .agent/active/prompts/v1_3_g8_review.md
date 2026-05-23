# Review v1.3 Lane G.8 — man page auto-generation

Lane G final sub-phase. `clap_mangen` 0.2 roff(7) man(1) pages for `rev-stealth`
+ all public subcommands → `target/man/man1/`. Gated by new `manpage-drift`
CI job mirroring G.3 `completion-drift`.

## Files
- `Cargo.toml` (ws) + `crates/stealth-cli/Cargo.toml`: `clap_mangen = "0.2"` (workspace dep).
- `crates/stealth-cli/src/lib.rs`: hidden `Manpages(ManpagesArgs)` + `generate_manpages` + `write_man_recursive` (DFS, one `.1` per node, skip clap-auto `help`). `INTERNAL_HIDDEN_SUBCOMMANDS` += `"manpages"`.
- `scripts/gen_manpages.sh`: wipe-then-regen via `cargo run -q --bin rev-stealth -- manpages target/man/man1`.
- `.github/workflows/ci.yml`: `manpage-drift` job — 7-anchor tracking + regen + `git diff --exit-code` + `git status --porcelain` (mirrors G.3).
- `.gitignore`: `!/target/man/` carve-out.
- `crates/stealth-cli/tests/man_page_quality.rs`: 5 tests.
- `target/man/man1/*.1`: 44 committed files.

## Section coverage
clap_mangen 0.2 folds `after_help` into one `.SH EXTRA` verbatim (no 0.2 API to split). Root=6 SH (NAME/SYN/DESC/OPTS/SUBCOMMANDS/VERSION), sub=5 SH with EXAMPLES/EXIT/ENV markers preserved inside EXTRA.

Tests assert: `.TH ` prelude + 4 always-SH + spider EXTRA's 3 markers + root SUBCOMMANDS + hidden/help leak prevention (mirrors G.3 round-1 #2).

## Gates PASS
- `cargo build -p rev-stealth`: clean (1 pre-existing G.6 dead_code, unchanged).
- `cargo test --workspace`: **882 PASS / 0 FAIL / 38 ign** (baseline 877 + 5 new).
- `cargo test -p rev-stealth --test man_page_quality`: 5/5 PASS.
- `./scripts/gen_manpages.sh`: 44 pages, exit 0.
- `mandoc rev-stealth-spider.1`: clean render, all G.2 sections visible.

## Asks
1. `Box::leak` for per-node `name`/`bin_name` (clap `Str: From<&'static str>` only) — mirrors G.3 `strip_internal_subcommands`. OK?
2. 5-section EXTRA vs 6-SH spec — clap_mangen 0.2 API limit. OK or follow-up issue?
3. `wipe-then-regen` in script (vs G.3 per-file overwrite) — handles stale orphans locally. OK?

## Scope
release.yml install-step → Lane H. G.7 round-5 verify parallel; G.8 only touches `lib.rs` (no G.7 collision). Lane H B-3 `f2cd477` workspace alias scheme preserved.
