// SPDX-License-Identifier: MIT
// Source: derived from obscura (Apache-2.0), https://github.com/h4ckf0r0day/obscura
//
// `obscura-bridge` — supervises a vendored `obscura` browser subprocess and
// exposes a CDP client (via `chromiumoxide` for standard commands, with a
// `tokio-tungstenite` direct WebSocket escape hatch for obscura-specific
// extensions). See `.agent/active/plan_v1.0.0.md` §3.1 / Phase 1a.
//
// Independent SSRF guard (S10) is enforced at this layer in addition to any
// guard inside obscura, so that compromise or misconfiguration of the
// subprocess cannot reach private network targets through the bridge.

#![forbid(unsafe_code)]
#![warn(missing_debug_implementations)]

pub mod auth_inject;
pub mod bridge;
pub mod cdp_shim;
pub mod config;
pub mod error;
pub mod network_capture;
pub mod page;
pub mod ssrf;
pub mod traits;

pub use auth_inject::{
    inject_cookies, set_user_agent_override, CookieInjectionStatus, CookieParam as AuthCookieParam,
    SameSite as AuthCookieSameSite,
};
pub use bridge::{ObscuraBridge, ShutdownPolicy};
pub use config::ObscuraConfig;
pub use error::{BridgeError, Result};
pub use page::{DomSnapshot, NavResult, NodeId, PageHandle};
pub use traits::BrowserOps;

/// Re-export of the CDP client type used by the bridge so downstream crates
/// can name it without depending on `chromiumoxide` directly.
pub use chromiumoxide::Browser as CdpClient;

/// Install a `tokio::signal::ctrl_c` listener that calls `shutdown` on the
/// supplied bridge when the host runtime is asked to terminate. Returns a
/// `JoinHandle` so the caller can `abort()` it during clean shutdown to avoid
/// the handler racing a normal `shutdown()` path.
///
/// This is best-effort: if the runtime is already torn down when the signal
/// fires, the handle resolves with an error which is logged at `warn` level.
pub fn install_shutdown_hook(
    bridge: std::sync::Arc<tokio::sync::Mutex<Option<ObscuraBridge>>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        if let Err(e) = tokio::signal::ctrl_c().await {
            tracing::warn!(error = %e, "ctrl_c listener failed; shutdown hook inactive");
            return;
        }
        tracing::info!("ctrl_c received; running obscura-bridge shutdown hook");
        let mut guard = bridge.lock().await;
        if let Some(b) = guard.take() {
            if let Err(e) = b.shutdown().await {
                tracing::warn!(error = %e, "bridge shutdown via signal hook failed");
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_browser_ops_trait_object_safety() {
        // Compile-time check: BrowserOps must remain object-safe so mocks can
        // substitute for ObscuraBridge in downstream tests.
        fn _take(_: Box<dyn BrowserOps>) {}
    }
}
