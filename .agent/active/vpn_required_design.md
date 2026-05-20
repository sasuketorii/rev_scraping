# Phase 6b — VPN-Required Fail-Closed Guard + 3-Instance Rotation Design

Status: **DRAFT — Architecture only (no implementation in this phase).**
Author: Opus architect, Phase 6b.
Target user env:
```
VPN_PROVIDER=surfshark
VPN_COUNTRIES=Japan
VPN_INSTANCES=vpn-1:8001:8881, vpn-2:8002:8882, vpn-3:8003:8883
```
(container : http_proxy_port : control_port)

Existing primitives we build on:
- `crates/vpn-rotate/src/leak_guard.rs` — `LeakGuard` with kill-switch / DNS / IPv6 / exit-IP / country checks (complete; not wired).
- `crates/vpn-rotate/src/docker.rs` — bollard-backed rotate/status.
- `crates/obscura-bridge/src/config.rs` — `ObscuraConfig::proxy: Option<Url>` (received, not yet forwarded to chromiumoxide via obscura `--proxy`).
- `vendor/obscura/crates/obscura-cli/src/main.rs:189-217` — accepts `--proxy <url>` and forwards to chromiumoxide.
- `crates/stealth-cli/src/commands/spider.rs` — `--http-only` reqwest fallback path; **no VPN coupling today**.
- `crates/stealth-core/src/lib.rs:34-39` — `ExitCode {Ok=0, UserError=1, TransientError=2, PermanentError=3}`. **Exit 7 (leak) is new** and must be added.

---

## A. VPN-required policy enforcement

### Recommendation (Opus pick)
1. **CLI flag `--require-vpn` defaults to ON** for every fetcher subcommand (`spider`, `cf-evaluate`, `relocate --url`, future `browse`). Operators opt **out** with `--no-require-vpn` only after they explicitly acknowledge a leak risk. Default-ON matches the "fail-closed" charter and removes the most common human-error vector ("I forgot the flag").
2. **Config file `~/.rev_scraping/policy.toml`** is the *source of truth for site policy* (require_vpn, exit_country, allowed_fallbacks, max_concurrency). Loaded once at process start. CLI flag overrides the file; env var overrides both.
3. **Env var `REV_SCRAPING_REQUIRE_VPN=1`** is supported for CI / agent integration but is *advisory unless `--no-require-vpn` is also passed* — env cannot silently loosen policy, only enforce it.
4. **`--http-only` MUST also be routed through the VPN** when `require_vpn=true`. We attach a reqwest proxy (`http://127.0.0.1:<port>`) before any request. The "I'm just using reqwest" mental model is exactly how leaks happen.
5. **Override hierarchy** (highest first):
   - `REV_SCRAPING_REQUIRE_VPN=1` (cannot be loosened by lower layers)
   - `--no-require-vpn` CLI flag (rejected if env=1)
   - `policy.toml::require_vpn`
   - Built-in default = `true`

### Rejected
- Opt-in (`--require-vpn` defaults to OFF). Rejected: one missed flag = full IP exposure. The whole reason this phase exists is to remove that footgun.
- Per-fetcher policy. Rejected: a single `policy.toml` keeps it auditable; differential exposure across spider vs. http-only is precisely what we're fixing.

### Risks
- Default-ON breaks `cargo test` flows that hit localhost. Mitigation: localhost / RFC1918 targets bypass the proxy automatically (reqwest `no_proxy`) and the leak_guard probe is short-circuited via `REV_SCRAPING_TEST_BYPASS_VPN=1` (only honored in `cfg(test)` builds + when CARGO is present).

---

## B. `leak_guard` ↔ spider wiring

### Recommendation: **Plan 3 (probe at startup + background monitor)**
- **Startup probe** (sync, blocking the first request): on every fetcher invocation, *before* the first network egress, run `LeakGuard::probe_all()` against the instance(s) we plan to use. Fail → exit **7 (Leak)**, no requests sent.
- **Background monitor**: a `tokio::spawn`'d task polls leak_guard every 30 s. On failure it:
  1. Fires a `tokio::sync::Notify` (`vpn_down_notify`) consumed by every in-flight `RequestPipeline`.
  2. Calls `ObscuraBridge::force_kill()` so chromiumoxide cannot continue surfacing requests on the now-unguarded host network namespace.
  3. Sets a global `AtomicBool::vpn_down=true`; next request returns `StealthError::Leak` immediately.
- Exit 7 must be added to `ExitCode` (`Leak = 7`). Numeric gap from `PermanentError=3` is deliberate and reserves 4–6 for future categories.

