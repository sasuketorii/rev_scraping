# CDP Protocol Compatibility — obscura ⇄ chromiumoxide 0.9.1

Investigation date: 2026-05-12.
obscura: `$REPO_ROOT/vendor/obscura` (HEAD).
chromiumoxide: `~/.cargo/registry/src/index.crates.io-*/chromiumoxide-0.9.1/`
              + `chromiumoxide_cdp-0.9.1` + `chromiumoxide_types-0.9.1`.

## TL;DR

The panic at `chromiumoxide-0.9.1/src/handler/mod.rs:208` (`'Created target not present'`)
is a downstream symptom, not a root cause. The root cause is that **every event obscura
emits whose payload contains a `TargetInfo` or a `Frame` fails to deserialize against
chromiumoxide 0.9's generated PDL types** because required (non-`Option`, no `default`)
fields are missing. The events arrive on the WS as `InvalidMessage`, are dropped, the
`Handler.targets` map is never populated by `Target.targetCreated`, then when the
response to `Target.createTarget` (id=N) is matched, `self.targets.get_mut(&resp.target_id)`
returns `None` → `panic!("Created target not present")`.

The same `InvalidMessage` is what the spider log shows:
`WS Invalid message: data did not match any variant of untagged enum Message`.
(`Message::Response` doesn't match because the payload has no `id`; `Message::Event`
doesn't match because the strongly-typed event struct rejects the JSON.)

## How chromiumoxide parses incoming frames

`chromiumoxide_types::Message<T = CdpEventMessage>` is `#[serde(untagged)]` with
variants `Response(Response)` and `Event(T)`. `Response` is `{id, result, error}` —
*no* `sessionId` field, but `serde` does not `deny_unknown_fields`, so an extra
`sessionId` on a response is silently ignored (OK for us).

`CdpEventMessage` (in `chromiumoxide_cdp-0.9.1/src/cdp.rs:1238`) has a hand-written
`Deserialize` that reads `method`, `sessionId`, `params`, then **dispatches `params`
into a specific generated `EventXxx` struct keyed off `method`**
(`super::browser_protocol::target::EventTargetCreated::IDENTIFIER`, etc.). If the JSON
doesn't fit that struct, the whole `Message` parse fails.

Connection (`src/conn.rs:133`) wraps that as `CdpError::InvalidMessage(text, err)`.
Handler (`src/handler/mod.rs:627`) by default re-raises it (only `warn!`s if
`config.ignore_invalid_messages == true`, which `Browser::launch` doesn't set).

## Concrete schema diffs (the smoking guns)

Raw obscura output, captured from `ws://127.0.0.1:19222/devtools/browser`
after `Target.setDiscoverTargets` + `Target.createTarget`:

```
{"method":"Target.targetCreated","params":{"targetInfo":{
  "targetId":"browser","type":"browser","title":"","url":"",
  "attached":true,"browserContextId":""}}}

{"method":"Target.targetCreated","params":{"targetInfo":{
  "targetId":"page-1","type":"page","title":"","url":"about:blank",
  "attached":false,"browserContextId":"default"}}}

{"method":"Target.attachedToTarget","params":{
  "sessionId":"page-1-session",
  "targetInfo":{...same fields as above...},
  "waitingForDebugger":false}}
```

vs. chromiumoxide-required struct
(`chromiumoxide_cdp-0.9.1/src/cdp.rs:105128 TargetInfo`,
`:107025 EventAttachedToTarget`, `:107100 EventTargetCreated`):

| Field | chromiumoxide requirement | obscura sends? | Fatal? |
|---|---|---|---|
| `targetInfo.canAccessOpener` (bool, required, no default) | **required** | **missing** | **YES — every Target event fails to parse** |
| `targetInfo.openerId` (Option) | optional | missing | ok |
| `targetInfo.openerFrameId` (Option) | optional | missing | ok |
| `targetInfo.parentFrameId` (Option) | optional | missing | ok |
| `targetInfo.subtype` (Option) | optional | missing | ok |
| `targetInfo.browserContextId` (Option<BrowserContextId>) | optional | sent as `""` (empty string) for the browser target — should be omitted; passes as a non-empty string ID but the empty string may not validate as a `BrowserContextId` if newtype-validated | likely ok |

`Page.frameNavigated` (`server.rs:471`) emits a `frame` payload missing **two more**
non-Option fields from `Frame` (`chromiumoxide_cdp-0.9.1/src/cdp.rs:85413`):

| Field | required by chromiumoxide | obscura sends? |
|---|---|---|
| `frame.secureContextType` (`SecureContextType` enum) | **required** | **missing** |
| `frame.crossOriginIsolatedContextType` (`CrossOriginIsolatedContextType` enum) | **required** | **missing** |
| `frame.loaderId` | required, obscura sends ✓ | ok |
| `frame.mimeType` | required, obscura sends ✓ | ok |

Once a session is attached, every `Page.frameNavigated` obscura emits will also
trip `InvalidMessage`.

Other observations (non-fatal but worth noting):

- obscura's `CdpResponse` (`crates/obscura-cdp/src/types.rs:14`) carries `sessionId`
  on the success/error response itself. Chromium's CDP **does** include `sessionId`
  on responses to a session-scoped command, and chromiumoxide's `Response` struct
  doesn't have the field but doesn't reject it either — fine.
- obscura's `CdpEvent` puts `sessionId` at the top level — matches Chromium and
  matches `CdpEventMessage`'s custom deserializer. Good.
- obscura's `Browser.getVersion` fast path (`server.rs:596`) omits
  `protocol.Version.protocolVersion` capitalization — sends `"protocolVersion"`,
  which is what Chrome sends. Good.
- The HTTP `/json/version` endpoint correctly returns `webSocketDebuggerUrl`.
  Good — that's the only thing chromiumoxide needs to dial in.

## Recovery flow analysis (why "Created target not present")

1. `Handler::new` synthesises `Target.setDiscoverTargets{discover:true}` on connect
   (`handler/mod.rs:96`).
2. obscura replies with the `Target.targetCreated` for the synthetic `"browser"`
   target *and* a response. The `targetCreated` event fails to parse →
   `InvalidMessage` → dropped. `self.targets` stays empty.
3. User code calls `Browser.new_page` → `CreateTargetParams`. obscura sends
   `Target.targetCreated` (for `page-1`) and `Target.attachedToTarget` *before* the
   response (correct ordering per `server.rs:521` comment). Both events fail to
   parse for the same reason. Then the response arrives:
   `{"id":3,"result":{"targetId":"page-1"}}` — parsed fine as `Response`.
4. `on_response → PendingRequest::CreateTarget → self.targets.get_mut("page-1")` →
   `None` → `panic!("Created target not present")` (`handler/mod.rs:208`).

The author left a `// TODO can this even happen?` next to the panic. It can, when
the upstream event stream is silently filtered.

## Auxiliary observations

- chromiumoxide also sends `SetDiscoverTargets` *unconditionally* on startup. obscura
  handles it in `domains::target::handle` (`setDiscoverTargets`) — that path is fine
  on the request side. The reply event is what's broken.
- obscura's CDP server is **single-threaded** (one `cdp_processor` task on a
  `LocalSet`) and a long `Page.navigate` will starve `Target.getBrowserContexts`.
  obscura has a fast-path bypass for that (`server.rs:614`). Not a chromiumoxide
  problem, but worth knowing: chromiumoxide's `Handler` pipelines commands and
  has a 30 s default `request_timeout` (`handler/mod.rs:34`).
- obscura supports `flatten:true` on `attachToTarget` by always returning a flat
  `sessionId`. chromiumoxide 0.9 expects flat sessions exclusively. Good.

## Recommendation: option B (thin adapter) is the right call

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **A.** Replace chromiumoxide entirely with a hand-rolled `tokio-tungstenite` CDP client tailored to obscura. | Total control. No struct mismatches. | Re-implementing the parts of chromiumoxide we use (Page handle, navigate-with-lifecycle, evaluate, screenshot, network interception, target lifecycle, command-future timing) is **3–6 weeks**. Every future feature is bespoke. | ❌ over-budget |
| **B.** Keep chromiumoxide as the API surface, splice an adapter into the WS path that rewrites incoming events to satisfy chromiumoxide's PDL. Outgoing commands are already valid; only inbound `Target.*` and `Page.frameNavigated` need patching. | Smallest delta. Recovers without touching either vendor crate. Localised, testable. Buys us the panic fix today; future obscura/chromiumoxide upgrades require re-evaluating the patch list (~10 fields, not 1000). | Need a proxy WS hop (extra task & port) **or** a fork of chromiumoxide's `Connection` to inject a transform — the cleaner path is the proxy. Adds ~0.1 ms per message; irrelevant for scraping workloads. | ✅ **recommended** |
| **C.** Patch obscura's CDP server to emit Chrome-canonical fields (`canAccessOpener`, `secureContextType`, `crossOriginIsolatedContextType`, etc.). | Fixes the underlying interoperability. | Forbidden by this task (`vendor/` is read-only). Even if allowed, it doesn't compose with future chromiumoxide PDL bumps because every release pulls in new required fields. Upstream PR-and-wait cycle. | ❌ blocked by constraint |

### Recommended approach (B) — engineering plan

- **Component**: `rev-stealth/src/cdp_adapter.rs`.
- **Topology**: `chromiumoxide ⇄ tokio-tungstenite local proxy ⇄ obscura`.
  Spider connects chromiumoxide to `ws://127.0.0.1:PROXY/devtools/browser`.
  Proxy upstream-dials obscura. Each text frame is parsed as `serde_json::Value`,
  patched if it matches a known method, re-serialised, forwarded.
- **Patch rules**:
  1. Any `targetInfo` object → inject `canAccessOpener: false` if absent.
  2. `Page.frameNavigated.params.frame` → inject
     `secureContextType: "Secure"` and `crossOriginIsolatedContextType: "NotIsolated"`
     if absent (these are the safest defaults; both are valid enum variants).
  3. (Defensive) `targetInfo.browserContextId == ""` → drop the key so it
     deserialises as `None` rather than as an empty `BrowserContextId` newtype.
- **Out of scope**: outgoing commands need no patching; obscura's `CdpRequest`
  deserialiser (`types.rs:3`) accepts the wire format chromiumoxide sends.

#### Work estimate

| Task | Estimate |
|---|---|
| Implement proxy + patch rules | 0.5 day |
| Wire into `rev-stealth` spider startup (port selection, lifetime, shutdown) | 0.5 day |
| Tests (unit on the JSON rewriter, integration through `Browser::launch` + `new_page` + `navigate` against a real obscura) | 1 day |
| Buffer for unknown unknowns (more missing fields surfacing once we get past the panic — Network.requestWillBeSent etc.) | 1 day |
| **Total** | **3 person-days** |

#### Test strategy

1. **Unit**: golden JSON fixtures of obscura's actual output (captured in this
   investigation; see `/tmp/probe_ws.py` runs) → patched form → assert the patched
   form deserialises into `chromiumoxide_cdp::cdp::events::CdpEventMessage` via
   `serde_json::from_str`. This catches future obscura/chromiumoxide drift.
2. **Integration**: launch obscura subprocess + proxy, drive `Browser::launch` →
   `new_page` → `goto("about:blank")` → `goto(<test URL>)` → `evaluate("1+1")`.
   Must not panic, must return `2`.
3. **Regression watch**: when bumping either `chromiumoxide` or `vendor/obscura`,
   re-run the unit goldens; any new required field surfaces as a deserialisation
   error there, *before* it becomes a runtime panic.

## Appendix — raw transcripts

`Target.setDiscoverTargets` + `Target.getBrowserContexts` + `Target.createTarget`
+ `Target.attachToTarget` against obscura 0.1.0 on 19222 (see body of report
for the captured frames; `/tmp/probe_ws.py` reproduces).
