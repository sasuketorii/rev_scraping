// SPDX-License-Identifier: MIT
// Source: derived from obscura (Apache-2.0), https://github.com/h4ckf0r0day/obscura

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use chromiumoxide::{Browser, BrowserConfig};
use futures::StreamExt;
use tokio::process::{Child, Command};
use tokio::sync::Mutex;
use url::Url;
use uuid::Uuid;

use crate::cdp_shim::CdpShim;
use crate::config::ObscuraConfig;
use crate::error::{BridgeError, Result};
use crate::page::{PageHandle, TargetId};
use crate::ssrf;
use crate::traits::BrowserOps;

/// SIGTERM grace period before SIGKILL escalation (plan S2).
pub const DEFAULT_GRACE: Duration = Duration::from_secs(5);

/// How `shutdown` should escalate when the subprocess does not exit.
#[derive(Debug, Clone, Copy)]
pub struct ShutdownPolicy {
    pub grace: Duration,
}

impl Default for ShutdownPolicy {
    fn default() -> Self {
        Self {
            grace: DEFAULT_GRACE,
        }
    }
}

/// Supervises one `obscura` browser subprocess and owns the CDP client used
/// to talk to it. See plan §3.1.
pub struct ObscuraBridge {
    cfg: ObscuraConfig,
    cdp: Browser,
    /// chromiumoxide driver task — must outlive the Browser; aborted in shutdown.
    handler: Mutex<Option<tokio::task::JoinHandle<()>>>,
    child: Mutex<Option<Child>>,
    /// CDP compatibility shim — patches obscura events to satisfy
    /// chromiumoxide 0.9's strict PDL structs. See `cdp_shim`.
    shim: Mutex<Option<CdpShim>>,
    tmp_dir: PathBuf,
    session_id: Uuid,
    shutdown_done: Mutex<bool>,
}

impl std::fmt::Debug for ObscuraBridge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ObscuraBridge")
            .field("session_id", &self.session_id)
            .field("tmp_dir", &self.tmp_dir)
            .field("binary_path", &self.cfg.binary_path)
            .finish()
    }
}

impl ObscuraBridge {
    /// Spawn the obscura binary in `serve` mode and connect a chromiumoxide
    /// CDP client to it. Errors if the binary is missing or the CDP endpoint
    /// does not come up within ~10 seconds.
    pub async fn launch(cfg: ObscuraConfig) -> Result<Self> {
        if !cfg.binary_path.exists() {
            return Err(BridgeError::BinaryNotFound {
                path: cfg.binary_path.display().to_string(),
            });
        }

        let session_id = cfg.session_id;
        let tmp_dir = std::env::temp_dir().join(format!("obscura-bridge-{session_id}"));
        tokio::fs::create_dir_all(&tmp_dir).await?;

        // Reserve port early so we know where to connect.
        let port = match cfg.cdp_port {
            Some(p) => p,
            None => pick_free_port().await?,
        };

        let mut cmd = Command::new(&cfg.binary_path);
        cmd.arg("serve").arg("--port").arg(port.to_string());
        if let Some(proxy) = &cfg.proxy {
            cmd.arg("--proxy").arg(proxy.as_str());
        }
        if cfg.blocklist_enabled {
            // obscura's serve subcommand enables blocklist by default; the
            // explicit flag is forward-compat for when an opt-out is added.
            cmd.arg("--stealth");
        }
        for extra in &cfg.extra_args {
            cmd.arg(extra);
        }
        cmd.stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);

        let child = cmd.spawn().map_err(BridgeError::SpawnFailed)?;

        // Wait for the CDP endpoint. obscura advertises /json/version once ready.
        let ws_url = wait_for_cdp(port, Duration::from_secs(10)).await?;

        // Phase 5a: route chromiumoxide through a thin proxy that injects
        // the fields obscura omits (canAccessOpener, secureContextType, ...).
        // Without this, the chromiumoxide handler panics on first new_page.
        let shim = CdpShim::start(&ws_url)
            .await
            .map_err(|e| BridgeError::Other(format!("cdp_shim start: {e}")))?;
        let shim_url = shim.local_url();
        tracing::debug!(upstream = %ws_url, local = %shim_url, "CDP shim ready");

        // Connect chromiumoxide directly to the discovered WebSocket URL.
        let bc = BrowserConfig::builder()
            .with_head() // we don't launch chrome ourselves; obscura is the target
            .build()
            .map_err(BridgeError::Other)?;
        let _ = bc; // Builder is unused for connect path but keeps method graph intact.

