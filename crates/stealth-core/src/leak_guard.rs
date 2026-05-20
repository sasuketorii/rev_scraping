// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! Browser-side leak guard.
//!
//! This module ships the JS bootstrap that we inject before any page
//! script executes. Goal: deny the well-known fingerprint sidechannels
//! that survive a stealth UA-spoof:
//!
//! * **WebRTC** — STUN/TURN data channels expose the host IP behind the
//!   VPN. We override `RTCPeerConnection.createDataChannel` to throw and
//!   make `mediaDevices` unreachable.
//! * **Battery API** — high-resolution charge level + discharge time is
//!   a strong device-stable signal. Reject the promise.
//! * **navigator.connection** — `rtt` / `downlink` are otherwise stable
//!   per device, so the same UA across two sessions correlates.
//!   Randomise per access.
//!
//! The injection point is `Page::evaluate_on_new_document` (chromiumoxide
//! 0.9.x). Because the script runs *before* any page JS, every observable
//! property is overridden before site code can cache the original.

use thiserror::Error;

/// JS payload installed via `Page::evaluate_on_new_document` on every
/// new document (top frame + sub-frames). Self-invoking IIFE so it
/// leaves no globals.
pub const WEBRTC_LEAK_GUARD_JS: &str = r#"(() => {
  try {
    if (window.RTCPeerConnection) {
      const _RTC = window.RTCPeerConnection;
      window.RTCPeerConnection = class extends _RTC {
        constructor(...args) { super(...args); }
        createDataChannel() {
          throw new Error('rev_stealth: WebRTC data channel blocked');
        }
      };
    }
    if (navigator.mediaDevices) {
      Object.defineProperty(navigator, 'mediaDevices', {
        get: () => undefined,
        configurable: true,
      });
    }
    // Battery API — Chrome ships this on Android; rejecting matches
    // a privacy-aware build.
    if (navigator.getBattery) {
      navigator.getBattery = () =>
        Promise.reject(new Error('rev_stealth: getBattery blocked'));
    }
    // navigator.connection.rtt / downlink — randomise per access so
    // re-reads differ session-to-session.
    if (navigator.connection) {
      try {
        Object.defineProperty(navigator.connection, 'rtt', {
          get: () => 50 + Math.floor(Math.random() * 100),
          configurable: true,
        });
        Object.defineProperty(navigator.connection, 'downlink', {
          get: () => 5 + Math.random() * 5,
          configurable: true,
        });
      } catch (_) { /* property may be non-configurable; ignore */ }
    }
  } catch (_) { /* never throw out of the bootstrap */ }
})();"#;

#[derive(Debug, Error)]
pub enum LeakGuardError {
    #[error("CDP injection failed: {0}")]
    CdpInjectFailed(String),
}

/// Install the WebRTC / Battery / connection leak guard on a page.
/// Idempotent: re-installing simply registers a second copy of the
/// script (each is a self-contained IIFE).
#[cfg(feature = "browser")]
pub async fn install_leak_guard(page: &chromiumoxide::Page) -> Result<(), LeakGuardError> {
    page.evaluate_on_new_document(WEBRTC_LEAK_GUARD_JS)
        .await
        .map_err(|e| LeakGuardError::CdpInjectFailed(format!("{e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn js_blocks_webrtc_data_channel() {
        assert!(WEBRTC_LEAK_GUARD_JS.contains("RTCPeerConnection"));
        assert!(WEBRTC_LEAK_GUARD_JS.contains("createDataChannel"));
        assert!(WEBRTC_LEAK_GUARD_JS.contains("blocked"));
    }

    #[test]
    fn js_disables_media_devices() {
        assert!(WEBRTC_LEAK_GUARD_JS.contains("mediaDevices"));
        assert!(WEBRTC_LEAK_GUARD_JS.contains("get: () => undefined"));
    }

    #[test]
    fn js_blocks_battery_api() {
        assert!(WEBRTC_LEAK_GUARD_JS.contains("getBattery"));
        assert!(WEBRTC_LEAK_GUARD_JS.contains("Promise.reject"));
    }

    #[test]
    fn js_randomises_connection_metrics() {
        assert!(WEBRTC_LEAK_GUARD_JS.contains("navigator.connection"));
        assert!(WEBRTC_LEAK_GUARD_JS.contains("rtt"));
        assert!(WEBRTC_LEAK_GUARD_JS.contains("downlink"));
        assert!(WEBRTC_LEAK_GUARD_JS.contains("Math.random"));
    }

    #[test]
    fn js_is_self_invoking_iife() {
        // Belt-and-braces: the snippet must not leak any globals.
        // Our IIFE wraps the body in `(() => { ... })();`.
        assert!(WEBRTC_LEAK_GUARD_JS.starts_with("(() => {"));
        assert!(WEBRTC_LEAK_GUARD_JS.trim_end().ends_with("})();"));
    }

    #[test]
    fn cdp_inject_failed_error_display() {
        let e = LeakGuardError::CdpInjectFailed("connection closed".into());
        assert!(format!("{e}").contains("CDP injection failed"));
        assert!(format!("{e}").contains("connection closed"));
    }
}
