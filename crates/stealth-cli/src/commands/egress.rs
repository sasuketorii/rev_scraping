// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.2.0 (P10.5 — egress probe, feature-gated)
//! `rev-stealth measure --enable-egress-probe` — VPS egress diagnostics.
//!
//! After a VPS deploy (see `dist/systemd/` and `docs/deploy/vps.md`) the
//! operator needs to confirm that outbound traffic exits via the expected
//! IP / country / ISP and that no obvious TLS / DNS leak has occurred.
//!
//! This module performs an opt-in **HTTP HEAD** probe against a minimal,
//! well-known endpoint and reports a small JSON shape. The probe is gated
//! behind the `vps-egress-probe` Cargo feature so that:
//!
//!   * the default `cargo build` / `cargo test` of the workspace performs
//!     **zero external network calls** from this code path, and
//!   * shipping a binary without the feature flag makes the probe
//!     impossible to invoke, even with the CLI flag set.
//!
//! When the feature is disabled, [`run_probe`] returns a deterministic
//! `disabled` payload and does not link any networking. Even with the
//! feature enabled, the probe still requires the runtime
//! `--enable-egress-probe` CLI flag (double opt-in).
//!
//! Secret hygiene: any HTTP response headers we surface are passed through
//! [`redact_response_headers`], which scrubs `set-cookie`,
//! `authorization`, `x-api-key`, `x-auth-token`, and any header whose name
//! contains `token`, `secret`, `cookie`, or `auth`.

use serde_json::{json, Value};

/// Result of an egress probe call. When the feature is disabled, or when
/// the CLI flag was not set, returns a deterministic `disabled` stub
/// without performing any network I/O.
pub async fn run_probe(enabled_via_cli: bool) -> Value {
    if !enabled_via_cli {
        return json!({
            "enabled": false,
            "reason": "cli flag --enable-egress-probe not set",
        });
    }
    run_probe_inner().await
}

#[cfg(not(feature = "vps-egress-probe"))]
async fn run_probe_inner() -> Value {
    json!({
        "enabled": false,
        "reason": "binary built without `vps-egress-probe` feature",
    })
}

/// Round-2 reviewer finding: `reqwest::Error` Display can append the
/// request URL. Strip it before any caller formats `{e}`.
#[cfg(feature = "vps-egress-probe")]
fn scrub_reqwest_error(e: reqwest::Error) -> String {
    e.without_url().to_string()
}

#[cfg(feature = "vps-egress-probe")]
async fn run_probe_inner() -> Value {
    // The endpoint is configurable at build time via
    // `REV_STEALTH_EGRESS_PROBE_URL`; default points at a well-known
    // minimal echo. We use HEAD to keep the body small and avoid pulling
    // response payloads that could contain secrets.
    let url = option_env!("REV_STEALTH_EGRESS_PROBE_URL")
        .unwrap_or("https://check.ifconfig.io/");
    // P10.5 review round-1: redact the URL before echoing it back, so
    // that if an operator points the probe at a tokenized endpoint
    // (`https://user:pw@host/...?token=...`) the credential never lands
    // in stdout JSON or in an error message.
    let url_safe = redact_url(url);

    let started = std::time::Instant::now();
    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .redirect(reqwest::redirect::Policy::limited(2))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            return json!({
                "enabled": true,
                "ok": false,
                "error": format!("client build: {e}"),
            });
        }
    };
    let resp = match client.head(url).send().await {
        Ok(r) => r,
        Err(e) => {
            // Round-2 reviewer finding: `reqwest::Error`'s Display impl can
            // append the full request URL ("error sending request for url
            // (...)"). If REV_STEALTH_EGRESS_PROBE_URL contained userinfo
            // or a sensitive query parameter, formatting `{e}` would
            // re-leak it past our `url_safe` prefix. Strip the URL from
            // the error before formatting, and surface only the redacted
            // form ourselves.
            let safe_err = scrub_reqwest_error(e);
            return json!({
                "enabled": true,
                "ok": false,
                "error": format!("HEAD {url_safe}: {safe_err}"),
            });
        }
    };
    let latency_ms = started.elapsed().as_millis() as u64;
    let status = resp.status().as_u16();
    // NOTE: this is the HTTP wire version (e.g. HTTP/1.1, HTTP/2.0), not the
    // negotiated TLS protocol. reqwest does not expose the TLS version on
    // the Response surface; we report the HTTP version honestly and leave
    // a real TLS-version probe to a future slice.
    let http_version = resp.version();
    let headers_redacted = redact_response_headers(
        resp.headers()
            .iter()
            .map(|(k, v)| {
                (
                    k.as_str().to_string(),
                    v.to_str().unwrap_or("<binary>").to_string(),
                )
            })
            .collect(),
    );
    let exit_ip = headers_redacted
        .get("x-real-ip")
        .or_else(|| headers_redacted.get("x-forwarded-for"))
        .cloned()
        .unwrap_or_else(|| "<unknown>".to_string());
    json!({
        "enabled": true,
        "ok": true,
        "endpoint": url_safe,
        "status": status,
        "latency_ms": latency_ms,
        "http_version": format!("{http_version:?}"),
        "tls_protocol_version": "<not exposed by reqwest>",
        "exit_ip": exit_ip,
        "country": "<unknown>",
        "isp": "<unknown>",
        "headers_redacted": headers_redacted,
    })
}

