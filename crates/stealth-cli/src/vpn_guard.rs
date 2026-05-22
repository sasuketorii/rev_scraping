// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.0.0 (Phase 6c)
//! Fail-closed VPN-required guard. Called by spider / cf-evaluate /
//! relocate (--url) before any network egress. On failure produces a
//! `StealthError::Leak` mapped to exit code 7 via
//! [`stealth_core::ExitCode::Leak`].

use serde_json::{json, Value};
use stealth_core::StealthError;
use vpn_rotate::leak_guard::{probe_all, InstanceDescriptor, ProbeReport};

use crate::policy::{Policy, VpnInstance};

/// Run a startup leak probe against every configured instance.
///
/// Returns `Ok(Some(report_json))` when `require_vpn=true` and the
/// probe passed; `Ok(None)` when `require_vpn=false` (gate disabled);
/// `Err(StealthError::Leak)` when any check fails.
///
/// The JSON report is meant to be attached to the subcommand's success
/// payload so operators can audit which instance carried each fetch.
pub async fn run_startup_probe(
    require_vpn: bool,
    policy: &Policy,
) -> Result<Option<Value>, StealthError> {
    if !require_vpn {
        return Ok(None);
    }
    if policy.vpn_instances.is_empty() {
        return Err(StealthError::Leak(
            "require_vpn=true but no VPN instances configured \
             (VPN_INSTANCES env / ~/.rev_scraping/policy.toml is empty)"
                .into(),
        ));
    }
    let instances: Vec<InstanceDescriptor> =
        policy.vpn_instances.iter().map(to_descriptor).collect();
    let expected = policy.vpn_required_country.as_deref();
    match probe_all(&instances, expected).await {
        Ok(reports) => Ok(Some(reports_to_json(&reports))),
        Err(e) => Err(StealthError::Leak(format!("{e}"))),
    }
}

fn to_descriptor(v: &VpnInstance) -> InstanceDescriptor {
    InstanceDescriptor {
        name: v.name.clone(),
        http_proxy_port: v.http_proxy_port,
        control_port: v.control_port,
    }
}

fn reports_to_json(reports: &[ProbeReport]) -> Value {
    json!({
        "kind": "probe_all",
        "instances": reports
            .iter()
            .map(|r| json!({
                "name": r.instance_name,
                "exit_ip": r.exit_ip,
                "exit_country": r.exit_country,
                "kill_switch_on": r.kill_switch_on,
                "dns_lock_on": r.dns_lock_on,
                "ipv6_disabled": r.ipv6_disabled,
            }))
            .collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn require_vpn_false_returns_none() {
        let pol = Policy::default();
        let r = run_startup_probe(false, &pol).await.unwrap();
        assert!(r.is_none());
    }

    #[tokio::test]
    async fn require_vpn_true_no_instances_returns_leak() {
        let pol = Policy {
            schema_version: 1,
            require_vpn: true,
            vpn_required_country: None,
            vpn_instances: vec![],
            proxies: Default::default(),
            fallback_chain: Default::default(),
        };
        let err = run_startup_probe(true, &pol).await.unwrap_err();
        assert_eq!(err.exit_code().as_i32(), 7);
    }
}
