// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! Leak-guard checks for the Gluetun VPN container.
//!
//! Wave 0.0.4 fail-closed pre-flight: before we ever route a request,
//! verify the container the workload talks to actually has:
//!
//! 1. `NET_ADMIN` capability + `FIREWALL=on` env  → kill-switch in place
//!    so a Wireguard down event drops traffic instead of silently
//!    falling back to host routing.
//! 2. DNS-over-TLS pinned to a privacy provider, with the host
//!    `/etc/resolv.conf` bypass disabled (`DNS_KEEP_NAMESERVER=off`).
//! 3. IPv6 disabled in the container kernel (`net.ipv6.conf.all.disable_ipv6 = 1`)
//!    so we never leak v6 around the v4 tunnel.
//! 4. A reachable, externally-observed exit IP that matches the VPN
//!    egress (and optionally the expected ISO-2 country).
//!
//! Each check returns `Err(LeakGuardError::*)` with a human-readable
//! detail; the caller (CLI / agent) decides whether to abort the run.
//!
//! Tests in this module do **not** require a live Docker daemon — the
//! `#[ignore]` markers gate the integration paths. Pure-logic tests
//! (Display / error type) always run in CI.

use std::time::Duration;

use bollard::Docker;
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// IP information reported by the upstream `https://ipinfo.io/json`
/// probe. `country` is the ISO-2 alpha code (`"JP"`, `"US"`, ...).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IpInfo {
    pub ip: String,
    pub country: Option<String>,
    pub asn: Option<String>,
}

#[derive(Debug, Error)]
pub enum LeakGuardError {
    #[error("kill-switch not enforced: {detail}")]
    KillSwitchNotEnforced { detail: String },

    #[error("DNS lock missing: {detail}")]
    DnsLockMissing { detail: String },

    #[error("IPv6 not disabled in container kernel")]
    Ipv6NotDisabled,

    #[error("exit IP fetch failed: {0}")]
    ExitIpFetchFailed(#[from] reqwest::Error),

    #[error("VPN exit country mismatch: expected {expected}, got {got}")]
    CountryMismatch { expected: String, got: String },

    #[error("docker connect/inspect failed: {0}")]
    DockerError(String),
}

/// A descriptor for one Gluetun instance in the pool. Mirrors the
/// `stealth-cli::policy::VpnInstance` shape so we don't take a circular
/// dep on the CLI crate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstanceDescriptor {
    pub name: String,
    pub http_proxy_port: u16,
    pub control_port: u16,
}

/// Per-instance result of [`probe_all`]. All `*_on` / `*_disabled`
/// booleans reflect *post-check* state — true means the check passed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProbeReport {
    pub instance_name: String,
    pub exit_ip: String,
    pub exit_country: String,
    pub kill_switch_on: bool,
    pub dns_lock_on: bool,
    pub ipv6_disabled: bool,
}

/// Synchronous, all-instance leak probe used by fetcher subcommands
/// before any network egress (Phase 6c "Plan 3" startup probe).
///
/// On any failure across the pool, returns the first
/// [`LeakGuardError`] encountered — caller maps to `StealthError::Leak`
/// (exit 7). Empty `instances` is treated as a leak: a fail-closed
/// policy with no instances configured cannot proceed.
pub async fn probe_all(
    instances: &[InstanceDescriptor],
    expected_country: Option<&str>,
) -> Result<Vec<ProbeReport>, LeakGuardError> {
    if instances.is_empty() {
        return Err(LeakGuardError::DockerError(
            "probe_all: no VPN instances configured (require_vpn=true but VPN_INSTANCES / policy.toml is empty)"
                .into(),
        ));
    }
    let mut out = Vec::with_capacity(instances.len());
    for inst in instances {
        let g = LeakGuard::new(&inst.name).await?;
        g.enforce_kill_switch().await?;
        g.enforce_dns_lock().await?;
        g.enforce_ipv6_disable().await?;
        let ip = g.verify_exit_ip(expected_country).await?;
        out.push(ProbeReport {
            instance_name: inst.name.clone(),
            exit_ip: ip.ip,
            exit_country: ip.country.unwrap_or_default(),
            kill_switch_on: true,
            dns_lock_on: true,
            ipv6_disabled: true,
        });
    }
    Ok(out)
}

/// Fail-closed inspector for a single Gluetun container.
pub struct LeakGuard {
    docker: Docker,
    container_name: String,
}

