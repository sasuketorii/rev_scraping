// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.0.0 (Phase 6d)
//! Bridge between [`crate::policy`] and
//! [`vpn_rotate::instance_pool::InstancePool`].
//!
//! Encapsulates:
//!   * "given `Policy::vpn_instances`, build a pool"
//!   * "given a session_id (+ optional explicit `--vpn-instance` flag),
//!     select the instance to use, honouring the on-disk session sticky
//!     cache under `~/.rev_scraping/sessions/`"
//!   * "report the selection as JSON for the spider result envelope"
//!
//! Privacy contract: if `require_vpn=true` and the pool is empty / all
//! failed, callers must exit 7 (Leak) rather than fall through to a
//! direct connection. This module exposes the signals; the caller wires
//! the exit.

use std::fmt;
use std::path::PathBuf;

use serde_json::{json, Value};
use url::Url;
use vpn_rotate::instance_pool::{InstancePool, VpnInstance};
use vpn_rotate::proxy_resolver::{
    AuthorizedTargets, FailSignal, FallbackChain, Policy as ResolverPolicy, ProxyKind,
    ProxyResolver, ProxyResolverError, ProxySelection, ProxyStrength, ResolveError,
    SelectionSource, VpnInstanceRef,
};

use crate::commands::exit::Phase2Exit;
use crate::policy::Policy;

#[derive(Debug, Clone)]
pub struct Selection {
    pub instance_name: String,
    pub proxy_url: Url,
    #[allow(dead_code)]
    pub healthy_count: usize,
    /// Whether the selection came from the on-disk sticky cache (vs a
    /// fresh HRW pick).
    #[allow(dead_code)]
    pub from_session_cache: bool,
}

impl Selection {
    #[allow(dead_code)]
    pub fn to_json(&self) -> Value {
        json!({
            "vpn_instance_used": self.instance_name,
            "vpn_proxy_url": self.proxy_url.as_str(),
            "vpn_pool_healthy_count": self.healthy_count,
            "vpn_from_session_cache": self.from_session_cache,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SelectionConversionError {
    EmptyInstanceName,
    UnsupportedProxyScheme { scheme: String },
}

impl fmt::Display for SelectionConversionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyInstanceName => write!(f, "selection instance_name is empty"),
            Self::UnsupportedProxyScheme { scheme } => {
                write!(f, "selection proxy_url uses unsupported scheme {scheme:?}")
            }
        }
    }
}

impl std::error::Error for SelectionConversionError {}

impl From<ProxySelection> for Selection {
    fn from(value: ProxySelection) -> Self {
        let proxy_url = value.proxy_url.unwrap_or_else(|| {
            Url::parse("http://127.0.0.1:0/").expect("hard-coded fallback proxy URL must parse")
        });
        Self {
            instance_name: value.tier_name,
            proxy_url,
            healthy_count: value.pool_healthy_count.unwrap_or(0),
            from_session_cache: value.from_session_cache,
        }
    }
}

impl TryFrom<&Selection> for ProxySelection {
    type Error = SelectionConversionError;

