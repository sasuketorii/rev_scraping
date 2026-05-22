// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.0.0 (Job C consistency)
//! Shared helper that builds the VPN-related JSON envelope block emitted
//! by the `spider`, `cf-evaluate`, and `relocate` (`--url` path)
//! subcommands. Centralising this here keeps the three CLI surfaces in
//! lockstep — Job C consistency contract.
//!
//! The envelope fields injected by [`build_vpn_envelope`]:
//!
//! ```json
//! {
//!   "vpn_instance_used":     "vpn-2" | null,
//!   "vpn_proxy_url":         "http://127.0.0.1:8002" | null,
//!   "vpn_pool_healthy_count": 3 | 0,
//!   "vpn_rotation_events":   [],
//!   "vpn_monitor": {
//!     "enabled":             true | false,
//!     "poll_interval_secs":  30,
//!     "last_check_at_iso":   "..." | null,
//!     "leak_detected":       false
//!   }
//! }
//! ```
//!
//! The function returns a flat [`serde_json::Map`] suitable for merging
//! into an existing `result` object via `.extend()`, so each subcommand
//! can keep its own command-specific fields adjacent.
//!
//! For non-network call sites (e.g. `relocate --html-file`) callers pass
//! `None` everywhere; the helper then emits the same shape with `null`
//! values and `enabled: false`, preserving the envelope contract.

use std::sync::Arc;

use serde_json::{json, Map, Value};
use tokio::sync::RwLock;
use vpn_rotate::leak_monitor::LeakState;
use vpn_rotate::proxy_resolver::ProxySelection;

use crate::vpn_selector::{default_proxy_attempts, selection_source_label, Selection};

/// Build the unified VPN envelope as a flat [`Map`].
///
/// * `selection` — the picked instance, if any (None when no VPN).
/// * `pool_healthy` — count from `InstancePool::healthy_count()`.
/// * `monitor_state` — Arc'd live state from `LeakMonitor::state_clone()`.
/// * `poll_interval_secs` — the (clamped) poll interval the monitor uses;
///   used only when `monitor_state` is `Some`.
/// * `rotation_events` — opaque array of per-attempt rotation events.
///   Pass `None` to default to an empty array.
pub async fn build_vpn_envelope(
    selection: Option<&Selection>,
    pool_healthy: usize,
    monitor_state: Option<&Arc<RwLock<LeakState>>>,
    poll_interval_secs: u64,
    rotation_events: Option<Vec<Value>>,
    proxy_selection: Option<&ProxySelection>,
) -> Map<String, Value> {
    let mut out = Map::new();
    out.insert(
        "vpn_instance_used".to_string(),
        selection
            .map(|s| Value::String(s.instance_name.clone()))
            .unwrap_or(Value::Null),
    );
    out.insert(
        "vpn_proxy_url".to_string(),
        selection
            .map(|s| Value::String(s.proxy_url.as_str().to_string()))
            .unwrap_or(Value::Null),
    );
    out.insert(
        "vpn_pool_healthy_count".to_string(),
        Value::Number(
            selection
                .map(|s| s.healthy_count)
                .unwrap_or(pool_healthy)
                .into(),
        ),
    );
    let proxy_tier_attempts = rotation_events
        .clone()
        .or_else(|| proxy_selection.map(|selection| default_proxy_attempts(Some(selection))))
        .unwrap_or_default();
    out.insert(
        "vpn_rotation_events".to_string(),
        Value::Array(rotation_events.unwrap_or_default()),
    );
    out.insert(
        "proxy_tier_used".to_string(),
        proxy_selection
            .map(|selection| Value::String(selection.tier_name.clone()))
            .unwrap_or(Value::Null),
    );
    out.insert(
        "proxy_tier_source".to_string(),
        proxy_selection
            .map(|selection| Value::String(selection_source_label(selection.source)))
            .unwrap_or(Value::Null),
    );
    out.insert(
        "proxy_tier_attempts".to_string(),
        Value::Array(proxy_tier_attempts),
    );
    out.insert(
        "vpn_monitor".to_string(),
        build_vpn_monitor_json(monitor_state, poll_interval_secs).await,
    );
    out
}