impl LeakGuard {
    /// Connect to the local Docker daemon and pin to the given
    /// container name (e.g. `"gluetun"`, `"vpn-1"`). The daemon is
    /// contacted lazily on the first inspect.
    pub async fn new(container_name: &str) -> Result<Self, LeakGuardError> {
        let docker = Docker::connect_with_local_defaults()
            .map_err(|e| LeakGuardError::DockerError(format!("docker connect: {e}")))?;
        Ok(Self {
            docker,
            container_name: container_name.to_string(),
        })
    }

    async fn inspect(&self) -> Result<bollard::models::ContainerInspectResponse, LeakGuardError> {
        self.docker
            .inspect_container(&self.container_name, None)
            .await
            .map_err(|e| {
                LeakGuardError::DockerError(format!(
                    "inspect {container}: {e}",
                    container = self.container_name
                ))
            })
    }

    fn collect_env(info: &bollard::models::ContainerInspectResponse) -> Vec<String> {
        info.config
            .as_ref()
            .and_then(|c| c.env.clone())
            .unwrap_or_default()
    }

    fn env_var<'a>(env: &'a [String], key: &str) -> Option<&'a str> {
        let prefix = format!("{key}=");
        env.iter().find_map(|e| e.strip_prefix(&prefix))
    }

    /// Compare a Linux capability string against an expected *base* name
    /// (e.g. `"NET_ADMIN"`). Docker's compose runtime accepts the short
    /// form (`NET_ADMIN`) in `cap_add`, but `docker inspect` normalises
    /// the runtime view to the kernel-prefixed form (`CAP_NET_ADMIN`).
    /// Accept either spelling — case-insensitively — so the leak-guard
    /// does not false-positive on a correctly-configured container.
    fn cap_matches(cap: &str, expected_base: &str) -> bool {
        cap.eq_ignore_ascii_case(expected_base)
            || cap.eq_ignore_ascii_case(&format!("CAP_{expected_base}"))
    }

    /// Pure helper: returns `true` if the given `CapAdd` list grants
    /// `NET_ADMIN` (accepting either the short or `CAP_`-prefixed form
    /// emitted by `docker inspect`).
    fn cap_list_has_net_admin(cap_add: &[String]) -> bool {
        cap_add.iter().any(|c| Self::cap_matches(c, "NET_ADMIN"))
    }

    /// 1. Kill-switch: `CAP_ADD = NET_ADMIN` + `FIREWALL=on`.
    pub async fn enforce_kill_switch(&self) -> Result<(), LeakGuardError> {
        let info = self.inspect().await?;

        let cap_add = info
            .host_config
            .as_ref()
            .and_then(|h| h.cap_add.clone())
            .unwrap_or_default();
        let has_net_admin = Self::cap_list_has_net_admin(&cap_add);
        if !has_net_admin {
            return Err(LeakGuardError::KillSwitchNotEnforced {
                detail: format!(
                    "container {container} missing NET_ADMIN capability (HostConfig.CapAdd = {cap_add:?})",
                    container = self.container_name
                ),
            });
        }

        let env = Self::collect_env(&info);
        let firewall = Self::env_var(&env, "FIREWALL").unwrap_or("");
        if !firewall.eq_ignore_ascii_case("on") {
            return Err(LeakGuardError::KillSwitchNotEnforced {
                detail: format!(
                    "container {container} env FIREWALL={firewall:?} (expected \"on\")",
                    container = self.container_name
                ),
            });
        }

        Ok(())
    }

    /// 2. DNS lock: DoT enabled, provider in {cloudflare, quad9},
    ///    `DNS_KEEP_NAMESERVER=off`.
    pub async fn enforce_dns_lock(&self) -> Result<(), LeakGuardError> {
        let info = self.inspect().await?;
        let env = Self::collect_env(&info);

        let dot = Self::env_var(&env, "DOT").unwrap_or("");
        if !dot.eq_ignore_ascii_case("on") {
            return Err(LeakGuardError::DnsLockMissing {
                detail: format!("DOT={dot:?} (expected \"on\")"),
            });
        }

        let providers = Self::env_var(&env, "DOT_PROVIDERS").unwrap_or("");
        let providers_lc = providers.to_ascii_lowercase();
        let provider_ok = providers_lc
            .split(',')
            .map(|s| s.trim())
            .any(|p| p == "cloudflare" || p == "quad9");
        if !provider_ok {
            return Err(LeakGuardError::DnsLockMissing {
                detail: format!(
                    "DOT_PROVIDERS={providers:?} (expected at least one of cloudflare / quad9)"
                ),
            });
        }

        // Default behaviour of Gluetun is to drop the host nameserver,
        // so an unset value is acceptable; we only reject an explicit "on".
        let keep = Self::env_var(&env, "DNS_KEEP_NAMESERVER").unwrap_or("off");
        if keep.eq_ignore_ascii_case("on") {
            return Err(LeakGuardError::DnsLockMissing {
                detail: "DNS_KEEP_NAMESERVER=on bypasses the DoT lock".into(),
            });
        }

        Ok(())
    }

    /// 3. IPv6 disabled in container kernel via sysctl.
    pub async fn enforce_ipv6_disable(&self) -> Result<(), LeakGuardError> {
        let info = self.inspect().await?;
        let sysctls = info
            .host_config
            .as_ref()
            .and_then(|h| h.sysctls.clone())
            .unwrap_or_default();

        let v = sysctls
            .get("net.ipv6.conf.all.disable_ipv6")
            .map(String::as_str)
            .unwrap_or("");
        if v != "1" {
            return Err(LeakGuardError::Ipv6NotDisabled);
        }
        Ok(())
    }

    /// 4. Verify the externally-observed exit IP. Optionally enforce
    ///    an ISO-2 country. The probe is *direct* — we hit
    ///    `https://ipinfo.io/json` from the host, which means the
    ///    caller is responsible for routing the request through the
    ///    VPN container's network namespace (e.g. via the gluetun
    ///    HTTP-proxy port). We deliberately do not couple this to the
    ///    proxy here so the helper stays reusable.
    pub async fn verify_exit_ip(
        &self,
        expected_country: Option<&str>,
    ) -> Result<IpInfo, LeakGuardError> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()?;

        let resp = client
            .get("https://ipinfo.io/json")
            .send()
            .await?
            .error_for_status()?;
        let json: serde_json::Value = resp.json().await?;

        let ip = json
            .get("ip")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let country = json
            .get("country")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let asn = json.get("org").and_then(|v| v.as_str()).map(str::to_string);

        let info = IpInfo { ip, country, asn };

        if let Some(expected) = expected_country {
            let got = info.country.as_deref().unwrap_or("");
            if !country_matches(expected, got) {
                return Err(LeakGuardError::CountryMismatch {
                    expected: expected.to_string(),
                    got: got.to_string(),
                });
            }
        }

        Ok(info)
    }
}

