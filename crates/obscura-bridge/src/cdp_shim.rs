// SPDX-License-Identifier: MIT
// Source: extended for rev_scraping v1.0.0 (Phase 5d full lifecycle compat,
// design from .agent/active/cdp_compat_deep_findings.md)
//
// Thin proxy that sits between chromiumoxide and the vendored obscura CDP
// server. Beyond Phase 5a event-shape patching, Phase 5d adds:
//
//   1. Response patcher: tracks outbound `id -> method`, patches inbound
//      `Page.getFrameTree` / `Target.getTargetInfo` responses to add the
//      `secureContextType` / `crossOriginIsolatedContextType` /
//      `canAccessOpener` fields chromiumoxide 0.9 requires.
//
//   2. Synthetic about:blank lifecycle: when chromiumoxide enables lifecycle
//      reporting on a session, obscura does not emit the initial
//      `init/commit/DOMContentLoaded/load/networkIdle` events that real Chrome
//      emits ~1ms after Page.enable for the already-attached about:blank
//      frame. Without those events, `Frame::is_loaded()` is false forever and
//      `new_page()` parks its initiator and never completes. The shim
//      synthesises them (once per session).
//
//   3. Synthetic initial `Page.frameNavigated{about:blank}` after Page.enable
//      so that chromiumoxide's frame manager knows about the implicit frame
//      before the synthetic lifecycle arrives.
//
// Topology:
//
//     chromiumoxide  <->  CdpShim (this module, 127.0.0.1:RANDOM)  <->  obscura

use std::sync::Arc;
use std::time::Instant;

use anyhow::Context;
use dashmap::DashMap;
use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::{
    handshake::server::{Request, Response},
    Message,
};

/// Direction of a JSON frame relative to chromiumoxide.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    /// chromiumoxide -> obscura (commands).
    Outbound,
    /// obscura -> chromiumoxide (events + responses).
    Inbound,
}

/// Per-connection shim state. Cheap to clone (`Arc` inside).
#[derive(Debug, Default)]
pub struct ShimState {
    /// outbound id -> method, for response patching.
    pending_commands: DashMap<u64, String>,
    /// sessionId -> frameId, learned from `Target.attachedToTarget`.
    session_frames: DashMap<String, String>,
    /// Has the shim already emitted synthetic lifecycle for this session?
    synthetic_emitted: DashMap<String, bool>,
    /// Has the shim already emitted the synthetic initial frameNavigated
    /// for this session?
    initial_frame_emitted: DashMap<String, bool>,
    /// Monotonic clock anchor for `timestamp` (seconds since shim start).
    epoch: once_cell_epoch::Epoch,
}

mod once_cell_epoch {
    use std::time::Instant;
    #[derive(Debug)]
    pub struct Epoch(Instant);
    impl Default for Epoch {
        fn default() -> Self {
            Self(Instant::now())
        }
    }
    impl Epoch {
        pub fn now_secs(&self) -> f64 {
            self.0.elapsed().as_secs_f64()
        }
    }
}

impl ShimState {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
}

/// Inject the fields obscura omits but chromiumoxide 0.9 requires (events).
///
/// Pure function — easy to unit-test against captured JSON.
pub fn patch_obscura_event(json: &mut Value) {
    let Some(method) = json
        .get("method")
        .and_then(|m| m.as_str())
        .map(str::to_owned)
    else {
        return; // not an event (probably a response)
    };

    match method.as_str() {
        "Target.targetCreated" | "Target.attachedToTarget" => {
            if let Some(target_info) = json
                .get_mut("params")
                .and_then(|p| p.get_mut("targetInfo"))
                .and_then(|t| t.as_object_mut())
            {
                target_info
                    .entry("canAccessOpener".to_string())
                    .or_insert(Value::Bool(false));

                // Defensive: empty-string browserContextId -> drop.
                if matches!(
                    target_info.get("browserContextId"),
                    Some(Value::String(s)) if s.is_empty()
                ) {
                    target_info.remove("browserContextId");
                }
            }
        }
        "Page.frameNavigated" => {
            if let Some(frame) = json
                .get_mut("params")
                .and_then(|p| p.get_mut("frame"))
                .and_then(|f| f.as_object_mut())
            {
                patch_frame_object(frame);
            }
        }
        "Network.requestWillBeSent" => {
            if let Some(params) = json.get_mut("params").and_then(|p| p.as_object_mut()) {
                patch_network_request_will_be_sent(params);
            }
        }
        "Network.responseReceived" => {
            if let Some(params) = json.get_mut("params").and_then(|p| p.as_object_mut()) {
                patch_network_response_received(params);
            }
        }
        _ => {} // pass-through
    }
}

/// Inject the fields chromiumoxide 0.9 requires on `Network.requestWillBeSent`.
fn patch_network_request_will_be_sent(params: &mut serde_json::Map<String, Value>) {
    params
        .entry("redirectHasExtraInfo".to_string())
        .or_insert(Value::Bool(false));
    if let Some(req) = params.get_mut("request").and_then(|r| r.as_object_mut()) {
        req.entry("initialPriority".to_string())
            .or_insert(Value::String("Medium".to_string()));
        req.entry("referrerPolicy".to_string())
            .or_insert(Value::String("no-referrer-when-downgrade".to_string()));
    }
}

