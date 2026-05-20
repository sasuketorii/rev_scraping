// SPDX-License-Identifier: MIT
// Source: design adapted from Scrapling (BSD-3-Clause), https://github.com/D4Vinci/Scrapling
// No verbatim code copy; only the detection/click/polling algorithm pattern is adapted.
//
// `CfEvaluator` is a **defender-testbed** instrument: it measures how a
// Cloudflare-protected origin responds to a synthetic Turnstile interaction.
// It deliberately does not attempt to defeat real-world WAF policy — see
// `evaluate_turnstile_resilience` for the bounded interaction loop.

use std::time::{Duration, Instant};

use rand::Rng;
use tracing::{debug, info, warn};

use crate::detect::detect_from_html;
use crate::page::PageOps;
use crate::types::{ChallengeType, SolveOpts, SolveOutcome};

/// CSS selector used to locate the Turnstile challenge iframe.
///
/// Cloudflare hosts the widget at `challenges.cloudflare.com/cdn-cgi/challenge-platform/`.
pub const TURNSTILE_IFRAME_SELECTOR: &str =
    r#"iframe[src*="challenges.cloudflare.com/cdn-cgi/challenge-platform"]"#;

const INTERSTITIAL_TITLE: &str = "Just a moment...";

// Offset ranges (relative to the iframe's top-left) where the checkbox typically renders.
// Sourced as a *bounded random region* — the exact pixel position is jittered each call.
const CLICK_X_OFFSET: (f64, f64) = (26.0, 28.0);
const CLICK_Y_OFFSET: (f64, f64) = (25.0, 27.0);

/// Evaluator wrapping any [`PageOps`] implementation.
pub struct CfEvaluator<'a, P: PageOps> {
    page: &'a P,
}

impl<'a, P: PageOps> CfEvaluator<'a, P> {
    pub fn new(page: &'a P) -> Self {
        Self { page }
    }

    /// Classify the current page's challenge surface.
    pub async fn detect(&self) -> anyhow::Result<ChallengeType> {
        let html = self.page.html().await?;
        Ok(detect_from_html(&html))
    }

    /// Defender-testbed: measure resilience of the current Turnstile flow.
    ///
    /// The function performs at most `opts.max_attempts` jittered checkbox
    /// clicks within the Turnstile iframe and polls the page title until the
    /// interstitial copy disappears. The function reports an outcome rather
    /// than trying to "win" against the challenge.
    pub async fn evaluate_turnstile_resilience(
        &self,
        opts: SolveOpts,
    ) -> anyhow::Result<SolveOutcome> {
        let challenge = self.detect().await?;
        if challenge != ChallengeType::Turnstile && challenge != ChallengeType::Interstitial {
            debug!(?challenge, "no turnstile challenge — early return");
            return Ok(SolveOutcome::NonTurnstile);
        }

        for attempt in 1..=opts.max_attempts {
            info!(
                attempt,
                max = opts.max_attempts,
                "turnstile evaluation attempt"
            );

            let bbox = self
                .page
                .iframe_bounding_box(TURNSTILE_IFRAME_SELECTOR)
                .await?;

            let Some(bbox) = bbox else {
                // No iframe — if the title is already clean, treat as cleared.
                if !self.title_is_interstitial().await? {
                    return Ok(SolveOutcome::Cleared);
                }
                warn!("turnstile iframe not present yet; retrying");
                tokio::time::sleep(Duration::from_millis(opts.poll_interval_ms)).await;
                continue;
            };

            let (cx, cy, delay) = sample_click_params(&bbox, opts.jitter_ms);
            self.page.click_at(cx, cy, delay).await?;

            match self
                .wait_cleared(Duration::from_secs(opts.clear_timeout_secs))
                .await
            {
                Ok(()) => return Ok(SolveOutcome::Cleared),
                Err(e) => {
                    warn!(error = %e, attempt, "challenge did not clear within timeout");
                    if attempt == opts.max_attempts {
                        return Ok(if self.title_is_interstitial().await.unwrap_or(true) {
                            SolveOutcome::Timeout
                        } else {
                            SolveOutcome::Cleared
                        });
                    }
                }
            }
        }

        Ok(SolveOutcome::StillBlocked)
    }

