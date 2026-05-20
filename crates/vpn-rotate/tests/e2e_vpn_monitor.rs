// SPDX-License-Identifier: MIT
// Source: new test for rev_scraping v1.0.0 (Phase 6e)
//! E2E (mock) integration test for the Phase 6e background leak monitor.
//!
//! This test does NOT require a Docker daemon. It exercises the
//! [`LeakMonitor`] state machine end-to-end:
//!   1. Spawn monitor with a [`LeakProbe`] that starts Healthy.
//!   2. Flip the probe to Leak verdict mid-flight.
//!   3. Assert the monitor's `Notify` fires within a bounded window AND
//!      that the latched `LeakState` reflects the failure.
//!
//! The Docker / obscura `force_kill` integration is exercised manually in
//! `crates/stealth-cli/tests/e2e_vpn_required.rs` (which already has the
//! `#[ignore]` Docker gating); this test specifically pins the monitor
//! contract that the CLI's `tokio::select!` race depends on.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use vpn_rotate::instance_pool::VpnInstance;
use vpn_rotate::leak_monitor::{LeakMonitor, LeakProbe, ProbeVerdict};

struct FlippingProbe {
    leak: Arc<Mutex<bool>>,
}

#[async_trait]
impl LeakProbe for FlippingProbe {
    async fn probe_once(
        &self,
        _instances: &[VpnInstance],
        _expected_country: Option<&str>,
    ) -> ProbeVerdict {
        if *self.leak.lock().unwrap() {
            ProbeVerdict::Leak {
                failed_instance: "vpn-1".into(),
                reason: "simulated mid-run leak".into(),
            }
        } else {
            ProbeVerdict::Healthy
        }
    }
}

#[tokio::test]
#[ignore]
async fn test_force_kill_on_leak_simulated() {
    let flag = Arc::new(Mutex::new(false));
    let probe = Arc::new(FlippingProbe { leak: flag.clone() });
    let instances = vec![VpnInstance {
        name: "vpn-1".into(),
        http_proxy_port: 8001,
        control_port: 8881,
    }];
    let monitor =
        LeakMonitor::spawn_with(instances, Some("JP".into()), Duration::from_secs(5), probe);
    let notify = monitor.notify_clone();
    let state = monitor.state_clone();

    // Let the monitor run a couple healthy ticks. Interval is clamped
    // to the MIN (5s) so we need a bit of headroom — but the FIRST tick
    // fires immediately, so 200ms is enough to capture it.
    tokio::time::sleep(Duration::from_millis(250)).await;
    {
        let st = state.read().await;
        assert!(!st.leak_detected, "should be healthy initially");
        assert!(st.ticks >= 1, "first tick should have fired");
    }

    // Flip the simulated VPN to leak. On the next tick (5s later, since
    // we're at MIN_POLL_INTERVAL) the monitor must latch.
    *flag.lock().unwrap() = true;
    let notified = tokio::time::timeout(Duration::from_secs(10), notify.notified()).await;
    assert!(
        notified.is_ok(),
        "monitor notify must fire within one poll cycle after leak"
    );

    let st = state.read().await;
    assert!(st.leak_detected, "state.leak_detected must be true");
    assert_eq!(st.failed_instance.as_deref(), Some("vpn-1"));
    assert!(st
        .reason
        .as_deref()
        .unwrap()
        .contains("simulated mid-run leak"));

    monitor.shutdown();
}