/// Inject the fields chromiumoxide 0.9 requires on `Network.responseReceived`.
fn patch_network_response_received(params: &mut serde_json::Map<String, Value>) {
    params
        .entry("hasExtraInfo".to_string())
        .or_insert(Value::Bool(false));
    if let Some(resp) = params.get_mut("response").and_then(|r| r.as_object_mut()) {
        resp.entry("charset".to_string())
            .or_insert(Value::String(String::new()));
        resp.entry("connectionReused".to_string())
            .or_insert(Value::Bool(false));
        resp.entry("connectionId".to_string())
            .or_insert_with(|| json!(0.0));
        resp.entry("encodedDataLength".to_string())
            .or_insert_with(|| json!(0.0));
        resp.entry("securityState".to_string())
            .or_insert(Value::String("unknown".to_string()));
    }
}

/// Inject defaults onto a single frame object in-place.
fn patch_frame_object(frame: &mut serde_json::Map<String, Value>) {
    frame
        .entry("secureContextType".to_string())
        .or_insert(Value::String("Secure".to_string()));
    frame
        .entry("crossOriginIsolatedContextType".to_string())
        .or_insert(Value::String("NotIsolated".to_string()));
    // `gatedAPIFeatures: Vec<...>` has no `#[serde(default)]` on the Rust
    // side, so a missing field is a hard parse error. Default to an empty
    // array so chromiumoxide can deserialise.
    frame
        .entry("gatedAPIFeatures".to_string())
        .or_insert_with(|| Value::Array(Vec::new()));
    if matches!(
        frame.get("browserContextId"),
        Some(Value::String(s)) if s.is_empty()
    ) {
        frame.remove("browserContextId");
    }
}

/// Recursively patch every `frame` in a frame-tree node.
fn patch_frame_tree(node: &mut Value) {
    if let Some(obj) = node.as_object_mut() {
        if let Some(frame) = obj.get_mut("frame").and_then(|f| f.as_object_mut()) {
            patch_frame_object(frame);
        }
        if let Some(children) = obj.get_mut("childFrames").and_then(|c| c.as_array_mut()) {
            for child in children.iter_mut() {
                patch_frame_tree(child);
            }
        }
    }
}

/// Patch a response payload by tracked method. Returns `true` if mutated.
fn patch_response(method: &str, value: &mut Value) -> bool {
    let Some(result) = value.get_mut("result") else {
        return false;
    };
    match method {
        "Page.getFrameTree" => {
            if let Some(tree) = result.get_mut("frameTree") {
                patch_frame_tree(tree);
                return true;
            }
            false
        }
        "Target.getTargetInfo" => {
            if let Some(info) = result.get_mut("targetInfo").and_then(|t| t.as_object_mut()) {
                info.entry("canAccessOpener".to_string())
                    .or_insert(Value::Bool(false));
                if matches!(
                    info.get("browserContextId"),
                    Some(Value::String(s)) if s.is_empty()
                ) {
                    info.remove("browserContextId");
                }
                return true;
            }
            false
        }
        _ => false,
    }
}

/// Build the 5-event synthetic lifecycle for an about:blank attach.
pub fn build_synthetic_lifecycle(
    session_id: &str,
    frame_id: &str,
    loader_id: &str,
    timestamp: f64,
) -> Vec<Value> {
    ["init", "commit", "DOMContentLoaded", "load", "networkIdle"]
        .iter()
        .map(|name| {
            json!({
                "method": "Page.lifecycleEvent",
                "sessionId": session_id,
                "params": {
                    "frameId": frame_id,
                    "loaderId": loader_id,
                    "name": name,
                    "timestamp": timestamp,
                }
            })
        })
        .collect()
}

/// Build the synthetic initial `Page.frameNavigated{about:blank}`.
fn build_initial_frame_navigated(session_id: &str, frame_id: &str, loader_id: &str) -> Value {
    json!({
        "method": "Page.frameNavigated",
        "sessionId": session_id,
        "params": {
            "frame": {
                "id": frame_id,
                "loaderId": loader_id,
                "url": "about:blank",
                "domainAndRegistry": "",
                "securityOrigin": "://",
                "mimeType": "text/html",
                "secureContextType": "Secure",
                "crossOriginIsolatedContextType": "NotIsolated",
                "adFrameStatus": { "adFrameType": "none" },
                "name": "about:blank",
                "gatedAPIFeatures": []
            },
            "type": "Navigation"
        }
    })
}

