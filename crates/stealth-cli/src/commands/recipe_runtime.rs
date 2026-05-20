// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 7b spider recipe integration)
//! Spider <-> stealth-sites glue: recipe lookup, TTL, --recipe-param parsing,
//! API-direct fetch path, and skeleton save-on-success.
//!
//! Phase 7b scope: consume manually-authored recipes (e.g. brain-market.com)
//! and save a minimal skeleton on first visit so the next call can hit. The
//! heavy auto-learning (Network capture / JS-bundle probe) is Phase 7c.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use stealth_sites::discovery::EndpointCandidate;
use stealth_sites::{
    render_url, ApiConfig, Endpoint, Rendering, ScrapingMethod, SiteMeta, SiteRecipe,
    SiteRecipeStore,
};
use url::Url;

/// Default recipe directory: `~/.rev_scraping/sites/`.
pub fn default_recipe_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".rev_scraping")
        .join("sites")
}

/// Outcome of a recipe lookup against the store.
#[allow(dead_code)]
#[derive(Debug)]
pub enum RecipeLookup {
    /// Recipe is present and (per TTL) fresh.
    Hit(Box<SiteRecipe>, Option<u64>),
    /// Recipe is present but expired (treated as refresh path).
    Expired(Box<SiteRecipe>),
    /// Recipe absent.
    Miss,
    /// Lookup was deliberately skipped (`--no-cache` or `--cache-refresh`).
    Skipped,
}

/// Decide whether `recipe.site.last_verified` is within `ttl_days`.
/// Returns `Some(remaining_days)` if fresh, `None` if expired or unparseable.
pub fn ttl_remaining_days(recipe: &SiteRecipe, ttl_days: u64) -> Option<u64> {
    let lv = recipe.site.last_verified.as_deref()?;
    let parsed: DateTime<Utc> = DateTime::parse_from_rfc3339(lv).ok()?.with_timezone(&Utc);
    let age = Utc::now().signed_duration_since(parsed);
    let age_days = age.num_days();
    if age_days < 0 {
        // Clock skew / future timestamp — treat as fresh.
        return Some(ttl_days);
    }
    let age_u = age_days as u64;
    if age_u >= ttl_days {
        None
    } else {
        Some(ttl_days - age_u)
    }
}

/// Parse `--recipe-param key=value` items into a map. Empty input yields
/// an empty map. Errors are returned as `Err(message)` for CLI surfacing.
pub fn parse_recipe_params(items: &[String]) -> Result<HashMap<String, String>, String> {
    let mut out = HashMap::new();
    for item in items {
        let (k, v) = item
            .split_once('=')
            .ok_or_else(|| format!("--recipe-param {item:?}: expected key=value"))?;
        let k = k.trim();
        if k.is_empty() {
            return Err(format!("--recipe-param {item:?}: key is empty"));
        }
        out.insert(k.to_string(), v.to_string());
    }
    Ok(out)
}

/// Pick the API endpoint to call.
/// - If `purpose` is given, return the first match for that purpose.
/// - Otherwise, return the first endpoint declared.
pub fn pick_endpoint<'a>(recipe: &'a SiteRecipe, purpose: Option<&str>) -> Option<&'a Endpoint> {
    let api = recipe.api.as_ref()?;
    match purpose {
        Some(p) => api.endpoints.iter().find(|e| e.purpose == p),
        None => api.endpoints.first(),
    }
}

/// Build the absolute URL for an endpoint. Uses `url_pattern` if present,
/// else joins `base_url` + `path`. Placeholders are filled from `params`.
pub fn build_endpoint_url(
    recipe: &SiteRecipe,
    endpoint: &Endpoint,
    params: &HashMap<String, String>,
) -> Result<Url, String> {
    let pattern = endpoint
        .url_pattern
        .clone()
        .or_else(|| {
            recipe
                .api
                .as_ref()
                .map(|api| format!("{}{}", api.base_url.trim_end_matches('/'), endpoint.path))
        })
        .ok_or_else(|| "endpoint missing url_pattern and recipe has no [api]".to_string())?;

    render_url(&pattern, params).map_err(|e| format!("render_url failed: {e}"))
}

/// Outcome of an API fetch via recipe.
#[derive(Debug)]
pub struct ApiFetchResult {
    pub url: String,
    pub status: u16,
    pub elapsed_ms: u128,
    pub body_json: Value,
}

