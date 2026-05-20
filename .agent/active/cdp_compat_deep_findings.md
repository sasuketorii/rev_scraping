# CDP Compat — Phase 5d Deep-Dive Findings

Investigation: 2026-05-12.
chromiumoxide: `~/.cargo/registry/.../chromiumoxide-0.9.1/`
chromiumoxide_cdp: `~/.cargo/registry/.../chromiumoxide_cdp-0.9.1/`
obscura (read-only): `vendor/obscura/`
shim under test: `crates/obscura-bridge/src/cdp_shim.rs`

## TL;DR

The Phase 5a shim **does** correctly patch every `Target.*` and `Page.frameNavigated`
**event**. Unit tests pass and live capture confirms the events are now well-formed.
But `new_page()` still hangs because of **two additional bugs** the event-patcher
doesn't touch:

1. **`Page.getFrameTree` *response* is dropped silently** because its `frameTree.frame`
   payload is missing `secureContextType` / `crossOriginIsolatedContextType`. Without
   this, the frame manager is never populated → no main frame → init can never finish.
2. **obscura never emits a `Page.lifecycleEvent{name:"load"}` for the initial
   `about:blank` attach**. Even if (1) were fixed, `Initialized → send_page` is
   gated on `main_frame.is_loaded()`, which only becomes true when a `load`
   lifecycle event is received for that frame's loader.

The shim has no "before there was a bug, now the protocol is silent" symptom.
There is **no** `WS Invalid message` after the shim — the captured stderr is empty
of that string. The original "data did not match any variant" string in Phase 5a
came from the responses to commands that obscura had not started replying to yet.
Today, every request gets a reply. The hang is purely a **frame-state-machine
deadlock inside chromiumoxide**, caused by silent JSON deserialization failure of
one specific response and one missing event.

## Full WS capture (`/tmp/cdp_stdout.log`, 30s alarm)

shim ↔ obscura traffic, in order. All events that come through `cdp_dump` are valid
JSON; **no `inbound_raw`** lines appeared, so nothing slipped past tungstenite.

| dir | id | method | notes |
|---|---|---|---|
| → | 0 | `Target.setDiscoverTargets` | |
| → | 1 | `Target.createTarget` | url=about:blank |
| ← | – | `Target.targetCreated` (browser) | patched: `canAccessOpener:false`, empty `browserContextId` dropped |
| ← | 0 | response | ok |
| ← | – | `Target.targetCreated` (page-1) | patched OK |
| ← | – | `Target.attachedToTarget` | patched OK |
| ← | 1 | response | targetId=page-1 |
| → | 2 | `Target.attachToTarget` | flatten=true |
| → | 3 | `Page.enable` | sessionId=page-1-session |
| ← | – | `Target.attachedToTarget` (duplicate) | ok |
| ← | 2 | response | sessionId=page-1-session |
| ← | 3 | response | |
| → | 4 | `Page.getFrameTree` | |
| ← | 4 | response | **frameTree.frame missing `secureContextType` + `crossOriginIsolatedContextType`** |
| → | 5 | `Page.setLifecycleEventsEnabled` | |
| ← | 5 | response | |
| → | 6 | `Runtime.enable` | |
| ← | – | `Runtime.executionContextCreated` | ok (frameId=page-1) |
| ← | 6 | response | |
| → | 7 | `Page.addScriptToEvaluateOnNewDocument` | utility world |
| ← | 7 | response | identifier=1 |
| → | 8 | `Network.enable` | |
| ← | 8 | response | |
| → | 9 | `Security.setIgnoreCertificateErrors` | |
| ← | 9 | response | |
| → | 10 | `Target.setAutoAttach` | |
| ← | 10 | response | |
| → | 11 | `Performance.enable` | |
| ← | 11 | response | |
| → | 12 | `Log.enable` | |
| ← | 12 | response | |
| → | 13 | `Network.setCacheDisabled` | |
| ← | 13 | response | |
| | | **silence for 28s, then alarm kills the process** | |

