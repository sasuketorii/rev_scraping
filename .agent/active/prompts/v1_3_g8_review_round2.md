# Review v1.3 Lane G.8 round 2 — fixes for round-1 high findings

Round 1 raised 2 High findings (no Medium/Low). Both fixed; tests extended to lock.

## High #1: `.TH` name = leaf instead of page stem
**Round 1**: `lib.rs:637 .name(segments.last())` → `.TH login`, parent pages emit dangling `config-set(1)` cross-refs.

**Fix**: `write_man_recursive` leaks `segments.join("-")` and sets `.name(stem_leaked)`. `bin_name` keeps space-joined invocation. Reviewer rationale documented inline.

After regen: `rev-stealth-auth-login.1` → `.TH rev-stealth-auth-login 1`. `rev-stealth-config.1` SUBCOMMANDS now lists `rev\-stealth\-config\-set(1)` (resolvable).

**Lock**: new test `manpages_th_name_matches_filename_stem` — parses first token after `.TH ` and asserts equal to filename stem for every emitted `.1`.

## High #2: clap auto `help` advertised in SUBCOMMANDS
**Round 1**: walker only skipped `name == "help"` during recursion (after `Man::render`), so parent pages still emitted `rev-stealth-help(1)` / `config-help(1)` cross-refs to non-existent files.

**Fix**: `disable_help_subcommand(true)` applied at TWO layers:
1. `generate_manpages` — on the stripped root.
2. `write_man_recursive` — per-node on `cmd.clone()` before `Man::new` (clap re-injects `help` on every node with children).

Defensive `if sub.get_name() == "help" continue` stays as belt-and-suspenders.

**Lock**: new test `manpages_do_not_advertise_help_subcommand` — scans every `.1` body for `\-help(1)` substring and fails on match.

## Asks acknowledged
- **Box::leak**: reviewer OK'd; leaked stem (not leaf) per fix #1.
- **.SH EXTRA**: reviewer OK as clap_mangen 0.2 limitation; no action.
- **wipe-then-regen**: reviewer OK; no action.

## Gates PASS
- `cargo build -p rev-stealth`: clean.
- `cargo test --workspace`: **886 PASS / 0 FAIL / 38 ign**.
- `cargo test -p rev-stealth --test man_page_quality`: **7/7 PASS** (added 2 from round 1).
- `./scripts/gen_manpages.sh`: 44 pages, exit 0.
- `mandoc rev-stealth-config.1`: SUBCOMMANDS lists fully-qualified `rev-stealth-config-set(1)` etc.
- `grep -r '\\-help(1)' target/man/man1/`: empty.

## Files changed in round 2
- `crates/stealth-cli/src/lib.rs`: `generate_manpages` + `write_man_recursive` (name → stem, +disable_help_subcommand both layers).
- `crates/stealth-cli/tests/man_page_quality.rs`: +2 tests.
- `target/man/man1/*.1`: regenerated 44 (content drift, same set).

No new deps. No CI / script / .gitignore / Cargo.toml changes.

## Asks
None. Both Highs addressed via reviewer's recommended approach.
