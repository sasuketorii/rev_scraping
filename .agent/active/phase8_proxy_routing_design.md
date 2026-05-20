# Phase 8 — Per-Site Proxy Routing Design

Status: design draft (no code yet)
Author: architect agent
Date: 2026-05-13
Schema version target: `policy.toml` v2, `authorized.toml` v2, `sites/*.toml` schema_version = 2
Backward-compat: **mandatory**. A pre-Phase-8 `policy.toml` / `authorized.toml` / recipe MUST load unchanged and behave exactly as in Phase 6d/F.

---

## 0. Goals & non-goals

**Goal.** Allow each authorized target URL to be reached via a *different* proxy egress (direct / Surfshark pool / Cloudflare WARP / commercial residential like IPRoyal), declared in `policy.toml` + `authorized.toml`, learnable into recipes, with zero added cost until an operator opts a paid tier in via env vars.

**Non-goals.**
- Auto-purchasing residential IPs.
- Geo-shopping individual exit IPs per request (provider does that).
- Replacing Phase 6 VPN enforcement (`require_vpn` semantics stay intact; Surfshark stays the default "vpn" tier).
- TLS/JA3 rotation (mobile-fp handles that orthogonally).

---

## A. `policy.toml` `[proxies.*]` schema

A new top-level table-of-tables. Each named entry is a "proxy tier slot". Keys are arbitrary identifiers used elsewhere by name. Reserved names: `direct` (always present implicitly, may be redefined only to attach `no_proxy`), `auto` (forbidden — `auto` is a *resolution mode*, not a tier).

### A.1 Schema

```toml
[proxies.direct]
type = "none"
no_proxy = ["localhost", "127.0.0.1", "*.lan"]   # optional
strength = "none"                                 # required for resolver gate

[proxies.surfshark]
type = "http-pool"                                # reuses InstancePool
instances_from = "policy.vpn_instances"           # symbolic ref, only legal value in v2
strength = "datacenter"                           # Surfshark = commercial DC

[proxies.warp]
type = "socks5"
url = "socks5://127.0.0.1:40000"                  # warp-cli mode proxy
no_proxy = []
strength = "datacenter"                           # WARP = Cloudflare DC

[proxies.iproyal]
type = "http"
url = "http://${IPROYAL_USER}:${IPROYAL_PASS}@residential.iproyal.com:12321"
auth_env = ["IPROYAL_USER", "IPROYAL_PASS"]       # required env vars; missing = tier disabled
rotation = "per-session"                          # one of: per-request | per-session | sticky
country_filter = ["JP", "US"]                     # provider-side username param
strength = "residential"
enabled_by_default = false                        # paid tiers MUST default false
```

### A.2 Field reference

| field | type | required | notes |
|---|---|---|---|
| `type` | enum | yes | `none` \| `http` \| `socks5` \| `http-pool` |
| `url` | string | iff `type ∈ {http, socks5}` | may contain `${VAR}` placeholders; `${VAR}` resolved from process env only |
| `instances_from` | string | iff `type = http-pool` | only `"policy.vpn_instances"` accepted in v2 |
| `auth_env` | `[string]` | optional | env var names that, if listed, MUST exist & be non-empty at load time or the tier is marked `disabled_missing_secret` |
| `no_proxy` | `[string]` | optional | host glob list |
| `rotation` | enum | optional, default `per-session` | informational; per-request rotation requires provider support |
| `country_filter` | `[string]` | optional | informational; passed to provider via username syntax (provider-specific, document only) |
| `strength` | enum | yes | `none` \| `datacenter` \| `residential` \| `mobile` |
| `enabled_by_default` | bool | optional, default `true` | paid tiers must set `false`; resolver only activates if env vars present **and** explicit `proxy_tier` reference or fallback inclusion |

### A.3 Hard schema rules (validated at load)

