// SPDX-License-Identifier: MIT
// Source: derived from obscura (Apache-2.0), https://github.com/h4ckf0r0day/obscura
//
// Integration test for full obscura lifecycle. Ignored by default — run with:
//
//     REV_SCRAPING_RUN_OBSCURA=1 \
//     OBSCURA_BIN=/abs/path/to/obscura \
//     cargo test -p obscura-bridge --tests -- --ignored
//
// If the binary is not present or the env flag is unset, the test skips
// gracefully so CI without the binary still passes.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use obscura_bridge::{ObscuraBridge, ObscuraConfig};

#[tokio::test]
#[ignore]
async fn ignored_obscura_lifecycle_e2e() {
    if std::env::var("REV_SCRAPING_RUN_OBSCURA").ok().as_deref() != Some("1") {
        eprintln!("skip: REV_SCRAPING_RUN_OBSCURA != 1");
        return;
    }
    let bin = std::env::var("OBSCURA_BIN")
        .ok()
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
    let _page = bridge.new_page().await.expect("new_page");

    let started = Instant::now();
    bridge.shutdown().await.expect("shutdown");
    let elapsed = started.elapsed();
    assert!(
        elapsed <= Duration::from_secs(6),
        "shutdown should complete within ~5s grace + slack, got {elapsed:?}"
    );
}
