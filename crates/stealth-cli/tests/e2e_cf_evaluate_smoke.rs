// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 4 E2E)
//! E2E #3 (cf-evaluate smoke): a deterministic smoke test for the
//! `cf-evaluate` CLI surface without spawning a real obscura subprocess.
//!
//! Strategy: we drive the CLI with a non-allowlisted URL targeting a
//! loopback address. AUP will block the call before any subprocess
//! launch happens — this proves:
//!  (a) the `cf-evaluate` subcommand is wired into the binary,
//!  (b) the JSON exit-code schema is well-formed,
//!  (c) AUP enforcement runs before obscura (the obscura binary need
//!      not exist on this host).
//!
//! A future, fully-live cf-evaluate E2E (mock httpd + built obscura)
//! is tracked in `tests/README.md`.
//!
//! Tagged `#[ignore]` per Phase 4 LGTM.

use std::process::Command;

fn rev_stealth_bin() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

#[test]
#[ignore]
fn cf_evaluate_subcommand_is_wired_and_aup_gated() {
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "cf-evaluate",
            "--url",
            "http://127.0.0.1:1/cf",
        ])
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("must spawn rev-stealth");

    // AUP rejection path: exit 1 with structured JSON.
    assert_eq!(
        out.status.code(),
        Some(1),
        "stderr: {}\nstdout: {}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout),
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("\"operation\":\"cf-evaluate\""),
        "missing operation field: {stdout}"
    );
    assert!(
        stdout.contains("\"ok\":false"),
        "missing ok=false field: {stdout}"
    );
}

#[test]
#[ignore]
fn cf_evaluate_help_is_advertised() {
    let out = Command::new(rev_stealth_bin())
        .args(["cf-evaluate", "--help"])
        .output()
        .expect("must spawn rev-stealth");
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("--url"));
    assert!(stdout.contains("--i-have-authorization"));
}