### Blocker matrix (recommended)
| Check                        | Action      | Reason                                         |
| ---------------------------- | ----------- | ---------------------------------------------- |
| Exit IP country ≠ JP         | **BLOCK**   | Wrong egress = wrong identity hypothesis.      |
| Kill-switch off              | **BLOCK**   | Wireguard down would silently leak.            |
| DNS lock missing             | **BLOCK**   | DNS queries are the most common leak vector.   |
| IPv6 not disabled            | **BLOCK**   | Dual-stack hosts will route v6 around tunnel.  |
| WebRTC leak                  | **WARN**    | Obscura JS S6 patch already neutralizes RTC.   |
| Exit IP unreachable / 5xx    | **BLOCK**   | Indeterminate = treat as leak (fail-closed).   |

### Rejected
- Plan 1 alone (startup probe only): a Wireguard handshake can drop mid-scrape; we *will* leak between checks.
- Plan 2 alone (background only): an obviously-broken VPN should never get a first request through.

### Risks
- `ipinfo.io` rate limit on the country probe. Mitigation: cache the result for 60 s per instance; ratelimit-aware fallback to `ifconfig.co/json`.
- `force_kill` mid-page causes obscura artefacts. Acceptable: leak > corrupted artefact.

---

## C. 3-instance rotation strategy

### Recommendation
- **Default = sticky-by-session** with **lazy-on-fail fallover**. Each `session_id` (UUID minted in `ObscuraConfig`) is hash-pinned to one of {vpn-1, vpn-2, vpn-3} (`hash(session_id) % 3`). The session sticks unless leak_guard or a request-level failure trips fallover → next-best instance by health score.
- **Round-robin** is *not* the default. RR breaks Cloudflare session fingerprint coherence (one TLS session, multiple egress IPs) and reduces stealth.
- **Lazy-on-fail** semantics: keep instance until N=3 consecutive failures *or* health_check fails *or* leak_guard fails. Then jump to the next instance and increment a per-instance cooldown counter (60 s).
- **Concurrent scraping**: a global `InstancePool` (Arc<Mutex<Vec<InstanceHealth>>>) doles out instances to new sessions. Goal = roughly even (≤2× imbalance) but coherence > balance.

### Health-check frequency
- **Pre-flight (every new session bind)**: control-port `/v1/openvpn/status` round-trip, ≤200 ms.
- **Periodic (background, 30 s)**: leak_guard + control port for all 3 instances.
- **Per-request (cheap path)**: AtomicBool::healthy from the most recent background tick. *No* synchronous probe per request — that's a known throughput killer.

### Rejected
- Round-robin default (breaks session coherence).
- Pure session-sticky w/ no fallover (one dead instance kills 1/3 of work).

### Risks
- Hash skew (some user IDs map all to vpn-1). Mitigation: rendezvous-hash (HRW) instead of mod-3.

---

## D. reqwest fallback (`--http-only`) through VPN

### Recommendation
When `require_vpn=true`:
- Construct reqwest client with `.proxy(Proxy::all(format!("http://127.0.0.1:{port}"))?)`.
- Pick `<port>` via the **same `InstancePool` as the browser path**, so the same session hits the same egress whether it browser-renders or http-only-fetches.
- Set `.no_proxy(NoProxy::from_string("127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"))` so tests / health probes don't blow up.
- Verify exit IP **after** the proxy is attached but **before** the user's first URL request, via a single in-proxy probe to `ipinfo.io` (the same fetch reuses the leak_guard cache).

### Rejected
- Use raw host reqwest "for speed". This is the exact leak path the phase exists to close.

### Risks
- Gluetun HTTP proxy doesn't support CONNECT for HTTP/2 in some builds. Mitigation: pin Gluetun to a known-good tag in compose; CI smoke-tests CONNECT.

---

## E. obscura subprocess proxy wiring

### Findings (from `vendor/obscura/crates/obscura-cli/src/main.rs:189-217`)
- obscura-cli accepts `--proxy <url>` and forwards to chromiumoxide via `cmd.arg("--proxy").arg(p)`.
- Chromiumoxide passes it through to Chromium as `--proxy-server=<url>`, which Chromium honors for *all* fetches except `localhost` and explicit `--proxy-bypass-list` entries.