/// Match an expected country (from policy) against the observed country
/// (from `ipinfo.io`). Accepts either ISO-2 alpha codes or the common long
/// name on either side, case-insensitively. Falls back to strict
/// case-insensitive equality for anything outside the small alias table.
fn country_matches(expected: &str, actual: &str) -> bool {
    if expected.eq_ignore_ascii_case(actual) {
        return true;
    }
    if let Some(alias) = country_alias(expected) {
        if alias.eq_ignore_ascii_case(actual) {
            return true;
        }
    }
    false
}

/// Minimal alias table for the countries we actually exit through. We
/// intentionally avoid pulling in a full ISO-3166 dependency: only entries
/// we plausibly use are listed.
///
/// v1.1.0 (P11): expanded to cover the 10 most common VPN exit countries:
/// JP, US, GB, DE, SG, NL, CA, AU, FR, IT.
fn country_alias(name: &str) -> Option<&'static str> {
    match name.to_ascii_lowercase().as_str() {
        "japan" => Some("JP"),
        "jp" => Some("Japan"),
        "united states" => Some("US"),
        "us" => Some("United States"),
        "united kingdom" => Some("GB"),
        "gb" => Some("United Kingdom"),
        "germany" => Some("DE"),
        "de" => Some("Germany"),
        "singapore" => Some("SG"),
        "sg" => Some("Singapore"),
        "netherlands" => Some("NL"),
        "nl" => Some("Netherlands"),
        "canada" => Some("CA"),
        "ca" => Some("Canada"),
        "australia" => Some("AU"),
        "au" => Some("Australia"),
        "france" => Some("FR"),
        "fr" => Some("France"),
        "italy" => Some("IT"),
        "it" => Some("Italy"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kill_switch_error_display_includes_detail() {
        let e = LeakGuardError::KillSwitchNotEnforced {
            detail: "missing NET_ADMIN".into(),
        };
        let s = format!("{e}");
        assert!(s.contains("kill-switch not enforced"));
        assert!(s.contains("missing NET_ADMIN"));
    }

    #[test]
    fn dns_lock_error_display() {
        let e = LeakGuardError::DnsLockMissing {
            detail: "DOT=off".into(),
        };
        assert!(format!("{e}").contains("DNS lock missing"));
    }

    #[test]
    fn ipv6_error_display() {
        let e = LeakGuardError::Ipv6NotDisabled;
        assert_eq!(format!("{e}"), "IPv6 not disabled in container kernel");
    }

    #[test]
    fn country_mismatch_error_display() {
        let e = LeakGuardError::CountryMismatch {
            expected: "JP".into(),
            got: "US".into(),
        };
        let s = format!("{e}");
        assert!(s.contains("expected JP"));
        assert!(s.contains("got US"));
    }

    #[test]
    fn ip_info_serde_roundtrip() {
        let i = IpInfo {
            ip: "203.0.113.1".into(),
            country: Some("JP".into()),
            asn: Some("AS64512 ExampleNet".into()),
        };
        let s = serde_json::to_string(&i).unwrap();
        let back: IpInfo = serde_json::from_str(&s).unwrap();
        assert_eq!(i, back);
    }

    /// Pure logic test for the env-var parser.
    #[test]
    fn env_var_extracts_value() {
        let env = vec![
            "PATH=/usr/bin".to_string(),
            "FIREWALL=on".to_string(),
            "DOT=on".to_string(),
        ];
        assert_eq!(LeakGuard::env_var(&env, "FIREWALL"), Some("on"));
        assert_eq!(LeakGuard::env_var(&env, "DOT"), Some("on"));
        assert_eq!(LeakGuard::env_var(&env, "MISSING"), None);
    }

    #[test]
    fn test_cap_matches_unprefixed() {
        // Compose-style short form must match.
        assert!(LeakGuard::cap_matches("NET_ADMIN", "NET_ADMIN"));
        assert!(LeakGuard::cap_matches("net_admin", "NET_ADMIN"));
    }

    #[test]
    fn test_cap_matches_prefixed() {
        // Docker-inspect normalised form must match.
        assert!(LeakGuard::cap_matches("CAP_NET_ADMIN", "NET_ADMIN"));
        assert!(LeakGuard::cap_matches("cap_net_admin", "NET_ADMIN"));
    }

    #[test]
    fn test_cap_matches_wrong_base() {
        // Different capability must not match.
        assert!(!LeakGuard::cap_matches("SYS_ADMIN", "NET_ADMIN"));
        assert!(!LeakGuard::cap_matches("CAP_SYS_ADMIN", "NET_ADMIN"));
        // Empty / unrelated values must not match.
        assert!(!LeakGuard::cap_matches("", "NET_ADMIN"));
        assert!(!LeakGuard::cap_matches("NET_ADMIN_EXTRA", "NET_ADMIN"));
    }

    #[test]
    fn test_leak_guard_accepts_docker_normalized_caps() {
        // Mirrors the `HostConfig.CapAdd` shape emitted by
        // `docker inspect` for a compose-launched container with
        // `cap_add: [NET_ADMIN]`. Docker normalises this to
        // `["CAP_NET_ADMIN"]` at runtime — the guard must accept it.
        let cap_add_normalized: Vec<String> = vec!["CAP_NET_ADMIN".to_string()];
        assert!(
            LeakGuard::cap_list_has_net_admin(&cap_add_normalized),
            "guard must accept docker-normalised CAP_NET_ADMIN",
        );

        // Legacy compose-short form must still be accepted.
        let cap_add_short: Vec<String> = vec!["NET_ADMIN".to_string()];
        assert!(LeakGuard::cap_list_has_net_admin(&cap_add_short));

        // Mixed list with an unrelated cap plus the normalised one.
        let cap_add_mixed: Vec<String> = vec!["CAP_CHOWN".to_string(), "CAP_NET_ADMIN".to_string()];
        assert!(LeakGuard::cap_list_has_net_admin(&cap_add_mixed));

        // Empty / missing must fail closed.
        let cap_add_empty: Vec<String> = vec![];
        assert!(!LeakGuard::cap_list_has_net_admin(&cap_add_empty));

        // Wrong capability only must fail closed.
        let cap_add_wrong: Vec<String> = vec!["CAP_SYS_ADMIN".to_string()];
        assert!(!LeakGuard::cap_list_has_net_admin(&cap_add_wrong));
    }

    /// Live Docker integration test (skipped in CI). Run with
    /// `REV_STEALTH_RUN_DOCKER_TESTS=1 cargo test --features docker -- --ignored`.
    #[tokio::test]
    #[ignore]
    async fn live_inspect_against_gluetun() {
        if std::env::var("REV_STEALTH_RUN_DOCKER_TESTS").is_err() {
            return;
        }
        let g = LeakGuard::new("gluetun").await.unwrap();
        // We don't assert PASS here; this test exists so an operator
        // can run it manually against a real container.
        let _ = g.enforce_kill_switch().await;
        let _ = g.enforce_dns_lock().await;
        let _ = g.enforce_ipv6_disable().await;
    }

    #[test]
    fn test_country_matches_japan_and_jp_equiv() {
        // Long form expected, ISO-2 observed (the realistic case: policy
        // says "Japan", ipinfo returns "JP").
        assert!(country_matches("Japan", "JP"));
        // Reverse: policy uses ISO-2, observation is long form.
        assert!(country_matches("JP", "Japan"));
        // Same for US / United States.
        assert!(country_matches("United States", "US"));
        assert!(country_matches("US", "United States"));
    }

    #[test]
    fn test_country_matches_case_insensitive() {
        assert!(country_matches("japan", "JP"));
        assert!(country_matches("JAPAN", "jp"));
        assert!(country_matches("jp", "japan"));
        assert!(country_matches("Jp", "jApAn"));
        // Plain case-insensitive equality path.
        assert!(country_matches("japan", "Japan"));
    }

    #[test]
    fn test_country_matches_unknown_alias_falls_back_to_strict() {
        // No alias entry for "Brazil" → only strict (case-insensitive)
        // equality applies.
        assert!(country_matches("Brazil", "brazil"));
        assert!(!country_matches("Brazil", "BR"));
        assert!(!country_matches("BR", "Brazil"));
        // And cross-country mismatches must still fail.
        assert!(!country_matches("Japan", "US"));
        assert!(!country_matches("JP", "US"));
    }

    // ---- P11 SHOULD: extended country alias coverage ----

    #[test]
    fn country_matches_uk_and_gb_equiv() {
        assert!(country_matches("United Kingdom", "GB"));
        assert!(country_matches("GB", "United Kingdom"));
        assert!(country_matches("united kingdom", "gb"));
        assert!(country_matches("gb", "United Kingdom"));
    }

    #[test]
    fn country_matches_germany_and_de_equiv() {
        assert!(country_matches("Germany", "DE"));
        assert!(country_matches("DE", "Germany"));
        assert!(country_matches("germany", "de"));
    }

    #[test]
    fn country_matches_known_aliases_8_total() {
        // Every newly-added P11 pair must be bidirectional.
        let pairs: &[(&str, &str)] = &[
            ("United Kingdom", "GB"),
            ("Germany", "DE"),
            ("Singapore", "SG"),
            ("Netherlands", "NL"),
            ("Canada", "CA"),
            ("Australia", "AU"),
            ("France", "FR"),
            ("Italy", "IT"),
        ];
        assert_eq!(pairs.len(), 8, "must cover all 8 new P11 countries");
        for (long, iso2) in pairs {
            assert!(country_matches(long, iso2), "long → iso2 failed: {long}");
            assert!(country_matches(iso2, long), "iso2 → long failed: {long}");
            // Case-insensitivity must hold on both sides.
            assert!(country_matches(&long.to_lowercase(), &iso2.to_lowercase()));
        }
    }

    /// Pseudo-proptest: exhaustively test every alias pair from the table
    /// for bidirectional symmetry, with random case-mangling applied.
    /// (We avoid a full proptest dependency; this iterates a fixed
    /// realistic case-permutation set deterministically.)
    #[test]
    fn country_alias_symmetric_property() {
        let pairs: &[(&str, &str)] = &[
            ("Japan", "JP"),
            ("United States", "US"),
            ("United Kingdom", "GB"),
            ("Germany", "DE"),
            ("Singapore", "SG"),
            ("Netherlands", "NL"),
            ("Canada", "CA"),
            ("Australia", "AU"),
            ("France", "FR"),
            ("Italy", "IT"),
        ];
        let case_perms: &[fn(&str) -> String] = &[
            |s| s.to_string(),
            |s| s.to_lowercase(),
            |s| s.to_uppercase(),
            |s| {
                s.chars()
                    .enumerate()
                    .map(|(i, c)| {
                        if i % 2 == 0 {
                            c.to_ascii_uppercase()
                        } else {
                            c.to_ascii_lowercase()
                        }
                    })
                    .collect()
            },
        ];
        for (long, iso2) in pairs {
            for fl in case_perms {
                for fi in case_perms {
                    let a = fl(long);
                    let b = fi(iso2);
                    assert!(country_matches(&a, &b), "expected {a:?} ↔ {b:?} to match");
                    assert!(
                        country_matches(&b, &a),
                        "expected {b:?} ↔ {a:?} to match (reverse)"
                    );
                }
            }
        }
    }
}