    fn try_from(value: &Selection) -> Result<Self, Self::Error> {
        if value.instance_name.is_empty() {
            return Err(SelectionConversionError::EmptyInstanceName);
        }
        let proxy_kind = match value.proxy_url.scheme() {
            "http" | "https" => ProxyKind::HttpPool,
            "socks5" | "socks5h" => ProxyKind::Socks5,
            scheme => {
                return Err(SelectionConversionError::UnsupportedProxyScheme {
                    scheme: scheme.to_string(),
                });
            }
        };
        Ok(ProxySelection {
            tier_name: "surfshark".to_string(),
            proxy_kind,
            proxy_url: Some(value.proxy_url.clone()),
            no_proxy: Vec::new(),
            strength: ProxyStrength::Datacenter,
            from_session_cache: value.from_session_cache,
            source: SelectionSource::Explicit,
            pool_healthy_count: Some(value.healthy_count),
        })
    }
}

/// Build an [`InstancePool`] from the configured policy.
pub fn build_pool(policy: &Policy) -> InstancePool {
    let instances: Vec<VpnInstance> = policy
        .vpn_instances
        .iter()
        .map(|v| VpnInstance {
            name: v.name.clone(),
            http_proxy_port: v.http_proxy_port,
            control_port: v.control_port,
        })
        .collect();
    InstancePool::new(instances)
}

#[allow(dead_code)]
pub fn build_resolver(policy: &Policy) -> Result<ProxyResolver, ProxyResolverError> {
    let resolver_policy = ResolverPolicy {
        require_vpn: policy.require_vpn,
        vpn_required_country: policy.vpn_required_country.clone(),
        vpn_instances: policy
            .vpn_instances
            .iter()
            .map(|v| VpnInstanceRef {
                name: v.name.clone(),
                http_proxy_port: v.http_proxy_port,
                control_port: v.control_port,
            })
            .collect(),
        fallback_chain: FallbackChain {
            auto: if policy.fallback_chain == FallbackChain::default() && policy.require_vpn {
                vec!["surfshark".to_string()]
            } else {
                policy.fallback_chain.auto.clone()
            },
            ..policy.fallback_chain.clone()
        },
        proxies: policy.proxies.clone(),
    };
    let resolver = ProxyResolver::load(&resolver_policy, &AuthorizedTargets::default())?;
    if policy.vpn_instances.is_empty() {
        Ok(resolver)
    } else {
        Ok(resolver.with_surfshark_pool(build_pool(policy)))
    }
}

/// Resolve which instance to use for `session_id`. Override priority:
///   1. `forced_name` (CLI `--vpn-instance <NAME>`)
///   2. On-disk sticky cache (`~/.rev_scraping/sessions/<session_id>.json`)
///   3. HRW pick over healthy instances
pub fn select(
    pool: &InstancePool,
    session_id: &str,
    forced_name: Option<&str>,
) -> Option<Selection> {
    let session_dir = InstancePool::default_session_dir();

    let (instance, from_cache) = if let Some(name) = forced_name {
        let inst = pool.pick_by_name(name)?;
        (inst, false)
    } else if let Some(name) = session_dir
        .as_deref()
        .and_then(|d| InstancePool::load_session(d, session_id))
    {
        match pool.pick_by_name(&name) {
            Some(i) => (i, true),
            None => {
                // Cached instance no longer exists; fall through to HRW.
                let fresh = pool.pick(session_id)?;
                (fresh, false)
            }
        }
    } else {
        let inst = pool.pick(session_id)?;
        (inst, false)
    };

    let proxy_url = Url::parse(&format!("http://127.0.0.1:{}", instance.http_proxy_port)).ok()?;

    // Best-effort persist (only when we *didn't* load from the cache).
    if !from_cache {
        if let Some(dir) = session_dir.as_deref() {
            let _ = InstancePool::persist_session(dir, session_id, &instance.name);
        }
    }

    Some(Selection {
        instance_name: instance.name.clone(),
        proxy_url,
        healthy_count: pool.healthy_count(),
        from_session_cache: from_cache,
    })
}

#[allow(dead_code)]
pub fn select_with_resolver(
    resolver: &ProxyResolver,
    url: &Url,
    session_id: &str,
    forced_tier: Option<&str>,
) -> Option<Selection> {
    match resolver.resolve(url, session_id, forced_tier) {
        Ok(selection)
            if selection.proxy_kind == ProxyKind::None || selection.proxy_url.is_none() =>
        {
            None
        }
        Ok(selection) => Some(Selection::from(selection)),
        Err(_) => match forced_tier {
            None | Some("auto") | Some("surfshark") => resolver
                .pick_pool_instance(session_id, None)
                .map(Selection::from),
            Some(_) => None,
        },
    }
}

pub fn validate_proxy_args(
    vpn_instance: Option<&str>,
    proxy_tier: Option<&str>,
) -> Result<(), Phase2Exit> {
    if vpn_instance.is_some() && proxy_tier.is_some_and(|tier| tier != "surfshark") {
        return Err(Phase2Exit::Transient);
    }
    Ok(())
}

pub fn select_proxy_with_resolver(
    resolver: &ProxyResolver,
    url: &Url,
    session_id: &str,
    proxy_tier: Option<&str>,
    vpn_instance: Option<&str>,
) -> Result<Option<ProxySelection>, ResolveError> {
    match proxy_tier {
        None => Ok(None),
        Some("surfshark") if vpn_instance.is_some() => resolver
            .pick_pool_instance(session_id, vpn_instance)
            .map(Some)
            .ok_or_else(|| ResolveError::TierUnavailable {
                tier: "surfshark".to_string(),
                reason: "http-pool has no healthy instances".to_string(),
            }),
        Some(tier) => resolver.resolve(url, session_id, Some(tier)).map(Some),
    }
}

pub fn selection_from_proxy(proxy_selection: Option<&ProxySelection>) -> Option<Selection> {
    let selection = proxy_selection?;
    if selection.proxy_kind == ProxyKind::None || selection.proxy_url.is_none() {
        return None;
    }
    Some(Selection::from(selection.clone()))
}

pub fn selection_source_label(source: SelectionSource) -> String {
    match source {
        SelectionSource::Explicit => "Explicit".to_string(),
        SelectionSource::RecipeRecommendation => "RecipeRecommendation".to_string(),
        SelectionSource::AutoFallback(idx) => format!("AutoFallback({idx})"),
    }
}

#[allow(dead_code)]
pub fn fail_signal_label(signal: FailSignal) -> &'static str {
    match signal {
        FailSignal::Timeout => "timeout",
        FailSignal::Http403 => "http_403",
        FailSignal::Http429 => "http_429",
        FailSignal::TlsHandshakeFailed => "tls_handshake_failed",
        FailSignal::ConnectionRefused => "connection_refused",
    }
}

