// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9c (auth replay CDP injection)
//! CDP helpers for replaying stored authentication state into a page target.

use chromiumoxide::cdp::browser_protocol::network::{
    CookieParam as CdpCookieParam, CookieSameSite, SetCookiesParams, SetUserAgentOverrideParams,
    TimeSinceEpoch,
};
use chrono::{DateTime, Utc};
use secrecy::{ExposeSecret, SecretString};

use crate::error::{BridgeError, Result};
use crate::PageHandle;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SameSite {
    Strict,
    Lax,
    None,
    Unspecified,
}

#[derive(Clone, Debug)]
pub struct CookieParam {
    pub name: String,
    pub value: SecretString,
    pub domain: String,
    pub path: String,
    pub expires: Option<DateTime<Utc>>,
    pub secure: bool,
    pub http_only: bool,
    pub same_site: SameSite,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CookieInjectionStatus {
    Ok,
    Failed,
    Skipped,
}

pub async fn inject_cookies(
    page: &PageHandle,
    cookies: &[CookieParam],
) -> Result<CookieInjectionStatus> {
    let params = cookies
        .iter()
        .map(cookie_param_to_cdp_param)
        .collect::<Result<Vec<_>>>()?;
    if params.is_empty() {
        return Ok(CookieInjectionStatus::Skipped);
    }
    match page.page.execute(SetCookiesParams::new(params)).await {
        Ok(_) => Ok(classify_cdp_result::<(), BridgeError>(Ok(()))),
        Err(err) => {
            let err = BridgeError::from(err);
            let cookies_redacted = redact_cookies_for_log(cookies);
            tracing::warn!(
                target: "obscura_bridge::auth_inject",
                cookie_count = cookies.len(),
                error = %err,
                cookies_redacted = ?cookies_redacted,
                "Network.setCookies failed; continuing without cookies"
            );
            Ok(classify_cdp_result::<(), BridgeError>(Err(err)))
        }
    }
}

pub async fn set_user_agent_override(
    page: &PageHandle,
    ua: &str,
    accept_language: Option<&str>,
) -> Result<()> {
    let mut params = SetUserAgentOverrideParams::new(ua);
    params.accept_language = accept_language.map(str::to_string);
    page.page
        .set_user_agent(params)
        .await
        .map_err(BridgeError::from)?;
    Ok(())
}

fn cookie_param_to_cdp_param(cookie: &CookieParam) -> Result<CdpCookieParam> {
    validate_cookie_param(cookie)?;
    let mut cdp = CdpCookieParam::new(
        cookie.name.clone(),
        cookie.value.expose_secret().to_string(),
    );
    let domain = cookie.domain.trim();
    if !domain.is_empty() {
        cdp.domain = Some(domain.to_string());
    }
    cdp.path = Some(if cookie.path.is_empty() {
        "/".to_string()
    } else {
        cookie.path.clone()
    });
    cdp.secure = Some(effective_secure(cookie));
    cdp.http_only = Some(cookie.http_only);
    cdp.same_site = match cookie.same_site {
        SameSite::Strict => Some(CookieSameSite::Strict),
        SameSite::Lax => Some(CookieSameSite::Lax),
        SameSite::None => Some(CookieSameSite::None),
        SameSite::Unspecified => None,
    };
    cdp.expires = cookie
        .expires
        .map(|expires| TimeSinceEpoch::new(expires.timestamp() as f64));
    Ok(cdp)
}

fn validate_cookie_param(cookie: &CookieParam) -> Result<()> {
    if cookie.name.starts_with("__Host-") {
        if cookie.path != "/" {
            return Err(BridgeError::Other(
                "__Host- cookie replay requires path=/".to_string(),
            ));
        }
        if !cookie.domain.trim().is_empty() {
            return Err(BridgeError::Other(
                "__Host- cookie replay requires no Domain attribute".to_string(),
            ));
        }
    }
    Ok(())
}

fn effective_secure(cookie: &CookieParam) -> bool {
    cookie.secure
        || cookie.name.starts_with("__Host-")
        || cookie.name.starts_with("__Secure-")
        || matches!(cookie.same_site, SameSite::None)
}

fn classify_cdp_result<T, E>(res: std::result::Result<T, E>) -> CookieInjectionStatus {
    match res {
        Ok(_) => CookieInjectionStatus::Ok,
        Err(_) => CookieInjectionStatus::Failed,
    }
}

fn redact_cookie_for_log(cookie: &CookieParam) -> String {
    format!(
        "name={}, domain={}, path={}, value=<redacted:{}b>",
        cookie.name,
        cookie.domain,
        cookie.path,
        cookie.value.expose_secret().len()
    )
}

fn redact_cookies_for_log(cookies: &[CookieParam]) -> Vec<String> {
    cookies.iter().map(redact_cookie_for_log).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn cookie(name: &str, same_site: SameSite) -> CookieParam {
        CookieParam {
            name: name.to_string(),
            value: SecretString::from("secret".to_string()),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: true,
            http_only: true,
            same_site,
        }
    }

    #[test]
    fn cdp_inject_maps_same_site_correctly_all_variants() {
        let strict = cookie_param_to_cdp_param(&cookie("strict", SameSite::Strict)).unwrap();
        let lax = cookie_param_to_cdp_param(&cookie("lax", SameSite::Lax)).unwrap();
        let none = cookie_param_to_cdp_param(&cookie("none", SameSite::None)).unwrap();
        let unspecified =
            cookie_param_to_cdp_param(&cookie("unspecified", SameSite::Unspecified)).unwrap();

        assert_eq!(strict.same_site, Some(CookieSameSite::Strict));
        assert_eq!(lax.same_site, Some(CookieSameSite::Lax));
        assert_eq!(none.same_site, Some(CookieSameSite::None));
        assert_eq!(unspecified.same_site, None);
    }

    #[test]
    fn cdp_inject_preserves_secure_flag() {
        let mut secure = cookie("plain-secure", SameSite::Lax);
        secure.secure = true;
        let cdp_secure = cookie_param_to_cdp_param(&secure).unwrap();
        assert_eq!(cdp_secure.secure, Some(true));

        let mut insecure = cookie("plain-insecure", SameSite::Lax);
        insecure.secure = false;
        let cdp_insecure = cookie_param_to_cdp_param(&insecure).unwrap();
        assert_eq!(cdp_insecure.secure, Some(false));
    }

    #[test]
    fn cdp_inject_preserves_http_only_flag() {
        let mut http_only = cookie("http-only", SameSite::Lax);
        http_only.http_only = true;
        let cdp_http_only = cookie_param_to_cdp_param(&http_only).unwrap();
        assert_eq!(cdp_http_only.http_only, Some(true));

        let mut js_visible = cookie("js-visible", SameSite::Lax);
        js_visible.http_only = false;
        let cdp_js_visible = cookie_param_to_cdp_param(&js_visible).unwrap();
        assert_eq!(cdp_js_visible.http_only, Some(false));
    }

    #[test]
    fn cdp_inject_preserves_expires_field() {
        let mut c = cookie("persistent", SameSite::Lax);
        let expires = Utc.with_ymd_and_hms(2032, 3, 4, 5, 6, 7).unwrap();
        c.expires = Some(expires);
        let cdp = cookie_param_to_cdp_param(&c).unwrap();
        assert_eq!(
            cdp.expires.as_ref().map(TimeSinceEpoch::inner).copied(),
            Some(expires.timestamp() as f64)
        );
    }

    #[test]
    fn cdp_inject_handles_session_cookie_without_expires() {
        let mut c = cookie("session", SameSite::Lax);
        c.expires = None;
        let cdp = cookie_param_to_cdp_param(&c).unwrap();
        assert_eq!(cdp.expires, None);
    }

    #[test]
    fn cdp_inject_graceful_degrade_on_cdp_error() {
        assert_eq!(
            classify_cdp_result::<_, BridgeError>(Ok(())),
            CookieInjectionStatus::Ok
        );
        assert_eq!(
            classify_cdp_result::<(), _>(Err(BridgeError::Other("boom".to_string()))),
            CookieInjectionStatus::Failed
        );
    }

    #[test]
    fn inject_cookies_does_not_log_value() {
        let mut c = cookie("sid", SameSite::Lax);
        c.value = SecretString::from("SUPERSECRETVALUE12345".to_string());
        let redacted = redact_cookie_for_log(&c);
        assert!(redacted.contains("value=<redacted:21b>"));
        assert!(!redacted.contains("SUPERSECRETVALUE12345"));
    }

    #[test]
    fn cdp_inject_validates_host_prefix() {
        let mut c = cookie("__Host-session", SameSite::Lax);
        c.domain = String::new();
        c.path = "/account".to_string();
        assert!(cookie_param_to_cdp_param(&c).is_err());

        c.path = "/".to_string();
        c.domain = "example.com".to_string();
        assert!(cookie_param_to_cdp_param(&c).is_err());

        c.domain = String::new();
        assert!(cookie_param_to_cdp_param(&c).is_ok());
    }

    #[test]
    fn cdp_inject_marks_samesite_none_as_secure() {
        let mut c = cookie("cross-site", SameSite::None);
        c.secure = false;
        let cdp = cookie_param_to_cdp_param(&c).unwrap();
        assert_eq!(cdp.secure, Some(true));
    }

    #[tokio::test]
    #[ignore]
    async fn e2e_inject_and_get_round_trip_via_obscura() {
        if std::env::var("REV_SCRAPING_RUN_OBSCURA").as_deref() != Ok("1") {
            return;
        }

        use std::sync::Arc;

        use chromiumoxide::cdp::browser_protocol::network::GetCookiesParams;
        use chromiumoxide::{Browser, BrowserConfig};
        use futures::StreamExt;

        let (mut browser, mut handler) = Browser::launch(
            BrowserConfig::builder()
                .no_sandbox()
                .build()
                .expect("browser config builds"),
        )
        .await
        .expect("launch chromium");
        let handler_task = tokio::spawn(async move { while handler.next().await.is_some() {} });

        let cdp_page = browser
            .new_page("data:text/html,<html><body>cookie round trip</body></html>")
            .await
            .expect("open page");
        let page = PageHandle {
            target_id: crate::page::TargetId(cdp_page.target_id().inner().clone()),
            page: Arc::new(cdp_page.clone()),
        };
        let c = CookieParam {
            name: "round_trip_sid".to_string(),
            value: SecretString::from("secret".to_string()),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: true,
            http_only: true,
            same_site: SameSite::Lax,
        };

        assert_eq!(
            inject_cookies(&page, &[c]).await.expect("inject cookies"),
            CookieInjectionStatus::Ok
        );
        let cookies = cdp_page
            .execute(
                GetCookiesParams::builder()
                    .url("https://example.com/")
                    .build(),
            )
            .await
            .expect("get cookies")
            .result
            .cookies;
        assert!(cookies.iter().any(|cookie| cookie.name == "round_trip_sid"));

        browser.close().await.expect("close browser");
        handler_task.abort();
    }
}