1. **Secret reject.** Any literal `http(s)://user:pass@…` URL where `user`/`pass` does not match `^\$\{[A-Z0-9_]+\}$` is **rejected with exit 2**. The same `secret_reject` validator already used by `stealth-sites` (per Phase 6 notes) is invoked.
2. `${VAR}` interpolation reads `std::env::var` exactly once at load. Missing var on a `enabled_by_default=false` tier → tier disabled (resolver returns "tier not configured"). Missing var on `enabled_by_default=true` tier → exit 2.
3. Resolved secret values live in memory only. The `Debug` impl on the proxy config struct redacts userinfo (`http://***:***@host:port`).
4. The reserved name `auto` MUST NOT appear under `[proxies.*]`.
5. `strength` ordering: `none < datacenter < residential < mobile`. Used by §H gate.

---

## B. `authorized.toml` `proxy_tier` + `min_proxy_strength`

```toml
[[targets]]
url_pattern = "^https://api\\.example\\.com/.*$"
owner = "Sasuke Torii (user-confirmed)"
authorization_doc = "..."
proxy_tier = "surfshark"            # default if omitted: "auto"
min_proxy_strength = "datacenter"   # default if omitted: "none"

[[targets]]
url_pattern = "^https://cloudflare-strict\\.example\\.com/.*$"
proxy_tier = "iproyal"
min_proxy_strength = "residential"

[[targets]]
url_pattern = "^https://internal\\.lan/.*$"
proxy_tier = "direct"
min_proxy_strength = "none"
```

- `proxy_tier`: either a named slot from `[proxies.*]` **or** the literal string `"auto"`.
- Omitted `proxy_tier` ⇒ treat as `"auto"`.
- Omitted `min_proxy_strength` ⇒ `"none"` (no gate).
- Resolver rejects (exit 2) if `proxy_tier`'s strength < `min_proxy_strength` *unless* `proxy_tier = "auto"` (in which case the resolver filters the fallback chain to only tiers meeting the floor).
- Multiple matching `[[targets]]` rows: longest `url_pattern` wins; on tie, first-defined wins. Document explicitly.

---

## C. Fallback chain

```toml
[fallback_chain]
auto = ["direct", "surfshark", "warp"]
fail_signals = ["timeout", "http_403", "http_429", "tls_handshake_failed", "connection_refused"]
max_attempts_per_tier = 1
cooldown_ms_between_tiers = 250
```

Rules:
1. Paid tiers (`enabled_by_default = false`) are **never** silently added to `auto`. If an operator wants `iproyal` in auto, they must list it here explicitly *and* set the env vars.
2. The list is filtered at runtime against (a) `min_proxy_strength` of the matched target and (b) tier availability (env vars present, pool healthy, etc.).
3. `fail_signals` is the exact set that triggers tier advancement. Anything else (e.g. `http_500`) is returned to the caller without rotating.
4. `--no-fallback` CLI flag forces single-tier attempt.
5. Default omitted ⇒ built-in `["direct", "surfshark"]` (Phase 6d behaviour).

---

## D. Rust API design

**Decision: extend existing `vpn-rotate` crate, do NOT create `stealth-proxy`.**

Rationale:
- `vpn-rotate::instance_pool::InstancePool` already owns the only pool concept we need.
- A new crate would force a circular dep (resolver needs `policy::Policy` from `stealth-cli`, pool from `vpn-rotate`) or a third shared crate just for types — overkill.
- Surfshark tier *is* the existing InstancePool; renaming it to "one tier among many" inside `vpn-rotate` is a natural refactor.
- Rename plan: `vpn-rotate` keeps its name (no breaking rename), but gains a `proxy_resolver` module. The crate now means "egress routing", with VPN as one subcategory.

### D.1 New module `vpn-rotate::proxy_resolver`

