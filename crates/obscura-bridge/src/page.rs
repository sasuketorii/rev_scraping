// SPDX-License-Identifier: MIT
// Source: derived from obscura (Apache-2.0), https://github.com/h4ckf0r0day/obscura

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chromiumoxide::cdp::browser_protocol::network::{
    EnableParams, EventRequestWillBeSent, EventResponseReceived,
};
use chromiumoxide::Page as CdpPage;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use url::Url;

use crate::error::{BridgeError, Result};
use crate::network_capture::{CapturedRequest, NetworkCapture};
use crate::ssrf;

/// CDP target-id alias (newtype around String for clarity in signatures).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TargetId(pub String);

/// CDP DOM nodeId (i64 per the protocol).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct NodeId(pub i64);

/// Result of a `navigate()` call.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NavResult {
    pub final_url: String,
    pub http_status: Option<u16>,
}

/// Lightweight DOM snapshot returned by `dom_snapshot()`. Phase 1a returns the
/// outer HTML of `document.documentElement`; richer accessors land in later
/// phases together with `stealth-parse`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DomSnapshot {
    pub url: String,
    pub html: String,
}

/// Handle to a single CDP page/target owned by an [`super::ObscuraBridge`].
///
/// PageHandle is `Clone` because it only carries an `Arc` to the underlying
/// chromiumoxide page; closing happens when the bridge is dropped or
/// `shutdown()` is called.
#[derive(Debug, Clone)]
pub struct PageHandle {
    pub(crate) page: Arc<CdpPage>,
    pub(crate) target_id: TargetId,
}

impl PageHandle {
    pub fn target_id(&self) -> &TargetId {
        &self.target_id
    }

