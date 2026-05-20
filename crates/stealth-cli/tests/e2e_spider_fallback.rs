// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 5b HTTP fallback E2E)
//! E2E: `rev-stealth spider --http-only` against a real allowlisted host.
//!
//! Tagged `#[ignore]` because it requires:
//!   - network connectivity to rev-c.com
//!   - a temporary AUP allowlist entry for `rev-c.com`
//!
//! Run with:
//!   cargo test --test e2e_spider_fallback -- --ignored test_rev_c_blog_via_fallback

use std::process::Command;

fn rev_stealth_bin() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

#[test]
#[ignore]
fn test_rev_c_blog_via_fallback() {
    // Write a temp authorized.toml so the AUP allowlist accepts rev-c.com
    // without polluting the user's real config.
    let tmp = tempfile::tempdir().expect("tempdir");
    let cfg_dir = tmp.path().join(".rev_scraping");
    std::fs::create_dir_all(&cfg_dir).unwrap();
    let auth = cfg_dir.join("authorized.toml");
    std::fs::write(
        &auth,
        r#"
[[targets]]
url_pattern = "^https://company\\.rev-c\\.com/"
note = "e2e fallback test"
"#,
    )
    .unwrap();

    let out = Command::new(rev_stealth_bin())
        .env("HOME", tmp.path())
        .env_remove("REV_SCRAPING_AUP_ACK")
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://company.rev-c.com/blog/",
            "--http-only",
            // Phase 6c: this E2E pre-dates the fail-closed VPN guard.
            // It deliberately exercises the http-only path without a
            // VPN. Explicitly opt out so the default-on policy doesn't
            // turn this into an exit-7.
            "--allow-no-vpn",
        ])
        .output()
        .expect("spawn rev-stealth");

    let stdout = String::from_utf8_lossy(&out.stdout);
    eprintln!("STDOUT: {stdout}");
    eprintln!("STDERR: {}", String::from_utf8_lossy(&out.stderr));

    assert_eq!(out.status.code(), Some(0), "spider must exit 0");

    let v: serde_json::Value =
        serde_json::from_str(stdout.lines().last().unwrap_or("{}")).expect("valid json");
    let r = &v["result"];
    assert_eq!(r["fetcher"].as_str(), Some("http-only"));
    assert_eq!(r["http_status"].as_u64(), Some(200));
    assert!(
        r["html_size"].as_u64().unwrap_or(0) > 50_000,
        "html_size {:?} too small",
        r["html_size"]
    );
    assert_eq!(r["used_fallback"].as_bool(), Some(true));
}
