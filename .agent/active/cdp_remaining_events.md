# Phase 5e — Remaining `WS Invalid message` events (full enumeration)

Date: 2026-05-12
Target run:
`rev-stealth spider --url https://company.rev-c.com/blog/ --no-auto-fallback --format json`
chromiumoxide 0.9.1 + obscura (vendored).

## Method

1. Added a temporary inbound dumper in `crates/obscura-bridge/src/cdp_shim.rs`
   gated by env `REV_STEALTH_CDP_DUMP=<path>`. It appended every JSON frame
   chromiumoxide receives to `/tmp/cdp_all_inbound.jsonl` (reverted after capture).
2. Re-parsed each captured frame with the **exact** type chromiumoxide uses:
   `chromiumoxide_types::Message<chromiumoxide_cdp::cdp::events::CdpEventMessage>`
   (a temporary `examples/parse_inbound.rs`, also removed).
3. Cross-referenced each failing event against the typed struct in
   `~/.cargo/registry/src/index.crates.io-*/chromiumoxide_cdp-0.9.1/src/cdp.rs`.

## Result summary

- Captured frames: **103**
- Successfully deserialized: **57**
- `WS Invalid message` failures: **46**
- Unique offending event methods: **2** (matches the warning count exactly)

```
total=103  ok=57  fail=46
  Network.requestWillBeSent   x23
  Network.responseReceived    x23
```

No other Phase-5d-predicted methods (`Network.dataReceived`,
`Network.loadingFinished`, `Page.frameStarted*Loading`,
`Page.frameRequestedNavigation`, `DOM.*`, `Runtime.*`,
`Target.targetInfoChanged`) appear in obscura's inbound stream for this URL.
They will need patching only if/when obscura starts emitting them.

## Failing event 1 — `Network.requestWillBeSent` (23 occurrences)

`chromiumoxide_cdp` typed struct (`browser_protocol::network::EventRequestWillBeSent`).

obscura currently emits (sample):
```
params: { requestId, loaderId, documentURL, request{url,method,headers},
          timestamp, wallTime, initiator{type:"other"}, frameId, type:"Document" }
```

### Missing required fields on the event itself

| Field | Type | Recommended default | Notes |
|-------|------|---------------------|-------|
| `redirectHasExtraInfo` | `bool` | `false` | top-level required field |

### Missing required fields on nested `request: Request`

| Field | Type (`Network.Request`) | Recommended default |
|-------|--------------------------|---------------------|
| `initialPriority` | enum `ResourcePriority` (`VeryLow`/`Low`/`Medium`/`High`/`VeryHigh`) | `"Medium"` (matches Chrome for Document) |
| `referrerPolicy`  | enum `RequestReferrerPolicy` | `"no-referrer-when-downgrade"` |

`Initiator` is OK (only `type` is required; obscura sends `"other"`).

## Failing event 2 — `Network.responseReceived` (23 occurrences)

typed: `browser_protocol::network::EventResponseReceived`.

obscura currently emits (sample):
```
params: { requestId, loaderId, timestamp, type:"Document",
          response{url,status,statusText,headers,mimeType}, frameId }
```

### Missing required fields on the event itself

| Field | Type | Recommended default |
|-------|------|---------------------|
| `hasExtraInfo` | `bool` | `false` |

### Missing required fields on nested `response: Network.Response`

| Field | Type | Recommended default |
|-------|------|---------------------|
| `charset` | `String` | `""` |
| `connectionReused` | `bool` | `false` |
| `connectionId` | `f64`  | `0.0` |
| `encodedDataLength` | `f64` | `0.0` |
| `securityState` | enum `security::SecurityState` (`unknown`/`neutral`/`insecure`/`secure`/`info`/`insecure-broken`) | `"unknown"` |

All other `Response` fields are either present already (`url`, `status`,
`statusText`, `headers`, `mimeType`) or `Option<…>` / `skip_serializing_if`.

## Patch sketch (next phase)

Both events flow through `cdp_shim::patch_obscura_event`. Extend the match in
`crates/obscura-bridge/src/cdp_shim.rs`:

```rust
"Network.requestWillBeSent" => {
    if let Some(params) = json.get_mut("params").and_then(|p| p.as_object_mut()) {
        params.entry("redirectHasExtraInfo".into())
              .or_insert(Value::Bool(false));
        if let Some(req) = params.get_mut("request").and_then(|r| r.as_object_mut()) {
            req.entry("initialPriority".into())
               .or_insert(Value::String("Medium".into()));
            req.entry("referrerPolicy".into())
               .or_insert(Value::String("no-referrer-when-downgrade".into()));
        }
    }
}
"Network.responseReceived" => {
    if let Some(params) = json.get_mut("params").and_then(|p| p.as_object_mut()) {
        params.entry("hasExtraInfo".into()).or_insert(Value::Bool(false));
        if let Some(r) = params.get_mut("response").and_then(|r| r.as_object_mut()) {
            r.entry("charset".into()).or_insert(Value::String(String::new()));
            r.entry("connectionReused".into()).or_insert(Value::Bool(false));
            r.entry("connectionId".into()).or_insert_with(|| serde_json::json!(0.0));
            r.entry("encodedDataLength".into()).or_insert_with(|| serde_json::json!(0.0));
            r.entry("securityState".into()).or_insert(Value::String("unknown".into()));
        }
    }
}
```

Add 2 unit tests mirroring `test_patch_frame_navigated_injects_secure_context_type`.

## Effort estimate

Same magnitude as Phase 5d frame-tree patcher additions:
- code: ~30 lines in `patch_obscura_event`
- tests: 2 new unit tests (~40 lines)
- verification: re-run spider, assert 0 `WS Invalid` lines

Estimated effort: **~1.5 hours** total (implementation 30 min, tests 30 min,
verification + cleanup 30 min).
