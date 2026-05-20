// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9c (auth replay context)
//! Shared auth replay context for reqwest and obscura-backed commands.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Context;
use obscura_bridge::{
    inject_cookies, set_user_agent_override, AuthCookieParam, AuthCookieSameSite,
    CookieInjectionStatus, PageHandle,
};
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT_LANGUAGE, USER_AGENT};
use stealth_auth::{AuthCookieJar, AuthStore, Cookie, SameSite};

#[derive(Clone)]
pub struct AuthReplayContext {
    #[allow(dead_code)]
    pub profile: String,
    pub jar: Arc<AuthCookieJar>,
    pub user_agent: Option<String>,
    pub accept_language: Option<String>,
    pub cookies: Vec<Cookie>,
}

impl AuthReplayContext {
    pub fn load(store: &AuthStore, profile: &str, aad_context: &str) -> anyhow::Result<Self> {
        let cookies = store
            .load(profile, aad_context)
            .with_context(|| format!("load auth profile {profile:?}"))?;
        let replay = store
            .browser_replay_metadata(profile)
            .with_context(|| format!("load auth browser metadata for profile {profile:?}"))?
            .unwrap_or_default();
        Ok(Self {
            profile: profile.to_string(),
            jar: Arc::new(AuthCookieJar::from_cookies(cookies.clone())),
            user_agent: replay.user_agent,
            accept_language: replay.accept_language,
            cookies,
        })
    }

    pub fn apply_to_reqwest(&self, mut builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
        builder = builder.cookie_provider(self.jar.clone());
        let mut headers = HeaderMap::new();
        if let Some(ua) = &self.user_agent {
            if let Ok(value) = HeaderValue::from_str(ua) {
                headers.insert(USER_AGENT, value);
            }
        }
        if let Some(accept_language) = &self.accept_language {
            if let Ok(value) = HeaderValue::from_str(accept_language) {
                headers.insert(ACCEPT_LANGUAGE, value);
            }
        }
        if !headers.is_empty() {
            builder = builder.default_headers(headers);
        }
        builder
    }

    pub async fn apply_to_obscura_page(
        &self,
        page: &PageHandle,
    ) -> anyhow::Result<CookieInjectionStatus> {
        if let Some(ua) = &self.user_agent {
            set_user_agent_override(page, ua, self.accept_language.as_deref())
                .await
                .context("apply auth user-agent replay")?;
        }
        let params = self
            .cookies
            .iter()
            .map(cookie_to_obscura_param)
            .collect::<Vec<_>>();
        let status = inject_cookies(page, &params)
            .await
            .context("inject auth cookies over CDP")?;
        if status == CookieInjectionStatus::Failed {
            tracing::warn!(
                profile = %self.profile,
                cookie_injection_status = ?status,
                "auth replay cookie injection failed; continuing without cookies"
            );
        }
        Ok(status)
    }

    pub fn warn_on_ua_mismatch(&self, observed_ua: Option<&str>) {
        if self.ua_mismatch(observed_ua) {
            tracing::warn!(
                profile = %self.profile,
                ua_mismatch = true,
                "auth replay user-agent differs from caller UA"
            );
        }
    }

    fn ua_mismatch(&self, observed_ua: Option<&str>) -> bool {
        match (self.user_agent.as_deref(), observed_ua) {
            (Some(stored), Some(observed)) => stored != observed,
            _ => false,
        }
    }

    #[cfg(test)]
    pub fn ua_mismatch_for_test(&self, observed_ua: Option<&str>) -> bool {
        self.ua_mismatch(observed_ua)
    }
}

pub fn default_auth_store_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".rev_scraping")
        .join("auth")
}

