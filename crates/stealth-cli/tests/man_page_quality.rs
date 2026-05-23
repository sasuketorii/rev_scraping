// SPDX-License-Identifier: MIT
//! Lane G.8 (v1.3 Black-Belt CLI): man page quality smoke test.
//!
//! Drives `rev-stealth manpages <tmp>` and asserts that every emitted `.1`
//! file:
//!
//!   1. Begins with the roff `.TH` (title heading) macro — so it is a
//!      well-formed man source, not an empty file or stray cargo chatter.
//!   2. Contains the four roff section headers that clap_mangen renders for
//!      every command: `.SH NAME`, `.SH SYNOPSIS`, `.SH DESCRIPTION`,
//!      `.SH OPTIONS`. The top-level page additionally has `.SH SUBCOMMANDS`
//!      + `.SH VERSION`; per-subcommand pages with `after_help` carry the
//!      EXAMPLES / EXIT CODES / ENV content inside a single `.SH EXTRA`
//!      section. We assert both shapes.
//!   3. Carries the canonical `rev-stealth` bin-name in the NAME section
//!      header, so a renamed binary would loudly break this test before the
//!      CI drift gate diffs `target/man/`.
//!
//! The CI `manpage-drift` job already gates byte-level drift against the
//! committed `target/man/man1/` tree; this test gives a faster local signal
//! when the clap surface or `clap_mangen::Man::render` plumbing changes
//! before the committed files have been refreshed.
//!
//! Also locks the hidden-subcommand stripping contract (`completions`,
//! `manpages`): no `.1` file for those internal commands should exist after
//! generation — same invariant the bash/zsh/fish/nushell completion tests
//! enforce for shell completions.

use std::process::{Command, Stdio};

/// Run `cargo run --bin rev-stealth -- manpages <dir>` against a temp
/// directory and return its absolute path. Panics on non-zero exit; the test
/// is allowed to be loud because a regression here means the CommandFactory
/// + clap_mangen wiring is broken.
fn gen_into_tempdir() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().expect("create tempdir for man-page output");
    let out = Command::new(env!("CARGO"))
        .args([
            "run",
            "--quiet",
            "--bin",
            "rev-stealth",
            "--",
            "manpages",
            tmp.path()
                .to_str()
                .expect("tempdir path must be UTF-8 for argv"),
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("cargo run rev-stealth manpages <dir> spawnable");
    assert!(
        out.status.success(),
        "manpages exited non-zero: stderr={}",
        String::from_utf8_lossy(&out.stderr)
    );
    tmp
}

/// Enumerate every `.1` file in `dir`. Returns sorted file names (not paths)
/// so the assertion messages are stable across machines.
fn collect_man_files(dir: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .expect("read man-page output dir")
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".1"))
        .collect();
    names.sort();
    names
}

#[test]
fn manpages_emits_top_level_and_per_subcommand_files() {
    let tmp = gen_into_tempdir();
    let names = collect_man_files(tmp.path());
    // Top-level + 11 public subcommands + sub-subcommands. The exact count
    // depends on the clap tree (44 at the time of writing), so we sanity
    // check a lower bound rather than the exact value — the
    // `manpage-drift` CI gate locks the exact set byte-for-byte.
    assert!(
        names.len() >= 20,
        "expected >= 20 man pages, got {}: {:?}",
        names.len(),
        names
    );
    assert!(
        names.contains(&"rev-stealth.1".to_string()),
        "missing top-level rev-stealth.1: {names:?}"
    );
    // Anchor checks: a representative leaf in each of the major subcommand
    // families (G.5 mutate commands, G.2 documented surfaces).
    for required in [
        "rev-stealth-spider.1",
        "rev-stealth-doctor.1",
        "rev-stealth-config-set.1",
        "rev-stealth-auth-login.1",
        "rev-stealth-vpn-rotate.1",
        "rev-stealth-hermes-install.1",
    ] {
        assert!(
            names.contains(&required.to_string()),
            "missing required man page {required}: {names:?}"
        );
    }
}

#[test]
fn manpages_have_well_formed_roff_structure() {
    let tmp = gen_into_tempdir();
    for name in collect_man_files(tmp.path()) {
        let path = tmp.path().join(&name);
        let body = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("read {name}: {e}"));
        // clap_mangen emits a small roff-portability prelude (`.ie \n(.g .ds
        // Aq \(aq` apostrophe-fallback macro etc.) before the `.TH` title
        // heading, so we look for `.TH ` anywhere in the first ~10 lines
        // rather than at the literal byte-0 of the file.
        let head: String = body.lines().take(20).collect::<Vec<_>>().join("\n");
        assert!(
            head.lines().any(|l| l.starts_with(".TH ")),
            "{name} must contain `.TH ` (roff title heading) in its prelude, got: {head}"
        );
        // Every clap_mangen-rendered page carries these four sections.
        for required_sh in [".SH NAME", ".SH SYNOPSIS", ".SH DESCRIPTION", ".SH OPTIONS"] {
            assert!(
                body.lines().any(|l| l == required_sh),
                "{name} missing required section {required_sh}"
            );
        }
    }
}

