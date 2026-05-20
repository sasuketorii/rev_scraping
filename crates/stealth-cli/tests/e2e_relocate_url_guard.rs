// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 4.5 hotfix)
//! Regression E2E for the `relocate --url` AUP+SSRF guard (C1 fix).
//!
//! Before the hotfix, `relocate --url` called `reqwest::get` directly,
//! bypassing both the AUP allowlist and the SSRF guard. These tests
//! exercise the full binary and assert exit code 1 for:
//!   * a non-allowlisted public URL (AUP reject path), and
//!   * an SSRF target (loopback/private IP / link-local).
//!
//! Tests run unconditionally (no `#[ignore]`): they touch no network
//! because both should be rejected *before* `reqwest::get` is reached.

use std::process::Command;

fn rev_stealth_bin() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

#[test]
fn test_relocate_url_rejects_non_allowlisted() {
    // No AUP ack, no authorization flag, no matching allowlist entry → exit 1.
    // Point HOME at an empty tempdir so any developer-machine authorized.toml
    // does not bleed in.
    let tmp = tempfile::tempdir().expect("tempdir");
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "relocate",
            "--stable-id",
            "anything",
            "--url",
            "https://aup-unlisted.example.invalid/page",
        ])
        .env("HOME", tmp.path())
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("must spawn rev-stealth");
    assert_eq!(
        out.status.code(),
        Some(1),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("\"ok\":false") && stdout.contains("AUP"),
        "expected AUP rejection JSON, got: {stdout}"
    );
}

#[test]
fn test_relocate_url_rejects_ssrf() {
    // Use --i-have-authorization to skip AUP, then assert SSRF guard
    // rejects a loopback target with exit 1 and a "SSRF guard" message.
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "relocate",
            "--stable-id",
            "anything",
            "--url",
            "http://127.0.0.1/admin",
            "--i-have-authorization",
        ])
        .output()
        .expect("must spawn rev-stealth");
    assert_eq!(
        out.status.code(),
        Some(1),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("\"ok\":false") && stdout.contains("SSRF"),
        "expected SSRF rejection JSON, got: {stdout}"
    );
}

#[test]
fn test_relocate_url_rejects_invalid_url_syntax() {
    // Bad URL syntax must be rejected with exit 1 before any AUP/SSRF/fetch.
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "relocate",
            "--stable-id",
            "anything",
            "--url",
            "not-a-url",
        ])
        .output()
        .expect("must spawn rev-stealth");
    assert_eq!(out.status.code(), Some(1));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("invalid url"),
        "expected invalid-url JSON, got: {stdout}"
    );
}

#[test]
fn test_spider_invalid_url_rejected_before_aup() {
    // Spider must reject bogus URL syntax with exit 1 + an "invalid url"
    // error message, NOT an "AUP: …" message (URL parse runs first).
    let tmp = tempfile::tempdir().expect("tempdir");
    let out = Command::new(rev_stealth_bin())
        .args(["--format", "json", "spider", "--url", "::: not a url :::"])
        .env("HOME", tmp.path())
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("must spawn rev-stealth");
    assert_eq!(out.status.code(), Some(1));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("invalid url"),
        "expected invalid-url before AUP, got: {stdout}"
    );
    assert!(
        !stdout.contains("AUP:"),
        "AUP error should not appear before URL parse: {stdout}"
    );
}

#[test]
fn test_json_format_propagates_exit_code() {
    // H1: --format json must still propagate the underlying non-zero exit
    // code to the OS process status, not silently exit 0.
    let tmp = tempfile::tempdir().expect("tempdir");
    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://aup-unlisted.example.invalid/x",
        ])
        .env("HOME", tmp.path())
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("must spawn rev-stealth");
    assert_eq!(
        out.status.code(),
        Some(1),
        "JSON-format error path must propagate exit 1, got {:?}",
        out.status.code()
    );
}
