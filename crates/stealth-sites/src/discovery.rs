// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 7c auto-learn)
//! Endpoint discovery helpers: URL path-template normalization, same-eTLD+1
//! filtering, JSON-MIME / 2xx-3xx filters, and aggregation of captured
//! network requests into `Endpoint` rows.
//!
//! The capture itself (chromiumoxide `Network.requestWillBeSent` /
//! `responseReceived`) lives in `obscura-bridge::network_capture`. This module
//! is intentionally side-effect-free and easy to unit-test.
//!
//! ## Normalization rules
//! - UUIDs (RFC 4122 hex form, with or without dashes, length >= 22 hex chars)
//!   collapse to `{id}`.
//! - All-numeric segments collapse to `{id}`.
//! - "Slug-like" segments (mixed-case / underscore / dash, not a known
//!   keyword) collapse to `{slug}` when they look like user-controlled
//!   identifiers (heuristic: contains an underscore, or is purely lower-case
//!   and >= 6 chars, or is mixed alnum >= 20 chars).
//!
//! These are heuristics tuned to brain-market and similar SPA backends; we
//! prefer false-negatives (leaving a literal segment) over false-positives
//! (collapsing a real path part like `articles`).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use url::Url;

/// One captured request, agnostic of the capture mechanism.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapturedRequest {
    pub url: String,
    pub method: String,
    /// CDP `Network.ResourceType` lower-cased ("xhr", "fetch", ...).
    pub resource_type: String,
    pub status: Option<u16>,
    pub mime_type: Option<String>,
    /// True if `url` has the same registrable domain as the page that
    /// captured it. Computed by the caller (which has the page origin).
    pub same_etld_plus_1: bool,
}

/// A normalized endpoint candidate (pre-`Endpoint` upsert form).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct EndpointCandidate {
    pub method: String,
    pub path_template: String,
    pub url_template: String,
    /// Provenance tag, surfaces into [`crate::recipe::Endpoint::discovered_via`].
    /// `"network-capture"` for CDP Network events, `"js-bundle-scan"` for
    /// URLs extracted from JS bundles, `None` for legacy callers.
    #[serde(default)]
    pub discovered_via: Option<String>,
}

/// Heuristic: does this path segment look like a UUID-ish identifier?
fn looks_like_uuid(seg: &str) -> bool {
    // RFC 4122 8-4-4-4-12 = 36 chars
    if seg.len() == 36
        && seg.chars().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        })
    {
        return true;
    }
    // Long opaque token (e.g. brain-market `b1ETN3QjMgoTZsNWa0JXY`).
    if seg.len() >= 20
        && seg
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        && seg.chars().any(|c| c.is_ascii_uppercase())
        && seg.chars().any(|c| c.is_ascii_lowercase())
    {
        return true;
    }
    false
}

fn looks_like_numeric(seg: &str) -> bool {
    !seg.is_empty() && seg.chars().all(|c| c.is_ascii_digit())
}

fn looks_like_slug(seg: &str) -> bool {
    if seg.len() < 4 {
        return false;
    }
    // Reject API verbs / common nouns we *want* to keep as literals.
    const KEEP_AS_LITERAL: &[&str] = &[
        "users",
        "user",
        "articles",
        "article",
        "posts",
        "post",
        "items",
        "search",
        "list",
        "list_articles",
        "profile",
        "auth",
        "login",
        "logout",
        "session",
        "sessions",
        "feed",
        "feeds",
        "api",
        "v1",
        "v2",
        "v3",
        "v4",
        "graphql",
        "rest",
        "public",
        "private",
        "me",
        "categories",
        "tags",
        "comments",
        "comment",
        "data",
        "index",
        "home",
        "about",
        "contact",
    ];
    if KEEP_AS_LITERAL.iter().any(|k| k.eq_ignore_ascii_case(seg)) {
        return false;
    }
    // Underscore'd identifier (fujin_metaverse style).
    if seg.contains('_')
        && seg
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return true;
    }
    // Lower-case with digits and >=6 chars (e.g. "alice42").
    if seg.len() >= 6
        && seg
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && seg.chars().any(|c| c.is_ascii_digit())
    {
        return true;
    }
    false
}