/// Process a JSON message in either direction. Returns any synthetic frames
/// the shim must additionally emit (always inbound-bound — extras are framed
/// as `Message::Text` and sent towards chromiumoxide).
pub fn patch_message(state: &ShimState, direction: Direction, value: &mut Value) -> Vec<Value> {
    let mut extras: Vec<Value> = Vec::new();

    match direction {
        Direction::Outbound => {
            // Record id -> method for later response patching.
            if let (Some(id), Some(method)) = (
                value.get("id").and_then(|v| v.as_u64()),
                value.get("method").and_then(|v| v.as_str()),
            ) {
                state.pending_commands.insert(id, method.to_string());

                // Synthesise about:blank lifecycle when chromiumoxide first
                // enables it for a session. We do it on the *outbound*
                // request side so the lifecycle events arrive at
                // chromiumoxide before the response (which would otherwise
                // be the last thing it sees from this command).
                let session_id_opt = value
                    .get("sessionId")
                    .and_then(|v| v.as_str())
                    .map(str::to_owned);
                if matches!(method, "Page.setLifecycleEventsEnabled" | "Page.enable") {
                    if let Some(session_id) = session_id_opt {
                        // Initial frameNavigated: emit before lifecycle on
                        // first Page.enable (or first setLifecycleEventsEnabled
                        // if Page.enable wasn't seen separately) — once.
                        if !state
                            .initial_frame_emitted
                            .get(&session_id)
                            .map(|b| *b.value())
                            .unwrap_or(false)
                        {
                            if let Some(frame_id) =
                                state.session_frames.get(&session_id).map(|f| f.clone())
                            {
                                let loader_id = uuid::Uuid::new_v4().to_string();
                                extras.push(build_initial_frame_navigated(
                                    &session_id,
                                    &frame_id,
                                    &loader_id,
                                ));
                                state.initial_frame_emitted.insert(session_id.clone(), true);
                            }
                        }

                        if method == "Page.setLifecycleEventsEnabled"
                            && !state
                                .synthetic_emitted
                                .get(&session_id)
                                .map(|b| *b.value())
                                .unwrap_or(false)
                        {
                            if let Some(frame_id) =
                                state.session_frames.get(&session_id).map(|f| f.clone())
                            {
                                let loader_id = uuid::Uuid::new_v4().to_string();
                                let ts = state.epoch.now_secs();
                                extras.extend(build_synthetic_lifecycle(
                                    &session_id,
                                    &frame_id,
                                    &loader_id,
                                    ts,
                                ));
                                state.synthetic_emitted.insert(session_id.clone(), true);
                            }
                        }
                    }
                }
            }
        }
        Direction::Inbound => {
            // Event-shape patch first (operates on `method` field).
            patch_obscura_event(value);

            // Learn (sessionId -> frameId) from attachedToTarget. obscura uses
            // the targetId as the implicit frame id for the page.
            if value.get("method").and_then(|m| m.as_str()) == Some("Target.attachedToTarget") {
                let session = value
                    .get("params")
                    .and_then(|p| p.get("sessionId"))
                    .and_then(|s| s.as_str())
                    .map(str::to_owned);
                let target_id = value
                    .get("params")
                    .and_then(|p| p.get("targetInfo"))
                    .and_then(|ti| ti.get("targetId"))
                    .and_then(|t| t.as_str())
                    .map(str::to_owned);
                if let (Some(s), Some(t)) = (session, target_id) {
                    state.session_frames.insert(s, t);
                }
            }

            // Response patcher: id present + result present + tracked.
            if let Some(id) = value.get("id").and_then(|v| v.as_u64()) {
                if value.get("result").is_some() || value.get("error").is_some() {
                    if let Some((_, method)) = state.pending_commands.remove(&id) {
                        if value.get("result").is_some() {
                            patch_response(&method, value);
                        }
                    }
                }
            }
        }
    }

    extras
}

/// A running WebSocket proxy from `127.0.0.1:<local_port>` to the upstream
/// obscura CDP endpoint.
pub struct CdpShim {
    upstream_ws_url: String,
    listener_port: u16,
    task: JoinHandle<()>,
    shutdown_tx: Option<oneshot::Sender<()>>,
}

impl std::fmt::Debug for CdpShim {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CdpShim")
            .field("upstream_ws_url", &self.upstream_ws_url)
            .field("listener_port", &self.listener_port)
            .finish()
    }
}

impl CdpShim {
    pub async fn start(upstream_ws_url: &str) -> anyhow::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .context("CdpShim: bind local listener")?;
        let port = listener.local_addr()?.port();
        let upstream = upstream_ws_url.to_string();
        let upstream_for_task = upstream.clone();

        let (shutdown_tx, mut shutdown_rx) = oneshot::channel::<()>();

        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = &mut shutdown_rx => {
                        tracing::debug!("CdpShim: shutdown signal received");
                        break;
                    }
                    accepted = listener.accept() => {
                        let (stream, _peer) = match accepted {
                            Ok(v) => v,
                            Err(e) => {
                                tracing::warn!(error = %e, "CdpShim: accept failed");
                                continue;
                            }
                        };
                        let upstream = upstream_for_task.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_connection(stream, upstream).await {
                                tracing::warn!(error = %e, "CdpShim: connection handler error");
                            }
                        });
                    }
                }
            }
        });

        Ok(Self {
            upstream_ws_url: upstream,
            listener_port: port,
            task,
            shutdown_tx: Some(shutdown_tx),
        })
    }

    pub fn local_url(&self) -> String {
        format!("ws://127.0.0.1:{}/devtools/browser", self.listener_port)
    }

    pub fn upstream_url(&self) -> &str {
        &self.upstream_ws_url
    }

    pub fn local_port(&self) -> u16 {
        self.listener_port
    }

    pub async fn shutdown(mut self) -> anyhow::Result<()> {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
        self.task.abort();
        let _ = (&mut self.task).await;
        Ok(())
    }
}