pub fn record_proxy_attempt(
    attempts: &mut Vec<Value>,
    tier: impl Into<String>,
    signal: impl Into<String>,
) {
    attempts.push(json!({
        "tier": tier.into(),
        "signal": signal.into(),
    }));
}

pub fn default_proxy_attempts(proxy_selection: Option<&ProxySelection>) -> Vec<Value> {
    let mut attempts = Vec::new();
    if let Some(selection) = proxy_selection {
        record_proxy_attempt(&mut attempts, selection.tier_name.clone(), "ok");
    }
    attempts
}

#[allow(dead_code)]
pub fn rotate_proxy_on_signal(
    resolver: &ProxyResolver,
    url: &Url,
    session_id: &str,
    current: &ProxySelection,
    signal: FailSignal,
    no_fallback: bool,
    attempts: &mut Vec<Value>,
) -> Option<ProxySelection> {
    record_proxy_attempt(
        attempts,
        current.tier_name.clone(),
        fail_signal_label(signal),
    );
    if no_fallback {
        return None;
    }
    let next = resolver.next_fallback(url, session_id, &current.tier_name, signal)?;
    record_proxy_attempt(attempts, next.tier_name.clone(), "ok");
    Some(next)
}

pub fn proxy_resolve_exit(err: &ResolveError) -> (Phase2Exit, String) {
    match err {
        ResolveError::UnknownTier { tier } => (
            Phase2Exit::Transient,
            format!("unknown proxy tier '{tier}'"),
        ),
        ResolveError::TierBelowFloor {
            tier,
            actual,
            required,
        } => (
            Phase2Exit::Leak,
            format!("tier {tier} strength={actual:?} below required {required:?}"),
        ),
        ResolveError::NoEligibleTier { .. } => (
            Phase2Exit::ProxyExhausted,
            "all proxy tiers failed".to_string(),
        ),
        ResolveError::TierUnavailable { tier, reason } => (
            Phase2Exit::Transient,
            format!("proxy tier {tier:?} is currently unavailable: {reason}"),
        ),
        ResolveError::NoAuthorizedMatch { url } => (
            Phase2Exit::Transient,
            format!("no authorized target matches url {url}"),
        ),
    }
}