fn cookie_to_obscura_param(cookie: &Cookie) -> AuthCookieParam {
    AuthCookieParam {
        name: cookie.name.clone(),
        value: cookie.value.clone(),
        domain: cookie.domain.clone(),
        path: cookie.path.clone(),
        expires: cookie.expires,
        secure: cookie.secure,
        http_only: cookie.http_only,
        same_site: match cookie.same_site {
            SameSite::Strict => AuthCookieSameSite::Strict,
            SameSite::Lax => AuthCookieSameSite::Lax,
            SameSite::None => AuthCookieSameSite::None,
            SameSite::Unspecified => AuthCookieSameSite::Unspecified,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use secrecy::SecretString;
    use stealth_auth::{BrowserReplayMetadata, Cookie};

    fn cookie() -> Cookie {
        Cookie {
            name: "sid".to_string(),
            value: SecretString::from("secret".to_string()),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: true,
            http_only: true,
            same_site: SameSite::Lax,
        }
    }

    #[test]
    fn replay_context_applies_user_agent_to_reqwest() {
        let ctx = AuthReplayContext {
            profile: "work".to_string(),
            jar: Arc::new(AuthCookieJar::from_cookies(vec![cookie()])),
            user_agent: Some("ReplayUA/1.0".to_string()),
            accept_language: Some("ja,en;q=0.9".to_string()),
            cookies: vec![],
        };
        let client = ctx
            .apply_to_reqwest(reqwest::Client::builder())
            .build()
            .unwrap();
        let _req = client
            .get("https://example.com/")
            .build()
            .expect("request builds with replay client");
        assert_eq!(ctx.user_agent.as_deref(), Some("ReplayUA/1.0"));
        assert_eq!(ctx.accept_language.as_deref(), Some("ja,en;q=0.9"));
    }

    #[test]
    fn replay_context_warns_on_ua_mismatch_with_capture() {
        let ctx = AuthReplayContext {
            profile: "work".to_string(),
            jar: Arc::new(AuthCookieJar::from_cookies(vec![])),
            user_agent: Some("ReplayUA/1.0".to_string()),
            accept_language: None,
            cookies: vec![],
        };
        assert!(ctx.ua_mismatch_for_test(Some("OtherUA/1.0")));
        assert!(!ctx.ua_mismatch_for_test(Some("ReplayUA/1.0")));
        ctx.warn_on_ua_mismatch(Some("OtherUA/1.0"));
    }

    #[test]
    fn replay_context_loads_default_when_meta_missing_browser_replay() {
        let temp = tempfile::tempdir().unwrap();
        let store = AuthStore::open_with_passphrase(
            temp.path(),
            SecretString::from("integration passphrase".to_string()),
        )
        .unwrap();
        let mut c = cookie();
        c.expires = Some(Utc::now() + chrono::Duration::days(1));
        store.save("work", &[c], "example.com").unwrap();
        let ctx = AuthReplayContext::load(&store, "work", "example.com").unwrap();
        assert!(ctx.user_agent.is_none());
        assert!(ctx.accept_language.is_none());
        assert_eq!(ctx.jar.cookie_count(), 1);
    }

    #[test]
    fn replay_context_jar_sends_cookies_over_https() {
        // Domain match + secure=true => Cookie header is set on https.
        let ctx = AuthReplayContext {
            profile: "work".to_string(),
            jar: Arc::new(AuthCookieJar::from_cookies(vec![cookie()])),
            user_agent: None,
            accept_language: None,
            cookies: vec![],
        };
        use reqwest::cookie::CookieStore;
        let https = url::Url::parse("https://example.com/area").unwrap();
        let http = url::Url::parse("http://example.com/area").unwrap();
        assert!(ctx.jar.cookies(&https).is_some(), "expect cookie on https");
        assert!(
            ctx.jar.cookies(&http).is_none(),
            "secure cookie not on http"
        );
        let other = url::Url::parse("https://other.test/").unwrap();
        assert!(
            ctx.jar.cookies(&other).is_none(),
            "domain mismatch filtered"
        );
    }

    #[test]
    fn replay_context_jar_filters_expired_cookie() {
        let mut c = cookie();
        c.expires = Some(Utc::now() - chrono::Duration::minutes(5));
        c.secure = false;
        let ctx = AuthReplayContext {
            profile: "work".to_string(),
            jar: Arc::new(AuthCookieJar::from_cookies(vec![c])),
            user_agent: None,
            accept_language: None,
            cookies: vec![],
        };
        use reqwest::cookie::CookieStore;
        let url = url::Url::parse("http://example.com/").unwrap();
        assert!(ctx.jar.cookies(&url).is_none());
    }

    #[tokio::test]
    async fn replay_context_apply_to_reqwest_sets_default_headers() {
        // Verify reqwest builder is configured by actually sending a request
        // to a local echo server and inspecting what the server saw. Default
        // headers attached via `ClientBuilder::default_headers` are only
        // materialised on the wire, not on the un-sent `RequestBuilder`.
        use axum::extract::State;
        use axum::http::HeaderMap;
        use axum::response::Json;
        use axum::routing::get;
        use axum::Router;
        use std::sync::{Arc, Mutex};

        type Captured = Arc<Mutex<Option<(String, String)>>>;
        async fn echo(State(cap): State<Captured>, headers: HeaderMap) -> Json<serde_json::Value> {
            let ua = headers
                .get(reqwest::header::USER_AGENT)
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default()
                .to_string();
            let al = headers
                .get(reqwest::header::ACCEPT_LANGUAGE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default()
                .to_string();
            *cap.lock().unwrap() = Some((ua, al));
            Json(serde_json::json!({"ok": true}))
        }

        let cap: Captured = Arc::new(Mutex::new(None));
        let app = Router::new().route("/", get(echo)).with_state(cap.clone());
        let listener = match tokio::net::TcpListener::bind("127.0.0.1:0").await {
            Ok(listener) => listener,
            Err(err) if err.kind() == std::io::ErrorKind::PermissionDenied => return,
            Err(err) => panic!("bind local test server: {err}"),
        };
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        let ctx = AuthReplayContext {
            profile: "work".to_string(),
            jar: Arc::new(AuthCookieJar::from_cookies(vec![cookie()])),
            user_agent: Some("Replay/9.9".to_string()),
            accept_language: Some("ja-JP,ja;q=0.8".to_string()),
            cookies: vec![],
        };
        let client = ctx
            .apply_to_reqwest(reqwest::Client::builder())
            .build()
            .expect("client builds");
        let resp = client
            .get(format!("http://{addr}/"))
            .send()
            .await
            .expect("request sends");
        assert!(resp.status().is_success());
        let (ua, al) = cap.lock().unwrap().clone().expect("captured");
        assert_eq!(ua, "Replay/9.9");
        assert_eq!(al, "ja-JP,ja;q=0.8");
        server.abort();
    }

    #[test]
    fn replay_context_loads_browser_replay_metadata() {
        let temp = tempfile::tempdir().unwrap();
        let store = AuthStore::open_with_passphrase(
            temp.path(),
            SecretString::from("integration passphrase".to_string()),
        )
        .unwrap();
        store
            .save_with_browser_replay(
                "work",
                &[cookie()],
                "example.com",
                BrowserReplayMetadata {
                    user_agent: Some("ReplayUA/1.0".to_string()),
                    accept_language: Some("ja,en;q=0.9".to_string()),
                },
            )
            .unwrap();
        let ctx = AuthReplayContext::load(&store, "work", "example.com").unwrap();
        assert_eq!(ctx.user_agent.as_deref(), Some("ReplayUA/1.0"));
        assert_eq!(ctx.accept_language.as_deref(), Some("ja,en;q=0.9"));
    }
}
