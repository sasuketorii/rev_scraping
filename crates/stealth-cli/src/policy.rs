// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.0.0 (Phase 6c)
//! `~/.rev_scraping/policy.toml` loader + override precedence for the
//! fail-closed VPN-required guard.
//!
//! Precedence (highest first):
//!   1. `REV_SCRAPING_REQUIRE_VPN=1` env var (cannot be loosened)
//!   2. `--require-vpn` CLI flag
//!   3. `--allow-no-vpn` CLI flag (rejected if env=1)
//!   4. `policy.toml::require_vpn`
//!   5. Built-in default = `true` (fail-closed)
//!
//! The companion `VPN_INSTANCES` env var (`vpn-1:8001:8881,...`) parser
//! lives here too — used by both the policy and the `vpn-rotate` port
//! mapping override.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use vpn_rotate::proxy_resolver::{FallbackChain, RawTierConfig};

/// Env var that, when set to `1`, forces `require_vpn=true` regardless
/// of CLI flags or `policy.toml`. `0` / unset are advisory only.
pub const ENV_REQUIRE_VPN: &str = "REV_SCRAPING_REQUIRE_VPN";

/// Env var that overrides `vpn_instances` from `policy.toml`.
/// Format: `name:http_proxy_port:control_port[,name:port:port...]`.
pub const ENV_VPN_INSTANCES: &str = "VPN_INSTANCES";

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Policy {
    #[serde(default = "default_require_vpn")]
    pub require_vpn: bool,
    #[serde(default)]
    pub vpn_required_country: Option<String>,
    #[serde(default = "default_vpn_instances")]
    pub vpn_instances: Vec<VpnInstance>,
    #[serde(default)]
    pub proxies: BTreeMap<String, RawTierConfig>,
    #[serde(default)]
    pub fallback_chain: FallbackChain,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct VpnInstance {
    pub name: String,
    pub http_proxy_port: u16,
    pub control_port: u16,
}

fn default_require_vpn() -> bool {
    true
}

fn default_vpn_instances() -> Vec<VpnInstance> {
    vec![]
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            require_vpn: default_require_vpn(),
            vpn_required_country: None,
            vpn_instances: default_vpn_instances(),
            proxies: BTreeMap::new(),
            fallback_chain: FallbackChain::default(),
        }
    }
}

impl Policy {
    /// Default config path: `~/.rev_scraping/policy.toml`.
    pub fn default_path() -> Option<PathBuf> {
        dirs::home_dir().map(|h| h.join(".rev_scraping").join("policy.toml"))
    }

    /// Load from `~/.rev_scraping/policy.toml` if present; otherwise
    /// return [`Policy::default`].
    pub fn load() -> Result<Self> {
        let path = match Self::default_path() {
            Some(p) => p,
            None => return Ok(Self::default()),
        };
        Self::load_from(&path)
    }

    /// Load from an explicit path. Missing file → default policy.
    pub fn load_from(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let raw =
            std::fs::read_to_string(path).map_err(|e| anyhow!("read {}: {e}", path.display()))?;
        let p: Policy =
            toml::from_str(&raw).map_err(|e| anyhow!("parse {}: {e}", path.display()))?;
        Ok(p)
    }

    /// Merge in `VPN_INSTANCES` env override (if set + parseable). The
    /// env wins over the file when both are present.
    pub fn with_env_overrides(mut self) -> Self {
        if let Ok(raw) = std::env::var(ENV_VPN_INSTANCES) {
            if let Ok(parsed) = parse_vpn_instances_env(&raw) {
                if !parsed.is_empty() {
                    self.vpn_instances = parsed;
                }
            }
        }
        self
    }
}

/// Parse `VPN_INSTANCES` env var:
/// `vpn-1:8001:8881,vpn-2:8002:8882`.
/// Whitespace tolerated. Empty input → empty vec.
pub fn parse_vpn_instances_env(s: &str) -> Result<Vec<VpnInstance>> {
    let s = s.trim();
    if s.is_empty() {
        return Ok(vec![]);
    }
    let mut out = Vec::new();
    for (idx, raw) in s.split(',').enumerate() {
        let raw = raw.trim();
        if raw.is_empty() {
            continue;
        }
        let parts: Vec<&str> = raw.split(':').map(str::trim).collect();
        if parts.len() != 3 {
            return Err(anyhow!(
                "VPN_INSTANCES entry #{idx} {raw:?} must be name:http_proxy_port:control_port"
            ));
        }
        let name = parts[0].to_string();
        if name.is_empty() {
            return Err(anyhow!("VPN_INSTANCES entry #{idx} has empty name"));
        }
        let http_proxy_port: u16 = parts[1].parse().map_err(|e| {
            anyhow!(
                "VPN_INSTANCES entry #{idx} http_proxy_port {:?}: {e}",
                parts[1]
            )
        })?;
        let control_port: u16 = parts[2].parse().map_err(|e| {
            anyhow!(
                "VPN_INSTANCES entry #{idx} control_port {:?}: {e}",
                parts[2]
            )
        })?;
        out.push(VpnInstance {
            name,
            http_proxy_port,
            control_port,
        });
    }
    Ok(out)
}

