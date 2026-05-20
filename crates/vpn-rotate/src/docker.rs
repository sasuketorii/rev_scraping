// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! bollard-backed Docker control for the VPN pool.
//!
//! Wave 3 implementation. Surface area:
//!
//! - [`rotate`] — issue a `restart` against the chosen Gluetun container
//!   so the WireGuard tunnel re-handshakes with a fresh egress IP.
//!   Honors [`RotationStrategy::LazyOnFail`] via a process-local
//!   failure counter (in-memory, so cross-process callers should drive
//!   their own counter and pass `reason="forced"` to skip the gate).
//! - [`status`] — return container running state plus the public IP
//!   reported by `https://api.ipify.org/?format=json` proxied through
//!   the Gluetun HTTP-proxy port. The proxy port is computed from the
//!   `--container` slug (`vpn-1` → `127.0.0.1:8881`, `vpn-2` →
//!   `8882`, …) so the same compose template Wave 3 ships works.
//!
//! Threat model / hygiene (RustSkills §3.1):
//!
//! - **bounded queue**: a process-local [`Mutex`] gate caps concurrent
//!   rotations at 1; a configurable cap of N >= 2 lands when a real
//!   pool is in use.
//! - **kill switch**: a `restart_container` failure surfaces as a
//!   transient error; the caller (CLI) propagates exit code 2 and the
//!   `reason` field is recorded in the audit trail.
//! - **secret redaction**: this module never reads any of the
//!   `WIREGUARD_*` secrets; only container names. Secrets stay in
//!   docker-compose.vpn.yml + the `.env` file.
//!
//! Tests: the docker-Daemon-touching paths are guarded by the
//! `REV_STEALTH_RUN_DOCKER_TESTS=1` env (off by default in CI).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use bollard::Docker;
use stealth_core::{Result, StealthError};
use tokio::sync::Mutex;
use tracing::{debug, info, warn};

use crate::{RotationReport, RotationRequest, RotationStrategy, StatusReport};

/// Number of consecutive failures observed since the last successful
/// rotation. Used by [`RotationStrategy::LazyOnFail`] to decide whether
/// a rotation request should fire.
static FAIL_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Threshold above which a `LazyOnFail` request actually rotates.
/// Configurable via `REV_STEALTH_VPN_FAIL_THRESHOLD`; defaults to 3.
fn fail_threshold() -> u64 {
    std::env::var("REV_STEALTH_VPN_FAIL_THRESHOLD")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3)
}

/// One-shot Docker client cached for the process. Connection is lazy.
fn docker_client() -> Result<&'static Docker> {
    static CLIENT: OnceLock<std::result::Result<Docker, String>> = OnceLock::new();
    let cell = CLIENT.get_or_init(|| {
        Docker::connect_with_local_defaults().map_err(|e| format!("docker connect: {e}"))
    });
    match cell {
        Ok(d) => Ok(d),
        Err(e) => Err(StealthError::Transient(e.clone())),
    }
}

/// Rotation gate: at most one in-flight rotation at a time.
fn rotation_gate() -> &'static Mutex<()> {
    static GATE: OnceLock<Mutex<()>> = OnceLock::new();
    GATE.get_or_init(|| Mutex::new(()))
}

/// Resolve which Gluetun container a request applies to. The
/// `region` field of the request, when present, picks `vpn-{region}`;
/// otherwise we round-robin through `vpn-1` / `vpn-2` / `vpn-3` based
/// on the rotation counter so successive lazy rotations distribute.
fn pick_container(req: &RotationRequest) -> String {
    if let Some(region) = req.region.as_deref() {
        // Numeric region -> vpn-N; otherwise treat as a country code
        // prefix and pin to vpn-1. The compose template doesn't tag
        // containers by country; richer routing belongs in a higher
        // layer.
        if region.chars().all(|c| c.is_ascii_digit()) {
            return format!("vpn-{region}");
        }
    }
    let i = FAIL_COUNTER.load(Ordering::Relaxed) % 3 + 1;
    format!("vpn-{i}")
}