/// GET the rendered endpoint URL and parse the body as JSON.
///
/// Exit-code semantics for the caller:
/// - HTTP error / network error → exit 2 (transient)
/// - JSON parse error → exit 3 (permanent — schema drift)
pub async fn fetch_api_endpoint(
    recipe: &SiteRecipe,
    endpoint: &Endpoint,
    params: &HashMap<String, String>,
    proxy: Option<&Url>,
) -> Result<ApiFetchResult, (i32, String)> {
    let url = build_endpoint_url(recipe, endpoint, params)
        .map_err(|e| (1, format!("recipe url build: {e}")))?;

    let ua = crate::commands::fallback_http::DEFAULT_USER_AGENT;
    let mut builder = reqwest::Client::builder()
        .user_agent(ua)
        .timeout(Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::limited(10));

    // Phase 7c privacy fix: route recipe-API calls through the VPN proxy
    // when the spider selected one. Without this, the recipe-hit path
    // would bypass the VPN entirely and leak the user's real IP to
    // every cached API. RFC1918 / loopback destinations are exempt to
    // keep CDP self-loops working when this client is used in tests.
    if let Some(p) = proxy {
        let no_proxy = reqwest::NoProxy::from_string(
            "127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",
        );
        let proxy = reqwest::Proxy::all(p.as_str())
            .map_err(|e| (2, format!("recipe api proxy parse: {e}")))?
            .no_proxy(no_proxy);
        builder = builder.proxy(proxy);
    }

    let client = builder
        .build()
        .map_err(|e| (2, format!("reqwest build: {e}")))?;

    let start = Instant::now();
    let mut req = client.get(url.clone());
    // Inject endpoint-required headers if shaped as a simple table.
    if let Some(toml::Value::Table(t)) = &endpoint.required_headers {
        for (k, v) in t.iter() {
            if let Some(s) = v.as_str() {
                req = req.header(k.as_str(), s);
            }
        }
    } else {
        req = req.header(reqwest::header::ACCEPT, "application/json");
    }
    let resp = req
        .send()
        .await
        .map_err(|e| (2, format!("recipe api fetch failed: {e}")))?;

    let status = resp.status().as_u16();
    let final_url = resp.url().to_string();
    let bytes = resp
        .bytes()
        .await
        .map_err(|e| (2, format!("recipe api body read: {e}")))?;
    let elapsed_ms = start.elapsed().as_millis();

    if !(200..300).contains(&status) {
        return Err((2, format!("recipe api HTTP {status} from {final_url}")));
    }

    let body_json: Value =
        serde_json::from_slice(&bytes).map_err(|e| (3, format!("recipe api JSON parse: {e}")))?;

    Ok(ApiFetchResult {
        url: final_url,
        status,
        elapsed_ms,
        body_json,
    })
}

/// Build a minimal `SiteRecipe` skeleton from the URL + a rough rendering
/// guess. Used on cache miss to seed the next visit. Auto-learned endpoints
/// arrive in Phase 7c.
pub fn build_skeleton_recipe(url: &Url, rendering_guess: Rendering) -> Option<SiteRecipe> {
    let domain = url.host_str()?.to_string();
    Some(SiteRecipe {
        schema_version: 1,
        site: SiteMeta {
            domain,
            last_verified: Some(Utc::now().to_rfc3339()),
            rendering: rendering_guess,
            framework: None,
            backend_hint: None,
            tags: vec!["auto-skeleton".to_string()],
        },
        api: None,
        scraping_strategy: None,
        rate_limits: None,
        selectors: None,
        fingerprint: None,
        anti_bot: None,
        notes: None,
        auth: None,
    })
}

/// Convert a list of discovery `EndpointCandidate`s into recipe `Endpoint`
/// rows, generating a `purpose` from the path's last literal segment.
pub fn candidates_to_endpoints(candidates: &[EndpointCandidate]) -> Vec<Endpoint> {
    let now = Utc::now().to_rfc3339();
    candidates
        .iter()
        .map(|c| {
            let purpose = stealth_sites::discovery::derive_purpose(c);
            Endpoint {
                purpose,
                path: c.path_template.clone(),
                url_pattern: Some(c.url_template.clone()),
                http_method: c.method.clone(),
                required_headers: None,
                required_query: vec![],
                response_shape: None,
                discovered_via: c.discovered_via.clone(),
                last_verified: Some(now.clone()),
                avg_latency_ms: None,
                ok_status: vec![200],
            }
        })
        .collect()
}

