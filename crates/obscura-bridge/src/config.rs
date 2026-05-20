// SPDX-License-Identifier: MIT
// Source: derived from obscura (Apache-2.0), https://github.com/h4ckf0r0day/obscura

use std::path::PathBuf;

use url::Url;
use uuid::Uuid;

/// Per-launch configuration for an [`super::ObscuraBridge`].
///
/// `blocklist_enabled` and `ssrf_guard` default to `true` per plan §3.1: the
/// bridge enforces SSRF independently from obscura's own guard (S10) so a
/// misconfigured subprocess cannot reach RFC1918 / link-local / IMDS targets.
#[derive(Debug, Clone)]
pub struct ObscuraConfig {
    pub binary_path: PathBuf,
    pub session_id: Uuid,
    /// Deprecated (Phase 9 hotfix-1): this field is currently ignored by
    /// the obscura subprocess launcher; obscura is a fully-headless browser
    /// and does not accept a headed-mode toggle. Retained for source/binary
    /// compatibility with existing call sites (spider, cf-evaluate). Slated
    /// for removal in v1.2; see `.agent/active/phase9_hotfix1_followups.md`.
    pub headless: bool,
    pub blocklist_enabled: bool,
    pub ssrf_guard: bool,
    pub mobile_fp: Option<mobile_fp::Fingerprint>,
    pub proxy: Option<Url>,
    /// TCP port on which obscura serves CDP. `None` => let the bridge pick an
    /// ephemeral free port (placeholder 0 -> bridge resolves at launch time).
    pub cdp_port: Option<u16>,
    /// Extra CLI args appended verbatim. For diagnostics / experimentation.
    pub extra_args: Vec<String>,
}

impl Default for ObscuraConfig {
    fn default() -> Self {
        Self {
            binary_path: PathBuf::from("obscura"),
            session_id: Uuid::new_v4(),
            headless: true,
            blocklist_enabled: true,
            ssrf_guard: true,
            mobile_fp: None,
            proxy: None,
            cdp_port: None,
            extra_args: Vec::new(),
        }
    }
}

impl ObscuraConfig {
    /// Convenience constructor: explicit binary path, default everything else.
    pub fn with_binary(binary_path: PathBuf) -> Self {
        Self {
            binary_path,
            ..Self::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_obscura_config_defaults() {
        let cfg = ObscuraConfig::default();
        assert!(cfg.blocklist_enabled, "blocklist must default to ON");
        assert!(cfg.ssrf_guard, "bridge SSRF guard must default to ON (S10)");
        assert!(cfg.headless, "headless default ON for unattended use");
        assert!(cfg.proxy.is_none());
        assert!(cfg.mobile_fp.is_none());
        assert!(cfg.cdp_port.is_none());
        assert!(cfg.extra_args.is_empty());
    }

    #[test]
    fn test_session_id_is_unique_per_bridge() {
        // Each fresh ObscuraConfig (one-per-bridge) must mint a new UUID so
        // per-session FP cache keys (S3) don't collide.
        let a = ObscuraConfig::default();
        let b = ObscuraConfig::default();
        assert_ne!(a.session_id, b.session_id);
    }
}
