// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 7b spider recipe E2E).
//
// E2E smoke for the Phase 7b recipe-aware spider against brain-market.com.
// Both tests are `#[ignore]` because they require network egress; run with
//   cargo test -p stealth-cli --test e2e_spider_recipe_brain_market -- --ignored

use std::process::Command;

fn rev_stealth_bin() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

fn template_dir() -> std::path::PathBuf {
    // CARGO_MANIFEST_DIR = crates/stealth-cli; templates live two levels up.
    let mut p = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.pop();
    p.pop();
    p.join("templates").join("sites")
}

/// Copy the bundled brain-market recipe template into a tempdir so the spider
/// hits a real, recognized recipe and takes the API-direct path. Asserts the
/// JSON contains `recipe.hit=true` and `recipe.fetched_via="api"`.
#[test]
#[ignore]
fn test_brain_market_api_path_via_recipe() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let src = template_dir().join("brain-market.com.example.toml");
    let dst = tmp.path().join("brain-market.com.toml");
    std::fs::copy(&src, &dst).expect("copy template");

    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://brain-market.com/u/fujin_metaverse/",
            "--recipe-endpoint",
            "user_articles",
            "--recipe-param",
            "username=fujin_metaverse",
            "--allow-no-vpn",
            "--i-have-authorization",
            "--recipe-dir",
            tmp.path().to_str().unwrap(),
        ])
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("spawn rev-stealth");

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert_eq!(
        out.status.code(),
        Some(0),
        "expected exit 0; stderr={} stdout={}",
        String::from_utf8_lossy(&out.stderr),
        stdout,
    );
    assert!(stdout.contains("\"hit\":true"), "stdout: {stdout}");
    assert!(
        stdout.contains("\"fetched_via\":\"api\""),
        "stdout: {stdout}"
    );
}

/// First-visit skeleton save: empty recipe dir + http-only fetch → after a
/// successful run, a recipe file should exist for the host. Network-dependent.
#[test]
#[ignore]
fn test_brain_market_skeleton_save_on_first_visit() {
    let tmp = tempfile::tempdir().expect("tempdir");

    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://example.com/",
            "--allow-no-vpn",
            "--i-have-authorization",
            "--http-only",
            "--recipe-dir",
            tmp.path().to_str().unwrap(),
        ])
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("spawn rev-stealth");

    let code = out.status.code().unwrap_or(-1);
    assert!(code == 0 || code == 2, "exit was {code}");

    if code == 0 {
        let p = tmp.path().join("example.com.toml");
        assert!(
            p.exists(),
            "skeleton recipe should have been saved at {}",
            p.display()
        );
    }
}
