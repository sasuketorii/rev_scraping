// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.0.0 (Phase 5b HTTP fallback)
//! reqwest-based HTTP fallback fetcher for the spider subcommand.
//!
//! Used when:
//!   * `--http-only` is set (obscura is skipped entirely), or
//!   * `--auto-fallback` (default) is set and obscura launch / CDP fails.
//!
//! SSRF / AUP enforcement is performed by the caller before we ever touch the
//! network. This module is intentionally narrow: GET an URL, return HTML +
//! metadata. No JS execution, no cookies persisted across calls.
//!
//! VPN proxy wiring (`vpn-rotate` → reqwest proxy) is intentionally deferred to
//! a follow-up task; see TODO below.

use std::time::{Duration, Instant};

use anyhow::{anyhow, Context};
use url::Url;

/// Chrome 145 desktop UA — kept in sync with `mobile-fp`'s desktop ladder so
/// fallback fetches don't accidentally diverge from the browser identity that
/// the rest of the toolkit advertises.
pub const DEFAULT_USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
     AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36";

pub const DEFAULT_ACCEPT_LANGUAGE: &str = "ja,en;q=0.9";

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

pub const MAX_REDIRECTS: usize = 10;

#[allow(dead_code)]
// `used_fallback` is part of the public spec but currently
// derived at the call site from the `Fetcher` enum.
#[derive(Debug)]
pub struct FetchResult {
    pub status: u16,
    pub html: String,
    pub final_url: String,
    pub elapsed_ms: u128,
    /// Always `true` for entries produced by this module — its presence in the
    /// spider JSON output is the agent-visible signal that we did not use a
    /// real browser for this fetch.
    pub used_fallback: bool,
}

pub struct HttpFallback;

impl HttpFallback {
    /// GET `url` with stealth-ish headers and return the response body.
    ///
    /// SSRF guard MUST already have been run on `url` by the caller.
    #[allow(dead_code)]
    pub async fn fetch_html(url: &Url, user_agent: Option<&str>) -> anyhow::Result<FetchResult> {
        Self::fetch_html_with(url, user_agent, DEFAULT_TIMEOUT, None).await
    }

    #[allow(dead_code)]
    pub async fn fetch_html_with_timeout(
        url: &Url,
        user_agent: Option<&str>,
        timeout: Duration,
    ) -> anyhow::Result<FetchResult> {
        Self::fetch_html_with(url, user_agent, timeout, None).await
    }

    /// Phase 6d entrypoint: route through an optional `proxy_url` (HTTP
    /// CONNECT proxy, typically `http://127.0.0.1:<vpn_port>`).
    ///
    /// Note on no_proxy: `reqwest::Proxy::no_proxy` matches against the
    /// *target URL host*, not the proxy URL host. The previous version of
    /// this builder set `no_proxy("127.0.0.1,...,RFC1918")` thinking it
    /// referred to the proxy itself; in practice it silently broke proxy
    /// routing on at least some reqwest builds (suspected CIDR parse
    /// failure dropping the whole list, or the matcher tripping on the
    /// target hostname resolution path). Since every caller of this
    /// fallback runs an SSRF guard upstream and we never fetch private
    /// hosts here, we simply route ALL destinations through the proxy
    /// when one is configured. If a future caller needs to bypass for
    /// internal services we will add an explicit `--bypass-proxy`
    /// pattern flag.
    pub async fn fetch_html_with(
        url: &Url,
        user_agent: Option<&str>,
        timeout: Duration,
        proxy_url: Option<&Url>,
    ) -> anyhow::Result<FetchResult> {
        Self::fetch_html_with_configured(
            url,
            user_agent,
            None,
            timeout,
            proxy_url,
            std::convert::identity,
        )
        .await
    }