/// Redact userinfo and sensitive query parameters from a URL so that it
/// is safe to echo in stdout JSON or error messages.
///
/// * `https://user:pw@host/path?token=xyz&q=ok`
///   becomes
///   `https://<redacted>@host/path?token=<redacted>&q=ok`
///
/// On parse failure, returns `<unparseable-url>` rather than the raw
/// input, to fail closed for secret hygiene.
#[allow(dead_code)]
pub fn redact_url(raw: &str) -> String {
    let mut u = match url::Url::parse(raw) {
        Ok(u) => u,
        Err(_) => return "<unparseable-url>".to_string(),
    };
    if !u.username().is_empty() || u.password().is_some() {
        // url::Url requires both set_username and set_password to succeed.
        let _ = u.set_username("<redacted>");
        let _ = u.set_password(None);
    }
    // Rebuild the query, redacting any pair whose key looks credential-ish.
    let needs_redact = u.query_pairs().any(|(k, _)| is_sensitive_param(&k));
    if needs_redact {
        let new_pairs: Vec<(String, String)> = u
            .query_pairs()
            .map(|(k, v)| {
                let kk = k.into_owned();
                let vv = if is_sensitive_param(&kk) {
                    "<redacted>".to_string()
                } else {
                    v.into_owned()
                };
                (kk, vv)
            })
            .collect();
        let mut q = u.query_pairs_mut();
        q.clear();
        for (k, v) in &new_pairs {
            q.append_pair(k, v);
        }
        drop(q);
    }
    u.into()
}

fn is_sensitive_param(k: &str) -> bool {
    // Normalize hyphens/underscores/case so variants like `api-key`,
    // `api_key`, `apikey`, `Access-Key`, `X-Auth-Token` all collapse to
    // the same substring set. Reviewer round-3 finding.
    let norm: String = k
        .chars()
        .filter(|c| !matches!(c, '-' | '_'))
        .flat_map(|c| c.to_lowercase())
        .collect();
    // Exact-name matches.
    if matches!(
        norm.as_str(),
        "token"
            | "secret"
            | "key"
            | "auth"
            | "password"
            | "passwd"
            | "apikey"
            | "accesskey"
            | "sessionkey"
            | "sessionid"
            | "cookie"
            | "bearer"
            | "credential"
            | "credentials"
            | "sig"
            | "signature"
    ) {
        return true;
    }
    // Substring matches on the normalized form so prefixes/suffixes like
    // `x-api-key`, `clientsecret`, `csrf-token`, `aws-session-token`,
    // `accesstoken`, `refreshtoken`, etc. all hit.
    norm.contains("token")
        || norm.contains("secret")
        || norm.contains("auth")
        || norm.contains("password")
        || norm.contains("passwd")
        || norm.contains("apikey")
        || norm.contains("accesskey")
        || norm.contains("session")
        || norm.contains("cookie")
        || norm.contains("credential")
        || norm.contains("bearer")
        || norm.contains("signature")
}