/// Build just the inner `vpn_monitor` object. Exposed so `spider` (and
/// any future caller emitting a leak-shutdown payload) can reuse it
/// without paying for the whole envelope.
pub async fn build_vpn_monitor_json(
    state: Option<&Arc<RwLock<LeakState>>>,
    poll_interval_secs: u64,
) -> Value {
    match state {
        None => json!({ "enabled": false }),
        Some(s) => {
            let st = s.read().await.clone();
            // We don't carry a wall-clock for `last_check_at` (it's
            // `Instant`), so we project "did at least one tick happen?"
            // into an RFC3339 timestamp synthesised at read time.
            let last_check_at_iso = st.last_check_at.map(|_| chrono::Utc::now().to_rfc3339());
            json!({
                "enabled": true,
                "poll_interval_secs": poll_interval_secs,
                "ticks": st.ticks,
                "leak_detected": st.leak_detected,
                "failed_instance": st.failed_instance,
                "reason": st.reason,
                "last_check_at_iso": last_check_at_iso,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use url::Url;

    fn mk_selection(name: &str, port: u16) -> Selection {
        Selection {
            instance_name: name.to_string(),
            proxy_url: Url::parse(&format!("http://127.0.0.1:{port}")).unwrap(),
            healthy_count: 3,
            from_session_cache: false,
        }
    }

    #[tokio::test]
    async fn test_build_vpn_envelope_with_selection() {
        let sel = mk_selection("vpn-2", 8002);
        let env = build_vpn_envelope(Some(&sel), 3, None, 30, None, None).await;
        assert_eq!(env.get("vpn_instance_used").unwrap(), "vpn-2");
        assert_eq!(env.get("vpn_proxy_url").unwrap(), "http://127.0.0.1:8002/");
        assert_eq!(env.get("vpn_pool_healthy_count").unwrap(), 3);
        assert!(env.get("vpn_rotation_events").unwrap().is_array());
        assert_eq!(
            env.get("vpn_monitor").unwrap().get("enabled").unwrap(),
            false
        );
    }

    #[tokio::test]
    async fn test_build_vpn_envelope_without_selection_returns_nulls() {
        let env = build_vpn_envelope(None, 0, None, 30, None, None).await;
        assert!(env.get("vpn_instance_used").unwrap().is_null());
        assert!(env.get("vpn_proxy_url").unwrap().is_null());
        assert_eq!(env.get("vpn_pool_healthy_count").unwrap(), 0);
        assert!(env.get("proxy_tier_used").unwrap().is_null());
        assert!(env.get("proxy_tier_source").unwrap().is_null());
        assert_eq!(
            env.get("proxy_tier_attempts")
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            0
        );
        assert_eq!(
            env.get("vpn_monitor").unwrap().get("enabled").unwrap(),
            false
        );
    }

    #[tokio::test]
    async fn test_build_vpn_monitor_json_enabled_with_state() {
        let state = Arc::new(RwLock::new(LeakState {
            leak_detected: false,
            ticks: 7,
            ..LeakState::default()
        }));
        let v = build_vpn_monitor_json(Some(&state), 45).await;
        assert_eq!(v.get("enabled").unwrap(), true);
        assert_eq!(v.get("poll_interval_secs").unwrap(), 45);
        assert_eq!(v.get("ticks").unwrap(), 7);
        assert_eq!(v.get("leak_detected").unwrap(), false);
    }

    #[tokio::test]
    async fn test_build_vpn_envelope_passes_rotation_events_through() {
        let events = vec![json!({"attempt": 0, "instance": "vpn-1"})];
        let env = build_vpn_envelope(None, 0, None, 30, Some(events.clone()), None).await;
        let arr = env.get("vpn_rotation_events").unwrap().as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0].get("instance").unwrap(), "vpn-1");
    }

    #[tokio::test]
    async fn test_envelope_includes_proxy_tier_used() {
        let sel = mk_selection("surfshark", 8001);
        let proxy = vpn_rotate::proxy_resolver::ProxySelection {
            tier_name: "surfshark".to_string(),
            proxy_kind: vpn_rotate::proxy_resolver::ProxyKind::HttpPool,
            proxy_url: Some(Url::parse("http://127.0.0.1:8001/").unwrap()),
            no_proxy: Vec::new(),
            strength: vpn_rotate::proxy_resolver::ProxyStrength::Datacenter,
            from_session_cache: false,
            source: vpn_rotate::proxy_resolver::SelectionSource::Explicit,
            pool_healthy_count: Some(3),
        };

        let env = build_vpn_envelope(Some(&sel), 0, None, 30, None, Some(&proxy)).await;

        assert_eq!(env.get("proxy_tier_used").unwrap(), "surfshark");
        assert_eq!(env.get("proxy_tier_source").unwrap(), "Explicit");
    }

    #[tokio::test]
    async fn test_envelope_pool_healthy_count_reflects_actual_pool() {
        let policy = crate::policy::Policy {
            schema_version: 1,
            require_vpn: false,
            vpn_required_country: None,
            vpn_instances: (1..=3)
                .map(|i| crate::policy::VpnInstance {
                    name: format!("vpn-{i}"),
                    http_proxy_port: 8000 + i as u16,
                    control_port: 8880 + i as u16,
                })
                .collect(),
            proxies: Default::default(),
            fallback_chain: Default::default(),
        };
        let resolver = crate::vpn_selector::build_resolver(&policy).unwrap();
        let url = Url::parse("https://example.com/").unwrap();
        let proxy = crate::vpn_selector::select_proxy_with_resolver(
            &resolver,
            &url,
            "pool-count-session",
            Some("surfshark"),
            None,
        )
        .unwrap()
        .unwrap();
        let sel = crate::vpn_selector::Selection::from(proxy.clone());
        let env = build_vpn_envelope(Some(&sel), 0, None, 30, None, Some(&proxy)).await;

        assert_eq!(env.get("vpn_pool_healthy_count").unwrap(), 3);
    }

    #[tokio::test]
    async fn test_envelope_proxy_tier_attempts_array_format() {
        let proxy = vpn_rotate::proxy_resolver::ProxySelection {
            tier_name: "surfshark".to_string(),
            proxy_kind: vpn_rotate::proxy_resolver::ProxyKind::HttpPool,
            proxy_url: Some(Url::parse("http://127.0.0.1:8001/").unwrap()),
            no_proxy: Vec::new(),
            strength: vpn_rotate::proxy_resolver::ProxyStrength::Datacenter,
            from_session_cache: false,
            source: vpn_rotate::proxy_resolver::SelectionSource::AutoFallback(1),
            pool_healthy_count: Some(3),
        };
        let attempts = vec![json!({"tier": "direct", "signal": "http_403"})];

        let env = build_vpn_envelope(None, 0, None, 30, Some(attempts), Some(&proxy)).await;
        let attempts = env.get("proxy_tier_attempts").unwrap().as_array().unwrap();

        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0].get("tier").unwrap(), "direct");
        assert_eq!(attempts[0].get("signal").unwrap(), "http_403");
    }
}