/// Normalize a single segment to `{id}` / `{slug}` or itself.
pub fn normalize_segment(seg: &str) -> String {
    if looks_like_uuid(seg) {
        return "{id}".to_string();
    }
    if looks_like_numeric(seg) {
        return "{id}".to_string();
    }
    if looks_like_slug(seg) {
        return "{slug}".to_string();
    }
    seg.to_string()
}

/// Normalize the path of `url`. Returns `(path_template, origin_url_template)`.
///
/// The origin URL template preserves scheme + host + normalized path,
/// drops the query (query params vary per-call and aren't part of the
/// endpoint identity for `{param}` purposes).
pub fn normalize_url(url: &str) -> Option<(String, String)> {
    let parsed = Url::parse(url).ok()?;
    let host = parsed.host_str()?;
    let scheme = parsed.scheme();
    let path = parsed.path();
    let normalized: Vec<String> = path
        .split('/')
        .map(|s| {
            if s.is_empty() {
                s.to_string()
            } else {
                normalize_segment(s)
            }
        })
        .collect();
    let path_template = normalized.join("/");
    let url_template = format!("{}://{}{}", scheme, host, path_template);
    Some((path_template, url_template))
}

/// Extract the registrable-domain ("eTLD+1") form of a host using a very
/// small fallback algorithm: take the last two labels. For most public
/// suffixes this is correct (`brain-market.com` ← `api.brain-market.com`).
/// Crates like `publicsuffix` would be more accurate but add a sizable
/// PSL embed; the recipe layer only needs same-domain *filtering*, not
/// authoritative classification.
pub fn registrable_domain(host: &str) -> String {
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() <= 2 {
        return host.to_string();
    }
    // Naive "two-label suffix" — wrong for co.uk / co.jp etc., but our
    // filter is symmetric so false-positive same-domain matches just mean
    // we capture *more* endpoints, not the wrong site.
    let n = parts.len();
    format!("{}.{}", parts[n - 2], parts[n - 1])
}

/// Filter applied during aggregation: same eTLD+1, XHR/Fetch resource
/// type, JSON-ish MIME (when known), 2xx/3xx status (when known).
pub fn is_candidate(req: &CapturedRequest) -> bool {
    if !req.same_etld_plus_1 {
        return false;
    }
    let rt = req.resource_type.to_ascii_lowercase();
    if rt != "xhr" && rt != "fetch" {
        return false;
    }
    if let Some(s) = req.status {
        if !(200..400).contains(&s) {
            return false;
        }
    }
    if let Some(m) = req.mime_type.as_deref() {
        let m = m.to_ascii_lowercase();
        if !(m.contains("json") || m.contains("javascript") || m.is_empty()) {
            return false;
        }
    }
    true
}

/// Aggregate captured requests into deduped endpoint candidates.
/// Same (method, path_template) collapse to a single row.
pub fn aggregate_endpoints(reqs: &[CapturedRequest]) -> Vec<EndpointCandidate> {
    let mut seen: BTreeMap<(String, String), EndpointCandidate> = BTreeMap::new();
    for r in reqs.iter().filter(|r| is_candidate(r)) {
        if let Some((path_tpl, url_tpl)) = normalize_url(&r.url) {
            let key = (r.method.to_ascii_uppercase(), path_tpl.clone());
            seen.entry(key).or_insert(EndpointCandidate {
                method: r.method.to_ascii_uppercase(),
                path_template: path_tpl,
                url_template: url_tpl,
                discovered_via: Some("network-capture".to_string()),
            });
        }
    }
    seen.into_values().collect()
}

