// SPDX-License-Identifier: MIT
// Source: design adapted from Scrapling (BSD-3-Clause), https://github.com/D4Vinci/Scrapling
// No verbatim code copy; only the detection/click/polling algorithm pattern is adapted.

use async_trait::async_trait;

/// DOMRect-like bounding box returned by the page driver.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BoundingBox {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Minimal page-driver surface this crate depends on.
///
/// Phase 1a (`obscura-bridge`) will provide a concrete implementation; the
/// integration is wired up in Phase 2. The trait lets us unit-test the
/// evaluator with a fully synthetic page driver.
#[async_trait]
pub trait PageOps: Send + Sync + 'static {
    async fn evaluate(&self, js: &str) -> anyhow::Result<serde_json::Value>;
    async fn click_at(&self, x: f64, y: f64, delay_ms: u32) -> anyhow::Result<()>;
    async fn html(&self) -> anyhow::Result<String>;
    async fn title(&self) -> anyhow::Result<String>;
    async fn iframe_bounding_box(&self, selector: &str) -> anyhow::Result<Option<BoundingBox>>;
}
