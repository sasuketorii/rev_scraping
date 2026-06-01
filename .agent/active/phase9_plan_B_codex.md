# Phase 9 ExecPlan B: Authenticated Session Capture for rev_scraping
Date: 2026-05-14
Repository: `$REPO_ROOT`
Scope: CLI + MCP server workspace, not a Tauri GUI app.
This is an independent implementation design for bringing authenticated session capture to `rev_scraping`.
The goal is a human-in-the-loop login flow that captures post-auth cookies, encrypts them locally, and reuses them for HTTP and CDP scrape paths.
The stance is explicit: this feature is for the user's own accounts on systems they are authorized to access.
The feature stores session cookies, not passwords, passkeys, TOTP secrets, or recovery codes.
Primary recommendation table:
| Area | Decision |
|---|---|
| Launch mode | **Separate `rev-auth` helper binary**, invoked by `rev-scraping auth login` |
| Local fallback | **Manual cookie import** for CI and passkey-bound browser cases |
| Cookie storage | **Encrypted per-profile jar** under XDG config |
| AEAD | **`chacha20poly1305 = "0.10"`** |
| Key source | **`keyring = "3"`** with OS keystore backends |
| Serialization | **Custom `PersistedCookieJarV1`**, converted to/from `cookie_store` |
| HTTP reuse | **`reqwest::ClientBuilder::cookie_provider(...)`** |
| CDP reuse | **`Network.setCookies` before navigation** |
| Proxy policy | **Require same login/scrape proxy route by default** |
| MCP policy | **No cookie export or reveal over MCP** |
| Auto-refresh | **Manual headed refresh only** |
Assumptions:
| Item | Assumption |
|---|---|
| Rust edition | Rust 2024 |
| Runtime | Existing Tokio runtime |
| Browser | Existing `chromiumoxide` and `obscura` layers |
| HTTP | Existing `reqwest`, add/enable `cookies` feature if needed |
| Sites | Existing `stealth-sites` recipes |
| Proxy | Phase 8 resolver owns AUP allowlist, VPN-required policy, SSRF guard |
| Config | XDG config dir, fallback to `~/.config/rev_scraping` |
## A. UX / Launch modes
Phase 9 needs a local workflow that supports real human login, including 2FA, SMS, passkeys, and CAPTCHA.
It also needs a non-interactive fallback for CI and environments where a headed browser is impossible.
Option 1: headed obscura.
```text
rev-scraping auth login personal --url https://example.com/login --mode headed-obscura
```
The existing `obscura` browser stack is temporarily started with `headless=false`.
The user logs in in the live Chromium window.
On close or confirmation, the implementation calls CDP `Network.getAllCookies`.
```rust
pub async fn login_with_headed_obscura(
    req: AuthLoginRequest,
    browser_factory: Arc<dyn ObscuraBrowserFactory>,
) -> anyhow::Result<AuthCaptureResult>;
```
Assessment: medium discoverability, low friction, high 2FA compatibility, medium multi-account isolation, poor headless-CI fit, high scrape-environment fidelity.
Recommendation: **use as internal capture path, not the main boundary**.
Option 2: separate auth helper binary.
```text
rev-scraping auth login personal --url https://example.com/login --site x --proxy jp-res
rev-auth login personal --url https://example.com/login --site x --proxy jp-res
```
`rev-scraping auth login` is canonical.
`rev-auth` is the isolated helper process that owns the temporary headed browser.
```rust
pub async fn run_auth_helper(args: RevAuthArgs) -> anyhow::Result<std::process::ExitCode>;
```
Assessment: high discoverability, low friction, high 2FA compatibility, high multi-account isolation, medium CI fit, strong process boundary, medium packaging cost.
Recommendation: **adopt as default**.
Option 3: manual cookie import.
```text
rev-scraping auth import personal --format netscape --file cookies.txt
rev-scraping auth import personal --format json --file cookies.json
```
The user exports cookies from a browser extension or DevTools path.
The tool ingests Netscape cookies.txt or JSON and immediately encrypts the jar.
```rust
pub fn import_cookie_file(
    profile: &AuthProfileName,
    format: CookieImportFormat,
    input: impl std::io::Read,
    policy: &AuthImportPolicy,
) -> anyhow::Result<AuthImportReport>;
```
Assessment: medium discoverability, high friction, indirect 2FA support, strong passkey fallback, high multi-account and CI fit, higher plaintext exposure before import.
Recommendation: **support as fallback and CI path**.
Final UX recommendation:
```text
Default: `rev-scraping auth login` -> launches isolated `rev-auth` helper.
Fallback: `auth import` for CI, passkey-bound browser sessions, or no display server.
Diagnostic: `--mode headed-obscura` may directly use the existing browser layer.
```
## B. Cookie storage
Store encrypted jars at:
```text
~/.config/rev_scraping/auth/<profile>.jar.enc
~/.config/rev_scraping/auth/<profile>.meta.json
~/.config/rev_scraping/auth/audit.log
```
Use XDG resolution:
```rust
pub fn auth_config_dir() -> anyhow::Result<PathBuf>;
pub fn profile_jar_path(profile: &AuthProfileName) -> anyhow::Result<PathBuf>;
```
Encryption recommendation:
| Item | Choice |
|---|---|
| AEAD crate | **`chacha20poly1305 = "0.10"`** |
| Key size | 256-bit |
| Nonce | 96-bit random nonce per save |
| AAD | `rev_scraping:stealth-auth:v1:<profile>` |
| Plaintext buffer | `zeroize::Zeroizing<Vec<u8>>` |
OS keystore recommendation:
| Platform | Backend |
|---|---|
| macOS | Keychain via `keyring = "3"` |
| Linux desktop | libsecret via `keyring = "3"` |
| Linux headless | fail closed unless explicit CI fixture key is configured |
| Windows | Credential Manager / DPAPI via `keyring = "3"` |
Per-profile key interface:
```rust
pub trait KeyStore: Send + Sync {
    fn load_key(&self, profile: &AuthProfileName) -> anyhow::Result<zeroize::Zeroizing<[u8; 32]>>;
    fn create_key(&self, profile: &AuthProfileName) -> anyhow::Result<zeroize::Zeroizing<[u8; 32]>>;
    fn delete_key(&self, profile: &AuthProfileName) -> anyhow::Result<()>;
}
```
Use service and account names:
```rust
pub const KEYRING_SERVICE: &str = "rev_scraping.stealth_auth";
pub fn keyring_account(profile: &AuthProfileName) -> String {
    format!("cookie-jar:{}", profile.as_str())
}
```
Serialization recommendation:
| Option | Trade-off |
|---|---|
| `cookie_store::CookieStore` JSON | Fast, but crate-owned schema |
| Custom schema | More code, stable format, explicit metadata |
| Netscape inside envelope | Portable, loses modern attributes |
Choose **custom `PersistedCookieJarV1`** and convert to `cookie_store::CookieStore` for HTTP.
```rust
#[derive(serde::Serialize, serde::Deserialize)]
pub struct PersistedCookieJarV1 { pub version: u16, pub profile: String, pub cookies: Vec<PersistedCookieV1>, pub browser: BrowserReplayMetadata, pub route: AuthRouteBinding, pub lifecycle: AuthLifecycleMetadata }
#[derive(serde::Serialize, serde::Deserialize)]
pub struct PersistedCookieV1 { pub name: String, pub value: SecretCookieValue, pub domain: String, pub path: String, pub expires_at: Option<time::OffsetDateTime>, pub secure: bool, pub http_only: bool, pub same_site: Option<SameSiteMode>, pub priority: Option<CookiePriority>, pub source_scheme: Option<CookieSourceScheme>, pub partition_key: Option<CookiePartitionKey>, pub host_only: bool }
```
Required concrete API:
```rust
pub struct EncryptedCookieJar {
    profile: AuthProfileName,
    path: PathBuf,
    plaintext: PersistedCookieJarV1,
    keystore: Arc<dyn KeyStore>,
}
impl EncryptedCookieJar {
    pub fn load(profile: &str) -> anyhow::Result<Self>;
    pub fn save(&self) -> anyhow::Result<()>;
    pub fn merge_from_cdp(&mut self, cdp_cookies: Vec<CdpCookie>) -> anyhow::Result<()>;
    pub fn to_reqwest_jar(&self) -> anyhow::Result<Arc<dyn reqwest::cookie::CookieStore + Send + Sync>>;
}
```
CDP cookie type:
```rust
pub struct CdpCookie { pub name: String, pub value: SecretCookieValue, pub domain: String, pub path: String, pub expires: Option<f64>, pub http_only: bool, pub secure: bool, pub session: bool, pub same_site: Option<SameSiteMode>, pub priority: Option<CookiePriority>, pub source_scheme: Option<CookieSourceScheme>, pub partition_key: Option<CookiePartitionKey> }
```
Atomic write policy:
```text
serialize -> encrypt -> write temp -> chmod 0600 -> fsync file -> atomic rename -> fsync parent
```
Envelope:
```rust
pub struct EncryptedJarEnvelopeV1 { pub magic: [u8; 8], pub version: u16, pub profile_hash: [u8; 32], pub nonce: [u8; 12], pub ciphertext: Vec<u8>, pub created_at: time::OffsetDateTime }
```
Plaintext zeroization rules:
| Secret | Type |
|---|---|
| AEAD key | `zeroize::Zeroizing<[u8; 32]>` |
| serialized jar | `zeroize::Zeroizing<Vec<u8>>` |
| cookie value | `SecretCookieValue` with `ZeroizeOnDrop` |
| export buffer | `zeroize::Zeroizing<Vec<u8>>` |
## C. Lifecycle
Cookie state must be visible to users and orchestrators.
Do not hide stale sessions behind generic scrape errors.
Expiry summary:
```rust
pub struct CookieExpirySummary {
    pub total: usize,
    pub expired: usize,
    pub session: usize,
    pub persistent: usize,
    pub next_expiry_at: Option<time::OffsetDateTime>,
    pub warning: Option<AuthExpiryWarning>,
}
```
Warn-before-expiry threshold:
```rust
pub const DEFAULT_WARN_BEFORE_EXPIRY: time::Duration = time::Duration::days(7);
```
Recommendation: **warn when the earliest required cookie expires within seven days**.
Session-cookie policy options:
| Option | Behavior | Recommendation |
|---|---|---|
| Drop on save | safest, breaks many sessions | No |
| Persist forever | convenient, too sticky | No |
| Persist until delete/stale | balanced | **Yes** |
Default:
```rust
pub enum SessionCookiePolicy {
    PersistUntilDelete,
    DropOnProcessExit,
    DropAfter(time::Duration),
}
```
Use `SessionCookiePolicy::PersistUntilDelete`.
Lifecycle metadata:
```rust
pub struct AuthLifecycleMetadata {
    pub last_verified_at: Option<time::OffsetDateTime>,
    pub last_login_at: time::OffsetDateTime,
    pub stale_reason: Option<AuthStaleReason>,
    pub source_login_url: String,
    pub probe_url: Option<String>,
    pub required_cookies: Vec<String>,
}
```
Stale reason type:
```rust
pub enum AuthStaleReason {
    ExpiredCookie { name_hash: String },
    MissingRequiredCookie { name: String },
    HttpUnauthorized,
    HttpForbidden,
    RedirectedToLogin { location_host: String },
    LoginFormDetected { selector: String },
    ProxyBindingMismatch { expected: String, actual: String },
    ProbeFailed { status: u16 },
    ManualInvalidation,
}
```
Auth probe contract:
```rust
pub async fn probe_auth_status(
    session: &AuthenticatedSession,
    recipe: &AuthRecipe,
    route: &ResolvedProxyRoute,
) -> anyhow::Result<AuthProbeReport>;
```
Stale heuristics:
| Signal | Confidence |
|---|---|
| HTTP 401 | High |
| HTTP 403 after previously fresh profile | Medium |
| redirect to recipe login URL | High |
| login form selector detected | High |
| required cookie missing | High |
| `Set-Cookie` deletes required cookie | High |
| proxy route mismatch | High |
CLI output should say:
```text
profile: personal
status: stale
reason: redirected to login host login.example.com
action: run `rev-scraping auth refresh personal --site example`
```
## D. Application layer
HTTP and CDP paths must both replay cookies with the browser metadata captured at login time.
User-Agent and Accept-Language mismatches are common causes of invalidated sessions.
Authenticated session type:
```rust
pub struct AuthenticatedSession {
    pub profile: AuthProfileName,
    pub jar: Arc<dyn reqwest::cookie::CookieStore + Send + Sync>,
    pub browser: BrowserReplayMetadata,
    pub route: AuthRouteBinding,
}
```
Browser metadata:
```rust
pub struct BrowserReplayMetadata {
    pub user_agent: String,
    pub accept_language: Option<String>,
    pub platform: Option<String>,
    pub captured_with: CaptureEngine,
    pub captured_at: time::OffsetDateTime,
}
```
HTTP integration:
```rust
pub fn build_authenticated_http_client(
    base: reqwest::ClientBuilder,
    auth: &AuthenticatedSession,
    route: &ResolvedProxyRoute,
) -> anyhow::Result<reqwest::Client>;
```
Implementation rule:
```rust
let client = base
    .cookie_provider(auth.jar.clone())
    .user_agent(auth.browser.user_agent.clone())
    .default_headers(build_auth_replay_headers(&auth.browser)?)
    .build()?;
```
Replay headers:
| Header | Rule |
|---|---|
| `User-Agent` | must match login browser unless recipe pins a different value |
| `Accept-Language` | replay when captured |
| `Sec-CH-UA` | optional after reliable capture exists |
| `Sec-CH-UA-Platform` | optional and must match UA family |
CDP integration:
```rust
pub async fn apply_auth_to_cdp_page(
    page: &chromiumoxide::Page,
    session: &AuthenticatedSession,
    target_url: &url::Url,
) -> anyhow::Result<AuthCdpApplyReport>;
```
CDP flow:
```text
Network.enable
Emulation/UserAgent override with captured UA and language
validate cookies against target URL
Network.setCookies
navigate
optional recipe probe
```
CDP edge cases:
| Edge case | Handling |
|---|---|
| HttpOnly | CDP can set; never expose to JS/logs |
| SameSite=None | require `secure=true` |
| Partitioned cookies | persist and replay when CDP supports partition key |
| `__Host-` | require secure, path `/`, no domain |
| `__Secure-` | require secure |
| expired cookies | skip and warn |
| host-only mismatch | reject |
Phase 8 proxy interaction:
```rust
pub enum AuthProxyPolicy {
    RequireSameNamedProxy,
    WarnOnMismatch,
    AllowMismatchForManualImport,
}
```
Recommendation: **default to `RequireSameNamedProxy`**.
Many sites bind sessions to IP, ASN, geography, or risk score.
Login and scrape must resolve through the same Phase 8 proxy route unless a local manual-import escape hatch is explicitly used.
## E. CLI / MCP interfaces
CLI namespace:
```text
rev-scraping auth <command>
```
Subcommands:
```rust
#[derive(clap::Subcommand)]
pub enum AuthCommand {
    Login(AuthLoginArgs),
    List(AuthListArgs),
    Show(AuthShowArgs),
    Delete(AuthDeleteArgs),
    Status(AuthStatusArgs),
    Export(AuthExportArgs),
    Import(AuthImportArgs),
    Refresh(AuthRefreshArgs),
}
```
Login:
```text
rev-scraping auth login <profile> --url <login-url> [--site <recipe-id>] [--proxy <name>]
```
```rust
pub struct AuthLoginArgs {
    pub profile: String,
    pub url: url::Url,
    pub site: Option<String>,
    pub proxy: Option<String>,
    pub mode: AuthLoginMode,
}
pub enum AuthLoginMode {
    Helper,
    HeadedObscura,
    ManualInstructions,
}
```
Other commands:
| Command | Behavior |
|---|---|
| `auth list` | profiles, sites, status, counts, no values |
| `auth show <profile>` | domains, names, expiry, flags, no values by default |
| `auth show <profile> --reveal` | local TTY only, exact confirmation, audit log |
| `auth delete <profile>` | delete jar, metadata, keyring key; append audit |
| `auth status <profile>` | local expiry and required-cookie check |
| `auth status <profile> --probe` | network probe through Phase 8 route and SSRF guard |
| `auth export <profile> --format netscape|json` | local only, gated, audited |
| `auth import <profile> --format netscape|json` | ingest and immediately encrypt |
| `auth refresh <profile>` | rerun headed flow, no credential replay |
MCP tools:
```text
auth_list
auth_status
auth_login_start
auth_login_complete
```
MCP exclusions:
```text
no auth_export
no cookie reveal
no cookie values in any output
```
`auth_list` input schema:
```json
{"type":"object","additionalProperties":false,"properties":{"site":{"type":"string"}}}
```
`auth_list` output schema:
```json
{"type":"object","required":["profiles"],"properties":{"profiles":{"type":"array","items":{"type":"object","required":["profile","status","cookie_count","cookie_values_returned"],"properties":{"profile":{"type":"string"},"site_ids":{"type":"array","items":{"type":"string"}},"status":{"type":"string","enum":["fresh","warning","stale","unknown"]},"cookie_count":{"type":"integer","minimum":0},"expires_next":{"type":["string","null"],"format":"date-time"},"proxy_name":{"type":["string","null"]},"cookie_values_returned":{"type":"boolean","const":false}}}}}}
```
`auth_status` input schema:
```json
{"type":"object","required":["profile"],"additionalProperties":false,"properties":{"profile":{"type":"string"},"site":{"type":"string"},"probe":{"type":"boolean","default":false},"proxy":{"type":"string"}}}
```
`auth_status` output schema:
```json
{"type":"object","required":["profile","status","cookie_values_returned"],"properties":{"profile":{"type":"string"},"status":{"type":"string","enum":["fresh","warning","stale","unknown"]},"reason":{"type":["object","null"]},"last_verified_at":{"type":["string","null"],"format":"date-time"},"expires_next":{"type":["string","null"],"format":"date-time"},"required_cookie_status":{"type":"array","items":{"type":"object"}},"cookie_values_returned":{"type":"boolean","const":false}}}
```
`auth_login_start` input schema:
```json
{"type":"object","required":["profile","login_url"],"additionalProperties":false,"properties":{"profile":{"type":"string"},"login_url":{"type":"string","format":"uri"},"site":{"type":"string"},"proxy":{"type":"string"}}}
```
`auth_login_start` output schema:
```json
{"type":"object","required":["login_id","instructions","completion_deadline","cookie_values_returned"],"properties":{"login_id":{"type":"string"},"instructions":{"type":"string"},"local_browser_opened":{"type":"boolean"},"completion_deadline":{"type":"string","format":"date-time"},"cookie_values_returned":{"type":"boolean","const":false}}}
```
`auth_login_complete` input schema:
```json
{"type":"object","required":["login_id"],"additionalProperties":false,"properties":{"login_id":{"type":"string"}}}
```
`auth_login_complete` output schema:
```json
{"type":"object","required":["profile","status","captured_cookie_count","cookie_values_returned"],"properties":{"profile":{"type":"string"},"status":{"type":"string","enum":["stored","no_cookies","cancelled","failed"]},"captured_cookie_count":{"type":"integer","minimum":0},"domains":{"type":"array","items":{"type":"string"}},"warnings":{"type":"array","items":{"type":"string"}},"cookie_values_returned":{"type":"boolean","const":false}}}
```
## F. Integration with existing systems
AUP allowlist:
```text
Login URLs must already be allowlisted.
Identity-provider hosts must be added through recipe review, not a generic bypass.
```
```rust
pub fn validate_login_aup(
    login_url: &url::Url,
    site: Option<&SiteRecipe>,
    aup: &AupPolicy,
) -> Result<(), AuthPolicyError>;
```
Recommendation: **do not add `--ignore-aup`**.
If a login URL needs an override, use a local reviewed override file or a recipe update.
VPN-required:
```text
If `site.vpn_required = true`, auth login, auth probe, and authenticated scrape all inherit it.
```
```rust
pub fn resolve_auth_route(
    site: Option<&SiteRecipe>,
    requested_proxy: Option<&str>,
    phase8: &Phase8RouteResolver,
) -> Result<ResolvedProxyRoute, AuthRouteError>;
```
SSRF guard:
```text
No bypass is required.
Login is user-initiated but still public-host and allowlist validated.
Probe URL must pass SSRF guard every time.
```
```rust
pub fn validate_auth_probe_url(
    probe_url: &url::Url,
    ssrf: &SsrfGuard,
) -> Result<(), AuthPolicyError>;
```
Site recipe addition in `stealth-sites`:
```rust
pub struct AuthRecipe {
    pub login_url: String,
    pub probe_url: String,
    pub required_cookies: Vec<String>,
    pub ua_pin: Option<String>,
    pub login_hosts: Vec<String>,
    pub refusal_policy: Option<AuthRefusalPolicy>,
}
```
Recipe integration:
```rust
pub struct SiteRecipe {
    pub id: String,
    pub domains: Vec<String>,
    pub vpn_required: bool,
    pub auth: Option<AuthRecipe>,
}
```
Affected crate paths:
| Crate | Planned path |
|---|---|
| `stealth-cli` | `$REPO_ROOT/crates/stealth-cli/src/auth.rs` |
| `stealth-mcp` | `$REPO_ROOT/crates/stealth-mcp/src/auth_tools.rs` |
| `obscura-bridge` | `$REPO_ROOT/crates/obscura-bridge/src/auth.rs` |
| `stealth-sites` | `$REPO_ROOT/crates/stealth-sites/src/auth.rs` |
| `stealth-auth` | `$REPO_ROOT/crates/stealth-auth/src/lib.rs` |
## G. Security threat model
Cookie values are bearer secrets.
Treat them like account tokens.
Leakage vectors:
| # | Vector | Mitigation |
|---:|---|---|
| 1 | Disk theft | AEAD encryption, OS keystore, 0600 files |
| 2 | Process memory dump | `zeroize`, helper process isolation, narrow plaintext lifetime |
| 3 | Logs/traces | redaction layer, secret newtypes, no value `Debug` |
| 4 | MCP output | no cookie values, no export tool |
| 5 | Crash dumps/panics | panic hook redacts registered cookie strings |
| 6 | Multi-tenant CI | explicit `--profile`, no auto-load, fail closed keyring |
| 7 | Supply chain | pin versions, `cargo audit`, `cargo deny`, `#![forbid(unsafe_code)]` |
| 8 | Import/export plaintext | local-only gates, warnings, audit log |
| 9 | Terminal scrollback | redacted default output |
| 10 | Proxy mismatch | route binding validation before use |
Secret newtype:
```rust
#[derive(Clone, zeroize::Zeroize, zeroize::ZeroizeOnDrop)]
pub struct SecretCookieValue(String);
impl std::fmt::Debug for SecretCookieValue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("<redacted-cookie-value>")
    }
}
```
Tracing redaction:
```rust
pub struct AuthRedactionLayer;
```
The layer redacts fields named `cookie`, `cookies`, `set_cookie`, `authorization`, and `x_api_key`.
Type-level redaction is primary; tracing redaction is defense in depth.
Panic hook:
```rust
pub fn install_auth_panic_hook(redactor: Arc<AuthSecretRegistry>);
```
Audit log:
```text
~/.config/rev_scraping/auth/audit.log
```
Audit event fields:
| Field | Value |
|---|---|
| `ts` | ISO timestamp |
| `event` | login, refresh, import, export, delete, probe |
| `profile` | profile name |
| `site` | recipe id if known |
| `cookie_name_hashes` | hashes only |
| `value_hashes` | hashes only |
| `proxy` | route name |
| `result` | stored, stale, failed |
Recommendation: **append-only audit log with 10 MiB rotation and 0600 permissions**.
Security dependency policy:
| crate | version | policy |
|---|---:|---|
| `chacha20poly1305` | `0.10` | pinned, audit before upgrade |
| `keyring` | `3` | pinned, backend tests |
| `cookie_store` | `0.21` | pinned initially |
| `zeroize` | `1.8` | pinned |
| `time` | `0.3` | workspace compatible |
## H. SNS-specific challenges
SNS sessions are fragile and policy-sensitive.
Do not frame Phase 9 as a bypass system.
2FA/passkey matrix:
| Auth method | Supported path |
|---|---|
| TOTP | headed login |
| SMS | headed login |
| push approval | headed login |
| passkey in helper browser | maybe, depends on OS/browser |
| passkey bound to user's normal browser | manual import fallback |
CAPTCHA policy:
```text
The user may solve a CAPTCHA manually in the opened browser.
Phase 9 must not integrate automated CAPTCHA-solving services.
```
Device-fingerprint binding risks:
| Site family | Risk |
|---|---|
| Twitter/X-like | High |
| Meta-like | High |
| LinkedIn-like | High |
| forums/member sites | Medium |
| private dashboards | Low to medium |
Mitigations:
| Mitigation | Phase |
|---|---|
| captured UA replay | 9c |
| Accept-Language replay | 9c |
| proxy stickiness | 9b/9c |
| obscura stealth defaults | 9b/9d |
| explicit probes | 9e |
| refusal policy | 9g |
ToS stance:
```text
Logged-in SNS scraping can violate ToS even when technically possible.
Known-hostile SNS recipes should refuse by default or require explicit per-site opt-in.
```
```rust
pub enum AuthRefusalPolicy {
    Allow,
    WarnRequireExplicitFlag,
    RefuseByDefault,
}
```
Recommendation: **use `WarnRequireExplicitFlag` for moderate-risk SNS and `RefuseByDefault` for known-hostile SNS**.
## I. Auto-refresh
Recommendation: **reject silent auto-refresh by default**.
Reasons:
| Reason | Detail |
|---|---|
| Anti-bot risk | repeated unexpected logins can trigger challenges |
| User consent | user should know when auth is renewed |
| Credentials | Phase 9 stores no password or TOTP secret |
| Auditability | explicit refresh keeps history clear |
Manual refresh command:
```text
rev-scraping auth refresh <profile> [--site <recipe-id>] [--proxy <name>]
```
Signature:
```rust
pub async fn refresh_profile(
    profile: AuthProfileName,
    opts: AuthRefreshOptions,
) -> anyhow::Result<AuthCaptureResult>;
```
Rules:
```text
No background daemon.
No scheduled refresh.
No headless credential replay.
No form-filling with stored credentials.
Keep previous jar if refresh fails.
Replace jar only after new encrypted write succeeds.
```
Failure behavior:
| Failure | Behavior |
|---|---|
| user cancels | keep previous jar |
| no cookies captured | keep previous jar, warn |
| new probe fails | keep previous unless `--accept-unverified` |
| proxy mismatch | block by default |
## J. Legal / positioning
One-line stance:
```text
rev_scraping Phase 9 is for the user's own accounts on systems they are authorized to access.
```
CFAA and 不正アクセス禁止法 positioning:
| Topic | Position |
|---|---|
| CFAA | do not exceed authorized access |
| 不正アクセス禁止法 | do not use another person's identifiers or bypass access controls |
| ToS | technical access may still violate site terms |
| Credentials | do not store credentials |
| Cookies | store encrypted post-auth session cookies only |
Required `--help` and README copy:
```text
Authenticated scraping is only for your own accounts and systems you are authorized to access.
rev_scraping stores encrypted post-auth session cookies, not passwords.
Some sites prohibit logged-in scraping by their terms; site recipes may refuse or require explicit opt-in.
```
Forbidden storage types:
```rust
pub struct Password(String);      // forbidden
pub struct TotpSecret(String);    // forbidden
pub struct RecoveryCode(String);  // forbidden
```
Allowed secret-bearing type:
```rust
pub struct SecretCookieValue(String);
```
Recommendation: **enforce credential prohibition in crate docs, review checklist, and tests that reject credential import fields**.
## K. Crate layout
Recommendation: **create new workspace crate `stealth-auth`**.
Files to create:
```text
$REPO_ROOT/crates/stealth-auth/Cargo.toml
$REPO_ROOT/crates/stealth-auth/src/lib.rs
$REPO_ROOT/crates/stealth-auth/src/jar.rs
$REPO_ROOT/crates/stealth-auth/src/keystore.rs
$REPO_ROOT/crates/stealth-auth/src/capture.rs
$REPO_ROOT/crates/stealth-auth/src/probe.rs
$REPO_ROOT/crates/stealth-auth/src/redact.rs
$REPO_ROOT/crates/stealth-auth/src/audit.rs
$REPO_ROOT/crates/stealth-auth/src/import_export.rs
$REPO_ROOT/crates/stealth-auth/src/types.rs
```
Public API in `lib.rs`:
```rust
#![forbid(unsafe_code)]
pub mod audit;
pub mod capture;
pub mod import_export;
pub mod jar;
pub mod keystore;
pub mod probe;
pub mod redact;
pub mod types;
pub use jar::EncryptedCookieJar;
pub use types::{AuthProfileName, AuthRecipe, AuthenticatedSession, BrowserReplayMetadata, CdpCookie};
```
Module responsibilities:
| Module | Responsibility |
|---|---|
| `jar.rs` | encryption, atomic save, merge, reqwest conversion |
| `keystore.rs` | `keyring` wrappers and test keystore |
| `capture.rs` | headed login, CDP cookie extraction, browser metadata |
| `probe.rs` | expiry, required cookies, HTTP probe |
| `redact.rs` | secret newtypes, tracing layer, panic hook |
| `audit.rs` | append-only audit events |
| `import_export.rs` | Netscape/JSON import and gated export |
| `types.rs` | shared structs and enums |
Dependency table:
| crate | version | purpose |
|---|---:|---|
| `chacha20poly1305` | `0.10` | AEAD |
| `keyring` | `3` | OS keystore |
| `cookie_store` | `0.21` | jar normalization |
| `reqwest` | existing | `cookie_provider` integration |
| `zeroize` | `1.8` | secret wiping |
| `time` | `0.3` | expiry math |
| `tracing` | existing | redacted logs |
| `serde` | `1` | persisted schema |
| `serde_json` | `1` | JSON import/export |
| `url` | existing or `2` | URL validation |
| `publicsuffix` | `2` | reject public-suffix cookies if no existing equivalent |
| `thiserror` | `2` | library error types |
| `proptest` | `1` | merge property tests |
Feature layout:
```toml
[features]
default = []
stealth-auth = ["dep:stealth-auth", "reqwest/cookies"]
```
`stealth-auth` crate features:
```toml
[features]
default = []
cdp-capture = ["dep:chromiumoxide"]
manual-import = []
test-fixtures = []
```
Recommendation: **keep `stealth-auth` optional until 9g exit criteria are met**.
## L. Testing strategy
Existing tests must not change.
All new tests are initially gated behind `--features stealth-auth`.
Unit tests:
| Test | Assertion |
|---|---|
| encrypt/decrypt round-trip | same redacted cookie summary after load |
| wrong profile AAD | decrypt fails |
| atomic write failure | previous jar remains valid |
| file mode | Unix jar is 0600 |
| key create/load/delete | memory keystore and OS wrapper behavior |
| redacted Debug | cookie values never appear |
| expiry math | expired/warning/session counts correct |
| prefix validation | invalid `__Host-` and `__Secure-` rejected |
Integration tests:
| Test | Scope |
|---|---|
| mock CDP stream | fake `Network.getAllCookies` -> encrypted jar |
| reqwest cookie provider | local server receives Cookie header |
| MCP schema snapshot | example payloads validate |
| status stale redirect | stub redirects to login |
| status fresh probe | stub returns account marker |
| Netscape import | fixture imports and encrypts |
Manual E2E:
```text
REV_SCRAPING_AUTH_E2E=1 cargo test --features stealth-auth auth_e2e
```
Fixture design:
```text
local axum server
/login sets httpOnly test cookie
/me requires cookie
/logout deletes cookie
```
Property tests with `proptest = "1"`:
| Property | Expected |
|---|---|
| merge idempotence | merging same set twice yields same jar |
| newer wins | same name/domain/path/partition replaced |
| expired skip | expired cookies are not replayed |
| partition separation | partitioned cookie does not overwrite unpartitioned |
| prefix validity | generated invalid prefix cookies fail validation |
Commands:
```text
cargo test -p stealth-auth --features stealth-auth
cargo test --workspace --features stealth-auth
cargo clippy --workspace --features stealth-auth --all-targets -- -D warnings
cargo test --workspace
```
Recommendation: **do not enable the feature by default until all pre-Phase-9 tests pass with it disabled**.
## M. Phased rollout (9a-9g)
Rollout table:
| sub-phase | scope | deliverable |
|---|---|---|
| 9a | crate scaffold + jar + keystore | encrypted jar round-trip green |
| 9b | CDP capture from headed obscura | `auth login` works locally |
| 9c | reqwest integration + recipe `auth:` block | HTTP scrape uses session |
| 9d | CDP scrape integration (`Network.setCookies`) | headless re-use |
| 9e | probe / `auth status` | staleness detection |
| 9f | MCP tools | external orchestrator can drive login |
| 9g | SNS hardening | UA pinning, proxy stickiness, refusal policy |
9a files:
```text
$REPO_ROOT/crates/stealth-auth/Cargo.toml
$REPO_ROOT/crates/stealth-auth/src/lib.rs
$REPO_ROOT/crates/stealth-auth/src/jar.rs
$REPO_ROOT/crates/stealth-auth/src/keystore.rs
$REPO_ROOT/crates/stealth-auth/src/types.rs
```
9a exit:
```text
save/load green, wrong AAD fails, 0600 permissions, no secret Debug output
```
9b files:
```text
$REPO_ROOT/crates/stealth-auth/src/capture.rs
$REPO_ROOT/crates/stealth-cli/src/auth.rs
```
9b exit:
```text
auth login opens browser, captures CDP cookies, records UA/language/proxy
```
9c files:
```text
$REPO_ROOT/crates/stealth-auth/src/http.rs
$REPO_ROOT/crates/stealth-sites/src/auth.rs
```
9c exit:
```text
recipe auth block exists, HTTP scrape uses profile, proxy mismatch blocks
```
9d files:
```text
$REPO_ROOT/crates/stealth-auth/src/cdp_apply.rs
$REPO_ROOT/crates/obscura-bridge/src/auth.rs
```
9d exit:
```text
Network.setCookies works before headless navigation, modern attributes preserved
```
9e files:
```text
$REPO_ROOT/crates/stealth-auth/src/probe.rs
$REPO_ROOT/crates/stealth-cli/src/auth.rs
```
9e exit:
```text
auth status reports fresh/warning/stale and probes through SSRF + Phase 8 route
```
9f files:
```text
$REPO_ROOT/crates/stealth-mcp/src/auth_tools.rs
```
9f exit:
```text
MCP list/status/start/complete work and never return cookie values
```
9g files:
```text
$REPO_ROOT/crates/stealth-auth/src/policy.rs
$REPO_ROOT/crates/stealth-sites/src/auth.rs
```
9g exit:
```text
UA pinning, proxy stickiness, refusal policy, and audit coverage are complete
```
## N. Risks + mitigations
| Risk | Impact | Likelihood | Mitigation |
|---|---|---:|---|
| key loss | jar cannot decrypt | Medium | document re-login, key delete invalidates profile |
| keyring missing on headless Linux | auth unavailable | Medium | fail closed; explicit CI fixture key only |
| anti-bot detection | account challenge/lockout | High for SNS | UA replay, proxy stickiness, low-rate probes |
| cookie expiry storm | many profiles stale | Medium | expiry warnings, manual refresh |
| MCP misuse | remote exfiltration | Medium | no values, no export, schemas tested |
| SSRF via login/probe URL | internal network access | Low-medium | AUP and SSRF guard |
| partial-write corruption | lost jar | Low | temp write, fsync, atomic rename |
| Chrome auto-update CDP drift | capture/set failure | Medium | adapter tests, ignore unsupported fields safely |
| partitioned cookie loss | modern login fails | Medium | persist partition key, feature-detect CDP |
| overbroad import | wrong site cookies stored | Medium | domain allowlist and confirmation |
| logging leak | account compromise | Low | secret newtypes and redaction tests |
| proxy mismatch | session invalidation | Medium | strict same-route default |
## O. Rollback
Feature gate:
```text
--features stealth-auth
```
Required invariant:
```text
Disabling `stealth-auth` compiles and passes all pre-Phase-9 tests.
```
Pattern:
```rust
#[cfg(feature = "stealth-auth")]
mod auth;
```
Disabled behavior:
```text
rev-scraping auth ...
error: authenticated session capture is not enabled in this build
```
Data rollback:
```text
Encrypted jars are inert without keystore keys.
They may safely remain on disk after feature disable.
```
Manual deletion:
```text
remove ~/.config/rev_scraping/auth/<profile>.jar.enc
remove keyring entry rev_scraping.stealth_auth / cookie-jar:<profile>
```
Phase rollback:
| Phase | Rollback |
|---|---|
| 9a | remove workspace member and feature |
| 9b | unregister `auth login` |
| 9c | ignore recipe `auth` when feature disabled |
| 9d | skip CDP cookie application |
| 9e | hide probe/status additions |
| 9f | unregister MCP auth tools |
| 9g | leave refusal policy inert when auth disabled |
Recommendation: **keep all behavior additive so existing scrape paths are unaffected by rollback**.
## P. Timeline
Calendar estimates:
| Sub-phase | Estimate | Calendar |
|---|---:|---|
| 9a | 1 week | Week 1 |
| 9b | 1 week | Week 2 |
| 9c | 1 week | Week 3 |
| 9d | 1 week | Week 4 |
| 9e | 0.5 week | Week 5 first half |
| 9f | 0.5 week | Week 5 second half |
| 9g | 1 week | Week 6 |
Critical path:
```text
9a -> 9b -> 9c -> 9d -> 9e -> 9g
```
MCP path:
```text
9e -> 9f
```
Sub-phase dependency DAG:
```text
          +------------------+
          | 9a jar/keystore  |
          +---------+--------+
                    |
                    v
          +---------+--------+
          | 9b headed login  |
          +---------+--------+
                    |
                    v
          +---------+--------+
          | 9c HTTP/recipes  |
          +---------+--------+
                    |
                    v
          +---------+--------+
          | 9d CDP replay    |
          +---------+--------+
                    |
                    v
          +---------+--------+
          | 9e probe/status  |
          +----+--------+----+
               |        |
               v        v
        +------+--+  +--+------+
        | 9f MCP  |  | 9g SNS  |
        +---------+  +---------+
```
Parallel work:
| Workstream | Can start after |
|---|---|
| manual import parser | 9a |
| recipe `auth` schema | 9a |
| redaction tests | 9a |
| MCP schema drafting | 9a |
| MCP implementation | 9e |
| SNS refusal copy | 9c |
Recommendation: **complete 9a first, then parallelize import/schema/redaction while 9b capture work proceeds**.
## Q. DECISION NEEDED
| # | Question | Options | Recommendation | Blast radius |
|---:|---|---|---|---|
| 1 | Launch mode default? | A1 headed obscura in main process; A2 separate `rev-auth`; A3 import only | **A2: separate `rev-auth` helper** | Adds binary/package artifact; improves isolation and multi-account behavior |
| 2 | SNS default policy? | B1 allow all allowlisted; B2 warn + explicit flag; B3 refuse hostile sites | **B2 for moderate risk, B3 for known-hostile SNS** | Users need recipe opt-in and acknowledgement |
| 3 | MCP exposure? | C1 CLI parity/export; C2 list/status/start/complete; C3 no MCP auth | **C2: no export and no values** | Orchestrators can drive login but cannot extract cookies |
| 4 | Headless Linux keyring fallback? | D1 plaintext; D2 passphrase key; D3 fail closed + CI fixture gate | **D3: fail closed** | Headless users configure keystore or controlled import |
| 5 | Cookie export gating? | E1 no export; E2 CLI-only confirmed/audited; E3 CLI+MCP | **E2: CLI-only export** | Local portability without remote exfiltration |
| 6 | Session cookie persistence? | F1 drop on save; F2 until delete/stale; F3 fixed 24h | **F2: persist until delete/stale** | Better reuse; clear delete/status UX required |
| 7 | Proxy route strictness? | G1 require same route; G2 warn; G3 allow mismatch | **G1 with manual-import-only escape hatch** | Profiles become route-aware; lockout risk drops |
| 8 | Serialization? | H1 raw `cookie_store` JSON; H2 custom schema; H3 Netscape envelope | **H2: `PersistedCookieJarV1`** | More 9a code; better format stability |
| 9 | Probe default? | I1 always probe; I2 local default + `--probe`; I3 never probe | **I2: local-only default** | Avoids surprise traffic; freshness is explicit |
| 10 | Unsafe policy? | J1 allow; J2 forbid; J3 feature-gated unsafe | **J2: `#![forbid(unsafe_code)]`** | Requires safe wrapper crates; appropriate for secrets |
Final implementation rule: **no cookie value crosses a public boundary unless the user explicitly invokes local CLI export/reveal**.