/// Extract candidate API URLs from a JS bundle body using a coarse regex
/// over single/double/backtick-quoted strings that look like versioned API
/// paths (`/vN/...`) or absolute `https://...` URLs with the same shape.
///
/// Returns *relative or absolute* string candidates. The caller is
/// expected to resolve relative paths against the page origin before
/// probing.
pub fn extract_bundle_url_candidates(body: &str, origin: &str) -> Vec<String> {
    use regex::Regex;
    // String literal containing either an absolute https URL OR a
    // root-relative path, ending in a versioned segment `/vN/...`.
    let re = Regex::new(
        r#"['"`](https?://[a-zA-Z0-9.\-]+(?:/[a-zA-Z0-9_\-{}]+)*?/v\d+/[a-zA-Z][\w/.\-{}]*|(?:/[a-zA-Z0-9_\-{}]+)*?/v\d+/[a-zA-Z][\w/.\-{}]*)['"`]"#,
    )
    .expect("regex");
    let mut out = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for cap in re.captures_iter(body) {
        if let Some(m) = cap.get(1) {
            let raw = m.as_str().to_string();
            let abs = if raw.starts_with("http") {
                raw
            } else {
                let origin = origin.trim_end_matches('/');
                format!("{origin}{raw}")
            };
            if seen.insert(abs.clone()) {
                out.push(abs);
            }
        }
    }
    out
}

/// Convert raw URL strings (typically from [`extract_bundle_url_candidates`])
/// into `EndpointCandidate`s, applying path-template normalization and
/// tagging `discovered_via = "js-bundle-scan"`. Cross-domain candidates
/// (different eTLD+1 from `origin_host`) are dropped.
pub fn bundle_urls_to_candidates(urls: &[String], origin_host: &str) -> Vec<EndpointCandidate> {
    let origin_etld1 = registrable_domain(origin_host);
    let mut seen: BTreeMap<(String, String), EndpointCandidate> = BTreeMap::new();
    for u in urls {
        let parsed = match Url::parse(u) {
            Ok(p) => p,
            Err(_) => continue,
        };
        let host = match parsed.host_str() {
            Some(h) => h,
            None => continue,
        };
        if registrable_domain(host) != origin_etld1 {
            continue;
        }
        if let Some((path_tpl, url_tpl)) = normalize_url(u) {
            let key = ("GET".to_string(), path_tpl.clone());
            seen.entry(key).or_insert(EndpointCandidate {
                method: "GET".to_string(),
                path_template: path_tpl,
                url_template: url_tpl,
                discovered_via: Some("js-bundle-scan".to_string()),
            });
        }
    }
    seen.into_values().collect()
}

/// Merge candidates from two sources into a single deduped list, preferring
/// the first source's provenance on conflict.
pub fn merge_candidates(
    primary: Vec<EndpointCandidate>,
    secondary: Vec<EndpointCandidate>,
) -> Vec<EndpointCandidate> {
    let mut seen: BTreeMap<(String, String), EndpointCandidate> = BTreeMap::new();
    for c in primary.into_iter().chain(secondary) {
        let key = (c.method.clone(), c.path_template.clone());
        seen.entry(key).or_insert(c);
    }
    seen.into_values().collect()
}

