// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 7c auto-learn)
//! Network event capture during a chromiumoxide page render.
//!
//! ## Scope (Phase 7c)
//!
//! Provide a typed buffer (`NetworkCapture`) that Phase 7c integration code
//! pushes captured `Network.requestWillBeSent` / `Network.responseReceived`
//! events into during a render. The actual CDP event subscription wiring
//! is performed by the caller (the spider) on `PageHandle`, because the
//! handle owns the chromiumoxide `Page`. This file owns ONLY the buffer,
//! filters, and the eTLD+1 attribution step that the discovery aggregator
//! ([`stealth_sites::discovery`]) consumes.
//!
//! Keeping the buffer in `obscura-bridge` (rather than in `stealth-cli`)
//! means the MCP path and future direct callers can record the same
//! traffic without re-implementing the data shape.

use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

/// A single observed network request/response pair. Fields mirror the CDP
/// `Network.requestWillBeSent` + `Network.responseReceived` payloads that
/// are relevant for endpoint discovery.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapturedRequest {
    pub url: String,
    pub method: String,
    /// CDP `ResourceType` value (e.g. "XHR", "Fetch"), case-preserved.
    pub resource_type: String,
    pub status: Option<u16>,
    pub mime_type: Option<String>,
    /// Whether the captured URL shares the page-origin's eTLD+1 (filled
    /// by the caller before pushing). Defaults to `false` if unknown.
    pub same_etld_plus_1: bool,
}

/// Thread-safe collector that the page-side event loop can push into.
/// `finish()` consumes the collector and returns the accumulated rows.
#[derive(Debug, Default, Clone)]
pub struct NetworkCapture {
    inner: Arc<Mutex<Vec<CapturedRequest>>>,
}

impl NetworkCapture {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Push one captured row. Silently drops the row if the mutex is
    /// poisoned (the alternative — panicking inside a CDP event handler —
    /// would tear down the entire render).
    pub fn push(&self, req: CapturedRequest) {
        if let Ok(mut g) = self.inner.lock() {
            g.push(req);
        }
    }

    /// Snapshot without consuming. Useful for partial inspection during
    /// long-running renders.
    pub fn snapshot(&self) -> Vec<CapturedRequest> {
        self.inner.lock().map(|g| g.clone()).unwrap_or_default()
    }

    /// Drain the buffer and return its contents.
    pub fn finish(self) -> Vec<CapturedRequest> {
        match Arc::try_unwrap(self.inner) {
            Ok(m) => m.into_inner().unwrap_or_default(),
            Err(arc) => arc.lock().map(|g| g.clone()).unwrap_or_default(),
        }
    }

    /// Number of rows currently buffered.
    pub fn len(&self) -> usize {
        self.inner.lock().map(|g| g.len()).unwrap_or(0)
    }

    /// True if no rows have been buffered yet.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Decide whether a CDP `Network.responseReceived` should be forwarded to
/// the [`NetworkCapture`] buffer. The live listener in `page.rs` applies
/// the same predicate; factoring it out keeps the logic unit-testable
/// without a live browser.
pub fn should_capture(resource_type: &str, status: u16, mime_type: &str) -> bool {
    let is_json = mime_type.to_ascii_lowercase().contains("json");
    let is_script = resource_type.eq_ignore_ascii_case("Script");
    if !(is_json || is_script) {
        return false;
    }
    (200..400).contains(&status)
}

/// Two-label eTLD+1 approximation. See
/// [`stealth_sites::discovery::registrable_domain`] for the canonical
/// algorithm; we duplicate it here to avoid a `stealth-sites` dep from the
/// bridge layer.
pub fn registrable_domain(host: &str) -> String {
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() <= 2 {
        return host.to_string();
    }
    let n = parts.len();
    format!("{}.{}", parts[n - 2], parts[n - 1])
}

/// Inspection: filter Script-type rows out of a captured set. Used by the
/// JS bundle scan path to drive HEAD probes without re-walking the buffer
/// in the spider.
pub fn extract_script_urls(rows: &[CapturedRequest], limit: usize) -> Vec<String> {
    let mut out = Vec::new();
    for r in rows
        .iter()
        .filter(|r| r.resource_type.eq_ignore_ascii_case("Script"))
    {
        if out.len() >= limit {
            break;
        }
        out.push(r.url.clone());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk(url: &str) -> CapturedRequest {
        CapturedRequest {
            url: url.into(),
            method: "GET".into(),
            resource_type: "XHR".into(),
            status: Some(200),
            mime_type: Some("application/json".into()),
            same_etld_plus_1: true,
        }
    }

    #[test]
    fn test_capture_push_and_snapshot_roundtrip() {
        let cap = NetworkCapture::new();
        cap.push(mk("https://api.example.com/a"));
        cap.push(mk("https://api.example.com/b"));
        let s = cap.snapshot();
        assert_eq!(s.len(), 2);
        assert!(!cap.is_empty());
        assert_eq!(cap.len(), 2);
    }

    #[test]
    fn test_capture_finish_drains() {
        let cap = NetworkCapture::new();
        cap.push(mk("https://api.example.com/c"));
        let out = cap.finish();
        assert_eq!(out.len(), 1);
    }

    #[test]
    fn test_registrable_domain_two_labels() {
        assert_eq!(
            registrable_domain("api.brain-market.com"),
            "brain-market.com"
        );
        assert_eq!(registrable_domain("brain-market.com"), "brain-market.com");
        assert_eq!(registrable_domain("a.b.c.example.org"), "example.org");
    }

    #[test]
    fn test_should_capture_filters_non_json_mime() {
        assert!(!should_capture("XHR", 200, "text/html"));
        assert!(should_capture("XHR", 200, "application/json"));
        assert!(should_capture(
            "XHR",
            200,
            "application/json; charset=utf-8"
        ));
    }

    #[test]
    fn test_should_capture_filters_non_2xx_status() {
        assert!(!should_capture("XHR", 404, "application/json"));
        assert!(!should_capture("XHR", 500, "application/json"));
        assert!(should_capture("XHR", 200, "application/json"));
        assert!(should_capture("XHR", 301, "application/json"));
    }

    #[test]
    fn test_should_capture_allows_scripts_for_bundle_scan() {
        assert!(should_capture("Script", 200, "application/javascript"));
        assert!(!should_capture("Script", 404, "application/javascript"));
    }

    #[test]
    fn test_extract_script_urls_respects_limit() {
        let mut rows = Vec::new();
        for i in 0..10 {
            rows.push(CapturedRequest {
                url: format!("https://cdn.example.com/bundle-{i}.js"),
                method: "GET".into(),
                resource_type: "Script".into(),
                status: Some(200),
                mime_type: Some("application/javascript".into()),
                same_etld_plus_1: true,
            });
        }
        rows.push(CapturedRequest {
            url: "https://api.example.com/v1/foo".into(),
            method: "GET".into(),
            resource_type: "XHR".into(),
            status: Some(200),
            mime_type: Some("application/json".into()),
            same_etld_plus_1: true,
        });
        let urls = extract_script_urls(&rows, 5);
        assert_eq!(urls.len(), 5);
        assert!(urls.iter().all(|u| u.ends_with(".js")));
    }

    #[test]
    fn test_capture_is_thread_safe() {
        let cap = NetworkCapture::new();
        let c2 = cap.clone();
        let h = std::thread::spawn(move || {
            for i in 0..10 {
                c2.push(mk(&format!("https://x/{i}")));
            }
        });
        for i in 0..10 {
            cap.push(mk(&format!("https://y/{i}")));
        }
        h.join().unwrap();
        assert_eq!(cap.len(), 20);
    }
}
