// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.0.0 (Phase 6d)
//! `InstancePool` — sticky-by-session VPN instance selection with HRW
//! rendezvous-hashing + lazy-on-fail eviction.
//!
//! See `.agent/active/vpn_required_design.md` §C for the design.
//!
//! Behaviour summary:
//!
//! - [`InstancePool::pick`] takes a `session_id` and returns the highest-
//!   scoring healthy instance under HRW (xxhash3-seeded). Same session →
//!   same instance, modulo failure events. Distribution across many
//!   distinct session_ids is ~uniform (verified by the
//!   `test_instance_pool_pick_distributes_evenly` test below).
//! - [`InstancePool::mark_failure`] increments a per-instance consecutive
//!   failure counter. At `FAIL_THRESHOLD = 3` the instance is excluded
//!   from `pick` until a 60s cooldown expires (configurable via
//!   `with_failure_policy`).
//! - [`InstancePool::mark_success`] resets the failure counter.
//! - [`InstancePool::all_failed`] / [`InstancePool::healthy_count`] are
//!   the privacy-fail-closed signals the spider CLI uses to decide
//!   whether to keep going or exit 7.
//!
//! Session-id → instance persistence is best-effort on disk under
//! `~/.rev_scraping/sessions/<session_id>.json` so a multi-step run
//! (`spider --url X` then `relocate --url Y`) sticks to the same egress
//! even across process boundaries.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use dashmap::DashMap;
use serde::{Deserialize, Serialize};

/// One VPN instance descriptor as seen by the pool. Mirrors
/// `crates/stealth-cli::policy::VpnInstance` /
/// `vpn-rotate::leak_guard::InstanceDescriptor` so callers can convert
/// in either direction without a circular dep.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VpnInstance {
    pub name: String,
    pub http_proxy_port: u16,
    pub control_port: u16,
}

#[derive(Debug, Clone, Copy)]
pub struct FailurePolicy {
    pub threshold: u32,
    pub cooldown: Duration,
}

impl Default for FailurePolicy {
    fn default() -> Self {
        Self {
            threshold: 3,
            cooldown: Duration::from_secs(60),
        }
    }
}

#[derive(Debug, Clone)]
struct FailureRecord {
    consecutive_fails: u32,
    last_at: Instant,
}

/// Pool of VPN instances with HRW (rendezvous) sticky-by-session
/// selection + lazy-on-fail eviction.
#[derive(Debug, Clone)]
pub struct InstancePool {
    instances: Arc<Vec<VpnInstance>>,
    failed: Arc<DashMap<String, FailureRecord>>,
    policy: FailurePolicy,
    /// Seed mixed into the HRW hash. Lets test code force a known
    /// distribution; production callers use the default.
    seed: u64,
}

impl InstancePool {
    pub fn new(instances: Vec<VpnInstance>) -> Self {
        Self::with_failure_policy(instances, FailurePolicy::default())
    }

    pub fn with_failure_policy(instances: Vec<VpnInstance>, policy: FailurePolicy) -> Self {
        Self {
            instances: Arc::new(instances),
            failed: Arc::new(DashMap::new()),
            policy,
            seed: DEFAULT_HRW_SEED,
        }
    }

    /// Override the HRW seed. Tests use this to make distributions
    /// reproducible; do not call from production code.
    pub fn with_seed(mut self, seed: u64) -> Self {
        self.seed = seed;
        self
    }

    pub fn instances(&self) -> &[VpnInstance] {
        &self.instances
    }

    /// Pick the highest-HRW-scoring *healthy* instance for `session_id`.
    /// Returns `None` if every instance is currently excluded.
    pub fn pick(&self, session_id: &str) -> Option<&VpnInstance> {
        let mut best: Option<(u64, &VpnInstance)> = None;
        for inst in self.instances.iter() {
            if !self.is_healthy(&inst.name) {
                continue;
            }
            let score = rendezvous_hash_seeded(self.seed, session_id, &inst.name);
            match best {
                None => best = Some((score, inst)),
                Some((s, _)) if score > s => best = Some((score, inst)),
                _ => {}
            }
        }
        best.map(|(_, i)| i)
    }

    /// Has `name` accumulated >= `threshold` consecutive failures within
    /// the cooldown window?
    fn is_healthy(&self, name: &str) -> bool {
        match self.failed.get(name) {
            None => true,
            Some(rec) => {
                if rec.consecutive_fails < self.policy.threshold {
                    true
                } else {
                    // Excluded — but check if cooldown has expired.
                    rec.last_at.elapsed() >= self.policy.cooldown
                }
            }
        }
    }

    pub fn mark_failure(&self, name: &str) {
        let mut entry = self
            .failed
            .entry(name.to_string())
            .or_insert(FailureRecord {
                consecutive_fails: 0,
                last_at: Instant::now(),
            });
        entry.consecutive_fails = entry.consecutive_fails.saturating_add(1);
        entry.last_at = Instant::now();
    }

    pub fn mark_success(&self, name: &str) {
        self.failed.remove(name);
    }