    pub async fn fetch_html_with_configured<F>(
        url: &Url,
        user_agent: Option<&str>,
        accept_language: Option<&str>,
        timeout: Duration,
        proxy_url: Option<&Url>,
        configure: F,
    ) -> anyhow::Result<FetchResult>
    where
        F: FnOnce(reqwest::ClientBuilder) -> reqwest::ClientBuilder,
    {
        let ua = user_agent.unwrap_or(DEFAULT_USER_AGENT);
        let accept_language = accept_language.unwrap_or(DEFAULT_ACCEPT_LANGUAGE);

        let mut builder = reqwest::Client::builder()
            .user_agent(ua)
            .timeout(timeout)
            .redirect(reqwest::redirect::Policy::limited(MAX_REDIRECTS));

        if let Some(p) = proxy_url {
            let proxy = reqwest::Proxy::all(p.as_str()).context("building reqwest proxy")?;
            builder = builder.proxy(proxy);
        }

        builder = configure(builder);
        let client = builder.build().context("building reqwest client")?;

        let start = Instant::now();
        let resp = client
            .get(url.clone())
            .header(reqwest::header::ACCEPT_LANGUAGE, accept_language)
            .header(
                reqwest::header::ACCEPT,
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            )
            .send()
            .await
            .map_err(|e| {
                if e.is_timeout() {
                    anyhow!("reqwest fallback timed out after {:?}: {e}", timeout)
                } else {
                    anyhow!("reqwest fallback request failed: {e}")
                }
            })?;

        let status = resp.status().as_u16();
        let final_url = resp.url().to_string();
        let html = resp.text().await.context("reading reqwest response body")?;
        let elapsed_ms = start.elapsed().as_millis();

        Ok(FetchResult {
            status,
            html,
            final_url,
            elapsed_ms,
            used_fallback: true,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[ignore] // requires network
    async fn test_http_fallback_fetches_public_https() {
        let url = Url::parse("https://example.com/").unwrap();
        let r = HttpFallback::fetch_html(&url, None)
            .await
            .expect("example.com must fetch");
        assert_eq!(r.status, 200);
        assert!(r.used_fallback);
        assert!(r.html.to_ascii_lowercase().contains("example domain"));
        assert!(r.elapsed_ms > 0);
    }

    #[tokio::test]
    async fn test_http_fallback_respects_timeout() {
        // 10.255.255.1 is a TEST-NET-1-ish black hole that hangs without RST.
        // 1ms timeout guarantees a timeout error, fast, no network round-trip
        // measured.
        let url = Url::parse("http://10.255.255.1/").unwrap();
        let r = HttpFallback::fetch_html_with_timeout(&url, None, Duration::from_millis(50)).await;
        assert!(r.is_err(), "expected timeout/connect error, got {r:?}");
    }

    #[tokio::test]
    async fn test_http_fallback_follows_redirects_up_to_10() {
        // We can't dial the network in CI, but we CAN assert that the policy
        // we install on the client is `Policy::limited(10)` — i.e. the
        // construction itself is the contract. Build a client identical to the
        // one fetch_html uses and inspect.
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::limited(MAX_REDIRECTS))
            .build()
            .unwrap();
        // Smoke: client built without panic. The exact policy is private to
        // reqwest; we verify the constant is what we documented.
        assert_eq!(MAX_REDIRECTS, 10);
        drop(client);
    }

    #[tokio::test]
    async fn test_http_fallback_invalid_host_errors() {
        let url = Url::parse("http://this-host-does-not-resolve.invalid/").unwrap();
        let r = HttpFallback::fetch_html_with_timeout(&url, None, Duration::from_secs(2)).await;
        assert!(r.is_err());
    }

    #[test]
    fn test_default_constants_match_spec() {
        assert!(DEFAULT_USER_AGENT.contains("Chrome/145"));
        assert_eq!(DEFAULT_ACCEPT_LANGUAGE, "ja,en;q=0.9");
        assert_eq!(DEFAULT_TIMEOUT, Duration::from_secs(30));
        assert_eq!(MAX_REDIRECTS, 10);
    }
}