```rust
pub struct ProxyResolver {
    policy_proxies: BTreeMap<String, TierConfig>,   // resolved at load (secrets in memory)
    authorized: AuthorizedTargets,                  // already loaded elsewhere
    fallback_chain: FallbackChain,
    surfshark_pool: Option<InstancePool>,           // built once
}

pub enum ProxyKind { None, Http, Socks5, HttpPool }
pub enum ProxyStrength { None, Datacenter, Residential, Mobile }

pub struct ProxySelection {
    pub tier_name: String,
    pub proxy_kind: ProxyKind,
    pub proxy_url: Option<Url>,                     // resolved, secrets baked in
    pub no_proxy: Vec<String>,
    pub strength: ProxyStrength,
    pub from_session_cache: bool,
    pub source: SelectionSource,                    // Explicit | RecipeRecommendation | AutoFallback(idx)
}

pub enum FailSignal { Timeout, Http403, Http429, TlsHandshakeFailed, ConnectionRefused }

impl ProxyResolver {
    pub fn load(policy: &Policy, authorized: &AuthorizedTargets) -> Result<Self, ProxyResolverError>;
    pub fn resolve(&self, url: &Url, session_id: &str, forced_tier: Option<&str>) -> Result<ProxySelection, ResolveError>;
    pub fn next_fallback(&self, url: &Url, session_id: &str, failed_tier: &str, signal: FailSignal) -> Option<ProxySelection>;
    pub fn tier_strength(&self, tier_name: &str) -> Option<ProxyStrength>;
}
```

### D.2 Compat shim

`vpn_selector::Selection` (the existing struct in `stealth-cli/src/vpn_selector.rs`) gets a `From<ProxySelection>` impl. The old `select(...)` keeps its signature; internally it becomes:

```rust
pub fn select(pool, session_id, forced_name) -> Option<Selection>
  // unchanged: still resolves a Surfshark instance only
```

A *new* function lives alongside:

```rust
pub fn select_with_resolver(resolver, url, session_id, forced_tier) -> Option<Selection>
```

Phase 8 commands call the new fn; Phase 6 callers (if any remain unconverted) keep working.

### D.3 Error semantics

| condition | exit | message |
|---|---|---|
| secret in literal URL | 2 | "policy.toml proxy.<name>.url contains secret; use ${ENV}" |
| `auth_env` var missing on `enabled_by_default=true` tier | 2 | "proxy tier <name> requires env <VAR>" |
| `auth_env` var missing on `enabled_by_default=false` tier | n/a | tier silently `Disabled` |
| `proxy_tier = "xyz"` not in `[proxies.*]` | 2 | unknown tier |
| resolved strength < `min_proxy_strength` | 2 | "tier <name> strength=<X> below required <Y>" |
| `auto` fallback exhausted, last attempt failed | 8 | new exit code: "all proxy tiers failed" |

Exit code 7 (Leak) is preserved for VPN-required violations exactly as in Phase 6.

---

## E. CLI integration (spider / cf-evaluate / relocate)

### E.1 New flags

| flag | meaning | conflicts |
|---|---|---|
| `--proxy-tier <NAME\|auto>` | force tier; `auto` = use fallback chain | mutually exclusive with `--vpn-instance` |
| `--no-fallback` | disable chain; one attempt | — |
| `--proxy-tier-list` | print resolved `[proxies.*]` table + status, exit 0 | — |

### E.2 `--vpn-instance` legacy behaviour

Treated as syntactic sugar for `--proxy-tier surfshark` + pin within Surfshark pool. If both `--vpn-instance` and `--proxy-tier` are given and `--proxy-tier != surfshark`, exit 2.

### E.3 Result envelope additions

```json
{
  "...": "...",
  "proxy_tier_used": "surfshark",
  "proxy_tier_strength": "datacenter",
  "proxy_tier_source": "auto_fallback",
  "proxy_tier_attempts": [
    {"name": "direct", "signal": "http_403", "latency_ms": 412},
    {"name": "surfshark", "signal": null, "latency_ms": 1180}
  ],
  "vpn_instance_used": "vpn-2"
}
```

`vpn_instance_used` is retained for back-compat and is only populated when `tier_used = "surfshark"`.

---

## F. Recipe auto-learn

Add to `SiteRecipe::scraping_strategy`:

```rust
pub struct ScrapingStrategy {
    // existing...
    pub proxy_tier_recommended: Option<String>,
    pub proxy_tier_blacklist: Vec<String>,
    pub proxy_tier_last_learned_at: Option<DateTime<Utc>>,
}
```

