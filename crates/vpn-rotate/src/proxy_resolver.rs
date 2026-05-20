// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping Phase 8a (per-site proxy routing)
//! Phase 8 proxy routing configuration loader and resolver.
//!
//! Runtime resolution is deterministic and side-effect-light: policy and
//! authorization are validated at load time, then each resolve call maps a
//! URL/session pair to a configured proxy tier.

use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;
use std::sync::Arc;

use regex::Regex;
use serde::{Deserialize, Serialize};
use url::Url;

use crate::instance_pool::InstancePool;
use crate::instance_pool::VpnInstance;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProxyKind {
    None,
    Http,
    Socks5,
    #[serde(rename = "http-pool")]
    HttpPool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProxyStrength {
    #[default]
    None,
    Datacenter,
    Residential,
    Mobile,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FailSignal {
    #[serde(rename = "timeout")]
    Timeout,
    #[serde(rename = "http_403")]
    Http403,
    #[serde(rename = "http_429")]
    Http429,
    #[serde(rename = "tls_handshake_failed")]
    TlsHandshakeFailed,
    #[serde(rename = "connection_refused")]
    ConnectionRefused,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectionSource {
    Explicit,
    RecipeRecommendation,
    AutoFallback(usize),
}

#[derive(Clone, PartialEq, Eq)]
pub struct ProxySelection {
    pub tier_name: String,
    pub proxy_kind: ProxyKind,
    pub proxy_url: Option<Url>,
    pub no_proxy: Vec<String>,
    pub strength: ProxyStrength,
    pub from_session_cache: bool,
    pub source: SelectionSource,
    /// Healthy instance count of the underlying pool at selection time.
    /// `Some(n)` for `HttpPool` selections (e.g. Surfshark), `None` for
    /// non-pool tiers.
    pub pool_healthy_count: Option<usize>,
}

impl fmt::Debug for ProxySelection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ProxySelection")
            .field("tier_name", &self.tier_name)
            .field("proxy_kind", &self.proxy_kind)
            .field("proxy_url", &self.proxy_url.as_ref().map(redacted_url))
            .field("no_proxy", &self.no_proxy)
            .field("strength", &self.strength)
            .field("from_session_cache", &self.from_session_cache)
            .field("source", &self.source)
            .field("pool_healthy_count", &self.pool_healthy_count)
            .finish()
    }
}

#[derive(Clone)]
pub struct ProxyResolver {
    pub policy_proxies: BTreeMap<String, TierConfig>,
    pub authorized: AuthorizedTargets,
    pub fallback_chain: FallbackChain,
    pub surfshark_pool: Option<InstancePool>,
    pub require_vpn: bool,
    recipe_lookup: Option<Arc<dyn RecipeLookup>>,
}

impl fmt::Debug for ProxyResolver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ProxyResolver")
            .field("policy_proxies", &self.policy_proxies)
            .field("authorized", &self.authorized)
            .field("fallback_chain", &self.fallback_chain)
            .field("surfshark_pool", &self.surfshark_pool)
            .field("require_vpn", &self.require_vpn)
            .field("recipe_lookup_configured", &self.recipe_lookup.is_some())
            .finish()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ProxyResolverError {
    #[error("read {path}: {source}")]
    Read {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("parse {path}: {source}")]
    ParseToml {
        path: String,
        #[source]
        source: toml::de::Error,
    },
    #[error("policy.toml proxy.{tier}.url contains secret; use ${{ENV}} placeholders ({reason})")]
    SecretUrl { tier: String, reason: &'static str },
    #[error("proxy tier {tier} requires env {var}")]
    MissingEnv { tier: String, var: String },
    #[error("proxy tier {tier} has invalid URL: {source}")]
    InvalidUrl {
        tier: String,
        #[source]
        source: url::ParseError,
    },
    #[error("proxy tier name \"auto\" is reserved")]
    ReservedAutoTier,
    #[error("proxy tier {tier} type {kind:?} requires url")]
    MissingUrl { tier: String, kind: ProxyKind },
    #[error("proxy tier {tier} type http-pool must set instances_from = \"policy.vpn_instances\"")]
    InvalidInstancesFrom { tier: String },
    #[error("proxy tier {tier} type {kind:?} must not set instances_from")]
    UnexpectedInstancesFrom { tier: String, kind: ProxyKind },
    #[error("proxy tier {tier} uses unsupported rotation \"per-request\" (TODO Phase 8b provider support)")]
    UnsupportedPerRequestRotation { tier: String },
    #[error("authorized target {url_pattern:?} references unknown proxy_tier {tier:?}")]
    UnknownAuthorizedTier { url_pattern: String, tier: String },
    #[error(
        "authorized target {url_pattern:?} tier {tier:?} strength={actual:?} below required {required:?}"
    )]
    TierBelowRequiredStrength {
        url_pattern: String,
        tier: String,
        actual: ProxyStrength,
        required: ProxyStrength,
    },
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ResolveError {
    #[error("no authorized target matches url {url}")]
    NoAuthorizedMatch { url: String },
    #[error("forced/explicit proxy tier {tier:?} is not declared in [proxies.*]")]
    UnknownTier { tier: String },
    #[error("proxy tier {tier:?} strength {actual:?} is below required {required:?}")]
    TierBelowFloor {
        tier: String,
        actual: ProxyStrength,
        required: ProxyStrength,
    },
    #[error("proxy tier {tier:?} is currently unavailable: {reason}")]
    TierUnavailable { tier: String, reason: String },
    #[error("auto fallback chain is empty after filtering for url {url}")]
    NoEligibleTier { url: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlacklistEntry {
    pub name: String,
    pub age_days: u32,
}

pub trait RecipeLookup: Send + Sync {
    fn proxy_tier_recommended(&self, host: &str) -> Option<String>;

    fn proxy_tier_blacklist(&self, host: &str) -> Vec<BlacklistEntry>;
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Policy {
    #[serde(default = "default_require_vpn")]
    pub require_vpn: bool,
    #[serde(default)]
    pub vpn_required_country: Option<String>,
    #[serde(default)]
    pub vpn_instances: Vec<VpnInstanceRef>,
    #[serde(default)]
    pub proxies: BTreeMap<String, RawTierConfig>,
    #[serde(default)]
    pub fallback_chain: FallbackChain,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            require_vpn: default_require_vpn(),
            vpn_required_country: None,
            vpn_instances: Vec::new(),
            proxies: BTreeMap::new(),
            fallback_chain: FallbackChain::default(),
        }
    }
}

impl Policy {
    pub fn load_from(path: &Path) -> Result<Self, ProxyResolverError> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let body = std::fs::read_to_string(path).map_err(|source| ProxyResolverError::Read {
            path: path.display().to_string(),
            source,
        })?;
        Self::from_toml_str(&body, path.display().to_string())
    }

    pub fn from_toml_str(raw: &str, path: impl Into<String>) -> Result<Self, ProxyResolverError> {
        toml::from_str(raw).map_err(|source| ProxyResolverError::ParseToml {
            path: path.into(),
            source,
        })
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct VpnInstanceRef {
    pub name: String,
    pub http_proxy_port: u16,
    pub control_port: u16,
}

impl From<VpnInstanceRef> for VpnInstance {
    fn from(value: VpnInstanceRef) -> Self {
        Self {
            name: value.name,
            http_proxy_port: value.http_proxy_port,
            control_port: value.control_port,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq, Default)]
pub struct AuthorizedTargets {
    #[serde(default)]
    pub targets: Vec<AuthorizedTarget>,
}

impl AuthorizedTargets {
    pub fn load_from(path: &Path) -> Result<Self, ProxyResolverError> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let body = std::fs::read_to_string(path).map_err(|source| ProxyResolverError::Read {
            path: path.display().to_string(),
            source,
        })?;
        Self::from_toml_str(&body, path.display().to_string())
    }

    pub fn from_toml_str(raw: &str, path: impl Into<String>) -> Result<Self, ProxyResolverError> {
        toml::from_str(raw).map_err(|source| ProxyResolverError::ParseToml {
            path: path.into(),
            source,
        })
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct AuthorizedTarget {
    pub url_pattern: String,
    #[serde(default = "default_proxy_tier")]
    pub proxy_tier: String,
    #[serde(default)]
    pub min_proxy_strength: ProxyStrength,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct RawTierConfig {
    #[serde(rename = "type")]
    pub kind: ProxyKind,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub instances_from: Option<String>,
    #[serde(default)]
    pub auth_env: Vec<String>,
    #[serde(default)]
    pub no_proxy: Vec<String>,
    #[serde(default)]
    pub rotation: RotationMode,
    #[serde(default)]
    pub country_filter: Vec<String>,
    #[serde(default = "default_enabled_by_default")]
    pub enabled_by_default: bool,
    pub strength: ProxyStrength,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum RotationMode {
    PerRequest,
    #[default]
    PerSession,
    Sticky,
}

#[derive(Clone, PartialEq, Eq)]
pub struct TierConfig {
    pub kind: ProxyKind,
    pub proxy_url: Option<Url>,
    pub instances_from: Option<String>,
    pub auth_env: Vec<String>,
    pub no_proxy: Vec<String>,
    pub rotation: RotationMode,
    pub country_filter: Vec<String>,
    pub strength: ProxyStrength,
    pub enabled_by_default: bool,
    pub state: TierState,
}

impl fmt::Debug for TierConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TierConfig")
            .field("kind", &self.kind)
            .field("proxy_url", &self.proxy_url.as_ref().map(redacted_url))
            .field("instances_from", &self.instances_from)
            .field("auth_env", &self.auth_env)
            .field("no_proxy", &self.no_proxy)
            .field("rotation", &self.rotation)
            .field("country_filter", &self.country_filter)
            .field("strength", &self.strength)
            .field("enabled_by_default", &self.enabled_by_default)
            .field("state", &self.state)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TierState {
    Ready,
    Disabled { reason: String },
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct FallbackChain {
    #[serde(default = "default_fallback_auto")]
    pub auto: Vec<String>,
    #[serde(default = "default_fail_signals")]
    pub fail_signals: Vec<FailSignal>,
    #[serde(default = "default_max_attempts_per_tier")]
    pub max_attempts_per_tier: u32,
    #[serde(default = "default_cooldown_ms_between_tiers")]
    pub cooldown_ms_between_tiers: u64,
    #[serde(default = "default_blacklist_ttl_days")]
    pub blacklist_ttl_days: u32,
}

impl Default for FallbackChain {
    fn default() -> Self {
        Self {
            auto: default_fallback_auto(),
            fail_signals: default_fail_signals(),
            max_attempts_per_tier: default_max_attempts_per_tier(),
            cooldown_ms_between_tiers: default_cooldown_ms_between_tiers(),
            blacklist_ttl_days: default_blacklist_ttl_days(),
        }
    }
}

impl ProxyResolver {
    pub fn load(
        policy: &Policy,
        authorized: &AuthorizedTargets,
    ) -> Result<Self, ProxyResolverError> {
        let mut policy_proxies = BTreeMap::new();

        if policy.proxies.contains_key("auto") {
            return Err(ProxyResolverError::ReservedAutoTier);
        }

        for (name, raw) in &policy.proxies {
            let tier = resolve_tier(name, raw)?;
            policy_proxies.insert(name.clone(), tier);
        }

        ensure_builtin_tiers(policy, &mut policy_proxies);
        validate_authorized_targets(authorized, &policy_proxies)?;

        let surfshark_pool = if policy.vpn_instances.is_empty() {
            None
        } else {
            let instances = policy
                .vpn_instances
                .iter()
                .cloned()
                .map(VpnInstance::from)
                .collect();
            Some(InstancePool::new(instances))
        };

        Ok(Self {
            policy_proxies,
            authorized: authorized.clone(),
            fallback_chain: policy.fallback_chain.clone(),
            surfshark_pool,
            require_vpn: policy.require_vpn,
            recipe_lookup: None,
        })
    }

    pub fn with_recipe_lookup(mut self, recipe_lookup: Arc<dyn RecipeLookup>) -> Self {
        self.recipe_lookup = Some(recipe_lookup);
        self
    }

    pub fn with_surfshark_pool(mut self, surfshark_pool: InstancePool) -> Self {
        self.surfshark_pool = Some(surfshark_pool);
        self
    }

    pub fn pick_pool_instance(
        &self,
        session_id: &str,
        forced_name: Option<&str>,
    ) -> Option<ProxySelection> {
        let tier = self.policy_proxies.get("surfshark")?;
        if tier.kind != ProxyKind::HttpPool || tier.state != TierState::Ready {
            return None;
        }
        let pool = self.surfshark_pool.as_ref()?;
        let session_dir = InstancePool::default_session_dir();

        let (instance, from_cache) = if let Some(name) = forced_name {
            let inst = pool.pick_by_name(name)?;
            (inst, false)
        } else if let Some(name) = session_dir
            .as_deref()
            .and_then(|d| InstancePool::load_session(d, session_id))
        {
            match pool.pick_by_name(&name) {
                Some(inst) => (inst, true),
                None => {
                    let fresh = pool.pick(session_id)?;
                    (fresh, false)
                }
            }
        } else {
            let inst = pool.pick(session_id)?;
            (inst, false)
        };

        let proxy_url =
            Url::parse(&format!("http://127.0.0.1:{}", instance.http_proxy_port)).ok()?;

        if !from_cache {
            if let Some(dir) = session_dir.as_deref() {
                let _ = InstancePool::persist_session(dir, session_id, &instance.name);
            }
        }

        Some(ProxySelection {
            tier_name: "surfshark".to_string(),
            proxy_kind: ProxyKind::HttpPool,
            proxy_url: Some(proxy_url),
            no_proxy: tier.no_proxy.clone(),
            strength: tier.strength,
            from_session_cache: from_cache,
            source: SelectionSource::Explicit,
            pool_healthy_count: Some(pool.healthy_count()),
        })
    }

    pub fn resolve(
        &self,
        url: &Url,
        session_id: &str,
        forced_tier: Option<&str>,
    ) -> Result<ProxySelection, ResolveError> {
        let target = self.match_authorized_target(url);
        if target.is_none() && forced_tier.is_none() {
            return Err(ResolveError::NoAuthorizedMatch {
                url: url.as_str().to_string(),
            });
        }

        let floor = target
            .map(|target| target.min_proxy_strength)
            .unwrap_or(ProxyStrength::None);
        let effective_tier = forced_tier
            .or_else(|| target.map(|target| target.proxy_tier.as_str()))
            .expect("forced tier or authorized target exists");

        if effective_tier == "auto" {
            return self.resolve_auto(url, session_id, floor);
        }

        self.selection_for_tier(session_id, effective_tier, floor, SelectionSource::Explicit)
    }

    /// Return the deterministic next retry tier after `failed_tier`.
    ///
    /// This method is stateless: it does not store per-session attempt
    /// counters. Therefore `max_attempts_per_tier = 1` advances to the
    /// next usable tier, while values greater than one return the same
    /// tier once as a deterministic same-tier retry signal for callers
    /// that own the actual attempt counter.
    pub fn next_fallback(
        &self,
        url: &Url,
        session_id: &str,
        failed_tier: &str,
        signal: FailSignal,
    ) -> Option<ProxySelection> {
        let target = self.match_authorized_target(url);
        let floor = target
            .map(|target| target.min_proxy_strength)
            .unwrap_or(ProxyStrength::None);
        let (candidates, _) = self.auto_candidates(url, floor);
        let failed_idx = candidates.iter().position(|tier| tier == failed_tier)?;

        if !self.fallback_chain.fail_signals.contains(&signal) {
            return None;
        }

        let max_attempts = self.fallback_chain.max_attempts_per_tier.max(1) as usize;
        if max_attempts > 1 {
            // Retry the same tier. `next_fallback` is stateless, so callers
            // that own attempt counters use this as the deterministic same-tier
            // slot until `max_attempts_per_tier` is exhausted.
            return self
                .selection_for_tier(
                    session_id,
                    failed_tier,
                    floor,
                    SelectionSource::AutoFallback(failed_idx),
                )
                .ok();
        }

        let next_idx = failed_idx + 1;
        if next_idx >= candidates.len() {
            return None;
        }

        self.selection_for_tier(
            session_id,
            &candidates[next_idx],
            floor,
            SelectionSource::AutoFallback(next_idx),
        )
        .ok()
    }

    pub fn tier_strength(&self, tier_name: &str) -> Option<ProxyStrength> {
        self.policy_proxies.get(tier_name).map(|tier| tier.strength)
    }

    fn resolve_auto(
        &self,
        url: &Url,
        session_id: &str,
        floor: ProxyStrength,
    ) -> Result<ProxySelection, ResolveError> {
        let (candidates, promoted_recommendation) = self.auto_candidates(url, floor);
        let Some(tier_name) = candidates.first() else {
            return Err(ResolveError::NoEligibleTier {
                url: url.as_str().to_string(),
            });
        };
        let source = if promoted_recommendation.as_deref() == Some(tier_name.as_str()) {
            SelectionSource::RecipeRecommendation
        } else {
            SelectionSource::AutoFallback(0)
        };
        self.selection_for_tier(session_id, tier_name, floor, source)
    }

    fn selection_for_tier(
        &self,
        session_id: &str,
        tier_name: &str,
        floor: ProxyStrength,
        source: SelectionSource,
    ) -> Result<ProxySelection, ResolveError> {
        let tier = self
            .policy_proxies
            .get(tier_name)
            .ok_or_else(|| ResolveError::UnknownTier {
                tier: tier_name.to_string(),
            })?;

        match &tier.state {
            TierState::Ready => {}
            TierState::Disabled { reason } => {
                return Err(ResolveError::TierUnavailable {
                    tier: tier_name.to_string(),
                    reason: reason.clone(),
                });
            }
        }

        if tier.strength < floor {
            return Err(ResolveError::TierBelowFloor {
                tier: tier_name.to_string(),
                actual: tier.strength,
                required: floor,
            });
        }

        let (proxy_url, from_session_cache, pool_healthy_count) = match tier.kind {
            ProxyKind::HttpPool => {
                let selection = self.pick_pool_instance(session_id, None).ok_or_else(|| {
                    ResolveError::TierUnavailable {
                        tier: tier_name.to_string(),
                        reason: "http-pool has no healthy instances".to_string(),
                    }
                })?;
                (
                    selection.proxy_url,
                    selection.from_session_cache,
                    selection.pool_healthy_count,
                )
            }
            ProxyKind::None => (None, false, None),
            ProxyKind::Http | ProxyKind::Socks5 => (tier.proxy_url.clone(), false, None),
        };

        Ok(ProxySelection {
            tier_name: tier_name.to_string(),
            proxy_kind: tier.kind,
            proxy_url,
            no_proxy: tier.no_proxy.clone(),
            strength: tier.strength,
            from_session_cache,
            source,
            pool_healthy_count,
        })
    }

    fn auto_candidates(&self, url: &Url, floor: ProxyStrength) -> (Vec<String>, Option<String>) {
        let mut candidates = self.fallback_chain.auto.clone();
        let mut promoted_recommendation = None;
        let active_blacklist = self.active_recipe_blacklist(url);

        if let Some(lookup) = &self.recipe_lookup {
            let host = url.host_str().unwrap_or("");
            if let Some(recommended) = lookup.proxy_tier_recommended(host) {
                if !active_blacklist
                    .iter()
                    .any(|blocked| blocked == &recommended)
                {
                    candidates.retain(|tier_name| tier_name != &recommended);
                    candidates.insert(0, recommended.clone());
                    promoted_recommendation = Some(recommended);
                }
            }
        }

        for blocked in &active_blacklist {
            let original_len = candidates.len();
            candidates.retain(|tier_name| tier_name != blocked);
            if candidates.len() != original_len {
                candidates.push(blocked.clone());
            }
        }

        let filtered = candidates
            .into_iter()
            .filter(|tier_name| {
                let Some(tier) = self.policy_proxies.get(tier_name) else {
                    return false;
                };
                matches!(tier.state, TierState::Ready) && tier.strength >= floor
            })
            .fold(Vec::new(), |mut tiers, tier_name| {
                push_unique(&mut tiers, tier_name);
                tiers
            });

        (filtered, promoted_recommendation)
    }

    fn active_recipe_blacklist(&self, url: &Url) -> Vec<String> {
        let Some(lookup) = &self.recipe_lookup else {
            return Vec::new();
        };
        let host = url.host_str().unwrap_or("");
        lookup
            .proxy_tier_blacklist(host)
            .into_iter()
            .filter(|entry| entry.age_days <= self.fallback_chain.blacklist_ttl_days)
            .map(|entry| entry.name)
            .fold(Vec::new(), |mut tiers, tier_name| {
                push_unique(&mut tiers, tier_name);
                tiers
            })
    }

    fn match_authorized_target(&self, url: &Url) -> Option<&AuthorizedTarget> {
        let mut best: Option<(usize, usize, &AuthorizedTarget)> = None;
        let url = url.as_str();
        for (idx, target) in self.authorized.targets.iter().enumerate() {
            let Ok(re) = Regex::new(&target.url_pattern) else {
                continue;
            };
            if !re.is_match(url) {
                continue;
            }
            let len = target.url_pattern.len();
            match best {
                None => best = Some((len, idx, target)),
                Some((best_len, best_idx, _))
                    if len > best_len || (len == best_len && idx < best_idx) =>
                {
                    best = Some((len, idx, target));
                }
                _ => {}
            }
        }
        best.map(|(_, _, target)| target)
    }
}

fn resolve_tier(name: &str, raw: &RawTierConfig) -> Result<TierConfig, ProxyResolverError> {
    if matches!(raw.rotation, RotationMode::PerRequest) {
        // TODO(Phase 8b): per-request rotation needs provider-specific
        // support before it can be enabled safely.
        return Err(ProxyResolverError::UnsupportedPerRequestRotation {
            tier: name.to_string(),
        });
    }

    match raw.kind {
        ProxyKind::Http | ProxyKind::Socks5 => {
            let raw_url = raw
                .url
                .as_deref()
                .ok_or_else(|| ProxyResolverError::MissingUrl {
                    tier: name.to_string(),
                    kind: raw.kind,
                })?;
            validate_url_secret_shape(raw_url).map_err(|reason| ProxyResolverError::SecretUrl {
                tier: name.to_string(),
                reason,
            })?;

            let env_values = load_env_values(raw_url, &raw.auth_env);
            if let Some(var) = env_values.missing.first() {
                if raw.enabled_by_default {
                    return Err(ProxyResolverError::MissingEnv {
                        tier: name.to_string(),
                        var: var.clone(),
                    });
                }
                return Ok(disabled_tier(
                    raw,
                    format!("missing env {}", env_values.missing.join(",")),
                ));
            }

            let resolved = interpolate_env_once(raw_url, &env_values.values);
            let proxy_url =
                Url::parse(&resolved).map_err(|source| ProxyResolverError::InvalidUrl {
                    tier: name.to_string(),
                    source,
                })?;
            Ok(ready_tier(raw, Some(proxy_url)))
        }
        ProxyKind::HttpPool => {
            if raw.instances_from.as_deref() != Some("policy.vpn_instances") {
                return Err(ProxyResolverError::InvalidInstancesFrom {
                    tier: name.to_string(),
                });
            }
            Ok(ready_tier(raw, None))
        }
        ProxyKind::None => {
            if raw.instances_from.is_some() {
                return Err(ProxyResolverError::UnexpectedInstancesFrom {
                    tier: name.to_string(),
                    kind: raw.kind,
                });
            }
            let env_values = load_env_values("", &raw.auth_env);
            if let Some(var) = env_values.missing.first() {
                if raw.enabled_by_default {
                    return Err(ProxyResolverError::MissingEnv {
                        tier: name.to_string(),
                        var: var.clone(),
                    });
                }
                return Ok(disabled_tier(
                    raw,
                    format!("missing env {}", env_values.missing.join(",")),
                ));
            }
            Ok(ready_tier(raw, None))
        }
    }
}

fn ensure_builtin_tiers(policy: &Policy, policy_proxies: &mut BTreeMap<String, TierConfig>) {
    policy_proxies
        .entry("direct".to_string())
        .or_insert_with(direct_tier);
    if !policy.vpn_instances.is_empty() {
        policy_proxies
            .entry("surfshark".to_string())
            .or_insert_with(surfshark_tier);
    }
}

fn validate_authorized_targets(
    authorized: &AuthorizedTargets,
    policy_proxies: &BTreeMap<String, TierConfig>,
) -> Result<(), ProxyResolverError> {
    for target in &authorized.targets {
        if target.proxy_tier == "auto" {
            continue;
        }
        let Some(tier) = policy_proxies.get(&target.proxy_tier) else {
            return Err(ProxyResolverError::UnknownAuthorizedTier {
                url_pattern: target.url_pattern.clone(),
                tier: target.proxy_tier.clone(),
            });
        };
        if tier.strength < target.min_proxy_strength {
            return Err(ProxyResolverError::TierBelowRequiredStrength {
                url_pattern: target.url_pattern.clone(),
                tier: target.proxy_tier.clone(),
                actual: tier.strength,
                required: target.min_proxy_strength,
            });
        }
    }
    Ok(())
}

fn ready_tier(raw: &RawTierConfig, proxy_url: Option<Url>) -> TierConfig {
    TierConfig {
        kind: raw.kind,
        proxy_url,
        instances_from: raw.instances_from.clone(),
        auth_env: raw.auth_env.clone(),
        no_proxy: raw.no_proxy.clone(),
        rotation: raw.rotation,
        country_filter: raw.country_filter.clone(),
        strength: raw.strength,
        enabled_by_default: raw.enabled_by_default,
        state: TierState::Ready,
    }
}

fn disabled_tier(raw: &RawTierConfig, reason: String) -> TierConfig {
    TierConfig {
        kind: raw.kind,
        proxy_url: None,
        instances_from: raw.instances_from.clone(),
        auth_env: raw.auth_env.clone(),
        no_proxy: raw.no_proxy.clone(),
        rotation: raw.rotation,
        country_filter: raw.country_filter.clone(),
        strength: raw.strength,
        enabled_by_default: raw.enabled_by_default,
        state: TierState::Disabled { reason },
    }
}

fn direct_tier() -> TierConfig {
    TierConfig {
        kind: ProxyKind::None,
        proxy_url: None,
        instances_from: None,
        auth_env: Vec::new(),
        no_proxy: Vec::new(),
        rotation: RotationMode::PerSession,
        country_filter: Vec::new(),
        strength: ProxyStrength::None,
        enabled_by_default: true,
        state: TierState::Ready,
    }
}

fn surfshark_tier() -> TierConfig {
    TierConfig {
        kind: ProxyKind::HttpPool,
        proxy_url: None,
        instances_from: Some("policy.vpn_instances".to_string()),
        auth_env: Vec::new(),
        no_proxy: Vec::new(),
        rotation: RotationMode::PerSession,
        country_filter: Vec::new(),
        strength: ProxyStrength::Datacenter,
        enabled_by_default: true,
        state: TierState::Ready,
    }
}

struct EnvValues {
    values: BTreeMap<String, String>,
    missing: Vec<String>,
}

fn load_env_values(raw_url: &str, auth_env: &[String]) -> EnvValues {
    let mut vars = placeholder_vars(raw_url);
    for var in auth_env {
        if !vars.iter().any(|existing| existing == var) {
            vars.push(var.clone());
        }
    }
    let mut values = BTreeMap::new();
    let mut missing = Vec::new();
    for var in vars {
        match std::env::var(&var) {
            Ok(value) if !value.is_empty() => {
                values.insert(var, value);
            }
            _ => missing.push(var),
        }
    }
    EnvValues { values, missing }
}

fn placeholder_vars(raw: &str) -> Vec<String> {
    let re = Regex::new(r"\$\{([A-Z0-9_]+)\}").expect("placeholder regex compiles");
    let mut vars = Vec::new();
    for cap in re.captures_iter(raw) {
        let var = cap[1].to_string();
        if !vars.iter().any(|existing| existing == &var) {
            vars.push(var);
        }
    }
    vars
}

fn interpolate_env_once(raw: &str, values: &BTreeMap<String, String>) -> String {
    let re = Regex::new(r"\$\{([A-Z0-9_]+)\}").expect("placeholder regex compiles");
    re.replace_all(raw, |caps: &regex::Captures<'_>| {
        values.get(&caps[1]).cloned().unwrap_or_default()
    })
    .into_owned()
}

fn validate_url_secret_shape(raw: &str) -> Result<(), &'static str> {
    let userinfo_re =
        Regex::new(r"^[A-Za-z][A-Za-z0-9+.-]*://([^/?#@]*)@").expect("userinfo regex compiles");
    let Some(caps) = userinfo_re.captures(raw) else {
        return Ok(());
    };
    let userinfo = &caps[1];
    if userinfo.is_empty() {
        return Ok(());
    }

    let placeholder_re =
        Regex::new(r"^\$\{[A-Z0-9_]+\}$").expect("secret placeholder regex compiles");
    let mut parts = userinfo.splitn(2, ':');
    let user = parts.next().unwrap_or_default();
    let pass = parts.next();

    if !user.is_empty() && !placeholder_re.is_match(user) {
        return Err("userinfo username must be exactly ${UPPER_SNAKE_123}");
    }
    if let Some(pass) = pass {
        if !pass.is_empty() && !placeholder_re.is_match(pass) {
            return Err("userinfo password must be exactly ${UPPER_SNAKE_123}");
        }
    }
    Ok(())
}

fn redacted_url(url: &Url) -> String {
    if url.username().is_empty() && url.password().is_none() {
        return url.as_str().to_string();
    }
    let mut redacted = url.clone();
    let _ = redacted.set_username("***");
    let _ = redacted.set_password(Some("***"));
    redacted.to_string()
}

fn push_unique(values: &mut Vec<String>, value: String) {
    if !values.iter().any(|existing| existing == &value) {
        values.push(value);
    }
}

fn default_require_vpn() -> bool {
    true
}

fn default_proxy_tier() -> String {
    "auto".to_string()
}

fn default_enabled_by_default() -> bool {
    true
}

fn default_fallback_auto() -> Vec<String> {
    vec!["direct".to_string(), "surfshark".to_string()]
}

fn default_fail_signals() -> Vec<FailSignal> {
    vec![
        FailSignal::Timeout,
        FailSignal::Http403,
        FailSignal::Http429,
        FailSignal::TlsHandshakeFailed,
        FailSignal::ConnectionRefused,
    ]
}

fn default_max_attempts_per_tier() -> u32 {
    1
}

fn default_cooldown_ms_between_tiers() -> u64 {
    250
}

fn default_blacklist_ttl_days() -> u32 {
    14
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvGuard {
        saved: Vec<(&'static str, Option<String>)>,
    }

    impl EnvGuard {
        fn set(vars: &[(&'static str, Option<&str>)]) -> Self {
            let saved = vars
                .iter()
                .map(|(name, _)| (*name, std::env::var(name).ok()))
                .collect();
            for (name, value) in vars {
                match value {
                    Some(value) => std::env::set_var(name, value),
                    None => std::env::remove_var(name),
                }
            }
            Self { saved }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            for (name, value) in &self.saved {
                match value {
                    Some(value) => std::env::set_var(name, value),
                    None => std::env::remove_var(name),
                }
            }
        }
    }

    fn one_instance_policy() -> Policy {
        Policy {
            vpn_instances: vec![VpnInstanceRef {
                name: "vpn-1".to_string(),
                http_proxy_port: 8001,
                control_port: 8881,
            }],
            ..Policy::default()
        }
    }

    fn empty_auth() -> AuthorizedTargets {
        AuthorizedTargets::default()
    }

    fn raw_tier(kind: ProxyKind, url: Option<&str>, strength: ProxyStrength) -> RawTierConfig {
        RawTierConfig {
            kind,
            url: url.map(str::to_string),
            instances_from: None,
            auth_env: Vec::new(),
            no_proxy: Vec::new(),
            rotation: RotationMode::PerSession,
            country_filter: Vec::new(),
            enabled_by_default: true,
            strength,
        }
    }

    fn routing_policy(require_vpn: bool, auto: &[&str]) -> Policy {
        let mut proxies = BTreeMap::new();
        proxies.insert(
            "warp".to_string(),
            raw_tier(
                ProxyKind::Socks5,
                Some("socks5://127.0.0.1:40000"),
                ProxyStrength::Datacenter,
            ),
        );
        proxies.insert(
            "residential".to_string(),
            raw_tier(
                ProxyKind::Http,
                Some("http://proxy.example:12321"),
                ProxyStrength::Residential,
            ),
        );
        Policy {
            require_vpn,
            proxies,
            fallback_chain: FallbackChain {
                auto: auto.iter().map(|tier| (*tier).to_string()).collect(),
                ..FallbackChain::default()
            },
            ..Policy::default()
        }
    }

    #[derive(Debug, Default)]
    struct FakeRecipe {
        recommended: Option<String>,
        blacklist: Vec<BlacklistEntry>,
    }

    impl RecipeLookup for FakeRecipe {
        fn proxy_tier_recommended(&self, _host: &str) -> Option<String> {
            self.recommended.clone()
        }

        fn proxy_tier_blacklist(&self, _host: &str) -> Vec<BlacklistEntry> {
            self.blacklist.clone()
        }
    }

    fn resolver_with_chain(chain: Vec<&str>, vpn: bool) -> ProxyResolver {
        let mut policy = routing_policy(false, &chain);
        if vpn {
            policy.vpn_instances = vec![VpnInstanceRef {
                name: "vpn-1".to_string(),
                http_proxy_port: 8001,
                control_port: 8881,
            }];
        }
        policy.proxies.insert(
            "iproyal".to_string(),
            RawTierConfig {
                enabled_by_default: false,
                auth_env: vec!["IPROYAL_USER".to_string(), "IPROYAL_PASS".to_string()],
                ..raw_tier(
                    ProxyKind::Http,
                    Some("http://${IPROYAL_USER}:${IPROYAL_PASS}@residential.example:12321"),
                    ProxyStrength::Residential,
                )
            },
        );
        let authorized = auth_for("^https://example\\.com/", "auto", ProxyStrength::None);
        ProxyResolver::load(&policy, &authorized).unwrap()
    }

    fn auth_for(pattern: &str, tier: &str, floor: ProxyStrength) -> AuthorizedTargets {
        AuthorizedTargets {
            targets: vec![AuthorizedTarget {
                url_pattern: pattern.to_string(),
                proxy_tier: tier.to_string(),
                min_proxy_strength: floor,
            }],
        }
    }

    #[test]
    fn strength_ordering_matches_design() {
        assert!(ProxyStrength::None < ProxyStrength::Datacenter);
        assert!(ProxyStrength::Datacenter < ProxyStrength::Residential);
        assert!(ProxyStrength::Residential < ProxyStrength::Mobile);
    }

    #[test]
    fn policy_toml_parses_proxies_and_fallback_chain() {
        let policy = Policy::from_toml_str(
            r#"
[[vpn_instances]]
name = "vpn-1"
http_proxy_port = 8001
control_port = 8881

[proxies.direct]
type = "none"
strength = "none"
no_proxy = ["localhost"]

[proxies.surfshark]
type = "http-pool"
instances_from = "policy.vpn_instances"
strength = "datacenter"

[fallback_chain]
auto = ["direct", "surfshark"]
fail_signals = ["timeout", "http_403"]
max_attempts_per_tier = 2
cooldown_ms_between_tiers = 10
blacklist_ttl_days = 3
"#,
            "policy.toml",
        )
        .unwrap();
        assert_eq!(policy.proxies.len(), 2);
        assert_eq!(policy.fallback_chain.fail_signals.len(), 2);
        assert_eq!(policy.fallback_chain.max_attempts_per_tier, 2);
    }

    #[test]
    fn authorized_defaults_proxy_tier_and_strength() {
        let authorized = AuthorizedTargets::from_toml_str(
            r#"
[[targets]]
url_pattern = "^https://example\\.com/"
"#,
            "authorized.toml",
        )
        .unwrap();
        assert_eq!(authorized.targets[0].proxy_tier, "auto");
        assert_eq!(
            authorized.targets[0].min_proxy_strength,
            ProxyStrength::None
        );
    }

    #[test]
    fn load_synthesizes_direct_and_surfshark_for_legacy_policy() {
        let policy = one_instance_policy();
        let resolver = ProxyResolver::load(&policy, &empty_auth()).unwrap();
        assert_eq!(resolver.tier_strength("direct"), Some(ProxyStrength::None));
        assert_eq!(
            resolver.tier_strength("surfshark"),
            Some(ProxyStrength::Datacenter)
        );
        assert_eq!(
            resolver.surfshark_pool.as_ref().unwrap().instances().len(),
            1
        );
    }

    #[test]
    fn with_surfshark_pool_binds_instances() {
        let resolver = ProxyResolver::load(&one_instance_policy(), &empty_auth())
            .unwrap()
            .with_surfshark_pool(InstancePool::new(vec![VpnInstance {
                name: "vpn-override".to_string(),
                http_proxy_port: 8100,
                control_port: 8900,
            }]));

        let pool = resolver.surfshark_pool.as_ref().unwrap();
        assert_eq!(pool.instances().len(), 1);
        assert_eq!(pool.instances()[0].name, "vpn-override");
    }

    #[test]
    fn pick_pool_instance_returns_hrw_sticky() {
        let policy = Policy {
            vpn_instances: vec![
                VpnInstanceRef {
                    name: "vpn-1".to_string(),
                    http_proxy_port: 8001,
                    control_port: 8881,
                },
                VpnInstanceRef {
                    name: "vpn-2".to_string(),
                    http_proxy_port: 8002,
                    control_port: 8882,
                },
                VpnInstanceRef {
                    name: "vpn-3".to_string(),
                    http_proxy_port: 8003,
                    control_port: 8883,
                },
            ],
            ..Policy::default()
        };
        let resolver = ProxyResolver::load(&policy, &empty_auth()).unwrap();

        let first = resolver.pick_pool_instance("sticky-session", None).unwrap();
        for _ in 0..20 {
            let again = resolver.pick_pool_instance("sticky-session", None).unwrap();
            assert_eq!(again.proxy_url, first.proxy_url);
        }
    }

    #[test]
    fn pick_pool_instance_honours_forced_name() {
        let policy = Policy {
            vpn_instances: vec![
                VpnInstanceRef {
                    name: "vpn-1".to_string(),
                    http_proxy_port: 8001,
                    control_port: 8881,
                },
                VpnInstanceRef {
                    name: "vpn-2".to_string(),
                    http_proxy_port: 8002,
                    control_port: 8882,
                },
            ],
            ..Policy::default()
        };
        let resolver = ProxyResolver::load(&policy, &empty_auth()).unwrap();

        let selection = resolver
            .pick_pool_instance("session-forced", Some("vpn-2"))
            .unwrap();

        assert_eq!(selection.tier_name, "surfshark");
        assert_eq!(selection.proxy_kind, ProxyKind::HttpPool);
        assert_eq!(
            selection.proxy_url.as_ref().unwrap().as_str(),
            "http://127.0.0.1:8002/"
        );
        assert_eq!(selection.strength, ProxyStrength::Datacenter);
        assert!(!selection.from_session_cache);
    }

    #[test]
    fn pick_pool_instance_returns_none_for_unknown_tier() {
        let resolver = ProxyResolver::load(&Policy::default(), &empty_auth()).unwrap();

        assert!(resolver.pick_pool_instance("session-empty", None).is_none());
    }

    #[test]
    fn mark_failure_via_pool_increments_failure_count() {
        let resolver = ProxyResolver::load(&one_instance_policy(), &empty_auth()).unwrap();
        let pool = resolver.surfshark_pool.as_ref().unwrap();

        pool.mark_failure("vpn-1");
        pool.mark_failure("vpn-1");
        assert_eq!(pool.healthy_count(), 1);

        pool.mark_failure("vpn-1");
        assert_eq!(pool.healthy_count(), 0);
        assert!(resolver
            .pick_pool_instance("session-after-failure", None)
            .is_none());
    }

    #[test]
    fn load_rejects_reserved_auto_tier() {
        let mut policy = Policy::default();
        policy.proxies.insert(
            "auto".to_string(),
            RawTierConfig {
                kind: ProxyKind::None,
                url: None,
                instances_from: None,
                auth_env: Vec::new(),
                no_proxy: Vec::new(),
                rotation: RotationMode::PerSession,
                country_filter: Vec::new(),
                enabled_by_default: true,
                strength: ProxyStrength::None,
            },
        );
        let err = ProxyResolver::load(&policy, &empty_auth()).unwrap_err();
        assert!(matches!(err, ProxyResolverError::ReservedAutoTier));
    }

    #[test]
    fn load_rejects_plaintext_userinfo_before_interpolation() {
        let policy = Policy::from_toml_str(
            r#"
[proxies.bad]
type = "http"
url = "http://literal:secret@example.com:8080"
strength = "residential"
"#,
            "policy.toml",
        )
        .unwrap();
        let err = ProxyResolver::load(&policy, &empty_auth()).unwrap_err();
        assert!(matches!(err, ProxyResolverError::SecretUrl { .. }));
    }

    #[test]
    fn load_interpolates_env_once_for_ready_tier_and_redacts_debug() {
        let _lock = ENV_LOCK.lock().unwrap();
        let _env = EnvGuard::set(&[
            ("IPROYAL_USER", Some("alice")),
            ("IPROYAL_PASS", Some("secret")),
        ]);
        let policy = Policy::from_toml_str(
            r#"
[proxies.iproyal]
type = "http"
url = "http://${IPROYAL_USER}:${IPROYAL_PASS}@residential.example:12321"
auth_env = ["IPROYAL_USER", "IPROYAL_PASS"]
strength = "residential"
"#,
            "policy.toml",
        )
        .unwrap();
        let resolver = ProxyResolver::load(&policy, &empty_auth()).unwrap();
        let tier = resolver.policy_proxies.get("iproyal").unwrap();
        assert_eq!(tier.state, TierState::Ready);
        assert_eq!(tier.proxy_url.as_ref().unwrap().username(), "alice");
        let debug = format!("{tier:?}");
        assert!(debug.contains("***:***"));
        assert!(!debug.contains("alice"));
        assert!(!debug.contains("secret"));
    }

    #[test]
    fn load_errors_when_default_on_env_missing() {
        let _lock = ENV_LOCK.lock().unwrap();
        let _env = EnvGuard::set(&[("IPROYAL_USER", None), ("IPROYAL_PASS", None)]);
        let policy = Policy::from_toml_str(
            r#"
[proxies.iproyal]
type = "http"
url = "http://${IPROYAL_USER}:${IPROYAL_PASS}@residential.example:12321"
auth_env = ["IPROYAL_USER", "IPROYAL_PASS"]
strength = "residential"
"#,
            "policy.toml",
        )
        .unwrap();
        let err = ProxyResolver::load(&policy, &empty_auth()).unwrap_err();
        assert!(matches!(err, ProxyResolverError::MissingEnv { .. }));
    }

    #[test]
    fn load_disables_default_off_tier_when_env_missing() {
        let _lock = ENV_LOCK.lock().unwrap();
        let _env = EnvGuard::set(&[("IPROYAL_USER", None), ("IPROYAL_PASS", None)]);
        let policy = Policy::from_toml_str(
            r#"
[proxies.iproyal]
type = "http"
url = "http://${IPROYAL_USER}:${IPROYAL_PASS}@residential.example:12321"
auth_env = ["IPROYAL_USER", "IPROYAL_PASS"]
strength = "residential"
enabled_by_default = false
"#,
            "policy.toml",
        )
        .unwrap();
        let resolver = ProxyResolver::load(&policy, &empty_auth()).unwrap();
        let tier = resolver.policy_proxies.get("iproyal").unwrap();
        assert!(matches!(tier.state, TierState::Disabled { .. }));
        assert!(tier.proxy_url.is_none());
    }

    #[test]
    fn load_checks_auth_env_even_without_url_placeholders() {
        let _lock = ENV_LOCK.lock().unwrap();
        let _env = EnvGuard::set(&[("WARP_READY", None)]);
        let policy = Policy::from_toml_str(
            r#"
[proxies.warp]
type = "socks5"
url = "socks5://127.0.0.1:40000"
auth_env = ["WARP_READY"]
strength = "datacenter"
enabled_by_default = false
"#,
            "policy.toml",
        )
        .unwrap();
        let resolver = ProxyResolver::load(&policy, &empty_auth()).unwrap();
        assert!(matches!(
            resolver.policy_proxies.get("warp").unwrap().state,
            TierState::Disabled { .. }
        ));
    }

    #[test]
    fn load_rejects_bad_http_pool_instances_from() {
        let policy = Policy::from_toml_str(
            r#"
[proxies.pool]
type = "http-pool"
instances_from = "other.pool"
strength = "datacenter"
"#,
            "policy.toml",
        )
        .unwrap();
        let err = ProxyResolver::load(&policy, &empty_auth()).unwrap_err();
        assert!(matches!(
            err,
            ProxyResolverError::InvalidInstancesFrom { .. }
        ));
    }

    #[test]
    fn load_rejects_per_request_rotation() {
        let policy = Policy::from_toml_str(
            r#"
[proxies.iproyal]
type = "http"
url = "http://proxy.example:12321"
strength = "residential"
rotation = "per-request"
"#,
            "policy.toml",
        )
        .unwrap();
        let err = ProxyResolver::load(&policy, &empty_auth()).unwrap_err();
        assert!(matches!(
            err,
            ProxyResolverError::UnsupportedPerRequestRotation { .. }
        ));
    }

    #[test]
    fn load_validates_authorized_tier_strength_floor() {
        let policy = one_instance_policy();
        let authorized = AuthorizedTargets {
            targets: vec![AuthorizedTarget {
                url_pattern: "^https://example\\.com/".to_string(),
                proxy_tier: "surfshark".to_string(),
                min_proxy_strength: ProxyStrength::Residential,
            }],
        };
        let err = ProxyResolver::load(&policy, &authorized).unwrap_err();
        assert!(matches!(
            err,
            ProxyResolverError::TierBelowRequiredStrength { .. }
        ));
    }

    #[test]
    fn load_validates_unknown_authorized_tier() {
        let policy = Policy::default();
        let authorized = AuthorizedTargets {
            targets: vec![AuthorizedTarget {
                url_pattern: "^https://example\\.com/".to_string(),
                proxy_tier: "missing".to_string(),
                min_proxy_strength: ProxyStrength::None,
            }],
        };
        let err = ProxyResolver::load(&policy, &authorized).unwrap_err();
        assert!(matches!(
            err,
            ProxyResolverError::UnknownAuthorizedTier { .. }
        ));
    }

    #[test]
    fn resolve_explicit_tier_returns_selection() {
        let policy = one_instance_policy();
        let authorized = auth_for("^https://example\\.com/", "surfshark", ProxyStrength::None);
        let resolver = ProxyResolver::load(&policy, &authorized).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        let selection = resolver.resolve(&url, "session", None).unwrap();

        assert_eq!(selection.tier_name, "surfshark");
        assert_eq!(selection.source, SelectionSource::Explicit);
    }

    #[test]
    fn resolve_explicit_tier_below_strength_floor_errors() {
        let authorized = auth_for(
            "^https://example\\.com/",
            "auto",
            ProxyStrength::Residential,
        );
        let resolver =
            ProxyResolver::load(&routing_policy(false, &["direct"]), &authorized).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        let err = resolver.resolve(&url, "s", Some("direct")).unwrap_err();

        assert!(matches!(err, ResolveError::TierBelowFloor { .. }));
    }

    #[test]
    fn resolve_explicit_tier_disabled_errors() {
        let _lock = ENV_LOCK.lock().unwrap();
        let _env = EnvGuard::set(&[("IPROYAL_USER", None), ("IPROYAL_PASS", None)]);
        let resolver = resolver_with_chain(vec!["direct"], false);
        let url = Url::parse("https://example.com/").unwrap();

        let err = resolver.resolve(&url, "s", Some("iproyal")).unwrap_err();

        assert!(matches!(err, ResolveError::TierUnavailable { .. }));
    }

    #[test]
    fn resolve_auto_returns_first_chain_tier() {
        let resolver = resolver_with_chain(vec!["direct", "surfshark"], true);
        let url = Url::parse("https://example.com/").unwrap();

        let selection = resolver.resolve(&url, "s", None).unwrap();

        assert_eq!(selection.tier_name, "direct");
        assert_eq!(selection.source, SelectionSource::AutoFallback(0));
    }

    #[test]
    fn resolve_auto_filters_below_floor() {
        let policy = one_instance_policy();
        let mut policy = Policy {
            require_vpn: false,
            fallback_chain: FallbackChain {
                auto: vec!["direct".to_string(), "surfshark".to_string()],
                ..FallbackChain::default()
            },
            ..policy
        };
        policy.proxies.clear();
        let authorized = auth_for("^https://example\\.com/", "auto", ProxyStrength::Datacenter);
        let resolver = ProxyResolver::load(&policy, &authorized).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        let selection = resolver.resolve(&url, "s", None).unwrap();

        assert_eq!(selection.tier_name, "surfshark");
    }

    #[test]
    fn resolve_auto_promotes_recipe_recommended() {
        let resolver = resolver_with_chain(vec!["direct", "surfshark"], true).with_recipe_lookup(
            Arc::new(FakeRecipe {
                recommended: Some("surfshark".to_string()),
                blacklist: Vec::new(),
            }),
        );
        let url = Url::parse("https://example.com/").unwrap();

        let selection = resolver.resolve(&url, "s", None).unwrap();

        assert_eq!(selection.tier_name, "surfshark");
        assert_eq!(selection.source, SelectionSource::RecipeRecommendation);
    }

    #[test]
    fn resolve_auto_skips_recipe_blacklist() {
        let resolver = resolver_with_chain(vec!["direct", "surfshark"], true).with_recipe_lookup(
            Arc::new(FakeRecipe {
                recommended: None,
                blacklist: vec![BlacklistEntry {
                    name: "direct".to_string(),
                    age_days: 0,
                }],
            }),
        );
        let url = Url::parse("https://example.com/").unwrap();

        let selection = resolver.resolve(&url, "s", None).unwrap();

        assert_eq!(selection.tier_name, "surfshark");
    }

    #[test]
    fn resolve_auto_revives_blacklist_after_ttl() {
        let resolver = resolver_with_chain(vec!["direct", "surfshark"], true).with_recipe_lookup(
            Arc::new(FakeRecipe {
                recommended: None,
                blacklist: vec![BlacklistEntry {
                    name: "direct".to_string(),
                    age_days: 999,
                }],
            }),
        );
        let url = Url::parse("https://example.com/").unwrap();

        let selection = resolver.resolve(&url, "s", None).unwrap();

        assert_eq!(selection.tier_name, "direct");
    }

    #[test]
    fn next_fallback_advances_to_next_tier() {
        let resolver = resolver_with_chain(vec!["direct", "surfshark"], true);
        let url = Url::parse("https://example.com/").unwrap();

        let selection = resolver
            .next_fallback(&url, "s", "direct", FailSignal::Http403)
            .unwrap();

        assert_eq!(selection.tier_name, "surfshark");
        assert_eq!(selection.source, SelectionSource::AutoFallback(1));
    }

    #[test]
    fn next_fallback_respects_max_attempts_per_tier() {
        let mut policy = one_instance_policy();
        policy.require_vpn = false;
        policy.fallback_chain = FallbackChain {
            auto: vec!["direct".to_string(), "surfshark".to_string()],
            max_attempts_per_tier: 2,
            ..FallbackChain::default()
        };
        let authorized = auth_for("^https://example\\.com/", "auto", ProxyStrength::None);
        let resolver = ProxyResolver::load(&policy, &authorized).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        let selection = resolver
            .next_fallback(&url, "s", "direct", FailSignal::Timeout)
            .unwrap();

        assert_eq!(selection.tier_name, "direct");
        assert_eq!(selection.source, SelectionSource::AutoFallback(0));
    }

    #[test]
    fn next_fallback_returns_none_when_signal_not_in_fail_signals() {
        let mut policy = routing_policy(false, &["direct", "surfshark"]);
        policy.vpn_instances = vec![VpnInstanceRef {
            name: "vpn-1".to_string(),
            http_proxy_port: 8001,
            control_port: 8881,
        }];
        policy.fallback_chain.fail_signals = vec![FailSignal::Timeout];
        let authorized = auth_for("^https://example\\.com/", "auto", ProxyStrength::None);
        let resolver = ProxyResolver::load(&policy, &authorized).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        assert!(resolver
            .next_fallback(&url, "s", "direct", FailSignal::Http429)
            .is_none());
    }

    #[test]
    fn next_fallback_returns_none_when_chain_exhausted() {
        let resolver = resolver_with_chain(vec!["direct"], false);
        let url = Url::parse("https://example.com/").unwrap();

        assert!(resolver
            .next_fallback(&url, "s", "direct", FailSignal::Timeout)
            .is_none());
    }

    #[test]
    fn resolve_no_authorized_match_returns_error() {
        let resolver =
            ProxyResolver::load(&routing_policy(false, &["direct"]), &empty_auth()).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        let err = resolver.resolve(&url, "s", None).unwrap_err();

        assert!(matches!(err, ResolveError::NoAuthorizedMatch { .. }));
    }
}