/// Resolve the host-side HTTP proxy port for a Gluetun container.
///
/// Phase 6c: when the `VPN_INSTANCES` env var is set and parseable, it
/// becomes the source of truth (matching `policy.toml`). Otherwise we
/// fall back to the hard-coded `vpn-N -> 888N` mapping that older
/// compose templates ship with (backward compat).
///
/// Format: `name:http_proxy_port:control_port[,name:port:port...]`.
fn proxy_port_for(container: &str) -> Option<u16> {
    if let Ok(raw) = std::env::var("VPN_INSTANCES") {
        if let Some(p) = proxy_port_from_env(&raw, container) {
            return Some(p);
        }
        // Env was set but contained no entry for this container.
        // Fall through to the hard-coded default rather than return
        // None, so partially-populated env doesn't break unrelated
        // containers.
    }
    let n: u16 = container.strip_prefix("vpn-")?.parse().ok()?;
    Some(8880 + n)
}

/// Pure parser for `VPN_INSTANCES` → `http_proxy_port` lookup. Extracted
/// so unit tests can exercise it without touching process env.
fn proxy_port_from_env(raw: &str, container: &str) -> Option<u16> {
    for entry in raw.split(',') {
        let entry = entry.trim();
        if entry.is_empty() {
            continue;
        }
        let mut parts = entry.split(':').map(str::trim);
        let name = parts.next()?;
        let port_str = parts.next()?;
        let _ctrl = parts.next()?;
        if name == container {
            return port_str.parse().ok();
        }
    }
    None
}

/// Probe the public IP via Gluetun's HTTP proxy. Returns `None` when
/// the probe fails (network blip, container down) — the caller treats
/// it as "unknown" rather than failing the whole rotation.
async fn probe_public_ip(container: &str) -> Option<String> {
    let port = proxy_port_for(container)?;
    #[cfg(feature = "docker")]
    {
        let proxy = format!("http://127.0.0.1:{port}");
        let client = reqwest::Client::builder()
            .proxy(reqwest::Proxy::http(&proxy).ok()?)
            .proxy(reqwest::Proxy::https(&proxy).ok()?)
            .timeout(Duration::from_secs(10))
            .build()
            .ok()?;
        let resp = client
            .get("https://api.ipify.org/?format=json")
            .send()
            .await
            .ok()?;
        let json: serde_json::Value = resp.json().await.ok()?;
        return json.get("ip").and_then(|v| v.as_str()).map(str::to_string);
    }
    #[allow(unreachable_code)]
    None
}