    /// Poll the page title until the interstitial copy disappears, or error on timeout.
    pub async fn wait_cleared(&self, timeout: Duration) -> anyhow::Result<()> {
        let started = Instant::now();
        let poll = Duration::from_millis(250);
        loop {
            if !self.title_is_interstitial().await? {
                return Ok(());
            }
            if started.elapsed() >= timeout {
                return Err(anyhow::anyhow!(
                    "timed out waiting for cloudflare challenge to clear after {:?}",
                    timeout
                ));
            }
            tokio::time::sleep(poll).await;
        }
    }

    async fn title_is_interstitial(&self) -> anyhow::Result<bool> {
        let t = self.page.title().await?;
        Ok(t.contains(INTERSTITIAL_TITLE))
    }
}

/// Sample a jittered click coordinate inside the iframe's checkbox region.
///
/// Returned `delay_ms` is uniform in `[jitter.0, jitter.1)`. When the caller
/// passes a collapsed range (lo == hi) we return the exact value.
pub(crate) fn sample_click_params(
    bbox: &crate::page::BoundingBox,
    jitter: (u32, u32),
) -> (f64, f64, u32) {
    let mut rng = rand::thread_rng();
    let x = bbox.x + rng.gen_range(CLICK_X_OFFSET.0..CLICK_X_OFFSET.1);
    let y = bbox.y + rng.gen_range(CLICK_Y_OFFSET.0..CLICK_Y_OFFSET.1);
    let (lo, hi) = jitter;
    let delay = if lo >= hi { lo } else { rng.gen_range(lo..hi) };
    (x, y, delay)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page::{BoundingBox, PageOps};
    use async_trait::async_trait;
    use std::sync::Arc;
    use std::sync::Mutex;

    /// Programmable mock page driver.
    #[derive(Default)]
    struct MockPage {
        html: Mutex<String>,
        // Series of titles to return one-by-one. After exhaustion the last value sticks.
        title_sequence: Mutex<Vec<String>>,
        bbox: Mutex<Option<BoundingBox>>,
        clicks: Mutex<Vec<(f64, f64, u32)>>,
    }

    impl MockPage {
        fn new() -> Arc<Self> {
            Arc::new(Self::default())
        }
        fn set_html(&self, h: &str) {
            *self.html.lock().unwrap() = h.into();
        }
        fn set_titles(&self, seq: &[&str]) {
            *self.title_sequence.lock().unwrap() =
                seq.iter().rev().map(|s| s.to_string()).collect();
        }
        fn set_bbox(&self, b: BoundingBox) {
            *self.bbox.lock().unwrap() = Some(b);
        }
        fn clicks(&self) -> Vec<(f64, f64, u32)> {
            self.clicks.lock().unwrap().clone()
        }
    }

    #[async_trait]
    impl PageOps for MockPage {
        async fn evaluate(&self, _js: &str) -> anyhow::Result<serde_json::Value> {
            Ok(serde_json::Value::Null)
        }
        async fn click_at(&self, x: f64, y: f64, delay_ms: u32) -> anyhow::Result<()> {
            self.clicks.lock().unwrap().push((x, y, delay_ms));
            Ok(())
        }
        async fn html(&self) -> anyhow::Result<String> {
            Ok(self.html.lock().unwrap().clone())
        }
        async fn title(&self) -> anyhow::Result<String> {
            let mut seq = self.title_sequence.lock().unwrap();
            if seq.len() > 1 {
                Ok(seq.pop().unwrap())
            } else {
                Ok(seq.last().cloned().unwrap_or_default())
            }
        }
        async fn iframe_bounding_box(
            &self,
            _selector: &str,
        ) -> anyhow::Result<Option<BoundingBox>> {
            Ok(*self.bbox.lock().unwrap())
        }
    }

    #[test]
    fn test_jitter_range_is_within_bounds() {
        let bbox = BoundingBox {
            x: 0.0,
            y: 0.0,
            width: 300.0,
            height: 65.0,
        };
        let mut min_x = f64::MAX;
        let mut max_x = f64::MIN;
        let mut min_y = f64::MAX;
        let mut max_y = f64::MIN;
        let mut min_d = u32::MAX;
        let mut max_d = u32::MIN;
        for _ in 0..100 {
            let (x, y, d) = sample_click_params(&bbox, (100, 200));
            min_x = min_x.min(x);
            max_x = max_x.max(x);
            min_y = min_y.min(y);
            max_y = max_y.max(y);
            min_d = min_d.min(d);
            max_d = max_d.max(d);
        }
        assert!(min_x >= 26.0 && max_x < 28.0, "x range: {min_x}..{max_x}");
        assert!(min_y >= 25.0 && max_y < 27.0, "y range: {min_y}..{max_y}");
        assert!(min_d >= 100 && max_d < 200, "delay range: {min_d}..{max_d}");
    }

    #[tokio::test]
    async fn test_iframe_click_coordinates_use_box_offset() {
        let page = MockPage::new();
        page.set_html(
            r#"<html><head><script src="https://challenges.cloudflare.com/turnstile/v0/api.js"></script></head><body></body></html>"#,
        );
        // First title = interstitial (triggers click), second = cleared.
        page.set_titles(&["Just a moment...", "Hello"]);
        page.set_bbox(BoundingBox {
            x: 200.0,
            y: 400.0,
            width: 300.0,
            height: 65.0,
        });

        let evaluator = CfEvaluator::new(&*page);
        let out = evaluator
            .evaluate_turnstile_resilience(SolveOpts {
                jitter_ms: (10, 11),
                max_attempts: 1,
                poll_interval_ms: 10,
                clear_timeout_secs: 1,
            })
            .await
            .unwrap();
        assert_eq!(out, SolveOutcome::Cleared);

        let clicks = page.clicks();
        assert_eq!(clicks.len(), 1);
        let (x, y, _d) = clicks[0];
        assert!((226.0..228.0).contains(&x), "x={x} not in box.x+[26,28)");
        assert!((425.0..427.0).contains(&y), "y={y} not in box.y+[25,27)");
    }

    #[tokio::test]
    async fn test_wait_cleared_polls_and_succeeds() {
        let page = MockPage::new();
        page.set_titles(&["Just a moment...", "Hello world"]);
        let evaluator = CfEvaluator::new(&*page);
        evaluator
            .wait_cleared(Duration::from_secs(2))
            .await
            .expect("should clear");
    }

    #[tokio::test]
    async fn test_wait_cleared_timeout() {
        let page = MockPage::new();
        page.set_titles(&["Just a moment..."]);
        let evaluator = CfEvaluator::new(&*page);
        let result = evaluator.wait_cleared(Duration::from_millis(400)).await;
        assert!(result.is_err(), "expected timeout, got {:?}", result);
    }

    #[tokio::test]
    async fn test_non_turnstile_early_return() {
        let page = MockPage::new();
        page.set_html("<html><head><title>Hi</title></head><body>ok</body></html>");
        page.set_titles(&["Hi"]);
        let evaluator = CfEvaluator::new(&*page);
        let out = evaluator
            .evaluate_turnstile_resilience(SolveOpts::default())
            .await
            .unwrap();
        assert_eq!(out, SolveOutcome::NonTurnstile);
        assert!(page.clicks().is_empty(), "must not click when no challenge");
    }

    #[tokio::test]
    async fn test_detect_via_evaluator() {
        let page = MockPage::new();
        page.set_html(
            r#"<html><head><script src="https://challenges.cloudflare.com/turnstile/v0/api.js"></script></head></html>"#,
        );
        let evaluator = CfEvaluator::new(&*page);
        assert_eq!(evaluator.detect().await.unwrap(), ChallengeType::Turnstile);
    }
}