So **every command obscura is given gets a reply**. The new_page future is waiting
purely on internal state in `chromiumoxide::handler::Target`, not on a missing WS frame.

## Root cause 1: getFrameTree response silently rejected

`chromiumoxide-0.9.1/src/handler/target.rs:214`:

```rust
GetFrameTreeParams::IDENTIFIER => {
    if let Some(resp) = resp
        .result
        .and_then(|val| GetFrameTreeParams::response_from_value(val).ok())
    {
        self.frame_manager.on_frame_tree(resp.frame_tree);
    }
}
```

`response_from_value` calls `serde_json::from_value::<GetFrameTreeReturns>(val)`.
That struct contains a `FrameTree` whose `frame: chromiumoxide_cdp::cdp::browser_protocol::page::Frame`
**requires** `secureContextType` (`SecureContextType` enum, no default) and
`crossOriginIsolatedContextType` (no default) — see
`chromiumoxide_cdp-0.9.1/src/cdp.rs:85413` (struct), `:85459` (`secure_context_type`),
`:85462` (`cross_origin_isolated_context_type`).

obscura's frame tree (captured id=4):

```json
{"frame":{"adFrameStatus":{"adFrameType":"none"},"domainAndRegistry":"",
  "id":"page-1","loaderId":"initial-loader","mimeType":"text/html",
  "securityOrigin":"about:blank","url":"about:blank"}}
```

Two required fields are missing → `from_value` returns `Err` → `.ok()` → `None` →
**the entire block is skipped without any log line.** `frame_manager.frames` stays
empty. `frame_manager.main_frame` stays `None`.

The shim's patch list **does not cover this response**. It only patches event payloads
keyed on `method`. The frameTree response has no `method` field, so
`patch_obscura_event` returns at the first guard.

## Root cause 2: no `load` lifecycle for initial about:blank

`chromiumoxide-0.9.1/src/handler/target.rs:398`:

```rust
TargetInit::Initialized => {
    if let Some(initiator) = self.initiator.take() {
        if self.frame_manager.main_frame()
            .map(|frame| frame.is_loaded())
            .unwrap_or_default()
        {
            if let Some(page) = self.get_or_create_page() {
                let _ = initiator.send(Ok(page.clone().into()));
            } else { self.initiator = Some(initiator); }
        } else {
            self.initiator = Some(initiator);   // <-- we sit here forever
        }
    }
}
```

`Frame::is_loaded` returns `self.lifecycle_events.contains("load")`
(`handler/frame.rs:139`). Lifecycle events come from
`CdpEvent::PageLifecycleEvent` → `frame_manager.on_page_lifecycle_event`
(`handler/target.rs:253`).

Search of `vendor/obscura/crates/obscura-cdp/src/domains/page.rs`:

- `Page.lifecycleEvent` is emitted **only inside the `Page.navigate` handler**
  (lines 71, 96, 138, 140, 145 — `init`, `commit`, `DOMContentLoaded`, `load`,
  `networkIdle`).
- Nothing emits a lifecycle event when a target is **first attached** at
  `about:blank` (which is what `Browser.new_page("about:blank")` produces in
  chromiumoxide). Real Chrome emits `init` + `DOMContentLoaded` + `load` + `networkIdle`
  for about:blank within ~1 ms of `Page.enable`. obscura does not.

So even if we patch the frameTree response so the frame exists, `is_loaded()` is
false → `initiator` is parked → `new_page` future never completes.

(This is purely a `new_page` problem. Once we do issue a real `Page.navigate`,
obscura *will* emit lifecycle events and that future completes — but we never get
to call navigate because we never got back from `new_page`.)

## Root cause 3 (latent, would bite next): no `Page.frameNavigated` at attach

