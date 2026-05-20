// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 4 E2E)
//! E2E #1 (AUP enforcement): verify that `rev-stealth spider` and
//! `rev-stealth cf-evaluate` both refuse to proceed when the target URL
//! does not match any pattern in `~/.rev_scraping/authorized.toml` and
//! no env-ack / `--i-have-authorization` bypass is supplied.
//!
//! This E2E corresponds to plan §1.2 S12: AUP technical enforcement —
//! deterministic, host-independent, runs without obscura.
//!
//! Tagged `#[ignore]` per Phase 4 LGTM (opt-in via `cargo test -- --ignored`
//! or `REV_SCRAPING_RUN_LIVE=1 cargo test`).

use std::process::Command;

fn rev_stealth_bin() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

fn run_live_enabled() -> bool {
    std::env::var("REV_SCRAPING_RUN_LIVE").as_deref() == Ok("1")
}

#[test]
#[ignore]
fn aup_rejects_spider_for_unlisted_target() {
    if !run_live_enabled() {
        eprintln!("skipping: set REV_SCRAPING_RUN_LIVE=1 to enable");
    }
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://aup-unlisted.example.invalid/",
        ])
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("must spawn rev-stealth");
    assert_eq!(
        out.status.code(),
        Some(1),
        "stderr: {}\nstdout: {}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout),
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("\"ok\":false") && stdout.contains("AUP"),
        "expected AUP rejection JSON, got: {stdout}"
    );
}

#[test]
#[ignore]
fn aup_rejects_cf_evaluate_for_unlisted_target() {
    if !run_live_enabled() {
        eprintln!("skipping: set REV_SCRAPING_RUN_LIVE=1 to enable");
    }
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "cf-evaluate",
            "--url",
            "https://aup-unlisted.example.invalid/cf",
        ])
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("must spawn rev-stealth");
    assert_eq!(
        out.status.code(),
        Some(1),
        "stderr: {}\nstdout: {}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout),
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("\"ok\":false"),
        "expected JSON err payload, got: {stdout}"
    );
}

#[test]
#[ignore]
fn aup_ack_env_var_with_wrong_hash_is_rejected() {
    if !run_live_enabled() {
        eprintln!("skipping: set REV_SCRAPING_RUN_LIVE=1 to enable");
    }
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://aup-bypass.example.invalid/",
        ])
        .env("REV_SCRAPING_AUP_ACK", "0000aaaa")
        .output()
        .expect("must spawn rev-stealth");
    assert_eq!(out.status.code(), Some(1));
}