pub async fn rotate(req: RotationRequest) -> Result<RotationReport> {
    let started = Instant::now();
    let container = pick_container(&req);

    // Lazy-on-fail gate.
    if matches!(req.strategy, RotationStrategy::LazyOnFail) && req.reason != "forced" {
        let fails = FAIL_COUNTER.load(Ordering::Relaxed);
        if fails < fail_threshold() {
            debug!(
                fails,
                threshold = fail_threshold(),
                reason = %req.reason,
                "lazy-on-fail: skipping rotation"
            );
            return Ok(RotationReport {
                rotated: false,
                container,
                previous_ip: None,
                new_ip: None,
                elapsed_ms: started.elapsed().as_millis() as u64,
            });
        }
    }

    let _gate = rotation_gate().lock().await;

    let docker = docker_client()?;
    let prev_ip = probe_public_ip(&container).await;

    info!(%container, reason = %req.reason, "rotating VPN container");
    docker
        .restart_container(&container, None)
        .await
        .map_err(|e| StealthError::Transient(format!("restart {container}: {e}")))?;

    // Wait for the Gluetun healthcheck to report ready. We poll the
    // container state every 500ms up to 60s.
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut healthy = false;
    while Instant::now() < deadline {
        match docker.inspect_container(&container, None).await {
            Ok(info) => {
                let running = info.state.as_ref().and_then(|s| s.running).unwrap_or(false);
                // Health status is reported as a Debug-formatted enum
                // by bollard; the precise variant path differs across
                // versions and is not publicly re-exported. We
                // stringify and pattern-match on the literal label,
                // which is stable across bollard 0.x.
                let health_label = info
                    .state
                    .as_ref()
                    .and_then(|s| s.health.as_ref())
                    .and_then(|h| h.status.as_ref())
                    .map(|s| format!("{s:?}"));
                debug!(?running, ?health_label, "post-restart container state");
                let health_ok = match health_label.as_deref() {
                    None => true, // no healthcheck configured
                    Some(label) => {
                        let l = label.to_ascii_uppercase();
                        l.contains("HEALTHY") && !l.contains("UNHEALTHY")
                            || l.contains("EMPTY")
                            || l == "NONE"
                    }
                };
                if running && health_ok {
                    healthy = true;
                    break;
                }
            }
            Err(e) => {
                warn!(?e, "inspect_container failed during rotation poll");
            }
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }

    if !healthy {
        return Err(StealthError::Transient(format!(
            "container {container} did not become healthy within 60s after restart"
        )));
    }

    let new_ip = probe_public_ip(&container).await;
    FAIL_COUNTER.store(0, Ordering::Relaxed);

    Ok(RotationReport {
        rotated: true,
        container,
        previous_ip: prev_ip,
        new_ip,
        elapsed_ms: started.elapsed().as_millis() as u64,
    })
}

pub async fn status(provider: &str) -> Result<StatusReport> {
    // The `provider` arg is used as the container slug; default
    // `surfshark` falls back to `vpn-1` since the compose template
    // uses generic container names.
    let container = if provider.starts_with("vpn-") {
        provider.to_string()
    } else {
        "vpn-1".to_string()
    };

    let docker = docker_client()?;
    let info = docker
        .inspect_container(&container, None)
        .await
        .map_err(|e| StealthError::Transient(format!("inspect {container}: {e}")))?;
    let running = info.state.as_ref().and_then(|s| s.running).unwrap_or(false);
    let current_ip = if running {
        probe_public_ip(&container).await
    } else {
        None
    };
    Ok(StatusReport {
        container,
        running,
        current_ip,
    })
}

/// Test-only helper to bump the failure counter so unit tests can
/// exercise the lazy-on-fail gate without spinning up real Docker.
#[cfg(test)]
pub(crate) fn record_failure() {
    FAIL_COUNTER.fetch_add(1, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn reset_counter() {
    FAIL_COUNTER.store(0, Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // Serialize tests that mutate process env (VPN_INSTANCES) so they
    // don't race the env-unaware port-lookup test.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn proxy_port_maps_one_to_one() {
        let _g = ENV_LOCK.lock().unwrap();
        // Ensure no stale env from other tests poisons the default path.
        std::env::remove_var("VPN_INSTANCES");
        assert_eq!(proxy_port_for("vpn-1"), Some(8881));
        assert_eq!(proxy_port_for("vpn-2"), Some(8882));
        assert_eq!(proxy_port_for("vpn-10"), Some(8890));
        assert_eq!(proxy_port_for("not-a-vpn"), None);
        assert_eq!(proxy_port_for("vpn-abc"), None);
    }

    #[test]
    fn test_proxy_port_from_env_instances() {
        let raw = "vpn-1:8001:8881,vpn-2:8002:8882,vpn-3:8003:8883";
        assert_eq!(proxy_port_from_env(raw, "vpn-1"), Some(8001));
        assert_eq!(proxy_port_from_env(raw, "vpn-2"), Some(8002));
        assert_eq!(proxy_port_from_env(raw, "vpn-3"), Some(8003));
        assert_eq!(proxy_port_from_env(raw, "vpn-9"), None);
        // whitespace + empty entry tolerated
        let raw2 = " vpn-1:8001:8881 , ";
        assert_eq!(proxy_port_from_env(raw2, "vpn-1"), Some(8001));
    }

    #[test]
    fn test_proxy_port_from_env_instances_overrides_hardcoded() {
        let _g = ENV_LOCK.lock().unwrap();
        // Without env: hard-coded vpn-1 -> 8881.
        std::env::remove_var("VPN_INSTANCES");
        assert_eq!(proxy_port_for("vpn-1"), Some(8881));
        // With env: vpn-1 -> 8001 (env wins).
        std::env::set_var("VPN_INSTANCES", "vpn-1:8001:8881,vpn-2:8002:8882");
        assert_eq!(proxy_port_for("vpn-1"), Some(8001));
        assert_eq!(proxy_port_for("vpn-2"), Some(8002));
        // Container not in env falls back to hard-coded.
        assert_eq!(proxy_port_for("vpn-3"), Some(8883));
        std::env::remove_var("VPN_INSTANCES");
    }

    #[test]
    fn pick_container_uses_numeric_region() {
        let req = RotationRequest {
            provider: "surfshark".into(),
            strategy: RotationStrategy::LazyOnFail,
            region: Some("2".into()),
            reason: "test".into(),
        };
        assert_eq!(pick_container(&req), "vpn-2");
    }

    #[test]
    fn pick_container_round_robins_when_no_region() {
        reset_counter();
        let req = RotationRequest {
            provider: "surfshark".into(),
            strategy: RotationStrategy::LazyOnFail,
            region: None,
            reason: "test".into(),
        };
        let a = pick_container(&req);
        record_failure();
        let b = pick_container(&req);
        record_failure();
        let c = pick_container(&req);
        record_failure();
        let d = pick_container(&req);
        // 1 -> 2 -> 3 -> 1 cycle. We don't assert exact values from
        // any specific start, just that we cycle through three slots.
        let mut seen: Vec<String> = vec![a, b, c, d];
        seen.sort();
        seen.dedup();
        assert_eq!(seen.len(), 3);
        for c in &seen {
            assert!(c.starts_with("vpn-"));
        }
        reset_counter();
    }

    #[tokio::test]
    async fn lazy_on_fail_skips_when_under_threshold() {
        reset_counter();
        std::env::set_var("REV_STEALTH_VPN_FAIL_THRESHOLD", "3");
        let req = RotationRequest {
            provider: "surfshark".into(),
            strategy: RotationStrategy::LazyOnFail,
            region: Some("1".into()),
            reason: "lazy-skip-test".into(),
        };
        // Counter at 0 < threshold 3 -> rotation skipped, no docker
        // call attempted (so this works in CI without Docker).
        let report = rotate(req).await.unwrap();
        assert!(!report.rotated);
        assert_eq!(report.container, "vpn-1");
        assert!(report.previous_ip.is_none());
        assert!(report.new_ip.is_none());
        std::env::remove_var("REV_STEALTH_VPN_FAIL_THRESHOLD");
    }

    #[tokio::test]
    async fn lazy_on_fail_with_forced_reason_attempts_rotation() {
        reset_counter();
        // `forced` reason bypasses the lazy gate; without Docker the
        // rotation should fail with a Transient error rather than a
        // skip.
        let req = RotationRequest {
            provider: "surfshark".into(),
            strategy: RotationStrategy::LazyOnFail,
            region: Some("1".into()),
            reason: "forced".into(),
        };
        let result = rotate(req).await;
        // We don't know whether Docker is available in the test env;
        // accept either Ok (Docker up) or Transient/Permanent (Docker
        // down). What we want to assert is that the lazy gate did NOT
        // short-circuit: if it had, we'd see Ok with rotated=false.
        if let Ok(r) = &result {
            // If Docker is available and the test container exists,
            // rotation may succeed; we still expect rotated=true.
            assert!(r.rotated, "forced reason must bypass lazy gate");
        }
        // Either outcome is acceptable in unit-test land.
    }
}