#[test]
fn manpages_subcommand_with_after_help_carries_examples_exit_env() {
    // G.2 documented surfaces have EXAMPLES / EXIT CODES / ENV blocks inside
    // clap's `after_help`. clap_mangen folds those into a single
    // `.SH EXTRA` section verbatim. Pick one well-known surface and lock the
    // three textual markers — if a future clap_mangen bump splits these into
    // separate sections, this test will guide the migration.
    let tmp = gen_into_tempdir();
    let body = std::fs::read_to_string(tmp.path().join("rev-stealth-spider.1"))
        .expect("read rev-stealth-spider.1");
    assert!(
        body.contains(".SH EXTRA"),
        "rev-stealth-spider.1 must have `.SH EXTRA` section (clap_mangen renders \
after_help here): body sections = {:?}",
        body.lines()
            .filter(|l| l.starts_with(".SH "))
            .collect::<Vec<_>>()
    );
    for marker in ["EXAMPLES:", "EXIT CODES:", "ENV:"] {
        assert!(
            body.contains(marker),
            "rev-stealth-spider.1 EXTRA section must include `{marker}` marker"
        );
    }
}

#[test]
fn manpages_top_level_has_subcommands_section() {
    // The root `rev-stealth.1` page enumerates its public subcommands in a
    // `.SH SUBCOMMANDS` section. Lock that contract — if the
    // `strip_internal_subcommands` walker accidentally hides a real
    // user-facing subcommand, this test would catch it.
    let tmp = gen_into_tempdir();
    let body = std::fs::read_to_string(tmp.path().join("rev-stealth.1"))
        .expect("read rev-stealth.1");
    assert!(
        body.contains(".SH SUBCOMMANDS"),
        "rev-stealth.1 must contain `.SH SUBCOMMANDS` listing public commands"
    );
    // Spot-check a few user-facing subcommand names that must appear in the
    // SUBCOMMANDS section. We do not enforce the full list — that's the
    // job of the byte-level CI drift gate.
    for name in ["spider", "doctor", "config", "auth", "vpn"] {
        assert!(
            body.contains(name),
            "rev-stealth.1 SUBCOMMANDS must mention `{name}`"
        );
    }
}

#[test]
fn manpages_th_name_matches_filename_stem() {
    // Round-1 reviewer (G.8) finding #1: `clap_mangen::Man::render` writes
    // the `Command::name` verbatim into the `.TH` title heading AND into
    // every parent-page subcommand cross-reference. The walker must set
    // `name` to the FULL dash-joined page stem so:
    //   1. `man rev-stealth-auth-login` finds the right title;
    //   2. `whatis rev-stealth-auth-login` shows the right one-liner;
    //   3. Parent pages render `rev-stealth-config-set(1)` (resolvable)
    //      not `config-set(1)` (dangling cross-ref).
    let tmp = gen_into_tempdir();
    for name in collect_man_files(tmp.path()) {
        let body = std::fs::read_to_string(tmp.path().join(&name))
            .unwrap_or_else(|e| panic!("read {name}: {e}"));
        let stem = name.trim_end_matches(".1");
        // `.TH <stem> 1 ...` — the first whitespace-separated token after
        // `.TH ` MUST equal the filename stem.
        let th_line = body
            .lines()
            .find(|l| l.starts_with(".TH "))
            .unwrap_or_else(|| panic!("{name} missing `.TH ` line"));
        let th_name = th_line
            .strip_prefix(".TH ")
            .and_then(|rest| rest.split_whitespace().next())
            .unwrap_or("<none>");
        assert_eq!(
            th_name, stem,
            "{name}: `.TH` name `{th_name}` must equal filename stem `{stem}` \
             (else `man`/`whatis` lookups break and parent cross-refs dangle)"
        );
    }
}

#[test]
fn manpages_do_not_advertise_help_subcommand() {
    // Round-1 reviewer (G.8) finding #2: clap auto-injects a `help`
    // subcommand on every node with children. The walker disables it via
    // `disable_help_subcommand(true)` per-node so the parent's `.SH
    // SUBCOMMANDS` block does NOT advertise dangling `*-help(1)` cross-refs
    // (no corresponding `.1` file is emitted). Lock that contract.
    let tmp = gen_into_tempdir();
    for name in collect_man_files(tmp.path()) {
        let body = std::fs::read_to_string(tmp.path().join(&name))
            .unwrap_or_else(|e| panic!("read {name}: {e}"));
        // clap_mangen renders subcommand cross-refs as
        // `rev\-stealth\-<sub>(1)` with literal `\-` dash escapes inside a
        // `.SH SUBCOMMANDS` block. A leaked `help` would appear as
        // `rev\-stealth\-help(1)` or `rev\-stealth\-<sub>\-help(1)`.
        for line in body.lines() {
            assert!(
                !line.contains("\\-help(1)"),
                "{name} advertises dangling `*-help(1)` cross-ref: {line}"
            );
        }
    }
}

#[test]
fn manpages_does_not_leak_internal_subcommands() {
    // Mirror of completion_smoke.rs's leak test: the hidden `completions`
    // and `manpages` subcommands must not appear as their own .1 files,
    // and the root SUBCOMMANDS list must not advertise them.
    let tmp = gen_into_tempdir();
    let names = collect_man_files(tmp.path());
    for leaked in [
        "rev-stealth-completions.1",
        "rev-stealth-manpages.1",
        "rev-stealth-help.1",
    ] {
        assert!(
            !names.contains(&leaked.to_string()),
            "internal/help subcommand leaked into man pages: {leaked}"
        );
    }
    let root = std::fs::read_to_string(tmp.path().join("rev-stealth.1"))
        .expect("read rev-stealth.1");
    // The root page renders subcommand names with surrounding roff `\fB ... \fR`
    // bold markers. Match on a word-boundary substring to avoid false positives
    // from a different command's description text mentioning the word.
    for hidden in ["\\fBcompletions\\fR", "\\fBmanpages\\fR"] {
        assert!(
            !root.contains(hidden),
            "root rev-stealth.1 SUBCOMMANDS advertises hidden subcommand: {hidden}"
        );
    }
}