    /// Navigate to `url`. SSRF guard runs *before* the CDP call (defence in
    /// depth on top of obscura's own guard).
    ///
    /// v1.1.0 (P12): the main-frame HTTP status is populated by enabling the
    /// CDP `Network` domain *before* the navigation and capturing the first
    /// `Document`-type `Network.responseReceived` event whose URL matches the
    /// final navigation URL (or, failing that, the requested URL).
    pub async fn navigate(&self, url: &Url) -> Result<NavResult> {
        ssrf::validate_url(url)?;

        // P12: enable Network domain and subscribe to responseReceived *before*
        // the goto, so we don't race the document fetch. Failures to enable the
        // domain are non-fatal — we degrade to http_status = None.
        let captured: Arc<Mutex<Option<u16>>> = Arc::new(Mutex::new(None));
        let mut res_stream_opt = None;
        if self.page.execute(EnableParams::default()).await.is_ok() {
            if let Ok(stream) = self.page.event_listener::<EventResponseReceived>().await {
                res_stream_opt = Some(stream);
            }
        }
        let requested_url = url.to_string();
        let captured_for_task = captured.clone();
        let requested_for_task = requested_url.clone();
        let listener_handle = res_stream_opt.map(|mut stream| {
            tokio::spawn(async move {
                while let Some(ev) = stream.next().await {
                    if is_main_frame_response(&ev, &requested_for_task) {
                        if let Ok(mut g) = captured_for_task.lock() {
                            if g.is_none() {
                                *g = Some(ev.response.status as u16);
                            }
                            // Keep listening cheaply; the outer task is
                            // cancelled when navigate() returns and the handle
                            // is dropped.
                        }
                    }
                }
            })
        });

        let nav = self
            .page
            .goto(url.as_str())
            .await
            .map_err(BridgeError::from)?;
        // chromiumoxide returns the same Page on success; resolve final URL.
        let final_url = nav
            .url()
            .await
            .map_err(BridgeError::from)?
            .unwrap_or_else(|| url.to_string());

        // Allow the responseReceived event to land. CDP delivers responses
        // typically before goto() resolves, but give a short grace window
        // for browsers that fire it after the main-frame load completes.
        if listener_handle.is_some() {
            for _ in 0..5 {
                if captured.lock().ok().and_then(|g| *g).is_some() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        }
        let http_status = captured.lock().ok().and_then(|g| *g);
        // Drop the listener task; the event_listener stream closes when the
        // page is dropped, so this is purely cooperative.
        if let Some(h) = listener_handle {
            h.abort();
        }

        Ok(NavResult {
            final_url,
            http_status,
        })
    }

    /// Run an arbitrary JS expression and return the JSON-encoded result.
    pub async fn evaluate(&self, js: &str) -> Result<serde_json::Value> {
        let eval = self.page.evaluate(js).await.map_err(BridgeError::from)?;
        eval.into_value::<serde_json::Value>()
            .map_err(BridgeError::from)
    }

    /// Poll for `css` until either it appears or `timeout` elapses.
    pub async fn wait_for_selector(&self, css: &str, timeout: Duration) -> Result<NodeId> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            // chromiumoxide's find_element returns Err on miss; we treat that
            // as "not yet" and retry until the deadline.
            match self.page.find_element(css).await {
                Ok(el) => {
                    // chromiumoxide exposes the protocol node id as a field.
                    return Ok(NodeId(*el.node_id.inner()));
                }
                Err(_) => {
                    if tokio::time::Instant::now() >= deadline {
                        return Err(BridgeError::Timeout {
                            ms: timeout.as_millis(),
                        });
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
        }
    }

    /// Enable the CDP `Network` domain and subscribe to
    /// `Network.requestWillBeSent` + `Network.responseReceived`, pushing
    /// JSON-ish 2xx/3xx XHR/Fetch responses joined by `requestId` into the
    /// supplied [`NetworkCapture`] buffer.
    ///
    /// Listener tasks are detached and terminate naturally when the
    /// underlying CDP page is dropped (the event streams close). The
    /// returned `Ok(())` indicates the subscription was installed; callers
    /// drive the render normally and inspect `cap.finish()` afterwards.
    ///
    /// `origin_host` is used for the same-eTLD+1 attribution flag on each
    /// row. If `None`, all captured rows have `same_etld_plus_1 = false`
    /// (and the discovery aggregator will filter them out).
    pub async fn with_network_capture(
        &self,
        cap: NetworkCapture,
        origin_host: Option<String>,
    ) -> Result<()> {
        self.page
            .execute(EnableParams::default())
            .await
            .map_err(BridgeError::from)?;

        let mut req_stream = self
            .page
            .event_listener::<EventRequestWillBeSent>()
            .await
            .map_err(BridgeError::from)?;
        let mut res_stream = self
            .page
            .event_listener::<EventResponseReceived>()
            .await
            .map_err(BridgeError::from)?;

        // req_id -> (url, method, resource_type)
        type PendingReq = HashMap<String, (String, String, String)>;
        let pending: Arc<Mutex<PendingReq>> = Arc::new(Mutex::new(HashMap::new()));

        let pending_req = pending.clone();
        tokio::spawn(async move {
            while let Some(ev) = req_stream.next().await {
                let rid = ev.request_id.inner().to_string();
                let url = ev.request.url.clone();
                let method = ev.request.method.clone();
                let rtype = ev
                    .r#type
                    .as_ref()
                    .map(|t| format!("{t:?}"))
                    .unwrap_or_else(|| "Other".to_string());
                if let Ok(mut g) = pending_req.lock() {
                    g.insert(rid, (url, method, rtype));
                }
            }
        });

        let origin_etld1 = origin_host
            .as_deref()
            .map(crate::network_capture::registrable_domain);
        let pending_res = pending.clone();
        let cap_for_res = cap.clone();
        tokio::spawn(async move {
            while let Some(ev) = res_stream.next().await {
                let rid = ev.request_id.inner().to_string();
                let (url, method, rtype) =
                    match pending_res.lock().ok().and_then(|mut g| g.remove(&rid)) {
                        Some(t) => t,
                        None => (
                            ev.response.url.clone(),
                            "GET".to_string(),
                            format!("{:?}", ev.r#type),
                        ),
                    };
                let status = ev.response.status as u16;
                let mime = ev.response.mime_type.clone();

                let same_etld1 = match (
                    &origin_etld1,
                    Url::parse(&url)
                        .ok()
                        .and_then(|u| u.host_str().map(|s| s.to_string())),
                ) {
                    (Some(o), Some(h)) => &crate::network_capture::registrable_domain(&h) == o,
                    _ => false,
                };

                if !crate::network_capture::should_capture(&rtype, status, &mime) {
                    continue;
                }
                cap_for_res.push(CapturedRequest {
                    url,
                    method,
                    resource_type: rtype,
                    status: Some(status),
                    mime_type: Some(mime),
                    same_etld_plus_1: same_etld1,
                });
            }
        });

        Ok(())
    }

    /// Capture the page outer HTML.
    pub async fn dom_snapshot(&self) -> Result<DomSnapshot> {
        let html = self.page.content().await.map_err(BridgeError::from)?;
        let url = self
            .page
            .url()
            .await
            .map_err(BridgeError::from)?
            .unwrap_or_default();
        Ok(DomSnapshot { url, html })
    }
}

// ---- v1.1.0 (P12): main-frame status helpers ----

/// Decide whether a `Network.responseReceived` event corresponds to the
/// main-frame document we just navigated to. Two heuristics, in order:
///
/// 1. `r#type == Document` (formatted via Debug — chromiumoxide does not
///    expose the enum variant publicly through a const path here).
/// 2. The response URL matches the requested URL after normalising
///    trailing slash and fragment.
fn is_main_frame_response(ev: &EventResponseReceived, requested_url: &str) -> bool {
    let type_str = format!("{:?}", ev.r#type);
    if type_str == "Document" {
        return true;
    }
    main_frame_url_matches(&ev.response.url, requested_url)
}

/// Pure URL-match helper for `is_main_frame_response`. Strips fragments
/// and trailing slashes for tolerant comparison. Exposed for direct
/// unit testing without a live CDP backend.
fn main_frame_url_matches(response_url: &str, requested_url: &str) -> bool {
    fn normalise(s: &str) -> String {
        let no_frag = s.split('#').next().unwrap_or(s);
        let trimmed = no_frag.trim_end_matches('/');
        trimmed.to_ascii_lowercase()
    }
    normalise(response_url) == normalise(requested_url)
}

#[cfg(test)]
mod p12_tests {
    use super::*;

    // Pure-helper tests cover the matching logic without needing a real
    // CDP server. Full integration is exercised by the existing obscura
    // E2E suite under `scripts/run_obscura_e2e.sh`.

    #[test]
    fn main_frame_url_matches_exact() {
        assert!(main_frame_url_matches(
            "https://example.com/foo",
            "https://example.com/foo"
        ));
    }

    #[test]
    fn main_frame_url_matches_ignores_trailing_slash() {
        assert!(main_frame_url_matches(
            "https://example.com/foo/",
            "https://example.com/foo"
        ));
        assert!(main_frame_url_matches(
            "https://example.com/",
            "https://example.com"
        ));
    }

    #[test]
    fn main_frame_url_matches_ignores_fragment() {
        assert!(main_frame_url_matches(
            "https://example.com/page#section",
            "https://example.com/page"
        ));
    }

    #[test]
    fn main_frame_url_matches_case_insensitive_host() {
        assert!(main_frame_url_matches(
            "https://Example.COM/foo",
            "https://example.com/foo"
        ));
    }

    #[test]
    fn main_frame_url_matches_rejects_different_path() {
        assert!(!main_frame_url_matches(
            "https://example.com/other",
            "https://example.com/foo"
        ));
    }

    #[test]
    fn nav_result_serde_with_status() {
        // P12: NavResult.http_status must serialise as a number (or null),
        // never as a string, so downstream consumers can rely on a stable
        // shape regardless of whether we managed to capture the status.
        let with = NavResult {
            final_url: "https://example.com/".to_string(),
            http_status: Some(200),
        };
        let s = serde_json::to_string(&with).unwrap();
        assert!(s.contains("\"http_status\":200"), "got {s}");

        let without = NavResult {
            final_url: "https://example.com/".to_string(),
            http_status: None,
        };
        let s = serde_json::to_string(&without).unwrap();
        assert!(s.contains("\"http_status\":null"), "got {s}");
    }
}