impl Drop for CdpShim {
    fn drop(&mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
        self.task.abort();
    }
}

async fn handle_connection(client_tcp: TcpStream, upstream_ws_url: String) -> anyhow::Result<()> {
    let captured_path: Arc<std::sync::Mutex<Option<String>>> =
        Arc::new(std::sync::Mutex::new(None));
    let captured_path_cb = captured_path.clone();

    #[allow(clippy::result_large_err)]
    let cb = move |req: &Request, res: Response| {
        if let Ok(mut g) = captured_path_cb.lock() {
            *g = Some(req.uri().path().to_string());
        }
        Ok(res)
    };
    let client_ws = tokio_tungstenite::accept_hdr_async(client_tcp, cb)
        .await
        .context("CdpShim: client handshake")?;

    let chosen_path = captured_path
        .lock()
        .ok()
        .and_then(|g| g.clone())
        .unwrap_or_else(|| "/devtools/browser".to_string());

    let upstream_url = rewrite_path(&upstream_ws_url, &chosen_path);

    tracing::debug!(%upstream_url, %chosen_path, "CdpShim: dialling upstream");

    let (upstream_ws, _resp) = tokio_tungstenite::connect_async(&upstream_url)
        .await
        .context("CdpShim: upstream connect")?;

    let (client_tx, mut client_rx) = client_ws.split();
    let (mut upstream_tx, mut upstream_rx) = upstream_ws.split();

    // Per-connection shared state.
    let state = ShimState::new();

    // We need to inject synthetic events into the client-bound stream from
    // *both* directions: extras computed during c2u (outbound) must reach
    // the client. Wrap client_tx in a tokio Mutex via an Arc.
    let client_tx = Arc::new(tokio::sync::Mutex::new(client_tx));

    // Outbound: client -> upstream. Snoop for id/method + emit extras.
    let state_c2u = state.clone();
    let client_tx_c2u = client_tx.clone();
    let c2u = async move {
        while let Some(msg) = client_rx.next().await {
            let msg = match msg {
                Ok(m) => m,
                Err(e) => {
                    tracing::trace!(error = %e, "CdpShim: client recv err");
                    break;
                }
            };
            if matches!(msg, Message::Close(_)) {
                let _ = upstream_tx.send(msg).await;
                break;
            }

            // Try to peek as JSON for state tracking + synthetic emission.
            let mut extras: Vec<Value> = Vec::new();
            let forwarded: Message = match &msg {
                Message::Text(text) => match serde_json::from_str::<Value>(text) {
                    Ok(mut v) => {
                        extras = patch_message(&state_c2u, Direction::Outbound, &mut v);
                        msg.clone()
                    }
                    Err(_) => msg.clone(),
                },
                _ => msg.clone(),
            };

            if upstream_tx.send(forwarded).await.is_err() {
                break;
            }

            // Send any synthetic events towards the client AFTER forwarding
            // the originating command upstream, so chromiumoxide can match
            // them by frameId.
            if !extras.is_empty() {
                let mut tx = client_tx_c2u.lock().await;
                for extra in extras {
                    let s = serde_json::to_string(&extra).unwrap_or_default();
                    if tx.send(Message::Text(s.into())).await.is_err() {
                        break;
                    }
                }
            }
        }
        let _ = upstream_tx.close().await;
    };

    // Inbound: upstream -> client. Patch events + responses.
    let state_u2c = state.clone();
    let client_tx_u2c = client_tx.clone();
    let u2c = async move {
        while let Some(msg) = upstream_rx.next().await {
            let msg = match msg {
                Ok(m) => m,
                Err(e) => {
                    tracing::trace!(error = %e, "CdpShim: upstream recv err");
                    break;
                }
            };
            let (patched, was_close) = match msg {
                Message::Text(text) => match serde_json::from_str::<Value>(&text) {
                    Ok(mut v) => {
                        let _extras = patch_message(&state_u2c, Direction::Inbound, &mut v);
                        let s = serde_json::to_string(&v).unwrap_or_else(|_| text.to_string());
                        (Message::Text(s.into()), false)
                    }
                    Err(_) => (Message::Text(text), false),
                },
                Message::Close(c) => (Message::Close(c), true),
                other => (other, false),
            };
            let mut tx = client_tx_u2c.lock().await;
            if tx.send(patched).await.is_err() {
                break;
            }
            if was_close {
                break;
            }
        }
        let mut tx = client_tx_u2c.lock().await;
        let _ = tx.close().await;
    };

    tokio::join!(c2u, u2c);
    Ok(())
}