/// Build a derivation-of-purpose hint for an endpoint candidate. Used to
/// auto-generate `purpose` strings when the agent hasn't named them yet.
pub fn derive_purpose(candidate: &EndpointCandidate) -> String {
    let last_literal = candidate
        .path_template
        .split('/')
        .rfind(|s| !s.is_empty() && !s.starts_with('{'))
        .unwrap_or("endpoint");
    format!(
        "{}_{}",
        candidate.method.to_ascii_lowercase(),
        last_literal.replace('-', "_")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(
        url: &str,
        method: &str,
        rt: &str,
        status: Option<u16>,
        mime: Option<&str>,
    ) -> CapturedRequest {
        CapturedRequest {
            url: url.to_string(),
            method: method.to_string(),
            resource_type: rt.to_string(),
            status,
            mime_type: mime.map(|s| s.to_string()),
            same_etld_plus_1: true,
        }
    }

    #[test]
    fn test_normalize_url_uuid_to_placeholder() {
        let (p, _) = normalize_url(
            "https://api.example.com/v1/articles/550e8400-e29b-41d4-a716-446655440000",
        )
        .expect("ok");
        assert_eq!(p, "/v1/articles/{id}");
    }

    #[test]
    fn test_normalize_url_numeric_id_to_placeholder() {
        let (p, _) = normalize_url("https://api.example.com/v1/items/42").expect("ok");
        assert_eq!(p, "/v1/items/{id}");
    }

    #[test]
    fn test_normalize_url_slug_to_placeholder() {
        let (p, _) =
            normalize_url("https://api.brain-market.com/v2/users/fujin_metaverse/articles")
                .expect("ok");
        assert_eq!(p, "/v2/users/{slug}/articles");
    }

    #[test]
    fn test_normalize_long_opaque_id_to_placeholder() {
        // 21-char mixed-case opaque token (brain-market article id pattern)
        let (p, _) =
            normalize_url("https://api.brain-market.com/v2/articles/b1ETN3QjMgoTZsNWa0JXY")
                .expect("ok");
        assert_eq!(p, "/v2/articles/{id}");
    }

    #[test]
    fn test_endpoint_dedup_after_normalization() {
        let reqs = vec![
            req(
                "https://api.example.com/v1/users/alice123/posts",
                "GET",
                "xhr",
                Some(200),
                Some("application/json"),
            ),
            req(
                "https://api.example.com/v1/users/bob_smith/posts",
                "GET",
                "xhr",
                Some(200),
                Some("application/json"),
            ),
        ];
        let out = aggregate_endpoints(&reqs);
        assert_eq!(out.len(), 1, "two slug variants must collapse");
        assert_eq!(out[0].path_template, "/v1/users/{slug}/posts");
    }

    #[test]
    fn test_same_etld_plus_1_filter() {
        let mut r = req(
            "https://evil.tracker.net/beacon",
            "GET",
            "xhr",
            Some(200),
            Some("application/json"),
        );
        r.same_etld_plus_1 = false;
        let out = aggregate_endpoints(&[r]);
        assert!(out.is_empty(), "cross-domain requests must be filtered");
    }

    #[test]
    fn test_json_mime_filter() {
        let r_html = req(
            "https://example.com/page",
            "GET",
            "xhr",
            Some(200),
            Some("text/html"),
        );
        let r_json = req(
            "https://example.com/api",
            "GET",
            "xhr",
            Some(200),
            Some("application/json"),
        );
        let out = aggregate_endpoints(&[r_html, r_json]);
        assert_eq!(out.len(), 1);
        assert!(out[0].path_template.starts_with("/api"));
    }

    #[test]
    fn test_status_2xx_3xx_filter() {
        let r_404 = req(
            "https://example.com/missing",
            "GET",
            "xhr",
            Some(404),
            Some("application/json"),
        );
        let r_500 = req(
            "https://example.com/oops",
            "GET",
            "xhr",
            Some(500),
            Some("application/json"),
        );
        let r_ok = req(
            "https://example.com/ok",
            "GET",
            "xhr",
            Some(200),
            Some("application/json"),
        );
        let r_301 = req(
            "https://example.com/moved",
            "GET",
            "xhr",
            Some(301),
            Some("application/json"),
        );
        let out = aggregate_endpoints(&[r_404, r_500, r_ok, r_301]);
        let paths: Vec<_> = out.iter().map(|c| c.path_template.as_str()).collect();
        assert!(paths.contains(&"/ok"));
        assert!(paths.contains(&"/moved"));
        assert!(!paths.contains(&"/missing"));
        assert!(!paths.contains(&"/oops"));
    }

    #[test]
    fn test_resource_type_filter_drops_non_xhr() {
        let r_doc = req(
            "https://example.com/main.css",
            "GET",
            "stylesheet",
            Some(200),
            Some("text/css"),
        );
        let out = aggregate_endpoints(&[r_doc]);
        assert!(
            out.is_empty(),
            "stylesheet must not be captured as endpoint"
        );
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
    fn test_derive_purpose_uses_last_literal_segment() {
        let c = EndpointCandidate {
            method: "GET".into(),
            path_template: "/v2/users/{slug}/articles".into(),
            url_template: "https://x/v2/users/{slug}/articles".into(),
            discovered_via: None,
        };
        assert_eq!(derive_purpose(&c), "get_articles");
    }

    #[test]
    fn test_js_bundle_scan_extracts_v2_patterns() {
        let body = r#"
            const A = "/v2/users/{username}/articles";
            const B = 'https://api.brain-market.com/v2/articles/{id}';
            const C = `https://cdn.example.com/foo/bar.js`;
            const D = "/static/main.css";
        "#;
        let out = extract_bundle_url_candidates(body, "https://brain-market.com");
        assert!(
            out.iter()
                .any(|u| u.ends_with("/v2/users/{username}/articles")),
            "expected v2 users in {out:?}"
        );
        assert!(
            out.iter()
                .any(|u| u == "https://api.brain-market.com/v2/articles/{id}"),
            "expected abs v2 articles in {out:?}"
        );
        assert!(
            !out.iter().any(|u| u.contains("main.css")),
            "css must not match: {out:?}"
        );
    }

    #[test]
    fn test_bundle_urls_to_candidates_drops_cross_domain() {
        let urls = vec![
            "https://api.brain-market.com/v2/users/{username}".into(),
            "https://evil.tracker.net/v1/beacon".into(),
        ];
        let out = bundle_urls_to_candidates(&urls, "brain-market.com");
        assert_eq!(out.len(), 1);
        assert!(out[0].path_template.starts_with("/v2/users"));
        assert_eq!(out[0].discovered_via.as_deref(), Some("js-bundle-scan"));
    }

    #[test]
    fn test_merge_candidates_prefers_primary_provenance() {
        let primary = vec![EndpointCandidate {
            method: "GET".into(),
            path_template: "/v2/x".into(),
            url_template: "https://h/v2/x".into(),
            discovered_via: Some("network-capture".into()),
        }];
        let secondary = vec![
            EndpointCandidate {
                method: "GET".into(),
                path_template: "/v2/x".into(),
                url_template: "https://h/v2/x".into(),
                discovered_via: Some("js-bundle-scan".into()),
            },
            EndpointCandidate {
                method: "GET".into(),
                path_template: "/v2/y".into(),
                url_template: "https://h/v2/y".into(),
                discovered_via: Some("js-bundle-scan".into()),
            },
        ];
        let out = merge_candidates(primary, secondary);
        assert_eq!(out.len(), 2);
        let x = out.iter().find(|c| c.path_template == "/v2/x").unwrap();
        assert_eq!(x.discovered_via.as_deref(), Some("network-capture"));
    }

    #[test]
    fn test_js_bundle_scan_resolves_relative_to_origin() {
        let body = r#" url: "/api/v1/me" "#;
        let out = extract_bundle_url_candidates(body, "https://example.com/");
        assert!(
            out.iter().any(|u| u == "https://example.com/api/v1/me"),
            "got {out:?}"
        );
    }

    #[test]
    fn test_method_normalized_to_upper() {
        let r = req(
            "https://example.com/api",
            "post",
            "fetch",
            Some(201),
            Some("application/json"),
        );
        let out = aggregate_endpoints(&[r]);
        assert_eq!(out[0].method, "POST");
    }
}
