// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.0.0 (Phase 5a CDP shim e2e)
//
// Real-binary end-to-end test for the CDP shim. Verifies that
// `ObscuraBridge::launch -> new_page` no longer panics with
// `Created target not present` after the shim patches `canAccessOpener`
// onto every `Target.targetCreated` / `Target.attachedToTarget`.
//
// Ignored by default; run with:
//
//   REV_SCRAPING_RUN_OBSCURA=1 \
//   REV_STEALTH_OBSCURA=/abs/path/to/obscura \
//   cargo test -p obscura-bridge --test cdp_shim_e2e -- --ignored

use std::path::PathBuf;

use obscura_bridge::{ObscuraBridge, ObscuraConfig};

#[tokio::test]
#[ignore]
async fn cdp_shim_new_page_does_not_panic() {
    if std::env::var("REV_SCRAPING_RUN_OBSCURA").ok().as_deref() != Some("1") {
        eprintln!("skip: REV_SCRAPING_RUN_OBSCURA != 1");
        return;
    }
    let bin = std::env::var("REV_STEALTH_OBSCURA")
        .ok()
        .or_else(|| std::env::var("OBSCURA_BIN").ok())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("vendor/obscura/target/release/obscura"));
    if !bin.exists() {
        eprintln!("skip: obscura binary not found at {}", bin.display());
        return;
    }

    let cfg = ObscuraConfig {
        binary_path: bin,
        ..Default::default()
    };

    let bridge = ObscuraBridge::launch(cfg).await.expect("launch obscura");
    let fut = async {
        let page = bridge
            .new_page()
            .await
            .expect("new_page through CDP shim must succeed (no panic)");
        let url = url::Url::parse("about:blank").unwrap();
        page.navigate(&url)
            .await
            .expect("navigate about:blank should succeed");
        page
    };
    let page = tokio::time::timeout(std::time::Duration::from_secs(60), fut)
        .await
        .expect("new_page + about:blank navigate within 60s");
    let _ = page;
    bridge.shutdown().await.expect("shutdown");
}

#[tokio::test]
#[ignore]
async fn cdp_shim_navigate_example_com() {
    if std::env::var("REV_SCRAPING_RUN_OBSCURA").ok().as_deref() != Some("1") {
        eprintln!("skip: REV_SCRAPING_RUN_OBSCURA != 1");
        return;
    }
    if std::env::var("REV_SCRAPING_RUN_NETWORK").ok().as_deref() != Some("1") {
        eprintln!("skip: REV_SCRAPING_RUN_NETWORK != 1");
        return;
    }
    let bin = std::env::var("REV_STEALTH_OBSCURA")
        .ok()
        .or_else(|| std::env::var("OBSCURA_BIN").ok())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("vendor/obscura/target/release/obscura"));
    if !bin.exists() {
        eprintln!("skip: obscura binary not found at {}", bin.display());
        return;
    }
    let cfg = ObscuraConfig {
        binary_path: bin,
        ..Default::default()
    };
    let bridge = ObscuraBridge::launch(cfg).await.expect("launch obscura");
    let fut = async {
        let page = bridge.new_page().await.expect("new_page");
        let url = url::Url::parse("https://example.com").unwrap();
        page.navigate(&url).await.expect("navigate example.com");
        page
    };
    let _ = tokio::time::timeout(std::time::Duration::from_secs(60), fut)
        .await
        .expect("new_page + example.com within 60s");
    bridge.shutdown().await.expect("shutdown");
}