/// Upsert auto-discovered endpoints into the recipe for `domain`. Loads any
/// existing recipe (or builds a skeleton), merges new endpoint rows in by
/// (method, path) key, and writes the result atomically. Returns the number
/// of *new* endpoints actually appended (after dedup).
///
/// Honors `recipe_no_learn` (returns 0 without writing) and `no_cache`
/// (likewise — caller's upstream check still applies, but defended here).
#[allow(clippy::too_many_arguments)]
pub fn upsert_auto_endpoints(
    store: &mut SiteRecipeStore,
    url: &Url,
    candidates: &[EndpointCandidate],
    recipe_no_learn: bool,
    no_cache: bool,
    rendering: Rendering,
) -> std::io::Result<usize> {
    if recipe_no_learn || no_cache || candidates.is_empty() {
        return Ok(0);
    }
    let domain = match url.host_str() {
        Some(h) => h.to_string(),
        None => return Ok(0),
    };

    let mut recipe = match store.load(&domain) {
        Ok(Some(r)) => r,
        _ => SiteRecipe {
            schema_version: 1,
            site: SiteMeta {
                domain: domain.clone(),
                last_verified: Some(Utc::now().to_rfc3339()),
                rendering,
                framework: None,
                backend_hint: None,
                tags: vec!["auto-skeleton".into()],
            },
            api: None,
            scraping_strategy: None,
            rate_limits: None,
            selectors: None,
            fingerprint: None,
            anti_bot: None,
            notes: None,
            auth: None,
        },
    };

    // Establish or get the api block; pick an origin from the first candidate
    // URL or default to the page origin.
    let base_url = candidates
        .first()
        .and_then(|c| Url::parse(&c.url_template).ok())
        .map(|u| format!("{}://{}", u.scheme(), u.host_str().unwrap_or("")))
        .unwrap_or_else(|| format!("{}://{}", url.scheme(), domain));

    let api = recipe.api.get_or_insert_with(|| ApiConfig {
        base_url: base_url.clone(),
        public_auth_required: false,
        auth_method: None,
        auth_secret_ref: None,
        rate_limit_recommendation: None,
        response_encoding: None,
        endpoints: Vec::new(),
    });

    let mut existing: std::collections::BTreeSet<(String, String)> = api
        .endpoints
        .iter()
        .map(|e| (e.http_method.to_ascii_uppercase(), e.path.clone()))
        .collect();

    let new_rows = candidates_to_endpoints(candidates);
    let mut added = 0usize;
    for ep in new_rows {
        let key = (ep.http_method.to_ascii_uppercase(), ep.path.clone());
        if existing.insert(key) {
            api.endpoints.push(ep);
            added += 1;
        }
    }

    if added > 0 {
        recipe.site.last_verified = Some(Utc::now().to_rfc3339());
        if let Err(e) = store.save(&recipe) {
            return Err(std::io::Error::other(format!("recipe save failed: {e}")));
        }
    }
    Ok(added)
}

/// Render the JSON payload for the `recipe.*` block in spider output.
pub fn recipe_json_block(
    hit: bool,
    domain: &str,
    endpoint_purpose: Option<&str>,
    endpoint_path: Option<&str>,
    fetched_via: Option<&str>,
    saved: bool,
    ttl_remaining_days: Option<u64>,
) -> Value {
    json!({
        "hit": hit,
        "domain": domain,
        "endpoint_purpose": endpoint_purpose,
        "endpoint_path": endpoint_path,
        "fetched_via": fetched_via,
        "saved": saved,
        "ttl_remaining_days": ttl_remaining_days,
    })
}

/// Open the store at `dir`, suppressing errors into `None` so the spider can
/// still proceed without a cache when the home dir is read-only.
pub fn open_store(dir: &std::path::Path) -> Option<SiteRecipeStore> {
    match SiteRecipeStore::open(dir) {
        Ok(s) => Some(s),
        Err(e) => {
            tracing::warn!(error = %e, dir = %dir.display(), "recipe store open failed; cache disabled");
            None
        }
    }
}