/// Replace the path component of a ws:// URL while preserving scheme/host/port.
fn rewrite_path(ws_url: &str, new_path: &str) -> String {
    if let Some(rest) = ws_url
        .strip_prefix("ws://")
        .or_else(|| ws_url.strip_prefix("wss://"))
    {
        let scheme = if ws_url.starts_with("wss://") {
            "wss"
        } else {
            "ws"
        };
        let authority = rest.split('/').next().unwrap_or(rest);
        let original_path = &rest[authority.len()..];
        let chosen =
            if new_path == "/devtools/browser" && original_path.starts_with("/devtools/browser/") {
                original_path.to_string()
            } else {
                new_path.to_string()
            };
        return format!("{scheme}://{authority}{chosen}");
    }
    ws_url.to_string()
}

// Silence the unused-import warning when running without tests in scope.
#[allow(dead_code)]
fn _touch_instant(_i: Instant) {}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ---- Phase 5a event-patch tests (kept) ----

    #[test]
    fn test_patch_target_created_injects_canaccessopener() {
        let mut v = json!({
            "method": "Target.targetCreated",
            "params": {
                "targetInfo": {
                    "targetId": "page-1",
                    "type": "page",
                    "title": "",
                    "url": "about:blank",
                    "attached": false,
                    "browserContextId": "default"
                }
            }
        });
        patch_obscura_event(&mut v);
        assert_eq!(
            v["params"]["targetInfo"]["canAccessOpener"],
            Value::Bool(false)
        );
        assert_eq!(v["params"]["targetInfo"]["browserContextId"], "default");
    }

    #[test]
    fn test_patch_target_created_preserves_existing_canaccessopener() {
        let mut v = json!({
            "method": "Target.targetCreated",
            "params": {
                "targetInfo": {
                    "targetId": "page-1",
                    "type": "page",
                    "title": "",
                    "url": "about:blank",
                    "attached": false,
                    "canAccessOpener": true
                }
            }
        });
        patch_obscura_event(&mut v);
        assert_eq!(
            v["params"]["targetInfo"]["canAccessOpener"],
            Value::Bool(true)
        );
    }

    #[test]
    fn test_patch_attached_to_target_injects_canaccessopener() {
        let mut v = json!({
            "method": "Target.attachedToTarget",
            "params": {
                "sessionId": "page-1-session",
                "targetInfo": {
                    "targetId": "page-1",
                    "type": "page",
                    "title": "",
                    "url": "about:blank",
                    "attached": true,
                    "browserContextId": "default"
                },
                "waitingForDebugger": false
            }
        });
        patch_obscura_event(&mut v);
        assert_eq!(
            v["params"]["targetInfo"]["canAccessOpener"],
            Value::Bool(false)
        );
    }

    #[test]
    fn test_patch_frame_navigated_injects_secure_context_type() {
        let mut v = json!({
            "method": "Page.frameNavigated",
            "params": {
                "frame": {
                    "id": "frame-1",
                    "loaderId": "loader-1",
                    "url": "about:blank",
                    "securityOrigin": "://",
                    "mimeType": "text/html"
                }
            }
        });
        patch_obscura_event(&mut v);
        assert_eq!(v["params"]["frame"]["secureContextType"], "Secure");
        assert_eq!(
            v["params"]["frame"]["crossOriginIsolatedContextType"],
            "NotIsolated"
        );
    }

    #[test]
    fn test_patch_unknown_method_no_modification() {
        let original = json!({
            "method": "Some.unknownMethod",
            "params": { "foo": "bar" }
        });
        let mut v = original.clone();
        patch_obscura_event(&mut v);
        assert_eq!(v, original);
    }

    #[test]
    fn test_patch_empty_browser_context_id_removed() {
        let mut v = json!({
            "method": "Target.targetCreated",
            "params": {
                "targetInfo": {
                    "targetId": "browser",
                    "type": "browser",
                    "title": "",
                    "url": "",
                    "attached": true,
                    "browserContextId": ""
                }
            }
        });
        patch_obscura_event(&mut v);
        let info = v["params"]["targetInfo"].as_object().unwrap();
        assert!(!info.contains_key("browserContextId"));
        assert_eq!(info.get("canAccessOpener"), Some(&Value::Bool(false)));
    }

    #[test]
    fn test_patch_response_passthrough() {
        let original = json!({
            "id": 3,
            "result": { "targetId": "page-1" }
        });
        let mut v = original.clone();
        patch_obscura_event(&mut v);
        assert_eq!(v, original);
    }

    #[test]
    fn test_rewrite_path_keeps_upstream_uuid_path() {
        let upstream = "ws://127.0.0.1:19222/devtools/browser/abcd-uuid";
        let r = rewrite_path(upstream, "/devtools/browser");
        assert_eq!(r, "ws://127.0.0.1:19222/devtools/browser/abcd-uuid");
    }

    #[test]
    fn test_rewrite_path_session_path() {
        let upstream = "ws://127.0.0.1:19222/devtools/browser";
        let r = rewrite_path(upstream, "/devtools/page/page-1");
        assert_eq!(r, "ws://127.0.0.1:19222/devtools/page/page-1");
    }

    // ---- Phase 5d new tests ----

    #[test]
    fn test_response_patcher_injects_frametree_fields() {
        let state = ShimState::new();
        let mut req = json!({
            "id": 4,
            "method": "Page.getFrameTree",
            "sessionId": "page-1-session"
        });
        patch_message(&state, Direction::Outbound, &mut req);

        let mut resp = json!({
            "id": 4,
            "result": {
                "frameTree": {
                    "frame": {
                        "id": "page-1",
                        "loaderId": "initial-loader",
                        "url": "about:blank",
                        "domainAndRegistry": "",
                        "securityOrigin": "about:blank",
                        "mimeType": "text/html"
                    }
                }
            }
        });
        let extras = patch_message(&state, Direction::Inbound, &mut resp);
        assert!(extras.is_empty());
        let frame = &resp["result"]["frameTree"]["frame"];
        assert_eq!(frame["secureContextType"], "Secure");
        assert_eq!(frame["crossOriginIsolatedContextType"], "NotIsolated");
    }

    #[test]
    fn test_response_patcher_recurses_into_child_frames() {
        let state = ShimState::new();
        let mut req = json!({"id": 4, "method": "Page.getFrameTree"});
        patch_message(&state, Direction::Outbound, &mut req);

        let mut resp = json!({
            "id": 4,
            "result": {
                "frameTree": {
                    "frame": {"id": "f0", "loaderId": "l0", "url": "about:blank",
                               "domainAndRegistry": "", "securityOrigin": "://", "mimeType": "text/html"},
                    "childFrames": [
                        {
                            "frame": {"id": "f1", "loaderId": "l1", "url": "about:blank",
                                       "domainAndRegistry": "", "securityOrigin": "://", "mimeType": "text/html"},
                            "childFrames": [
                                {"frame": {"id": "f2", "loaderId": "l2", "url": "about:blank",
                                            "domainAndRegistry": "", "securityOrigin": "://", "mimeType": "text/html"}}
                            ]
                        }
                    ]
                }
            }
        });
        patch_message(&state, Direction::Inbound, &mut resp);
        let tree = &resp["result"]["frameTree"];
        assert_eq!(tree["frame"]["secureContextType"], "Secure");
        assert_eq!(
            tree["childFrames"][0]["frame"]["secureContextType"],
            "Secure"
        );
        assert_eq!(
            tree["childFrames"][0]["childFrames"][0]["frame"]["secureContextType"],
            "Secure"
        );
    }

    #[test]
    fn test_response_patcher_target_get_target_info_can_access_opener() {
        let state = ShimState::new();
        let mut req = json!({"id": 7, "method": "Target.getTargetInfo"});
        patch_message(&state, Direction::Outbound, &mut req);

        let mut resp = json!({
            "id": 7,
            "result": {
                "targetInfo": {
                    "targetId": "page-1",
                    "type": "page",
                    "title": "",
                    "url": "about:blank",
                    "attached": true,
                    "browserContextId": ""
                }
            }
        });
        patch_message(&state, Direction::Inbound, &mut resp);
        let info = resp["result"]["targetInfo"].as_object().unwrap();
        assert_eq!(info.get("canAccessOpener"), Some(&Value::Bool(false)));
        assert!(!info.contains_key("browserContextId"));
    }

    #[test]
    fn test_response_patcher_unknown_method_passthrough() {
        let state = ShimState::new();
        let mut req = json!({"id": 9, "method": "Runtime.evaluate"});
        patch_message(&state, Direction::Outbound, &mut req);

        let original = json!({"id": 9, "result": {"result": {"type": "string", "value": "hi"}}});
        let mut resp = original.clone();
        patch_message(&state, Direction::Inbound, &mut resp);
        assert_eq!(resp, original);
    }

    #[test]
    fn test_id_method_map_evicted_after_response() {
        let state = ShimState::new();
        let mut req = json!({"id": 11, "method": "Page.getFrameTree"});
        patch_message(&state, Direction::Outbound, &mut req);
        assert_eq!(state.pending_commands.len(), 1);

        let mut resp = json!({"id": 11, "result": {"frameTree": {"frame": {
            "id": "f", "loaderId": "l", "url": "", "domainAndRegistry": "",
            "securityOrigin": "", "mimeType": "text/html"
        }}}});
        patch_message(&state, Direction::Inbound, &mut resp);
        assert_eq!(state.pending_commands.len(), 0, "id should be evicted");
    }

    #[test]
    fn test_synthetic_lifecycle_5_events_in_order() {
        let evs = build_synthetic_lifecycle("sess-1", "frame-1", "loader-1", 1.0);
        assert_eq!(evs.len(), 5);
        let names: Vec<&str> = evs
            .iter()
            .map(|e| e["params"]["name"].as_str().unwrap())
            .collect();
        assert_eq!(
            names,
            vec!["init", "commit", "DOMContentLoaded", "load", "networkIdle"]
        );
        for e in &evs {
            assert_eq!(e["sessionId"], "sess-1");
            assert_eq!(e["params"]["frameId"], "frame-1");
            assert_eq!(e["params"]["loaderId"], "loader-1");
        }
    }

    #[test]
    fn test_synthetic_lifecycle_emitted_once_per_session() {
        let state = ShimState::new();
        // 1. attachedToTarget records the frame
        let mut attached = json!({
            "method": "Target.attachedToTarget",
            "params": {
                "sessionId": "S1",
                "targetInfo": {
                    "targetId": "page-1", "type": "page", "title": "",
                    "url": "about:blank", "attached": true
                },
                "waitingForDebugger": false
            }
        });
        patch_message(&state, Direction::Inbound, &mut attached);

        // 2. First Page.setLifecycleEventsEnabled -> 5 lifecycle extras
        let mut req1 = json!({
            "id": 5, "method": "Page.setLifecycleEventsEnabled",
            "sessionId": "S1", "params": {"enabled": true}
        });
        let extras1 = patch_message(&state, Direction::Outbound, &mut req1);
        // initial frameNavigated (1) + 5 lifecycle = 6 on the very first call
        // (Page.enable hadn't been seen separately).
        let life: Vec<_> = extras1
            .iter()
            .filter(|e| e["method"] == "Page.lifecycleEvent")
            .collect();
        assert_eq!(life.len(), 5);

        // 3. Second call -> no synthetic lifecycle (already emitted)
        let mut req2 = json!({
            "id": 6, "method": "Page.setLifecycleEventsEnabled",
            "sessionId": "S1", "params": {"enabled": true}
        });
        let extras2 = patch_message(&state, Direction::Outbound, &mut req2);
        let life2: Vec<_> = extras2
            .iter()
            .filter(|e| e["method"] == "Page.lifecycleEvent")
            .collect();
        assert!(life2.is_empty());
    }

    #[test]
    fn test_attached_to_target_records_session_to_frame() {
        let state = ShimState::new();
        let mut attached = json!({
            "method": "Target.attachedToTarget",
            "params": {
                "sessionId": "S-xyz",
                "targetInfo": {
                    "targetId": "T-abc", "type": "page", "title": "",
                    "url": "about:blank", "attached": true
                },
                "waitingForDebugger": false
            }
        });
        patch_message(&state, Direction::Inbound, &mut attached);
        let got = state.session_frames.get("S-xyz").map(|r| r.clone());
        assert_eq!(got.as_deref(), Some("T-abc"));
    }

    #[test]
    fn test_initial_frame_navigated_about_blank_emitted_after_page_enable() {
        let state = ShimState::new();
        // attach
        let mut attached = json!({
            "method": "Target.attachedToTarget",
            "params": {
                "sessionId": "S1",
                "targetInfo": {
                    "targetId": "F1", "type": "page", "title": "",
                    "url": "about:blank", "attached": true
                },
                "waitingForDebugger": false
            }
        });
        patch_message(&state, Direction::Inbound, &mut attached);

        // Page.enable -> initial frameNavigated extra
        let mut enable = json!({
            "id": 3, "method": "Page.enable", "sessionId": "S1"
        });
        let extras = patch_message(&state, Direction::Outbound, &mut enable);
        assert_eq!(extras.len(), 1);
        assert_eq!(extras[0]["method"], "Page.frameNavigated");
        assert_eq!(extras[0]["sessionId"], "S1");
        assert_eq!(extras[0]["params"]["frame"]["id"], "F1");
        assert_eq!(extras[0]["params"]["frame"]["url"], "about:blank");
        assert_eq!(extras[0]["params"]["frame"]["secureContextType"], "Secure");

        // A subsequent setLifecycleEventsEnabled should NOT re-emit the
        // initial frameNavigated, only the 5 lifecycle events.
        let mut life = json!({
            "id": 4, "method": "Page.setLifecycleEventsEnabled",
            "sessionId": "S1", "params": {"enabled": true}
        });
        let extras2 = patch_message(&state, Direction::Outbound, &mut life);
        let nav_count = extras2
            .iter()
            .filter(|e| e["method"] == "Page.frameNavigated")
            .count();
        assert_eq!(nav_count, 0);
        let life_count = extras2
            .iter()
            .filter(|e| e["method"] == "Page.lifecycleEvent")
            .count();
        assert_eq!(life_count, 5);
    }

    // ---- Phase 5e Network event patch tests ----

    #[test]
    fn test_patch_network_request_will_be_sent_injects_all_fields() {
        let mut v = json!({
            "method": "Network.requestWillBeSent",
            "params": {
                "requestId": "r1",
                "loaderId": "l1",
                "documentURL": "https://example.com/",
                "request": {
                    "url": "https://example.com/",
                    "method": "GET",
                    "headers": {}
                },
                "timestamp": 1.0,
                "wallTime": 2.0,
                "initiator": {"type": "other"},
                "frameId": "f1",
                "type": "Document"
            }
        });
        patch_obscura_event(&mut v);
        assert_eq!(v["params"]["redirectHasExtraInfo"], Value::Bool(false));
        assert_eq!(v["params"]["request"]["initialPriority"], "Medium");
        assert_eq!(
            v["params"]["request"]["referrerPolicy"],
            "no-referrer-when-downgrade"
        );
    }

    #[test]
    fn test_patch_network_request_will_be_sent_preserves_existing_priority() {
        let mut v = json!({
            "method": "Network.requestWillBeSent",
            "params": {
                "redirectHasExtraInfo": true,
                "request": {
                    "url": "https://example.com/",
                    "method": "GET",
                    "headers": {},
                    "initialPriority": "VeryHigh",
                    "referrerPolicy": "strict-origin"
                }
            }
        });
        patch_obscura_event(&mut v);
        assert_eq!(v["params"]["redirectHasExtraInfo"], Value::Bool(true));
        assert_eq!(v["params"]["request"]["initialPriority"], "VeryHigh");
        assert_eq!(v["params"]["request"]["referrerPolicy"], "strict-origin");
    }

    #[test]
    fn test_patch_network_response_received_injects_all_fields() {
        let mut v = json!({
            "method": "Network.responseReceived",
            "params": {
                "requestId": "r1",
                "loaderId": "l1",
                "timestamp": 1.0,
                "type": "Document",
                "response": {
                    "url": "https://example.com/",
                    "status": 200,
                    "statusText": "OK",
                    "headers": {},
                    "mimeType": "text/html"
                },
                "frameId": "f1"
            }
        });
        patch_obscura_event(&mut v);
        assert_eq!(v["params"]["hasExtraInfo"], Value::Bool(false));
        let resp = &v["params"]["response"];
        assert_eq!(resp["charset"], "");
        assert_eq!(resp["connectionReused"], Value::Bool(false));
        assert_eq!(resp["connectionId"], json!(0.0));
        assert_eq!(resp["encodedDataLength"], json!(0.0));
        assert_eq!(resp["securityState"], "unknown");
    }

    #[test]
    fn test_patch_network_response_received_preserves_existing_charset() {
        let mut v = json!({
            "method": "Network.responseReceived",
            "params": {
                "hasExtraInfo": true,
                "response": {
                    "url": "https://example.com/",
                    "status": 200,
                    "statusText": "OK",
                    "headers": {},
                    "mimeType": "text/html",
                    "charset": "utf-8",
                    "connectionReused": true,
                    "connectionId": 12.0,
                    "encodedDataLength": 1024.0,
                    "securityState": "secure"
                }
            }
        });
        patch_obscura_event(&mut v);
        assert_eq!(v["params"]["hasExtraInfo"], Value::Bool(true));
        let resp = &v["params"]["response"];
        assert_eq!(resp["charset"], "utf-8");
        assert_eq!(resp["connectionReused"], Value::Bool(true));
        assert_eq!(resp["connectionId"], json!(12.0));
        assert_eq!(resp["encodedDataLength"], json!(1024.0));
        assert_eq!(resp["securityState"], "secure");
    }

    // ---- Original round-trip integration test (kept) ----

    #[tokio::test]
    async fn test_shim_round_trips_event_with_patch() {
        use futures::SinkExt;
        use tokio_tungstenite::tungstenite::Message;

        let upstream_listener = match TcpListener::bind("127.0.0.1:0").await {
            Ok(listener) => listener,
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                eprintln!("skipping websocket round-trip test: loopback bind denied");
                return;
            }
            Err(e) => panic!("bind upstream listener: {e}"),
        };
        let upstream_port = upstream_listener.local_addr().unwrap().port();
        let upstream_task = tokio::spawn(async move {
            let (sock, _) = upstream_listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(sock).await.unwrap();
            let payload = json!({
                "method": "Target.targetCreated",
                "params": {
                    "targetInfo": {
                        "targetId": "page-1",
                        "type": "page",
                        "title": "",
                        "url": "about:blank",
                        "attached": false,
                        "browserContextId": ""
                    }
                }
            });
            ws.send(Message::Text(payload.to_string().into()))
                .await
                .unwrap();
            let _ = ws.close(None).await;
        });

        let upstream_url = format!("ws://127.0.0.1:{upstream_port}/devtools/browser");
        let shim = CdpShim::start(&upstream_url).await.unwrap();

        let (mut client_ws, _) = tokio_tungstenite::connect_async(shim.local_url())
            .await
            .unwrap();
        let frame = tokio::time::timeout(std::time::Duration::from_secs(3), client_ws.next())
            .await
            .expect("frame within 3s")
            .expect("some frame")
            .expect("ws ok");
        let text = match frame {
            Message::Text(t) => t.to_string(),
            other => panic!("expected text, got {other:?}"),
        };
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(
            v["params"]["targetInfo"]["canAccessOpener"],
            Value::Bool(false)
        );
        assert!(v["params"]["targetInfo"].get("browserContextId").is_none());

        upstream_task.await.unwrap();
        shim.shutdown().await.unwrap();
    }
}