/// Convenience: where on disk we persist `session_id -> instance_name`.
#[allow(dead_code)]
pub fn session_dir() -> Option<PathBuf> {
    InstancePool::default_session_dir()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::{Policy, VpnInstance as PolicyVpnInstance};

    fn mk_policy(n: usize) -> Policy {
        Policy {
            schema_version: 1,
            require_vpn: true,
            vpn_required_country: None,
            vpn_instances: (1..=n)
                .map(|i| PolicyVpnInstance {
                    name: format!("vpn-{i}"),
                    http_proxy_port: 8000 + i as u16,
                    control_port: 8880 + i as u16,
                })
                .collect(),
            proxies: Default::default(),
            fallback_chain: FallbackChain::default(),
        }
    }

    fn mk_policy_with_require(n: usize, require_vpn: bool) -> Policy {
        Policy {
            require_vpn,
            ..mk_policy(n)
        }
    }

    #[test]
    fn build_pool_translates_policy_instances() {
        let pol = mk_policy(3);
        let pool = build_pool(&pol);
        assert_eq!(pool.instances().len(), 3);
        assert_eq!(pool.instances()[0].name, "vpn-1");
        assert_eq!(pool.instances()[0].http_proxy_port, 8001);
    }

    #[test]
    fn select_returns_none_for_empty_pool() {
        let pol = Policy::default();
        let pool = build_pool(&pol);
        assert!(select(&pool, "sess", None).is_none());
    }

    #[test]
    fn select_honours_forced_name_over_hrw() {
        let pool = build_pool(&mk_policy(3));
        let sel = select(&pool, "sess-xyz", Some("vpn-3")).unwrap();
        assert_eq!(sel.instance_name, "vpn-3");
        assert_eq!(sel.proxy_url.as_str(), "http://127.0.0.1:8003/");
        assert!(!sel.from_session_cache);
    }

    #[test]
    fn select_forced_unknown_name_returns_none() {
        let pool = build_pool(&mk_policy(3));
        assert!(select(&pool, "sess", Some("vpn-doesnotexist")).is_none());
    }

    #[test]
    fn select_json_envelope_shape() {
        let pool = build_pool(&mk_policy(3));
        let sel = select(&pool, "sess-json", Some("vpn-2")).unwrap();
        let j = sel.to_json();
        assert_eq!(j.get("vpn_instance_used").unwrap(), "vpn-2");
        assert_eq!(j.get("vpn_proxy_url").unwrap(), "http://127.0.0.1:8002/");
        assert!(j.get("vpn_pool_healthy_count").unwrap().as_u64().unwrap() >= 1);
    }

    #[test]
    fn build_resolver_translates_policy_instances() {
        let resolver = build_resolver(&mk_policy(2)).unwrap();

        assert_eq!(
            resolver.surfshark_pool.as_ref().unwrap().instances().len(),
            2
        );
        assert_eq!(
            resolver.tier_strength("surfshark"),
            Some(ProxyStrength::Datacenter)
        );
    }

    #[test]
    fn proxy_selection_to_selection_preserves_tier_name() {
        let proxy_selection = ProxySelection {
            tier_name: "surfshark".to_string(),
            proxy_kind: ProxyKind::HttpPool,
            proxy_url: Some(Url::parse("http://127.0.0.1:8001/").unwrap()),
            no_proxy: Vec::new(),
            strength: ProxyStrength::Datacenter,
            from_session_cache: true,
            source: SelectionSource::Explicit,
            pool_healthy_count: Some(3),
        };

        let selection = Selection::from(proxy_selection);

        assert_eq!(selection.instance_name, "surfshark");
        assert!(selection.from_session_cache);
        assert_eq!(selection.healthy_count, 3);
    }

    #[test]
    fn proxy_selection_to_selection_preserves_proxy_url() {
        let proxy_selection = ProxySelection {
            tier_name: "surfshark".to_string(),
            proxy_kind: ProxyKind::HttpPool,
            proxy_url: Some(Url::parse("http://127.0.0.1:8001/").unwrap()),
            no_proxy: Vec::new(),
            strength: ProxyStrength::Datacenter,
            from_session_cache: true,
            source: SelectionSource::Explicit,
            pool_healthy_count: Some(3),
        };

        let selection = Selection::from(proxy_selection);

        assert_eq!(selection.proxy_url.as_str(), "http://127.0.0.1:8001/");
        assert!(selection.from_session_cache);
    }

    #[test]
    fn selection_to_proxy_selection_round_trip() {
        let selection = Selection {
            instance_name: "vpn-1".to_string(),
            proxy_url: Url::parse("http://127.0.0.1:8001/").unwrap(),
            healthy_count: 3,
            from_session_cache: false,
        };

        let proxy_selection = ProxySelection::try_from(&selection).unwrap();

        assert_eq!(proxy_selection.tier_name, "surfshark");
        assert_eq!(proxy_selection.proxy_kind, ProxyKind::HttpPool);
        assert_eq!(
            proxy_selection.proxy_url.as_ref().unwrap().as_str(),
            "http://127.0.0.1:8001/"
        );
        assert_eq!(proxy_selection.strength, ProxyStrength::Datacenter);
        assert_eq!(proxy_selection.pool_healthy_count, Some(3));

        let round_trip = Selection::from(proxy_selection);
        assert_eq!(round_trip.instance_name, "surfshark");
        assert_eq!(round_trip.proxy_url.as_str(), "http://127.0.0.1:8001/");
        assert_eq!(round_trip.from_session_cache, selection.from_session_cache);
    }

    #[test]
    fn proxy_selection_try_from_selection_rejects_unsupported_scheme() {
        let selection = Selection {
            instance_name: "vpn-1".to_string(),
            proxy_url: Url::parse("ftp://127.0.0.1:21/").unwrap(),
            healthy_count: 1,
            from_session_cache: false,
        };

        let err = ProxySelection::try_from(&selection).unwrap_err();

        assert!(matches!(
            err,
            SelectionConversionError::UnsupportedProxyScheme { .. }
        ));
    }

    #[test]
    fn select_with_resolver_resolves_surfshark_via_pool() {
        let resolver = build_resolver(&mk_policy_with_require(1, false)).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        let selection =
            select_with_resolver(&resolver, &url, "resolver-session", Some("surfshark")).unwrap();

        assert_eq!(selection.instance_name, "surfshark");
        assert_eq!(selection.proxy_url.as_str(), "http://127.0.0.1:8001/");
    }

    #[test]
    fn select_with_resolver_returns_none_for_empty_pool() {
        let resolver = build_resolver(&Policy::default()).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        assert!(
            select_with_resolver(&resolver, &url, "resolver-session", Some("surfshark")).is_none()
        );
    }

    #[test]
    fn select_with_resolver_rejects_non_surfshark_tier_while_resolve_is_stub() {
        let resolver = build_resolver(&mk_policy_with_require(1, false)).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        assert!(select_with_resolver(&resolver, &url, "resolver-session", Some("warp")).is_none());
    }

    #[test]
    fn select_with_resolver_returns_none_for_direct_tier() {
        let policy = ResolverPolicy {
            require_vpn: false,
            ..ResolverPolicy::default()
        };
        let resolver = ProxyResolver::load(&policy, &AuthorizedTargets::default()).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        assert!(
            select_with_resolver(&resolver, &url, "resolver-session", Some("direct")).is_none()
        );
    }

    #[test]
    fn test_proxy_tier_auto_invokes_resolver() {
        let resolver = build_resolver(&mk_policy_with_require(1, false)).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        let selection = resolver
            .resolve(&url, "resolver-session-auto", Some("auto"))
            .unwrap();

        assert_eq!(selection.tier_name, "direct");
        assert_eq!(selection.source, SelectionSource::AutoFallback(0));
    }

    #[test]
    fn test_proxy_tier_explicit_invokes_resolver_with_forced_name() {
        let resolver = build_resolver(&mk_policy_with_require(1, false)).unwrap();
        let url = Url::parse("https://example.com/").unwrap();

        let selection = select_proxy_with_resolver(
            &resolver,
            &url,
            "resolver-session-explicit",
            Some("surfshark"),
            None,
        )
        .unwrap()
        .unwrap();

        assert_eq!(selection.tier_name, "surfshark");
        assert_eq!(selection.source, SelectionSource::Explicit);
        assert_eq!(selection.pool_healthy_count, Some(1));
    }

    #[test]
    fn test_proxy_tier_conflict_with_vpn_instance_exits_2() {
        assert_eq!(
            validate_proxy_args(Some("vpn-1"), Some("warp")),
            Err(Phase2Exit::Transient)
        );
        assert!(validate_proxy_args(Some("vpn-1"), Some("surfshark")).is_ok());
        assert!(validate_proxy_args(Some("vpn-1"), None).is_ok());
    }

    #[test]
    fn test_no_fallback_disables_rotation() {
        let resolver = build_resolver(&mk_policy_with_require(1, false)).unwrap();
        let url = Url::parse("https://example.com/").unwrap();
        let current = resolver
            .resolve(&url, "resolver-session-no-fallback", Some("auto"))
            .unwrap();
        let mut attempts = Vec::new();

        let next = rotate_proxy_on_signal(
            &resolver,
            &url,
            "resolver-session-no-fallback",
            &current,
            FailSignal::Http403,
            true,
            &mut attempts,
        );

        assert!(next.is_none());
        assert_eq!(attempts.len(), 1);
    }

    #[test]
    fn test_fallback_rotates_on_fail_signal() {
        let resolver = build_resolver(&mk_policy_with_require(1, false)).unwrap();
        let url = Url::parse("https://example.com/").unwrap();
        let current = resolver
            .resolve(&url, "resolver-session-rotate", Some("auto"))
            .unwrap();
        let mut attempts = Vec::new();

        let next = rotate_proxy_on_signal(
            &resolver,
            &url,
            "resolver-session-rotate",
            &current,
            FailSignal::Http403,
            false,
            &mut attempts,
        )
        .unwrap();

        assert_eq!(current.tier_name, "direct");
        assert_eq!(next.tier_name, "surfshark");
    }

    #[test]
    fn test_fallback_records_rotation_events() {
        let resolver = build_resolver(&mk_policy_with_require(1, false)).unwrap();
        let url = Url::parse("https://example.com/").unwrap();
        let current = resolver
            .resolve(&url, "resolver-session-events", Some("auto"))
            .unwrap();
        let mut attempts = Vec::new();

        let next = rotate_proxy_on_signal(
            &resolver,
            &url,
            "resolver-session-events",
            &current,
            FailSignal::Http403,
            false,
            &mut attempts,
        )
        .unwrap();

        assert_eq!(next.tier_name, "surfshark");
        assert_eq!(attempts.len(), 2);
        assert_eq!(attempts[0], json!({"tier": "direct", "signal": "http_403"}));
        assert_eq!(attempts[1], json!({"tier": "surfshark", "signal": "ok"}));
    }
}