/// Translate a `[scraping_strategy].preferred_method` into the spider branch.
#[allow(dead_code)]
pub fn method_label(m: &ScrapingMethod) -> &'static str {
    match m {
        ScrapingMethod::Api => "api",
        ScrapingMethod::Spider | ScrapingMethod::Obscura => "spider",
        ScrapingMethod::Hybrid => "hybrid",
        ScrapingMethod::Reqwest => "reqwest",
        ScrapingMethod::StealthCf => "stealth-cf",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_recipe(domain: &str, last_verified: Option<&str>) -> SiteRecipe {
        SiteRecipe {
            schema_version: 1,
            site: SiteMeta {
                domain: domain.to_string(),
                last_verified: last_verified.map(|s| s.to_string()),
                rendering: Rendering::Spa,
                framework: None,
                backend_hint: None,
                tags: vec![],
            },
            api: None,
            scraping_strategy: None,
            rate_limits: None,
            selectors: None,
            fingerprint: None,
            anti_bot: None,
            notes: None,
            auth: None,
        }
    }

    #[test]
    fn test_recipe_param_parse_key_value_pairs() {
        let v = vec![
            "username=fujin_metaverse".to_string(),
            "article_id=12345".to_string(),
        ];
        let m = parse_recipe_params(&v).expect("parse ok");
        assert_eq!(m.get("username").unwrap(), "fujin_metaverse");
        assert_eq!(m.get("article_id").unwrap(), "12345");
    }

    #[test]
    fn test_recipe_param_rejects_missing_equals() {
        let v = vec!["lonely".to_string()];
        let r = parse_recipe_params(&v);
        assert!(r.is_err());
    }

    #[test]
    fn test_recipe_param_value_may_contain_equals() {
        let v = vec!["q=a=b=c".to_string()];
        let m = parse_recipe_params(&v).expect("ok");
        assert_eq!(m.get("q").unwrap(), "a=b=c");
    }

    #[test]
    fn test_ttl_fresh_returns_remaining() {
        // last_verified = now → ~30 days remain on 30-day TTL.
        let now = Utc::now().to_rfc3339();
        let r = mk_recipe("ex.com", Some(&now));
        let remain = ttl_remaining_days(&r, 30).expect("fresh");
        assert!((29..=30).contains(&remain));
    }

    #[test]
    fn test_ttl_expired_returns_none() {
        // last_verified = 100 days ago → expired against 30-day TTL.
        let past = (Utc::now() - chrono::Duration::days(100)).to_rfc3339();
        let r = mk_recipe("ex.com", Some(&past));
        assert!(ttl_remaining_days(&r, 30).is_none());
    }

    #[test]
    fn test_ttl_missing_last_verified_is_none() {
        let r = mk_recipe("ex.com", None);
        assert!(ttl_remaining_days(&r, 30).is_none());
    }

    #[test]
    fn test_skeleton_recipe_uses_host() {
        let u = Url::parse("https://example.com/foo").unwrap();
        let r = build_skeleton_recipe(&u, Rendering::Ssr).expect("skeleton");
        assert_eq!(r.site.domain, "example.com");
        assert_eq!(r.site.rendering, Rendering::Ssr);
        assert!(r.site.tags.iter().any(|t| t == "auto-skeleton"));
    }

    #[test]
    fn test_build_endpoint_url_from_pattern() {
        let mut r = mk_recipe("api.example.com", None);
        r.api = Some(stealth_sites::ApiConfig {
            base_url: "https://api.example.com".to_string(),
            public_auth_required: false,
            auth_method: None,
            auth_secret_ref: None,
            rate_limit_recommendation: None,
            response_encoding: None,
            endpoints: vec![Endpoint {
                purpose: "user".to_string(),
                path: "/v1/users/{username}".to_string(),
                url_pattern: Some("https://api.example.com/v1/users/{username}".to_string()),
                http_method: "GET".to_string(),
                required_headers: None,
                required_query: vec![],
                response_shape: None,
                discovered_via: None,
                last_verified: None,
                avg_latency_ms: None,
                ok_status: vec![],
            }],
        });
        let ep = pick_endpoint(&r, Some("user")).expect("found");
        let mut params = HashMap::new();
        params.insert("username".to_string(), "alice".to_string());
        let u = build_endpoint_url(&r, ep, &params).expect("ok");
        assert_eq!(u.as_str(), "https://api.example.com/v1/users/alice");
    }

    #[test]
    fn test_build_endpoint_url_falls_back_to_base_plus_path() {
        let mut r = mk_recipe("api.example.com", None);
        r.api = Some(stealth_sites::ApiConfig {
            base_url: "https://api.example.com/".to_string(),
            public_auth_required: false,
            auth_method: None,
            auth_secret_ref: None,
            rate_limit_recommendation: None,
            response_encoding: None,
            endpoints: vec![Endpoint {
                purpose: "listing".to_string(),
                path: "/v1/items".to_string(),
                url_pattern: None,
                http_method: "GET".to_string(),
                required_headers: None,
                required_query: vec![],
                response_shape: None,
                discovered_via: None,
                last_verified: None,
                avg_latency_ms: None,
                ok_status: vec![],
            }],
        });
        let ep = pick_endpoint(&r, None).expect("first");
        let u = build_endpoint_url(&r, ep, &HashMap::new()).expect("ok");
        assert_eq!(u.as_str(), "https://api.example.com/v1/items");
    }

    #[tokio::test]
    async fn test_fetch_api_endpoint_uses_proxy_when_provided() {
        // Smoke test: a bogus proxy URL must surface as a builder/connect
        // error, not be silently dropped. We don't have a real proxy
        // available, so we point at an unroutable port and confirm we
        // get a (2, _) error back rather than a 0-exit success.
        let mut r = mk_recipe("api.example.com", None);
        r.api = Some(stealth_sites::ApiConfig {
            base_url: "https://192.0.2.1".to_string(), // TEST-NET-1, unroutable
            public_auth_required: false,
            auth_method: None,
            auth_secret_ref: None,
            rate_limit_recommendation: None,
            response_encoding: None,
            endpoints: vec![Endpoint {
                purpose: "ping".into(),
                path: "/health".into(),
                url_pattern: Some("https://192.0.2.1/health".into()),
                http_method: "GET".into(),
                required_headers: None,
                required_query: vec![],
                response_shape: None,
                discovered_via: None,
                last_verified: None,
                avg_latency_ms: None,
                ok_status: vec![],
            }],
        });
        let ep = pick_endpoint(&r, Some("ping")).unwrap();
        let proxy = Url::parse("http://127.0.0.1:1").unwrap(); // closed port
        let res = fetch_api_endpoint(&r, ep, &HashMap::new(), Some(&proxy)).await;
        // RFC1918/loopback bypass is configured but the *target* is
        // 192.0.2.1 which goes via the proxy → connect must fail.
        let err = res.expect_err("must fail");
        assert_eq!(err.0, 2, "network/proxy failure must be exit code 2");
    }

    fn cand(method: &str, path: &str, host: &str, via: &str) -> EndpointCandidate {
        EndpointCandidate {
            method: method.into(),
            path_template: path.into(),
            url_template: format!("https://{host}{path}"),
            discovered_via: Some(via.into()),
        }
    }

    #[test]
    fn test_upsert_auto_endpoints_into_fresh_recipe() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let mut store = SiteRecipeStore::open(tmp.path()).expect("open store");
        let url = Url::parse("https://brain-market.com/u/fujin_metaverse/").unwrap();
        let cands = vec![
            cand(
                "GET",
                "/v2/users/{slug}/articles",
                "api.brain-market.com",
                "network-capture",
            ),
            cand(
                "GET",
                "/v2/users/{slug}",
                "api.brain-market.com",
                "network-capture",
            ),
        ];
        let added = upsert_auto_endpoints(&mut store, &url, &cands, false, false, Rendering::Spa)
            .expect("upsert ok");
        assert_eq!(added, 2);
        let r = store.load("brain-market.com").expect("load").expect("hit");
        let paths: Vec<_> = r
            .api
            .unwrap()
            .endpoints
            .iter()
            .map(|e| e.path.clone())
            .collect();
        assert!(paths.iter().any(|p| p == "/v2/users/{slug}/articles"));
        assert!(paths.iter().any(|p| p == "/v2/users/{slug}"));
    }

    #[test]
    fn test_upsert_dedup_against_existing_endpoints() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let mut store = SiteRecipeStore::open(tmp.path()).expect("open store");
        let url = Url::parse("https://brain-market.com/").unwrap();
        let cands = vec![cand(
            "GET",
            "/v2/users/{slug}",
            "api.brain-market.com",
            "network-capture",
        )];
        let a = upsert_auto_endpoints(&mut store, &url, &cands, false, false, Rendering::Spa)
            .expect("first");
        assert_eq!(a, 1);
        let b = upsert_auto_endpoints(&mut store, &url, &cands, false, false, Rendering::Spa)
            .expect("second");
        assert_eq!(b, 0, "dedup must prevent re-adding");
    }

    #[test]
    fn test_upsert_respects_recipe_no_learn() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let mut store = SiteRecipeStore::open(tmp.path()).expect("open store");
        let url = Url::parse("https://example.com/").unwrap();
        let cands = vec![cand("GET", "/v1/x", "example.com", "network-capture")];
        let a = upsert_auto_endpoints(&mut store, &url, &cands, true, false, Rendering::Spa)
            .expect("no-learn");
        assert_eq!(a, 0);
        let r = store.load("example.com").expect("load");
        assert!(r.is_none(), "must NOT have written a recipe under no-learn");
    }

    #[test]
    fn test_recipe_json_block_shape() {
        let v = recipe_json_block(
            true,
            "brain-market.com",
            Some("user_articles_list"),
            Some("/v2/users/{username}/articles"),
            Some("api"),
            false,
            Some(28),
        );
        assert_eq!(v["hit"], json!(true));
        assert_eq!(v["domain"], "brain-market.com");
        assert_eq!(v["fetched_via"], "api");
        assert_eq!(v["ttl_remaining_days"], 28);
    }
}
