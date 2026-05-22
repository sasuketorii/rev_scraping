// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! vpn-rotate
//!
//! VPN IP rotation via Surfshark + Gluetun (Docker compose). Provides a
//! Rust API the CLI / agent skills consume:
//!
//! - [`RotationStrategy`] — `lazy-on-fail` / `every-n` / `interval`.
//! - [`RotationRequest`] — provider, strategy, optional region, audit reason.
//! - [`RotationReport`] — IP-before, IP-after, container id, elapsed.
//! - [`StatusReport`] — current public IP + container running state.
//! - [`rotate`] / [`status`] — async entry points.
//!
//! Wave 2.1 ships the structured surface. Wave 3 adds the bollard-backed
//! Docker control + lazy-on-fail counter + `https://api.ipify.org` IP
//! lookup behind the `docker` feature.

#![forbid(unsafe_code)]

use serde::{Deserialize, Serialize};
use stealth_core::{Result, StealthError};

#[cfg(feature = "docker")]
pub mod docker;

#[cfg(feature = "docker")]
pub mod leak_guard;

pub mod credentials;

pub mod instance_pool;

pub mod leak_monitor;

pub mod proxy_resolver;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RotationStrategy {
    /// Skip rotation unless the failure counter has crossed the threshold.
    LazyOnFail,
    /// Rotate every N requests.
    EveryN,
    /// Rotate on a wall-clock interval.
    Interval,
}

impl RotationStrategy {
    pub fn from_slug(slug: &str) -> Option<Self> {
        Some(match slug {
            "lazy-on-fail" | "lazy" => RotationStrategy::LazyOnFail,
            "every-n" | "every" => RotationStrategy::EveryN,
            "interval" => RotationStrategy::Interval,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RotationRequest {
    pub provider: String,
    pub strategy: RotationStrategy,
    pub region: Option<String>,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RotationReport {
    pub rotated: bool,
    pub container: String,
    pub previous_ip: Option<String>,
    pub new_ip: Option<String>,
    pub elapsed_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusReport {
    pub container: String,
    pub running: bool,
    pub current_ip: Option<String>,
}

/// Rotate the VPN egress.
pub async fn rotate(_req: RotationRequest) -> Result<RotationReport> {
    #[cfg(feature = "docker")]
    {
        return docker::rotate(_req).await;
    }
    #[allow(unreachable_code)]
    Err(StealthError::Permanent(
        "vpn-rotate: rotate() requires the `docker` feature (Wave 3)".into(),
    ))
}

/// Query the VPN container state and current public IP.
pub async fn status(_provider: &str) -> Result<StatusReport> {
    #[cfg(feature = "docker")]
    {
        return docker::status(_provider).await;
    }
    #[allow(unreachable_code)]
    Err(StealthError::Permanent(
        "vpn-rotate: status() requires the `docker` feature (Wave 3)".into(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotation_strategy_round_trip() {
        assert_eq!(
            RotationStrategy::from_slug("lazy-on-fail"),
            Some(RotationStrategy::LazyOnFail)
        );
        assert_eq!(
            RotationStrategy::from_slug("lazy"),
            Some(RotationStrategy::LazyOnFail)
        );
        assert_eq!(
            RotationStrategy::from_slug("every-n"),
            Some(RotationStrategy::EveryN)
        );
        assert_eq!(
            RotationStrategy::from_slug("interval"),
            Some(RotationStrategy::Interval)
        );
        assert_eq!(RotationStrategy::from_slug("nope"), None);
    }

    #[cfg(not(feature = "docker"))]
    #[tokio::test]
    async fn rotate_without_docker_feature_returns_permanent_error() {
        let req = RotationRequest {
            provider: "surfshark".into(),
            strategy: RotationStrategy::LazyOnFail,
            region: None,
            reason: "test".into(),
        };
        let err = rotate(req).await.unwrap_err();
        assert_eq!(err.exit_code(), stealth_core::ExitCode::PermanentError);
    }

    #[cfg(not(feature = "docker"))]
    #[tokio::test]
    async fn status_without_docker_feature_returns_permanent_error() {
        let err = status("surfshark").await.unwrap_err();
        assert_eq!(err.exit_code(), stealth_core::ExitCode::PermanentError);
    }
}