    /// True iff every configured instance is currently excluded.
    /// An empty pool returns `true` (no usable egress = fail-closed).
    pub fn all_failed(&self) -> bool {
        if self.instances.is_empty() {
            return true;
        }
        !self.instances.iter().any(|i| self.is_healthy(&i.name))
    }

    pub fn healthy_count(&self) -> usize {
        self.instances
            .iter()
            .filter(|i| self.is_healthy(&i.name))
            .count()
    }

    /// Force-pick a specific named instance (CLI `--vpn-instance` flag).
    /// Returns `None` if the name isn't in the pool. Health state is
    /// *ignored* — this is an operator override.
    pub fn pick_by_name(&self, name: &str) -> Option<&VpnInstance> {
        self.instances.iter().find(|i| i.name == name)
    }

    /// Persist `session_id -> instance_name` binding under
    /// `dir/<session_id>.json`. Best-effort; an io error is returned to
    /// the caller (CLI logs a warn but proceeds).
    pub fn persist_session(
        dir: &Path,
        session_id: &str,
        instance_name: &str,
    ) -> std::io::Result<()> {
        if !dir.exists() {
            std::fs::create_dir_all(dir)?;
        }
        let path = dir.join(format!("{session_id}.json"));
        let body = serde_json::json!({
            "session_id": session_id,
            "instance": instance_name,
            "ts_unix": std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
        });
        std::fs::write(&path, body.to_string())
    }

    /// Read back a previously persisted `session_id -> instance_name`.
    /// Missing file / parse error → `None`.
    pub fn load_session(dir: &Path, session_id: &str) -> Option<String> {
        let path = dir.join(format!("{session_id}.json"));
        let raw = std::fs::read_to_string(&path).ok()?;
        let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
        v.get("instance")
            .and_then(|s| s.as_str())
            .map(str::to_string)
    }

    /// Default on-disk session directory under
    /// `~/.rev_scraping/sessions`. None when HOME is unset.
    pub fn default_session_dir() -> Option<PathBuf> {
        directory_home().map(|h| h.join(".rev_scraping").join("sessions"))
    }
}

fn directory_home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Default HRW seed. Chosen arbitrarily; mixed into every score so that
/// two pools with different seeds produce uncorrelated distributions.
const DEFAULT_HRW_SEED: u64 = 0x5f37_59df_a4d2_6e7b;

/// Rendezvous-hash (HRW) score = xxh3(seed || name || key). The
/// highest-scoring instance wins; ties are broken by xxh3's
/// avalanching so they're effectively random.
pub fn rendezvous_hash(key: &str, name: &str) -> u64 {
    rendezvous_hash_seeded(DEFAULT_HRW_SEED, key, name)
}

