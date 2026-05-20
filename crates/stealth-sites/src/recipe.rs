// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 7a)
//
// Strongly typed view over the Site Recipe TOML schema (see
// `templates/sites/example.com.toml`).
//
// Several sub-objects are deliberately kept as `toml::Value` because the
// schema documents free-form shapes (`response_shape`, `rate_limit_recommendation`,
// `required_headers`, ...). The Phase 7a contract is "load + roundtrip without
// data loss"; downstream phases will tighten typing as needed.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

fn default_schema_version() -> u32 {
    1
}

fn default_http_method() -> String {
    "GET".to_string()
}

/// Top-level site recipe document.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteRecipe {
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,

    pub site: SiteMeta,

    #[serde(default)]
    pub api: Option<ApiConfig>,

    #[serde(default)]
    pub scraping_strategy: Option<ScrapingStrategy>,

    #[serde(default)]
    pub rate_limits: Option<RateLimits>,

    #[serde(default)]
    pub selectors: Option<Selectors>,

    #[serde(default)]
    pub fingerprint: Option<FingerprintHint>,

    #[serde(default)]
    pub anti_bot: Option<AntiBotConfig>,

    #[serde(default)]
    pub notes: Option<Notes>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth: Option<AuthRecipe>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthRecipe {
    #[serde(default)]
    pub required: bool,
    #[serde(default)]
    pub login_url: String,
    #[serde(default)]
    pub completion_pattern: Option<String>,
    #[serde(default)]
    pub recommended_profile: Option<String>,
    #[serde(default = "default_refusal_policy")]
    pub refusal_policy: RefusalPolicy,
    #[serde(default)]
    pub session_ttl_days: Option<u64>,
    #[serde(default)]
    pub note: Option<String>,
}

fn default_refusal_policy() -> RefusalPolicy {
    RefusalPolicy::Refuse
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RefusalPolicy {
    Refuse,
    WarnContinue,
    Allow,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RefusalAction {
    Continue,
    ContinueWithWarning(&'static str),
    Refuse(&'static str),
}

#[derive(Debug, thiserror::Error)]
pub enum RefusalError {
    #[error("auth required by recipe but no auth profile was supplied")]
    AuthRequiredButMissing,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteMeta {
    pub domain: String,
    #[serde(default)]
    pub last_verified: Option<String>,
    pub rendering: Rendering,
    #[serde(default)]
    pub framework: Option<String>,
    #[serde(default)]
    pub backend_hint: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Rendering {
    Spa,
    Ssr,
    Hybrid,
    ApiOnly,
    Static,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiConfig {
    pub base_url: String,
    #[serde(default)]
    pub public_auth_required: bool,
    #[serde(default)]
    pub auth_method: Option<AuthMethod>,
    #[serde(default)]
    pub auth_secret_ref: Option<String>,
    #[serde(default)]
    pub rate_limit_recommendation: Option<toml::Value>,
    #[serde(default)]
    pub response_encoding: Option<String>,
    #[serde(default)]
    pub endpoints: Vec<Endpoint>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum AuthMethod {
    None,
    Cookie,
    Bearer,
    Basic,
    Custom,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Endpoint {
    pub purpose: String,
    pub path: String,
    #[serde(default)]
    pub url_pattern: Option<String>,
    #[serde(default = "default_http_method")]
    pub http_method: String,
    #[serde(default)]
    pub required_headers: Option<toml::Value>,
    #[serde(default)]
    pub required_query: Vec<String>,
    #[serde(default)]
    pub response_shape: Option<toml::Value>,
    #[serde(default)]
    pub discovered_via: Option<String>,
    #[serde(default)]
    pub last_verified: Option<String>,
    #[serde(default)]
    pub avg_latency_ms: Option<u64>,
    #[serde(default)]
    pub ok_status: Vec<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScrapingStrategy {
    pub preferred_method: ScrapingMethod,
    #[serde(default)]
    pub fallback_method: Option<String>,
    #[serde(default)]
    pub paywall_fields: Vec<String>,
    #[serde(default)]
    pub public_fields: Vec<String>,
    #[serde(default)]
    pub follow_internal_links: Option<bool>,
    #[serde(default)]
    pub max_depth: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ScrapingMethod {
    Api,
    Spider,
    Hybrid,
    Obscura,
    Reqwest,
    #[serde(rename = "stealth-cf")]
    StealthCf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RateLimits {
    #[serde(default)]
    pub concurrent: Option<u32>,
    #[serde(default)]
    pub delay_ms: Option<u64>,
    #[serde(default)]
    pub jitter_ms: Option<u64>,
    #[serde(default)]
    pub respect_retry_after: Option<bool>,
}

/// The schema permits arbitrary stable-id keyed entries (`<field> = { css, attr?, stable_id }`).
/// We flatten the top-level table into a free-form map and surface it as `mappings`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Selectors {
    pub mappings: HashMap<String, toml::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FingerprintHint {
    #[serde(default)]
    pub mobile_preset: Option<String>,
    #[serde(default)]
    pub sec_ch_ua_required: Option<bool>,
    #[serde(default, alias = "required_ch_ua")]
    pub required_ch_ua: Option<String>,
    #[serde(default)]
    pub referer_policy: Option<String>,
    #[serde(default)]
    pub accept_language: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AntiBotConfig {
    #[serde(default)]
    pub cloudflare: Option<bool>,
    #[serde(default)]
    pub turnstile: Option<bool>,
    #[serde(default)]
    pub datadome: Option<bool>,
    #[serde(default)]
    pub recaptcha: Option<bool>,
    #[serde(default)]
    pub akamai: Option<bool>,
    #[serde(default)]
    pub bypass_strategy: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Notes {
    #[serde(default)]
    pub text: Option<String>,
}

impl SiteRecipe {
    /// True iff a `[auth]` section exists and `required = true`.
    pub fn auth_required(&self) -> bool {
        self.auth.as_ref().is_some_and(|a| a.required)
    }

    /// Decide how to react when an auth-aware command is invoked.
    /// `auth_provided` reflects whether the caller supplied `--use-auth`
    /// (or otherwise has a profile available).
    ///
    /// 9f ships only the decision logic. Wiring this into spider /
    /// cf-evaluate / relocate is 9d / 9e.
    pub fn enforce_auth_or_refusal(
        &self,
        auth_provided: bool,
    ) -> Result<RefusalAction, RefusalError> {
        let Some(auth) = self.auth.as_ref() else {
            return Ok(RefusalAction::Continue);
        };
        if auth_provided {
            return Ok(RefusalAction::Continue);
        }
        if !auth.required {
            return Ok(RefusalAction::Continue);
        }
        match auth.refusal_policy {
            RefusalPolicy::Refuse => Err(RefusalError::AuthRequiredButMissing),
            RefusalPolicy::WarnContinue => Ok(RefusalAction::ContinueWithWarning(
                "recipe declares auth.required=true but --use-auth was not supplied; continuing per refusal_policy=warn-continue",
            )),
            RefusalPolicy::Allow => Ok(RefusalAction::Continue),
        }
    }

    /// Look up endpoints matching a given `purpose` tag.
    pub fn endpoints_for(&self, purpose: &str) -> Vec<&Endpoint> {
        self.api
            .as_ref()
            .map(|api| {
                api.endpoints
                    .iter()
                    .filter(|e| e.purpose == purpose)
                    .collect()
            })
            .unwrap_or_default()
    }
}
