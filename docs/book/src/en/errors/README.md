# Error troubleshooting

Every `rev-stealth` failure surfaces as an `ErrorEnvelope` with these
fields (defined in `crates/stealth-agent-contracts/src/error.rs`):

```rust,ignore
pub struct ErrorEnvelope {
    pub kind: ErrorKind,       // snake_case on the wire
    pub message: String,
    pub retryable: bool,
    pub hint: Option<String>,
    pub retry_after_ms: Option<u64>,
}
```

On the wire `kind` is the snake_case `wire_name` from the table below.
Each page also surfaces a `doc_url` produced by the MCP layer that
points to its troubleshooting page.

| Variant | wire `kind` | When emitted | Retryable? |
|---|---|---|---|
| [`Aup`](./Aup.md) | `aup` | Acceptable Use Policy violation (site / robots / contract). | no |
| [`Ssrf`](./Ssrf.md) | `ssrf` | Server-Side Request Forgery guard tripped (private/internal target). | no |
| [`VpnLeak`](./VpnLeak.md) | `vpn_leak` | VPN / egress IP leak detected — real IP would have been exposed. | yes |
| [`RateLimit`](./RateLimit.md) | `rate_limit` | Per-host or global rate limit exceeded. | yes |
| [`Timeout`](./Timeout.md) | `timeout` | Operation exceeded its timeout budget. | yes |
| [`Captcha`](./Captcha.md) | `captcha` | Captcha challenge encountered and not bypassable in current mode. | no |
| [`Auth`](./Auth.md) | `auth` | Authentication / authorization failure. | no |
| [`NotFound`](./NotFound.md) | `not_found` | Target resource not found. | no |
| [`Validation`](./Validation.md) | `validation` | Input validation failure. | no |
| [`Network`](./Network.md) | `network` | Lower-level network / transport failure. | yes |
| [`Internal`](./Internal.md) | `internal` | Unclassified internal error (last resort). | no |
| [`RecipeNotFound`](./RecipeNotFound.md) | `recipe_not_found` | Recipe lookup failed: the requested `domain` has no recipe on disk. | no |
| [`RecipeInvalid`](./RecipeInvalid.md) | `recipe_invalid` | Recipe payload (TOML/JSON) failed schema or semantic validation. | no |
| [`AuthSessionExpired`](./AuthSessionExpired.md) | `auth_session_expired` | `auth_login_complete` polled past `login_timeout` budget. | yes |
| [`AuthSessionNotFound`](./AuthSessionNotFound.md) | `auth_session_not_found` | `session_token` is unknown to the registry (never issued, GC'd, or already consumed). | no |
| [`AuthSessionPending`](./AuthSessionPending.md) | `auth_session_pending` | `session_token` exists but the login helper has not yet finished. | yes |
| [`VpnNotConfigured`](./VpnNotConfigured.md) | `vpn_not_configured` | VPN rotation requested but no VPN backend is configured. | no |
| [`VpnAllInstancesFailed`](./VpnAllInstancesFailed.md) | `vpn_all_instances_failed` | VPN rotation tried every configured instance and none came up. | yes |
| [`VpnCountryMismatch`](./VpnCountryMismatch.md) | `vpn_country_mismatch` | VPN egress is up but the resolved country does not match the requested `country` constraint. | yes |
| [`CdpProtocol`](./CdpProtocol.md) | `cdp_protocol` | Chrome DevTools Protocol returned an unexpected error code. | yes |
| [`CdpDisconnected`](./CdpDisconnected.md) | `cdp_disconnected` | CDP WebSocket disconnected before the operation completed. | yes |
| [`CdpInjectionFailed`](./CdpInjectionFailed.md) | `cdp_injection_failed` | Stealth JS injection into the target page failed. | yes |
| [`BrowserCrashed`](./BrowserCrashed.md) | `browser_crashed` | Headless browser process crashed mid-operation. | yes |
| [`BrowserNotFound`](./BrowserNotFound.md) | `browser_not_found` | Headless browser binary could not be located on PATH. | no |
| [`CookieDecryptFailed`](./CookieDecryptFailed.md) | `cookie_decrypt_failed` | On-disk cookie store could not be decrypted (bad passphrase / corruption). | no |
| [`Aborted`](./Aborted.md) | `aborted` | Operation cancelled by caller (e.g. shutdown signal). | yes |