fn rendezvous_hash_seeded(seed: u64, key: &str, name: &str) -> u64 {
    let mut buf = Vec::with_capacity(8 + name.len() + 1 + key.len());
    buf.extend_from_slice(&seed.to_le_bytes());
    buf.extend_from_slice(name.as_bytes());
    buf.push(0xff);
    buf.extend_from_slice(key.as_bytes());
    xxhash_rust::xxh3::xxh3_64(&buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_instances(n: usize) -> Vec<VpnInstance> {
        (1..=n)
            .map(|i| VpnInstance {
                name: format!("vpn-{i}"),
                http_proxy_port: 8000 + i as u16,
                control_port: 8880 + i as u16,
            })
            .collect()
    }

    #[test]
    fn test_rendezvous_hash_deterministic() {
        let a = rendezvous_hash("sess-abc", "vpn-2");
        let b = rendezvous_hash("sess-abc", "vpn-2");
        assert_eq!(a, b, "same inputs must produce same hash");
        // Different key OR different name must (with overwhelming
        // probability) produce different hashes.
        assert_ne!(a, rendezvous_hash("sess-abd", "vpn-2"));
        assert_ne!(a, rendezvous_hash("sess-abc", "vpn-1"));
    }

    #[test]
    fn test_instance_pool_pick_distributes_evenly() {
        let pool = InstancePool::new(mk_instances(3));
        let n = 100_000;
        let mut counts = [0usize; 3];
        for i in 0..n {
            let sid = format!("session-{i}");
            let picked = pool.pick(&sid).unwrap();
            let idx: usize = picked
                .name
                .strip_prefix("vpn-")
                .and_then(|s| s.parse().ok())
                .map(|v: usize| v - 1)
                .unwrap();
            counts[idx] += 1;
        }
        // Each bucket should be within ±5% of n/3.
        let expected = n as f64 / 3.0;
        for (idx, c) in counts.iter().enumerate() {
            let pct = *c as f64 / n as f64 * 100.0;
            assert!(
                (*c as f64 - expected).abs() < expected * 0.05,
                "instance vpn-{} got {:.2}% of {} sessions (expected ~33.33%)",
                idx + 1,
                pct,
                n
            );
        }
        // Print for the audit report.
        eprintln!(
            "HRW distribution over {} sessions: vpn-1={} ({:.2}%) vpn-2={} ({:.2}%) vpn-3={} ({:.2}%)",
            n,
            counts[0], counts[0] as f64 / n as f64 * 100.0,
            counts[1], counts[1] as f64 / n as f64 * 100.0,
            counts[2], counts[2] as f64 / n as f64 * 100.0,
        );
    }

    #[test]
    fn test_instance_pool_pick_sticky_within_session() {
        let pool = InstancePool::new(mk_instances(3));
        let sid = "sticky-session-xyz";
        let first = pool.pick(sid).unwrap().name.clone();
        for _ in 0..100 {
            let again = pool.pick(sid).unwrap();
            assert_eq!(
                again.name, first,
                "same session_id must always map to the same instance"
            );
        }
    }

    #[test]
    fn test_mark_failure_three_times_excludes_instance() {
        let pool = InstancePool::new(mk_instances(3));
        pool.mark_failure("vpn-1");
        assert_eq!(pool.healthy_count(), 3);
        pool.mark_failure("vpn-1");
        assert_eq!(pool.healthy_count(), 3);
        pool.mark_failure("vpn-1");
        assert_eq!(
            pool.healthy_count(),
            2,
            "3 consecutive failures must evict vpn-1"
        );
        // Force HRW to pick vpn-1 for a session, verify it now lands elsewhere.
        let mut saw_vpn1 = false;
        for i in 0..1000 {
            if pool.pick(&format!("s-{i}")).unwrap().name == "vpn-1" {
                saw_vpn1 = true;
                break;
            }
        }
        assert!(!saw_vpn1, "vpn-1 must never be picked while excluded");
    }

    #[test]
    fn test_mark_success_resets_failure_counter() {
        let pool = InstancePool::new(mk_instances(3));
        pool.mark_failure("vpn-2");
        pool.mark_failure("vpn-2");
        pool.mark_success("vpn-2");
        // Counter reset means we can fail twice more without eviction.
        pool.mark_failure("vpn-2");
        pool.mark_failure("vpn-2");
        assert_eq!(pool.healthy_count(), 3);
        pool.mark_failure("vpn-2");
        assert_eq!(pool.healthy_count(), 2);
    }

    #[test]
    fn test_all_failed_returns_true_when_all_3_have_3_fails() {
        let pool = InstancePool::new(mk_instances(3));
        for n in ["vpn-1", "vpn-2", "vpn-3"] {
            for _ in 0..3 {
                pool.mark_failure(n);
            }
        }
        assert!(
            pool.all_failed(),
            "all 3 instances at threshold => pool dead"
        );
        assert_eq!(pool.healthy_count(), 0);
        assert!(pool.pick("any-session").is_none());
    }

    #[test]
    fn test_cooldown_60s_restores_failed_instance() {
        // Use a 50ms cooldown so the test stays fast.
        let pool = InstancePool::with_failure_policy(
            mk_instances(3),
            FailurePolicy {
                threshold: 3,
                cooldown: Duration::from_millis(50),
            },
        );
        for _ in 0..3 {
            pool.mark_failure("vpn-1");
        }
        assert_eq!(pool.healthy_count(), 2);
        std::thread::sleep(Duration::from_millis(80));
        // Cooldown elapsed: vpn-1 considered healthy again.
        assert_eq!(pool.healthy_count(), 3);
    }

    #[test]
    fn test_pick_returns_none_when_all_failed() {
        let pool = InstancePool::new(mk_instances(2));
        for _ in 0..3 {
            pool.mark_failure("vpn-1");
            pool.mark_failure("vpn-2");
        }
        assert!(pool.pick("session-a").is_none());
        assert!(pool.all_failed());
    }

    #[test]
    fn test_session_id_persists_to_disk() {
        let dir = tempfile::tempdir().unwrap();
        InstancePool::persist_session(dir.path(), "sess-42", "vpn-2").unwrap();
        let loaded = InstancePool::load_session(dir.path(), "sess-42").unwrap();
        assert_eq!(loaded, "vpn-2");
        // Unknown session id => None.
        assert!(InstancePool::load_session(dir.path(), "sess-nope").is_none());
    }

    #[test]
    fn test_session_id_lookup_after_restart() {
        let dir = tempfile::tempdir().unwrap();
        InstancePool::persist_session(dir.path(), "sess-restart", "vpn-3").unwrap();
        // Simulate a new process by dropping the pool entirely and only
        // reading back from disk.
        drop(InstancePool::new(mk_instances(3)));
        let loaded = InstancePool::load_session(dir.path(), "sess-restart");
        assert_eq!(loaded.as_deref(), Some("vpn-3"));
    }

    #[test]
    fn test_pick_by_name_bypasses_health_filter() {
        let pool = InstancePool::new(mk_instances(3));
        for _ in 0..3 {
            pool.mark_failure("vpn-1");
        }
        // pick() excludes vpn-1; pick_by_name returns it anyway.
        let force = pool.pick_by_name("vpn-1").unwrap();
        assert_eq!(force.name, "vpn-1");
        assert!(pool.pick_by_name("vpn-bogus").is_none());
    }

    #[test]
    fn test_empty_pool_all_failed_true() {
        let pool = InstancePool::new(vec![]);
        assert!(pool.all_failed());
        assert_eq!(pool.healthy_count(), 0);
        assert!(pool.pick("anything").is_none());
    }
}