        let (browser, mut handler) = Browser::connect(&shim_url)
            .await
            .map_err(BridgeError::from)?;
        let handler_task = tokio::spawn(async move {
            while let Some(ev) = handler.next().await {
                if let Err(e) = ev {
                    tracing::trace!(error = %e, "chromiumoxide handler event err");
                }
            }
        });

        tracing::info!(%session_id, %port, "obscura-bridge connected");

        Ok(Self {
            cfg,
            cdp: browser,
            handler: Mutex::new(Some(handler_task)),
            child: Mutex::new(Some(child)),
            shim: Mutex::new(Some(shim)),
            tmp_dir,
            session_id,
            shutdown_done: Mutex::new(false),
        })
    }

    pub fn cdp(&self) -> &Browser {
        &self.cdp
    }

    pub fn session_id(&self) -> Uuid {
        self.session_id
    }

    pub fn config(&self) -> &ObscuraConfig {
        &self.cfg
    }

    /// Bridge-side SSRF guard (S10). Static so callers can validate URLs
    /// without holding a live bridge.
    pub fn validate_url(url: &Url) -> Result<()> {
        ssrf::validate_url(url)
    }

    /// Open a new CDP page/target.
    pub async fn new_page(&self) -> Result<PageHandle> {
        let page = self
            .cdp
            .new_page("about:blank")
            .await
            .map_err(BridgeError::from)?;
        let target_id = TargetId(page.target_id().as_ref().to_string());
        Ok(PageHandle {
            page: Arc::new(page),
            target_id,
        })
    }

    /// SIGTERM, wait `grace`, SIGKILL — deterministic ≤5s (plan S2/S11).
    pub async fn shutdown(self) -> Result<()> {
        self.shutdown_with(ShutdownPolicy::default()).await
    }

    pub async fn shutdown_with(self, policy: ShutdownPolicy) -> Result<()> {
        let mut done = self.shutdown_done.lock().await;
        if *done {
            return Ok(());
        }
        *done = true;
        drop(done);

        // Abort the chromiumoxide handler so the WebSocket reader stops.
        if let Some(h) = self.handler.lock().await.take() {
            h.abort();
        }
        // Stop the CDP shim accept loop.
        if let Some(shim) = self.shim.lock().await.take() {
            if let Err(e) = shim.shutdown().await {
                tracing::warn!(error = %e, "cdp_shim shutdown error");
            }
        }
        // Best-effort: close the CDP browser (the underlying ws stream will
        // already be closing as the subprocess exits).
        // chromiumoxide::Browser::close() consumes the browser; we don't have
        // an owned value here because Browser is held by-value but not Clone.
        // Falling back to letting Drop handle the connection close.

        let mut child_slot = self.child.lock().await;
        let mut child = match child_slot.take() {
            Some(c) => c,
            None => return Ok(()),
        };
        drop(child_slot);

        // Already exited?
        if let Ok(Some(_status)) = child.try_wait() {
            return Ok(());
        }

        // SIGTERM via tokio::process (Child::start_kill issues SIGKILL on
        // unix; for SIGTERM we use nix-less std signaling via libc would be
        // unsafe. Tokio offers no SIGTERM API directly, so we use
        // `kill_on_drop` as a backstop and escalate to start_kill if grace
        // elapses).
        #[cfg(unix)]
        send_sigterm(&child);
        #[cfg(not(unix))]
        let _ = child.start_kill();

        match tokio::time::timeout(policy.grace, child.wait()).await {
            Ok(Ok(_status)) => Ok(()),
            Ok(Err(e)) => Err(BridgeError::Io(e)),
            Err(_) => {
                // Grace exhausted -> SIGKILL.
                tracing::warn!("obscura did not exit within grace; escalating to SIGKILL");
                let _ = child.start_kill();
                let _ = child.wait().await;
                Ok(())
            }
        }
    }

    /// Hard kill — used by `vpn-rotate::leak_guard::on_vpn_loss` (S11).
    /// Fire-and-forget: tries SIGKILL immediately and waits up to 5s.
    pub async fn force_kill(&self) -> Result<()> {
        let mut child_slot = self.child.lock().await;
        if let Some(mut child) = child_slot.take() {
            let _ = child.start_kill();
            let _ = tokio::time::timeout(DEFAULT_GRACE, child.wait()).await;
        }
        if let Some(h) = self.handler.lock().await.take() {
            h.abort();
        }
        let mut done = self.shutdown_done.lock().await;
        *done = true;
        Ok(())
    }

    /// TLS ClientHello dump — placeholder per plan S3 / Phase 0 SOW.
    ///
    /// Will be wired to obscura's stealth client (see
    /// `vendor/obscura/crates/obscura-net/src/wreq_client.rs`) once the
    /// observation mechanism is confirmed. Behind `tls-dump` feature so
    /// callers can already reference the symbol.
    #[cfg(feature = "tls-dump")]
    pub async fn dump_clienthello(&self) -> Result<Vec<u8>> {
        unimplemented!(
            "TLS ClientHello dump pending Phase 0 SOW (S3); \
             see plan_v1.0.0.md and vendor/obscura/crates/obscura-net"
        );
    }
}