/// Redact response headers that commonly carry credentials. Keys are
/// lowercased before comparison. Returns a `BTreeMap<String, String>`
/// for stable serialization.
///
/// `#[allow(dead_code)]` because the probe-side caller only exists under
/// the `vps-egress-probe` feature, but we still want this routine
/// available for unit tests (and any future re-use) without the feature
/// flag.
#[allow(dead_code)]
pub fn redact_response_headers(
    raw: Vec<(String, String)>,
) -> std::collections::BTreeMap<String, String> {
    let mut out = std::collections::BTreeMap::new();
    for (k, v) in raw {
        let lk = k.to_ascii_lowercase();
        let sensitive = matches!(
            lk.as_str(),
            "authorization" | "set-cookie" | "cookie" | "x-api-key" | "x-auth-token"
        ) || lk.contains("token")
            || lk.contains("secret")
            || lk.contains("cookie")
            || lk.contains("auth");
        let redacted = if sensitive { "<redacted>".to_string() } else { v };
        out.insert(lk, redacted);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn egress_probe_disabled_by_default() {
        // No CLI flag → always disabled, regardless of feature gate.
        let v = run_probe(false).await;
        assert_eq!(v["enabled"], false);
        assert!(v["reason"].is_string());
        // Crucially, no network I/O was performed.
    }

    #[test]
    fn egress_probe_redacts_token_in_response_headers() {
        let raw = vec![
            ("Authorization".to_string(), "Bearer super-secret".to_string()),
            ("Set-Cookie".to_string(), "session=abc; HttpOnly".to_string()),
            ("X-Api-Key".to_string(), "k-123".to_string()),
            ("X-Custom-Token".to_string(), "t-456".to_string()),
            ("Server".to_string(), "nginx".to_string()),
        ];
        let red = redact_response_headers(raw);
        assert_eq!(red.get("authorization").unwrap(), "<redacted>");
        assert_eq!(red.get("set-cookie").unwrap(), "<redacted>");
        assert_eq!(red.get("x-api-key").unwrap(), "<redacted>");
        assert_eq!(red.get("x-custom-token").unwrap(), "<redacted>");
        // Non-sensitive header passes through.
        assert_eq!(red.get("server").unwrap(), "nginx");
    }

    #[tokio::test]
    #[cfg(not(feature = "vps-egress-probe"))]
    async fn egress_probe_without_feature_returns_disabled_even_with_cli_flag() {
        let v = run_probe(true).await;
        assert_eq!(v["enabled"], false);
        assert!(
            v["reason"]
                .as_str()
                .unwrap()
                .contains("vps-egress-probe"),
            "reason should explain the feature gate"
        );
    }

    #[test]
    fn redact_url_strips_userinfo_and_token_query() {
        // Round-2 reviewer regression: tokenized probe endpoint must not
        // leak through to stdout / error JSON.
        // Round-3 reviewer regression: also covers `api-key`, `apikey`,
        // `access_key`, `cookie`, `x-csrf-token`, `signature` variants.
        let r = redact_url(
            "https://alice:s3cret@host.example/path\
             ?token=xyz&q=ok&api_key=AA&api-key=BB&apikey=CC\
             &access_key=DD&cookie=EE&x-csrf-token=FF&signature=GG",
        );
        assert!(!r.contains("alice"), "username leaked: {r}");
        assert!(!r.contains("s3cret"), "password leaked: {r}");
        assert!(!r.contains("xyz"), "token value leaked: {r}");
        assert!(!r.contains("AA"), "api_key value leaked: {r}");
        for needle in ["BB", "CC", "DD", "EE", "FF", "GG"] {
            assert!(
                !r.contains(needle),
                "sensitive param value `{needle}` leaked: {r}"
            );
        }
        // The url crate percent-encodes <redacted> in some positions; the
        // important property is that the secret tokens are gone, not the
        // exact form of the marker.
        assert!(
            r.contains("<redacted>") || r.contains("%3Credacted%3E"),
            "expected <redacted> marker (raw or %-encoded): {r}"
        );
        // Non-sensitive query pair survives.
        assert!(r.contains("q=ok"), "non-sensitive q dropped: {r}");
    }

    #[test]
    fn redact_url_fails_closed_on_garbage() {
        assert_eq!(redact_url("not a url"), "<unparseable-url>");
    }

    #[cfg(feature = "vps-egress-probe")]
    #[tokio::test]
    async fn scrub_reqwest_error_strips_url_with_token() {
        // Trigger a real reqwest::Error by HEADing an unreachable port.
        // The URL carries a SENSITIVE_TOKEN query param; the scrubbed
        // string must NOT contain it.
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_millis(100))
            .build()
            .unwrap();
        let url =
            "http://127.0.0.1:1/probe?token=SENSITIVE_TOKEN_DO_NOT_LEAK";
        let err = client.head(url).send().await.unwrap_err();
        // Sanity: raw Display does contain the URL (this is the bug).
        let raw = format!("{err}");
        // We only assert the scrubbed form is clean — the raw form may
        // or may not include the URL depending on reqwest internals, but
        // post-scrub MUST be safe regardless.
        let scrubbed = scrub_reqwest_error(err);
        assert!(
            !scrubbed.contains("SENSITIVE_TOKEN_DO_NOT_LEAK"),
            "scrubbed error leaked token: raw={raw} scrubbed={scrubbed}"
        );
        assert!(
            !scrubbed.contains("127.0.0.1:1"),
            "scrubbed error leaked host:port: {scrubbed}"
        );
    }

    #[test]
    fn gitignore_allows_dist_systemd() {
        // Sanity: P10.5 .gitignore edits keep dist/systemd tracked.
        // We verify by reading the .gitignore from the workspace root and
        // confirming the exception line is present. This avoids spawning
        // `git` from a unit test (some sandboxes disallow it).
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(2)
            .expect("workspace root")
            .to_path_buf();
        let gi = std::fs::read_to_string(root.join(".gitignore"))
            .expect("read .gitignore");
        assert!(
            gi.contains("!/dist/systemd"),
            "expected !/dist/systemd exception in .gitignore, got:\n{gi}"
        );
        assert!(
            gi.contains("/dist/*"),
            "expected /dist/* glob exclude in .gitignore"
        );
    }
}
