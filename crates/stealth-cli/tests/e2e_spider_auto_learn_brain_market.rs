// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 7c auto-learn E2E).
//
// Runs the spider against brain-market.com with an empty recipe dir and
// asserts that the post-render recipe contains the auto-discovered
// `/v2/users/{username}/articles` (or `{slug}`) endpoint shape. Marked
// `#[ignore]` because it requires network egress + a real obscura binary.
//   cargo test -p stealth-cli --test e2e_spider_auto_learn_brain_market -- --ignored

use std::process::Command;

fn rev_stealth_bin() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

#[test]
#[ignore]
fn test_brain_market_auto_discovers_user_articles_endpoint() {
    let tmp = tempfile::tempdir().expect("tempdir");

    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "spider",
            "--url",
            "https://brain-market.com/u/fujin_metaverse/",
            "--allow-no-vpn",
            "--i-have-authorization",
            "--recipe-dir",
            tmp.path().to_str().unwrap(),
            "--wait-ms",
            "4000",
        ])
        .env_remove("REV_SCRAPING_AUP_ACK")
        .output()
        .expect("spawn rev-stealth");

    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(
        out.status.code(),
        Some(0),
        "expected exit 0; stderr={stderr} stdout={stdout}"
    );

    let recipe_path = tmp.path().join("brain-market.com.toml");
    assert!(
        recipe_path.exists(),
        "recipe should have been written at {}",
        recipe_path.display()
    );
    let body = std::fs::read_to_string(&recipe_path).expect("read recipe");
    assert!(
        body.contains("/v2/users/")
            && (body.contains("/articles")
                || body.contains("{username}")
                || body.contains("{slug}")),
        "expected /v2/users/.../articles in recipe; got: {body}"
    );
}