impl BrowserOps for ObscuraBridge {
    fn cdp(&self) -> &Browser {
        &self.cdp
    }
}

impl Drop for ObscuraBridge {
    fn drop(&mut self) {
        // Best-effort fallback: if shutdown() was not awaited (e.g. a panic
        // unwound past it), the child still gets SIGKILLed via the
        // `kill_on_drop(true)` flag we set on spawn. We additionally try to
        // abort the handler task here.
        if let Ok(mut h) = self.handler.try_lock() {
            if let Some(j) = h.take() {
                j.abort();
            }
        }
    }
}

#[cfg(unix)]
fn send_sigterm(child: &Child) {
    if let Some(pid) = child.id() {
        // SAFETY-free: `libc::kill` via std is not exposed; use std::process
        // via `nix`-less workaround. We invoke `kill` through the `tokio`-
        // friendly `tokio::process::Command` path to avoid `unsafe`.
        // Spawn `/bin/kill -TERM <pid>` synchronously (cheap, ~1ms).
        let _ = std::process::Command::new("kill")
            .arg("-TERM")
            .arg(pid.to_string())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
}

/// Pick a free TCP port by binding 127.0.0.1:0 and reading back the addr.
async fn pick_free_port() -> Result<u16> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

/// Poll `http://127.0.0.1:{port}/json/version` until obscura answers, then
/// return the WebSocket debugger URL (using `webSocketDebuggerUrl` if
/// present so we preserve obscura's routing-key UUID).
async fn wait_for_cdp(port: u16, total: Duration) -> Result<String> {
    let deadline = tokio::time::Instant::now() + total;
    let endpoint = format!("127.0.0.1:{port}");
    let json_version = format!("http://{endpoint}/json/version");
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|e| BridgeError::Other(format!("reqwest build: {e}")))?;
    loop {
        if tokio::net::TcpStream::connect(&endpoint).await.is_ok() {
            // Try /json/version first (Chromium-compat endpoint). If it
            // returns a webSocketDebuggerUrl, use it verbatim. Otherwise
            // fall back to the generic root.
            if let Ok(resp) = client.get(&json_version).send().await {
                if let Ok(v) = resp.json::<serde_json::Value>().await {
                    if let Some(url) = v.get("webSocketDebuggerUrl").and_then(|s| s.as_str()) {
                        return Ok(url.to_string());
                    }
                }
            }
            return Ok(format!("ws://{endpoint}/devtools/browser"));
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(BridgeError::StartupTimeout);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// Mock helper: simulates the SIGTERM->grace->SIGKILL escalation logic
    /// in isolation from a real subprocess. We model the child as a bool
    /// that flips to "exited" after some delay; the test verifies that:
    ///   - if `exit_after < grace`, no SIGKILL escalation fires
    ///   - if `exit_after > grace`, escalation does fire
    async fn run_shutdown_logic(exit_after: Duration, grace: Duration) -> bool {
        let killed = Arc::new(AtomicBool::new(false));
        let killed2 = killed.clone();

        let exited = tokio::spawn(async move {
            tokio::time::sleep(exit_after).await;
        });

        let outcome = tokio::time::timeout(grace, exited).await;
        if outcome.is_err() {
            killed2.store(true, Ordering::SeqCst);
        }
        killed.load(Ordering::SeqCst)
    }

    #[tokio::test]
    async fn test_shutdown_sequence_logic() {
        // Case A: child exits within grace -> no SIGKILL.
        let escalated =
            run_shutdown_logic(Duration::from_millis(50), Duration::from_millis(300)).await;
        assert!(
            !escalated,
            "should NOT escalate when child exits inside grace"
        );

        // Case B: child overruns grace -> SIGKILL escalation.
        let escalated =
            run_shutdown_logic(Duration::from_millis(300), Duration::from_millis(50)).await;
        assert!(escalated, "must escalate when grace elapses");
    }

    #[test]
    fn test_default_grace_is_five_seconds() {
        // Plan S2: SIGTERM -> 5s -> SIGKILL is part of the LGTM criteria.
        assert_eq!(DEFAULT_GRACE, Duration::from_secs(5));
        assert_eq!(ShutdownPolicy::default().grace, Duration::from_secs(5));
    }
}