Learning rules:
1. Triggered only when `proxy_tier = "auto"` was the input (explicit selections do not mutate recipes).
2. On success at tier `T` after fallback: upsert `proxy_tier_recommended = T`, set timestamp.
3. On hard fail at tier `T` (consumed a `fail_signal`): append `T` to `proxy_tier_blacklist` (dedup). The blacklist is *advisory* — resolver demotes blacklisted tiers in `auto` but does not skip them entirely (they may have recovered).
4. Blacklist entries auto-expire after 14 days (timestamp on each entry: store as `[{name, observed_at}]`, not bare strings — schema for entries detailed in templates).
5. Recipe-recommended tier is used as the *first* candidate in auto chain, overriding `[fallback_chain] auto`'s normal order, but still filtered by `min_proxy_strength` and tier availability.

Schema bump for recipes: `schema_version = 2`. Loader accepts v1 (treats new fields as `None`/empty).

---

## G. Test strategy

### G.1 Unit (no network)

- `ProxyResolver::load`:
  - rejects literal-secret URLs
  - resolves `${VAR}` from process env (use `temp_env` crate or scoped setter)
  - disables paid tier when env missing, errors on default-on tier with missing env
- `resolve()`:
  - explicit `proxy_tier` always wins
  - `auto` honours recipe recommendation if provided via injected recipe lookup
  - `min_proxy_strength` enforcement (both explicit-reject and auto-filter paths)
  - longest-pattern-wins authorization match
- `next_fallback()`: walks chain, skips disabled tiers, returns None when exhausted

### G.2 Integration `#[ignore]` (localhost fakes)

- Fake socks5 server (use `fast-socks5` or hand-rolled) at 127.0.0.1:random → assert WARP-tier wiring carries through reqwest correctly.
- Fake HTTP CONNECT proxy at 127.0.0.1:random → assert IPRoyal-style auth header is sent.
- Surfshark tier: spin up existing InstancePool against a stub HTTP CONNECT proxy.

### G.3 E2E (`#[ignore]`, manual)

- `rev-stealth spider --url https://example.com/... --proxy-tier auto` → asserts:
  - first attempt direct → 403
  - fallback surfshark → 200
  - recipe `~/.rev_scraping/sites/example.com.toml` gains `proxy_tier_recommended = "surfshark"`
  - second invocation: `proxy_tier_attempts[0].name == "surfshark"` (skipped direct)

### G.4 Negative tests

- policy.toml with `[proxies.iproyal] url = "http://user:pass@..."` → exit 2 at load
- authorized.toml with `proxy_tier = "ghost"` → exit 2 at resolve
- `min_proxy_strength = "residential"` + `proxy_tier = "surfshark"` → exit 2
- existing Phase 6 policy.toml (no `[proxies.*]`, no `[fallback_chain]`) → loads, behaves as `proxies = {direct, surfshark}` and `fallback_chain.auto = ["direct", "surfshark"]`

---

## H. Security / privacy

### H.1 `min_proxy_strength` gate

Authorized.toml may specify the floor (§B). Resolver enforces it for *every* tier it would select, including all fallback steps. A blacklisted-but-passing tier still must pass the gate.

### H.2 Secret handling

- env-only interpolation, never disk persistence
- redacted `Debug` / `Display` on all proxy URL fields
- the resolved tier table is **not** written to JSON envelope's `proxy_url` — only the tier *name* leaks out
- `--proxy-tier-list` redacts userinfo
- `~/.rev_scraping/sessions/*.json` never contains proxy URLs (only tier name + instance name for Surfshark)

### H.3 Misconfiguration safety net

- If `require_vpn = true` and resolver picks `direct` for a non-LAN URL, exit 7 (Leak) — `direct` only allowed when (a) `min_proxy_strength = none` AND (b) target host matches a `no_proxy` glob OR `require_vpn = false`.
- WARP tier is NOT a substitute for VPN tier under `require_vpn = true` unless the operator explicitly adds `warp` to `[fallback_chain] auto`. Document loudly.

### H.4 Logging