### Recommendation
- `obscura-bridge::ObscuraConfig::proxy` already plumbs through; the missing piece is `bridge.rs::launch()` forwarding the URL to `obscura-cli --proxy`. (One-line addition in Phase 6d; not part of 6b.)
- The proxy URL is set by `InstancePool::checkout(session_id) -> InstanceHandle { http_proxy_url, control_port, container }`.
- Same instance for browser and reqwest (see §D).
- Add `--proxy-bypass-list "127.0.0.1;localhost"` to obscura's `extra_args` to keep CDP self-loop unaffected.

### Risks
- Chromium leaks DNS over the proxy by default *unless* `--host-resolver-rules` is set; in our case Gluetun proxies DNS, so this is fine. Document the assumption.

---

## F. Failure-time behaviour

### Recommendation
- **VPN goes down mid-scrape**:
  - `vpn_down_notify.notify_waiters()` → in-flight pipelines see the next `select!` arm and return `StealthError::Leak`.
  - `ObscuraBridge::force_kill()` invoked immediately (SIGKILL the obscura subprocess); we trade a corrupted artefact for a guaranteed no-leak.
  - Process exits **7** (`Leak`). No automatic VPN restart from inside the scraper — operator restarts the Gluetun stack. (Rationale: an unattended retry loop that brings up a partly-broken VPN is itself a leak vector.)
- **Rotation failure**:
  - 1 instance fail → mark unhealthy (60 s cooldown), checkout next by HRW score.
  - All 3 fail leak_guard → exit **7** (Leak). All 3 reachable but rotation fails → exit **2** (Transient, retryable). Discriminator = leak_guard error vs. control-port error.
- **Retry**: exponential backoff inside a *single* instance (250 ms, 500 ms, 1 s, give up), but the *instance switch* is non-retried — it's a definitive policy decision.

### Rejected
- Auto-restart Gluetun from the scraper. Privilege creep + leak-during-restart risk.

---

## G. Test strategy

### Unit (CI, always)
- `MockLeakGuard` trait impl with scriptable verdicts — assert spider exits 7 on each blocker type.
- Mock `GluetunControl` returning health 200 / 503 / timeout — assert pool transitions instance state.
- Policy precedence: env > flag > file > default. Table-driven.

### Integration (CI, with `feature = "docker-mock"`)
- testcontainers + a fake Gluetun (nginx returning canned `/v1/openvpn/status`).

### E2E (`#[ignore]`, manual, gated by `REV_STEALTH_RUN_DOCKER_TESTS=1`)
- Real 3-instance compose up → `rev-stealth spider --require-vpn`. Manually `docker stop vpn-2` mid-run, assert fallover to vpn-1/vpn-3.
- Stop all 3, assert exit **7**.
- Country-mismatch test: set `VPN_COUNTRIES=Germany` while policy says JP — assert exit **7** before first request.

### CI matrix
- PR: unit + integration (mocked Docker). No external network beyond `ipinfo.io` mock.
- Nightly: spawn ephemeral Gluetun + run a small subset of #[ignore] tests (requires a CI runner with Docker-in-Docker and Surfshark creds-in-secret).
- Pre-release: full manual E2E sign-off.

---

## H. Phased rollout (~3.5 days)

### Phase 6c (~1 day) — Minimum viable fail-closed
- Add `ExitCode::Leak = 7` + `StealthError::Leak`.
- Add `policy.toml` loader + `--require-vpn` / `--no-require-vpn` flags to all fetcher subcommands.
- Wire `LeakGuard::probe_all()` at the top of each fetcher's `run()`. No background monitor yet.
- Default = require_vpn=ON, single hard-coded instance (vpn-1) for now.
- Unit tests for policy precedence + probe.

### Phase 6d (~2 days) — Rotation + proxy wiring
- `InstancePool` + HRW-sticky + lazy-on-fail.
- `ObscuraBridge::launch()` forwards `--proxy` to obscura-cli.
- reqwest fallback uses `Proxy::all` with `no_proxy` allowlist.
- Both paths share `InstancePool::checkout(session_id)`.
- Integration tests with mocked Gluetun.

### Phase 6e (~0.5 day) — Continuous monitoring
- Background `tokio::spawn` polling leak_guard every 30 s.
- `tokio::sync::Notify` shutdown propagation.
- `ObscuraBridge::force_kill()` on leak event.
- One #[ignore] E2E asserting force-kill works.

---

## Open questions (defer past 6b)
1. Per-target policy (some sites tolerate residential US exit, others demand JP) — needs `policy.toml` per-host stanza.
2. Captcha-bypass crate's outbound HTTP needs the same proxy treatment — confirm in 6d audit.
3. mobile-fp / 5G carrier IP plausibility vs. JP datacentre VPN ASN — flag for separate FP-coherence phase.