/// Translate the two mutually-exclusive CLI bool flags into the
/// tri-state value [`effective_require_vpn`] expects.
pub fn cli_flags_to_tristate(require_vpn: bool, allow_no_vpn: bool) -> Option<bool> {
    if require_vpn {
        Some(true)
    } else if allow_no_vpn {
        Some(false)
    } else {
        None
    }
}

/// Resolve the effective `require_vpn` value given the override
/// hierarchy. `cli_require` is `Some(true)` when `--require-vpn` was
/// passed, `Some(false)` for `--allow-no-vpn`, and `None` when neither
/// flag was set.
pub fn effective_require_vpn(cli_require: Option<bool>, policy: &Policy) -> bool {
    // 1. Env=1 wins everything.
    if let Ok(v) = std::env::var(ENV_REQUIRE_VPN) {
        if v == "1" {
            return true;
        }
    }
    // 2. Explicit CLI flag (either direction).
    if let Some(v) = cli_require {
        return v;
    }
    // 3. Policy file value (already defaulted to true on a fresh load).
    policy.require_vpn
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // Serialize env-mutating tests so they don't race.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn clear_env() {
        std::env::remove_var(ENV_REQUIRE_VPN);
        std::env::remove_var(ENV_VPN_INSTANCES);
    }

    #[test]
    fn test_policy_default_require_vpn_is_true() {
        let p = Policy::default();
        assert!(
            p.require_vpn,
            "default must be fail-closed (require_vpn=true)"
        );
        assert!(p.vpn_required_country.is_none());
        assert!(p.vpn_instances.is_empty());
    }

    #[test]
    fn test_policy_load_missing_file_returns_default() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("does-not-exist.toml");
        let pol = Policy::load_from(&p).unwrap();
        assert_eq!(pol, Policy::default());
    }

    #[test]
    fn test_policy_load_from_toml_overrides_default() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("policy.toml");
        std::fs::write(
            &p,
            r#"
require_vpn = false
vpn_required_country = "Japan"

[[vpn_instances]]
name = "vpn-1"
http_proxy_port = 8001
control_port = 8881
"#,
        )
        .unwrap();
        let pol = Policy::load_from(&p).unwrap();
        assert!(!pol.require_vpn);
        assert_eq!(pol.vpn_required_country.as_deref(), Some("Japan"));
        assert_eq!(pol.vpn_instances.len(), 1);
        assert_eq!(pol.vpn_instances[0].name, "vpn-1");
        assert_eq!(pol.vpn_instances[0].http_proxy_port, 8001);
        assert_eq!(pol.vpn_instances[0].control_port, 8881);
    }

    #[test]
    fn test_vpn_instances_parse_from_env_var() {
        let v = parse_vpn_instances_env("vpn-1:8001:8881,vpn-2:8002:8882,vpn-3:8003:8883").unwrap();
        assert_eq!(v.len(), 3);
        assert_eq!(
            v[0],
            VpnInstance {
                name: "vpn-1".into(),
                http_proxy_port: 8001,
                control_port: 8881,
            }
        );
        assert_eq!(v[2].name, "vpn-3");
        assert_eq!(v[2].http_proxy_port, 8003);
        assert_eq!(v[2].control_port, 8883);
        // whitespace + empty entry tolerated
        let v = parse_vpn_instances_env(" vpn-1:8001:8881 , ").unwrap();
        assert_eq!(v.len(), 1);
        // empty input
        assert!(parse_vpn_instances_env("").unwrap().is_empty());
        // bad format
        assert!(parse_vpn_instances_env("vpn-1:8001").is_err());
        assert!(parse_vpn_instances_env("vpn-1:notaport:8881").is_err());
    }

    #[test]
    fn test_effective_require_vpn_env_var_wins_over_flag() {
        let _g = ENV_LOCK.lock().unwrap();
        clear_env();
        std::env::set_var(ENV_REQUIRE_VPN, "1");
        let pol = Policy {
            require_vpn: false,
            ..Policy::default()
        };
        // --allow-no-vpn = Some(false), env=1 must still force true.
        assert!(effective_require_vpn(Some(false), &pol));
        // No flag, env=1 → true.
        assert!(effective_require_vpn(None, &pol));
        clear_env();
    }

    #[test]
    fn test_effective_require_vpn_flag_over_policy() {
        let _g = ENV_LOCK.lock().unwrap();
        clear_env();
        // policy.require_vpn=true, --allow-no-vpn → false.
        let pol = Policy::default();
        assert!(pol.require_vpn);
        assert!(!effective_require_vpn(Some(false), &pol));
        // policy.require_vpn=false, --require-vpn → true.
        let pol2 = Policy {
            require_vpn: false,
            ..Policy::default()
        };
        assert!(effective_require_vpn(Some(true), &pol2));
        // no flag → falls through to policy value.
        assert!(effective_require_vpn(None, &pol));
        assert!(!effective_require_vpn(None, &pol2));
        clear_env();
    }

    #[test]
    fn test_effective_require_vpn_env_zero_does_not_loosen() {
        let _g = ENV_LOCK.lock().unwrap();
        clear_env();
        std::env::set_var(ENV_REQUIRE_VPN, "0");
        let pol = Policy::default(); // require_vpn=true
                                     // env=0 is advisory; policy still says true.
        assert!(effective_require_vpn(None, &pol));
        clear_env();
    }
}