- Per-attempt log line includes tier name + outcome + latency, never the proxy URL.
- Failure signals are categorical (the enum in §D), no raw error strings to logs at INFO level.

---

## I. Provider prerequisites

### I.1 Cloudflare WARP

```
brew install cloudflare-warp
warp-cli registration new
warp-cli mode proxy
warp-cli proxy port 40000
warp-cli connect
```

Phase 8 README will note: not auto-installed, not auto-started. Resolver does a single TCP-connect health check on first use and marks WARP disabled if down (with a log line, no exit).

### I.2 IPRoyal (residential)

```
export IPROYAL_USER='your-username'
export IPROYAL_PASS='your-password'
```

Endpoint, port, country syntax: documented inline in the `policy.toml` template comment. Resolver does NOT validate credentials at load (would leak presence info to the provider on every command invocation); first real request is the credential test.

### I.3 Other providers

Bright Data, Oxylabs, Smartproxy: same schema (`type = "http"`, `auth_env = [...]`, `url` with `${VAR}` placeholders). Documented as additional examples in template. No implementation difference.

---

## J. Migration plan

### J.1 Phase ordering (sub-phases)

| sub | scope | parallelizable | depends on |
|---|---|---|---|
| 8a | `vpn-rotate::proxy_resolver` types + policy/authorized loader (no CLI) | — | none |
| 8b | `[fallback_chain]` schema + `resolve()` + `next_fallback()` | with 8c | 8a |
| 8c | `vpn_selector` compat shim + Surfshark tier wiring through resolver | with 8b | 8a |
| 8d | `--proxy-tier` flag in spider/cf-evaluate/relocate + JSON envelope | sequential | 8b, 8c |
| 8e | recipe `proxy_tier_recommended/blacklist` + auto-learn writeback | — | 8d |
| 8f | WARP integration test + docs | parallel with 8e | 8d |
| 8g | IPRoyal integration test + docs (`#[ignore]`) | parallel with 8e | 8d |

8a is the chokepoint. 8b+8c can run as two Codex tasks once 8a lands. 8d serializes after both. 8e/8f/8g fan out.

### J.2 Backward compat guarantees

- Existing `policy.toml` without `[proxies.*]` / `[fallback_chain]` loads. Resolver synthesises:
  - `[proxies.direct] type=none strength=none`
  - `[proxies.surfshark] type=http-pool instances_from="policy.vpn_instances" strength=datacenter` (only if `vpn_instances` non-empty)
  - `[fallback_chain] auto = ["direct", "surfshark"]` (Phase 6d behaviour) when `require_vpn=false`, or `["surfshark"]` when `require_vpn=true`.
- Existing `authorized.toml` without `proxy_tier` ⇒ implicit `"auto"`, `min_proxy_strength = "none"`.
- Existing recipes (schema_version=1) load; new fields default to None/empty.
- Existing `--vpn-instance` continues to work (§E.2).
- All existing tests must pass unchanged. The compat-synthesis tests are added new.

### J.3 Documentation deliverables (out of scope for this design, listed for tracking)

- `README.md` "Phase 8 proxy tiers" section
- `docs/proxy_routing.md` operator guide (WARP & IPRoyal setup)
- `docs/security.md` update: `min_proxy_strength` semantics

---

## K. Open questions for sub-phase Codex prompts

1. `instances_from` extensibility: do we anticipate non-Surfshark http-pools (e.g. a second VPN provider with its own InstancePool)? Phase 8 says no — v2 only accepts `"policy.vpn_instances"`. Re-evaluate Phase 9.
2. `rotation = "per-request"`: requires either provider sticky-session URL syntax (provider-specific) or a `reqwest::Client` rebuild per request (perf hit). Phase 8 ships `per-session` only; `per-request` rejected at load with TODO marker.
3. Recipe blacklist expiry: 14d hardcoded vs `[fallback_chain] blacklist_ttl_days`. Defer to 8e implementer; default 14.
4. Should `--proxy-tier-list` probe each tier (TCP-connect)? Yes for `none`/`http`/`socks5`; for `http-pool`, reuse existing pool health. Mark slow tiers with `slow_probe_ms`.