Even with (1) and (2) addressed, obscura sends no `Page.frameStartedLoading`
or `Page.frameNavigated` during attach. After `Page.navigate` is called for the
real URL, obscura *does* emit `frameNavigated` (`page.rs:73`), but the `frame`
payload there is **also** missing `secureContextType` / `crossOriginIsolatedContextType`.
The Phase 5a shim patches this case (`patch_obscura_event` line 64-77), so it's
already handled — but worth confirming. The captured event from obscura was
patched correctly by the shim before being forwarded.

## What the shim must additionally do

In priority order:

1. **Patch the `Page.getFrameTree` response.** Match `id` against a tracked
   in-flight command id whose `method == "Page.getFrameTree"`. When the
   response comes back, walk into `result.frameTree.frame` (and recursively
   into `childFrames[*].frame`) and inject the same two enum defaults
   `secureContextType:"Secure"`, `crossOriginIsolatedContextType:"NotIsolated"`.
   *Implementation note*: this means the shim must keep a small `HashMap<i64,String>`
   of outbound `id → method` so it can find which inbound responses to patch.
   Add `Target.getTargets` / `Page.getNavigationHistory` to the watchlist
   pre-emptively (they share `TargetInfo` / `Frame`).

2. **Synthesise the initial about:blank lifecycle.** When the shim sees a
   `Page.setLifecycleEventsEnabled{enabled:true}` *response* for a given
   `sessionId`, it should immediately emit four synthetic events with the
   tracked `frameId` (which it learned from the same session's
   `Target.attachedToTarget`/`Page.getFrameTree`): `init`, `commit`,
   `DOMContentLoaded`, `load`, `networkIdle`. This matches real-Chrome
   behaviour. Without this, every `new_page` against obscura hangs.
   *Alternative*: synthesise on first `Page.enable` response; either works,
   but `setLifecycleEventsEnabled` is the closer match because lifecycle
   reporting is off until then.

3. **(Optional defensive)** When the shim sees `Page.getNavigationHistory`
   responses, the `entries[*]` need a `transitionType` etc. — not yet
   triggered by the bridge today, but the same pattern (response patching by
   tracked id+method) covers it.

## Implementation sketch for the response-patcher

```rust
struct PendingCommand { method: String /*, sent_at: Instant*/ }
let mut pending: HashMap<i64, PendingCommand> = HashMap::new();

// outbound: if let Ok(v) = serde_json::from_str(text), and v has both
//   id (number) and method (string), insert into pending.
// inbound: if v has "id" (number) and "result" (object), look up id in pending;
//   if method == "Page.getFrameTree", recursively patch every frame in
//   result.frameTree (and child_frames[*].frame).
```

The map needs no eviction policy beyond "remove on response" because chromiumoxide
guarantees a response per command (errors included). Worst-case bounded by
in-flight pipeline depth (≪100).

## Alternative approach: ditch chromiumoxide for obscura's native API

obscura ships *only* a Chrome-compatible CDP server (`obscura serve`). There is no
`serve --json` or HTTP-shaped REST surface; the entire vendored crate
(`vendor/obscura/crates/obscura-cdp/`) is CDP-over-WS only. So "use a stable
obscura HTTP API" is not an option today.

A hand-rolled CDP client tailored to obscura is technically possible (skip
chromiumoxide entirely) but per Phase 5a's option-A analysis, that's 3–6 weeks of
work to re-implement the parts of chromiumoxide we rely on (target lifecycle,
flatten sessions, isolated worlds, command timeouts, frame navigation,
network interception). Two more shim patch points (response patcher + synthetic
lifecycle) is **roughly half a day** and keeps Option B viable. Strongly
recommended: stay on Option B and extend the shim.

## What was reverted

The investigation added `tracing::info!(target:"cdp_dump", ...)` calls in
`crates/obscura-bridge/src/cdp_shim.rs::handle_connection`. These have been
removed at the end of the session. AUP allowlist temporarily included
`example.com`; reverted to pre-investigation state (`authorized.toml.bak`).
