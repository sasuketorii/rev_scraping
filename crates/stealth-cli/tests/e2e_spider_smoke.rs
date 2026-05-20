// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 2)
//! E2E smoke test: `rev-stealth spider --url <non-allowlisted>` exits 1 (AUP reject).
//!
//! This test does **not** require a running obscura subprocess; AUP enforcement
//! runs before any subprocess is spawned, so the assertion is deterministic on
//! any host. Tagged `#[ignore]` so it's opt-in (`cargo test -- --ignored`).

use std::process::Command;

fn rev_stealth_bin() -> std::path::PathBuf {
    // assert_cmd-free: locate the freshly built binary via CARGO_BIN_EXE_*.
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

#[test]
#[ignore]
fn spider_rejects_non_allowlisted_url_with_exit_1() {
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://this-host-is-definitely-not-in-anyones-allowlist.invalid/x",
        ])
        // Make sure no AUP_ACK leaks in from the caller.
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
        stdout.contains("AUP") || stdout.contains("\"ok\":false"),
        "expected AUP rejection JSON, got: {stdout}"
    );
}
