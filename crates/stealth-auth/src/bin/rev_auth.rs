// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9b (rev-auth binary)

#![forbid(unsafe_code)]

use anyhow::{anyhow, Context};
use chromiumoxide::cdp::browser_protocol::network::{Cookie as CdpCookie, CookieSameSite};
use chromiumoxide::{Browser, BrowserConfig};
use chrono::{DateTime, TimeZone, Utc};
use clap::{Args, Parser, Subcommand};
use futures::StreamExt;
use obscura_bridge::ObscuraBridge;
use publicsuffix::{List, Psl};
use regex::Regex;
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;
use stealth_auth::audit::{append_jsonl, AuditEvent};
use stealth_auth::auth_aup::{self, AuthAupDecision};
use stealth_auth::storage;
use stealth_auth::{install_auth_panic_hook, AuthStore, Cookie, SameSite};
use tokio::io::{AsyncBufReadExt, BufReader};
use url::Url;
use uuid::Uuid;
use vpn_rotate::instance_pool::{InstancePool, VpnInstance as PoolVpnInstance};
use vpn_rotate::leak_guard::{probe_all, InstanceDescriptor};
use vpn_rotate::leak_monitor::LeakMonitor;
use zeroize::Zeroize;

const EXIT_USER: i32 = 1;
/// Exit code 3: a required browser binary could not be located.
///
/// Historically named `EXIT_OBSCURA_NOT_FOUND` (Phase 9b). After hotfix-1
/// rewired `rev-auth` to system Chrome via `chromiumoxide`, this constant is
/// reused for "Chrome / Chromium not found". The numeric value is preserved
/// for shell-script callers and the wrapper `rev-stealth auth login`.
const EXIT_CHROME_NOT_FOUND: i32 = 3;
const EXIT_AUTH_EXPIRED: i32 = 4;
const EXIT_LEAK: i32 = 7;
const EXIT_ABORTED: i32 = 12;
/// Delay between CDP-driven Chrome.close() and process.wait() to let
/// Chrome's helper subprocesses flush state. Without this delay, macOS
/// LaunchServices flags subsequent launches as "crashed".
pub(crate) const CHROME_TEARDOWN_FLUSH_MS: u64 = 1500;

#[derive(Parser, Debug)]
#[command(
    name = "rev-auth",
    version,
    about = "Capture and encrypt authorized browser auth cookies"
)]
pub struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    Login(LoginArgs),
}

#[derive(
    clap::ValueEnum, Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize,
)]
#[serde(rename_all = "kebab-case")]
pub enum DisplayMode {
    Auto,
    Headed,
    Headless,
    Xvfb,
}

impl DisplayMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Headed => "headed",
            Self::Headless => "headless",
            Self::Xvfb => "xvfb",
        }
    }
}

impl std::fmt::Display for DisplayMode {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[derive(Args, Clone, Debug)]
pub struct LoginArgs {
    #[arg(long)]
    pub profile: String,
    #[arg(long)]
    pub url: String,
    #[arg(long)]
    pub domain: String,
    #[arg(long)]
    pub user_data_dir: Option<PathBuf>,
    #[arg(long)]
    pub completion_pattern: Option<String>,
    #[arg(long, default_value = "")]
    pub aad_context: String,
    /// Deprecated (Phase 9 hotfix-1): obscura is no longer used for interactive
    /// login. The flag is preserved for wrapper-script compatibility but ignored
    /// other than to emit a deprecation warning.
    #[arg(long, env = "REV_OBSCURA_BIN")]
    pub obscura_bin: Option<PathBuf>,
    /// Path to the Chrome / Chromium binary used to open the headed login
    /// window. Defaults to platform-standard locations (see
    /// `resolve_chrome_binary`).
    #[arg(long, env = "REV_AUTH_CHROME_BIN")]
    pub chrome_bin: Option<PathBuf>,
    /// Phase 9e: when set, write a completion marker file at
    /// `$TMPDIR/rev-auth-<token>.complete` on successful save so an MCP
    /// `auth_login_complete` call can detect completion without polling
    /// process state.
    #[arg(long)]
    pub mcp_session_token: Option<String>,
    /// Browser display mode for the interactive login.
    #[arg(
        long,
        env = "REV_AUTH_DISPLAY",
        value_enum,
        default_value_t = DisplayMode::Auto
    )]
    pub display: DisplayMode,
    /// Shortcut for `--display headless`.
    #[arg(long, conflicts_with = "xvfb")]
    pub headless: bool,
    /// Shortcut for `--display xvfb`.
    #[arg(long, conflicts_with = "headless")]
    pub xvfb: bool,
}

#[derive(Debug)]
struct AppError {
    code: i32,
    message: String,
}

impl AppError {
    fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct Policy {
    #[serde(default = "default_require_vpn")]
    require_vpn: bool,
    #[serde(default)]
    vpn_required_country: Option<String>,
    #[serde(default)]
    vpn_instances: Vec<PolicyVpnInstance>,
}

#[derive(Debug, Deserialize)]
struct PolicyVpnInstance {
    name: String,
    http_proxy_port: u16,
    control_port: u16,
}

struct VpnContext {
    selection: Option<PoolVpnInstance>,
    monitor: Option<LeakMonitor>,
}

trait EnvLookup {
    fn get(&self, key: &str) -> Option<String>;
}

struct ProcessEnv;

impl EnvLookup for ProcessEnv {
    fn get(&self, key: &str) -> Option<String> {
        std::env::var(key).ok()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TargetOs {
    Macos,
    Linux,
    Other,
}

impl TargetOs {
    fn current() -> Self {
        if cfg!(target_os = "macos") {
            Self::Macos
        } else if cfg!(target_os = "linux") {
            Self::Linux
        } else {
            Self::Other
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct DisplayModeDecision {
    mode: DisplayMode,
    warnings: Vec<&'static str>,
}

#[derive(Serialize)]
struct SuccessJson {
    ok: bool,
    profile: String,
    domain: String,
    cookie_count: usize,
    expires_at: Option<String>,
    saved_to: String,
}

trait CookieStore {
    fn save_cookies(
        &self,
        profile: &str,
        cookies: &[Cookie],
        aad_context: &str,
    ) -> anyhow::Result<()>;
}

impl CookieStore for AuthStore {
    fn save_cookies(
        &self,
        profile: &str,
        cookies: &[Cookie],
        aad_context: &str,
    ) -> anyhow::Result<()> {
        self.save(profile, cookies, aad_context)?;
        Ok(())
    }
}

fn default_require_vpn() -> bool {
    true
}

#[tokio::main]
async fn main() {
    install_auth_panic_hook();
    let cli = Cli::parse();
    let code = match cli.command {
        Command::Login(args) => match run_login(args).await {
            Ok(()) => 0,
            Err(error) => {
                eprintln!("{}", error.message);
                error.code
            }
        },
    };
    std::process::exit(code);
}

async fn run_login(args: LoginArgs) -> Result<(), AppError> {
    validate_login_args(&args).map_err(|error| AppError::new(EXIT_USER, error.to_string()))?;
    let env = ProcessEnv;
    let display_mode = resolve_login_display_mode(&args, &env, TargetOs::current());
    let login_url = Url::parse(&args.url)
        .map_err(|error| AppError::new(EXIT_USER, format!("invalid url: {error}")))?;
    ObscuraBridge::validate_url(&login_url)
        .map_err(|error| AppError::new(EXIT_USER, format!("SSRF guard: {error}")))?;

    let target_etld1 = registrable_domain(&args.domain)
        .ok_or_else(|| AppError::new(EXIT_USER, format!("invalid domain {:?}", args.domain)))?;
    let url_host = login_url
        .host_str()
        .ok_or_else(|| AppError::new(EXIT_USER, "login URL must include a host"))?;
    registrable_domain(url_host)
        .ok_or_else(|| AppError::new(EXIT_USER, format!("invalid login URL host {url_host:?}")))?;

    match auth_aup::enforce(&args.domain, &args.url) {
        AuthAupDecision::Allowed => {}
        AuthAupDecision::Rejected { message } => {
            return Err(AppError::new(EXIT_USER, format!("AUP: {message}")));
        }
    }

    if args.obscura_bin.is_some() {
        eprintln!(
            "warning: --obscura-bin / REV_OBSCURA_BIN are deprecated for rev-auth; \
             use --chrome-bin / REV_AUTH_CHROME_BIN (the flag is ignored)"
        );
    }

    let vpn = prepare_vpn_context()
        .await
        .map_err(|error| AppError::new(EXIT_LEAK, error.to_string()))?;

    let chrome_bin = resolve_chrome_binary(args.chrome_bin.as_deref())
        .map_err(|error| AppError::new(EXIT_CHROME_NOT_FOUND, error.to_string()))?;

    let profile_dir = ProfileDir::prepare(args.user_data_dir.as_deref())
        .map_err(|error| AppError::new(EXIT_USER, format!("profile dir: {error}")))?;

    let auth_dir = default_auth_dir()
        .map_err(|error| AppError::new(EXIT_USER, format!("auth dir: {error}")))?;
    storage::ensure_auth_dir(&auth_dir)
        .map_err(|error| AppError::new(EXIT_USER, format!("auth dir: {error}")))?;
    append_auth_login_start_audit(&auth_dir, &args.profile, display_mode)
        .map_err(|error| AppError::new(EXIT_USER, format!("audit log: {error}")))?;

    let config = build_chrome_config_with_vpn(
        &chrome_bin,
        profile_dir.path(),
        vpn.selection.as_ref(),
        display_mode,
    )
    .map_err(|error| {
        let code = if display_mode == DisplayMode::Xvfb {
            EXIT_CHROME_NOT_FOUND
        } else {
            EXIT_USER
        };
        AppError::new(code, format!("chrome config: {error}"))
    })?;

    let (mut browser, mut handler) = Browser::launch(config)
        .await
        .map_err(|error| AppError::new(EXIT_USER, format!("chrome launch: {error}")))?;
    let handler_task = tokio::spawn(async move {
        while let Some(event) = handler.next().await {
            // Drain the CDP event stream. We deliberately ignore individual
            // events here: cookie capture happens via an explicit CDP call.
            drop(event);
        }
    });

    let nav_result: Result<(), AppError> = async {
        let page = browser
            .new_page("about:blank")
            .await
            .map_err(|error| AppError::new(EXIT_USER, format!("new_page: {error}")))?;
        page.goto(login_url.as_str())
            .await
            .map_err(|error| AppError::new(EXIT_USER, format!("navigate: {error}")))?;

        wait_for_user_or_pattern(
            &page,
            args.completion_pattern.as_deref(),
            vpn.monitor.as_ref(),
        )
        .await?;

        if let Some(monitor) = vpn.monitor.as_ref() {
            if monitor.state_clone().read().await.leak_detected {
                return Err(AppError::new(EXIT_LEAK, "vpn leak detected during capture"));
            }
        }

        let mut raw_cookies = page
            .get_cookies()
            .await
            .map_err(|error| AppError::new(EXIT_USER, format!("cookie capture: {error}")))?;
        let mut cookies = filter_cdp_cookies(raw_cookies.iter_mut(), &target_etld1)
            .map_err(|error| AppError::new(EXIT_USER, error.to_string()))?;
        drop(raw_cookies);

        if all_cookies_expired(&cookies, Utc::now()) {
            cookies.zeroize();
            return Err(AppError::new(
                EXIT_AUTH_EXPIRED,
                "captured cookies are all expired",
            ));
        }

        // Save inside this scope so the page handle is still alive (we don't
        // strictly need it, but it keeps cleanup ordering simple).
        let store = open_store(&auth_dir)
            .map_err(|error| AppError::new(EXIT_USER, format!("auth store: {error}")))?;
        save_cookies_with_store(&store, &args.profile, &cookies, &args.aad_context)
            .map_err(|error| AppError::new(EXIT_USER, format!("auth save: {error}")))?;

        let output = SuccessJson {
            ok: true,
            profile: args.profile.clone(),
            domain: target_etld1.clone(),
            cookie_count: cookies.len(),
            expires_at: latest_expires_at(&cookies).map(|expires| expires.to_rfc3339()),
            saved_to: storage::enc_path(&auth_dir, &args.profile)
                .display()
                .to_string(),
        };
        cookies.zeroize();
        drop(cookies);
        let _ = page.close().await;

        // Phase 9e: best-effort completion marker for MCP `auth_login_complete`.
        if let Some(token) = args.mcp_session_token.as_deref() {
            let marker = std::env::temp_dir().join(format!("rev-auth-{token}.complete"));
            let _ = fs::write(&marker, b"done");
        }
        println!(
            "{}",
            serde_json::to_string(&output)
                .map_err(|error| AppError::new(EXIT_USER, format!("json output: {error}")))?
        );
        Ok(())
    }
    .await;

    // Always tear down Chrome regardless of outcome.
    // 1) CDP-driven graceful close
    let _ = browser.close().await;
    // 2) Let Chrome's helper subprocesses (renderer, GPU, network service)
    //    flush state and exit cleanly. Without this delay, macOS
    //    LaunchServices flags the next Chrome launch as "crashed".
    tokio::time::sleep(Duration::from_millis(CHROME_TEARDOWN_FLUSH_MS)).await;
    // 3) Wait for the parent Chrome process to fully exit
    let _ = browser.wait().await;
    handler_task.abort();
    profile_dir.cleanup();
    nav_result
}

fn resolve_login_display_mode(args: &LoginArgs, env: &impl EnvLookup, os: TargetOs) -> DisplayMode {
    let decision = resolve_login_display_mode_decision(args, env, os);
    for warning in &decision.warnings {
        eprintln!("{warning}");
    }
    decision.mode
}

fn resolve_login_display_mode_decision(
    args: &LoginArgs,
    env: &impl EnvLookup,
    os: TargetOs,
) -> DisplayModeDecision {
    if args.headless {
        return DisplayModeDecision {
            mode: DisplayMode::Headless,
            warnings: Vec::new(),
        };
    }
    if args.xvfb {
        return DisplayModeDecision {
            mode: DisplayMode::Xvfb,
            warnings: Vec::new(),
        };
    }
    if args.display != DisplayMode::Auto {
        return DisplayModeDecision {
            mode: args.display,
            warnings: Vec::new(),
        };
    }
    if env.get("REV_AUTH_HEADLESS").as_deref() == Some("1") {
        return DisplayModeDecision {
            mode: DisplayMode::Headless,
            warnings: vec![
                "warning: REV_AUTH_HEADLESS is deprecated; use REV_AUTH_DISPLAY=headless or --display headless",
            ],
        };
    }
    resolve_auto_display_mode(env, os)
}

fn resolve_display_mode(env: &impl EnvLookup, os: TargetOs) -> DisplayMode {
    match os {
        TargetOs::Macos => DisplayMode::Headed,
        TargetOs::Linux if env_has_non_empty(env, "DISPLAY") => DisplayMode::Headed,
        TargetOs::Linux
            if env.get("REV_AUTH_AUTO_XVFB").as_deref() == Some("1")
                && command_on_path(env, "xvfb-run") =>
        {
            DisplayMode::Xvfb
        }
        TargetOs::Linux => DisplayMode::Headless,
        TargetOs::Other => DisplayMode::Headed,
    }
}

fn resolve_auto_display_mode(env: &impl EnvLookup, os: TargetOs) -> DisplayModeDecision {
    let mode = resolve_display_mode(env, os);
    let warnings = if os == TargetOs::Linux && mode == DisplayMode::Headless {
        vec![
            "warning: DISPLAY is unset and REV_AUTH_AUTO_XVFB=1 with xvfb-run was not detected; using headless Chrome",
        ]
    } else {
        Vec::new()
    };
    DisplayModeDecision { mode, warnings }
}

fn env_has_non_empty(env: &impl EnvLookup, key: &str) -> bool {
    env.get(key)
        .as_deref()
        .is_some_and(|value| !value.trim().is_empty())
}

fn command_on_path(env: &impl EnvLookup, command: &str) -> bool {
    resolve_command_path(env, command).is_some()
}

/// Resolve the absolute path of a command on `PATH`.
///
/// Returns `Some(path)` for the first directory in `$PATH` whose
/// joined `command` is a regular file. Used by the Xvfb display mode to
/// wrap the Chrome launch in `xvfb-run` without relying on the OS to
/// re-resolve the wrapper at spawn time.
fn resolve_command_path(env: &impl EnvLookup, command: &str) -> Option<PathBuf> {
    let path = env.get("PATH")?;
    std::env::split_paths(&std::ffi::OsString::from(path))
        .map(|dir| dir.join(command))
        .find(|candidate| candidate.is_file())
}

/// Write an `xvfb-run` wrapper shim into `user_data_dir` and return its path.
///
/// chromiumoxide's argument builder unconditionally prepends `--` to every
/// `.arg(...)` token, so we cannot inject `-a -- <chrome_bin>` directly into
/// the spawn argv. The shim is the smallest stable workaround: a short shell
/// script that execs `xvfb-run -a -- <chrome_bin> "$@"`, forwarding the
/// chromium flags chromiumoxide assembles. The file name includes the
/// literal `xvfb-run` substring so `BrowserConfig`'s Debug output reflects
/// that the launch is wrapped.
///
/// The shim lives under the per-profile `user_data_dir` so it inherits that
/// directory's cleanup semantics; nothing here writes to a shared temp dir.
fn write_xvfb_run_shim(
    user_data_dir: &Path,
    xvfb_run: &Path,
    chrome_bin: &Path,
) -> Result<PathBuf, String> {
    let xvfb_run_str = xvfb_run.to_str().ok_or_else(|| {
        "xvfb-run path is not valid UTF-8; cannot generate wrapper shim".to_string()
    })?;
    let chrome_bin_str = chrome_bin.to_str().ok_or_else(|| {
        "chrome binary path is not valid UTF-8; cannot generate wrapper shim".to_string()
    })?;
    // Reject paths containing characters that would let the shim escape its
    // single-quoted shell context. Rare in practice but cheap to enforce.
    if xvfb_run_str.contains('\'') || chrome_bin_str.contains('\'') {
        return Err(
            "xvfb-run or chrome binary path contains a single quote; refusing to generate wrapper shim"
                .to_string(),
        );
    }
    std::fs::create_dir_all(user_data_dir).map_err(|error| {
        format!(
            "failed to create user data dir for xvfb-run shim {}: {error}",
            user_data_dir.display()
        )
    })?;
    let shim_path = user_data_dir.join("rev-auth-xvfb-run.sh");
    let script = format!("#!/bin/sh\nexec '{xvfb_run_str}' -a -- '{chrome_bin_str}' \"$@\"\n");
    std::fs::write(&shim_path, script).map_err(|error| {
        format!(
            "failed to write xvfb-run shim {}: {error}",
            shim_path.display()
        )
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&shim_path)
            .map_err(|error| {
                format!(
                    "failed to stat xvfb-run shim {}: {error}",
                    shim_path.display()
                )
            })?
            .permissions();
        perms.set_mode(0o700);
        std::fs::set_permissions(&shim_path, perms).map_err(|error| {
            format!(
                "failed to chmod xvfb-run shim {}: {error}",
                shim_path.display()
            )
        })?;
    }
    Ok(shim_path)
}

fn append_auth_login_start_audit(
    auth_dir: &Path,
    profile: &str,
    display_mode: DisplayMode,
) -> anyhow::Result<()> {
    append_jsonl(
        &auth_dir.join("audit.jsonl"),
        &AuditEvent {
            ts: Utc::now(),
            profile: profile.to_string(),
            action: "auth_login_start".to_string(),
            display_mode: Some(display_mode.to_string()),
        },
    )
    .map_err(Into::into)
}

fn validate_login_args(args: &LoginArgs) -> anyhow::Result<()> {
    if args.headless && args.xvfb {
        return Err(anyhow!("--headless and --xvfb are mutually exclusive"));
    }
    if args.profile.trim().is_empty() {
        return Err(anyhow!("--profile must not be empty"));
    }
    Url::parse(&args.url).context("--url must be an absolute URL")?;
    if args.domain.trim().is_empty() {
        return Err(anyhow!("--domain must not be empty"));
    }
    if let Some(pattern) = &args.completion_pattern {
        Regex::new(pattern).context("invalid --completion-pattern regex")?;
    }
    Ok(())
}

fn registrable_domain(input: &str) -> Option<String> {
    let host = input
        .trim()
        .trim_start_matches('.')
        .trim_end_matches('.')
        .to_ascii_lowercase();
    if host.is_empty() {
        return None;
    }
    let list = List::default();
    let domain = list.domain(host.as_bytes())?;
    std::str::from_utf8(domain.as_bytes())
        .ok()
        .map(str::to_string)
}

fn filter_cdp_cookies<'a, I>(cookies: I, target_etld1: &str) -> anyhow::Result<Vec<Cookie>>
where
    I: IntoIterator<Item = &'a mut CdpCookie>,
{
    let mut out = Vec::new();
    for cookie in cookies {
        let Some(cookie_etld1) = registrable_domain(&cookie.domain) else {
            cookie.value.zeroize();
            continue;
        };
        if cookie_etld1 != target_etld1 {
            cookie.value.zeroize();
            continue;
        }
        let value = std::mem::take(&mut cookie.value);
        out.push(Cookie {
            name: cookie.name.clone(),
            value: SecretString::from(value),
            domain: cookie.domain.clone(),
            path: cookie.path.clone(),
            expires: cdp_expires_to_datetime(cookie.expires),
            secure: cookie.secure,
            http_only: cookie.http_only,
            same_site: map_same_site(cookie.same_site.as_ref()),
        });
    }
    Ok(out)
}

fn cdp_expires_to_datetime(expires: f64) -> Option<DateTime<Utc>> {
    if !expires.is_finite() || expires <= 0.0 {
        return None;
    }
    let seconds = expires.trunc() as i64;
    let nanos = ((expires.fract()) * 1_000_000_000.0).round() as u32;
    Utc.timestamp_opt(seconds, nanos).single()
}

fn map_same_site(value: Option<&CookieSameSite>) -> SameSite {
    match value {
        Some(CookieSameSite::Strict) => SameSite::Strict,
        Some(CookieSameSite::Lax) => SameSite::Lax,
        Some(CookieSameSite::None) => SameSite::None,
        None => SameSite::Unspecified,
    }
}

fn all_cookies_expired(cookies: &[Cookie], now: DateTime<Utc>) -> bool {
    !cookies.is_empty()
        && cookies
            .iter()
            .all(|cookie| cookie.expires.is_some_and(|expires| expires <= now))
}

fn latest_expires_at(cookies: &[Cookie]) -> Option<DateTime<Utc>> {
    cookies.iter().filter_map(|cookie| cookie.expires).max()
}

fn save_cookies_with_store(
    store: &dyn CookieStore,
    profile: &str,
    cookies: &[Cookie],
    aad_context: &str,
) -> anyhow::Result<()> {
    store.save_cookies(profile, cookies, aad_context)
}

fn default_auth_dir() -> anyhow::Result<PathBuf> {
    if let Some(path) = std::env::var_os("REV_SCRAPING_AUTH_DIR") {
        return Ok(PathBuf::from(path));
    }
    let config = dirs::config_dir().ok_or_else(|| anyhow!("could not resolve config dir"))?;
    Ok(config.join("rev_scraping").join("auth"))
}

fn open_store(auth_dir: &Path) -> anyhow::Result<AuthStore> {
    if let Ok(passphrase) = std::env::var("REV_SCRAPING_AUTH_PASSPHRASE") {
        AuthStore::open_with_passphrase(auth_dir, SecretString::from(passphrase))
            .map_err(Into::into)
    } else {
        AuthStore::open(auth_dir).map_err(Into::into)
    }
}

/// Resolve the Chrome / Chromium binary path used to open the headed login
/// window.
///
/// Order:
///   1. Explicit `--chrome-bin` CLI flag (or `REV_AUTH_CHROME_BIN` env var,
///      surfaced via clap).
///   2. macOS standard install paths (Google Chrome, Canary, Chromium).
///   3. Linux PATH lookup for the usual binary names.
fn resolve_chrome_binary(explicit: Option<&Path>) -> anyhow::Result<PathBuf> {
    if let Some(path) = explicit {
        return existing_file(path)
            .ok_or_else(|| anyhow!("chrome binary not found: {}", path.display()));
    }
    if let Ok(path) = std::env::var("REV_AUTH_CHROME_BIN") {
        let path = PathBuf::from(path);
        return existing_file(&path)
            .ok_or_else(|| anyhow!("chrome binary not found: {}", path.display()));
    }
    for path in standard_chrome_paths() {
        if let Some(path) = existing_file(&path) {
            return Ok(path);
        }
    }
    Err(anyhow!(
        "Chrome / Chromium binary not found. Set --chrome-bin or REV_AUTH_CHROME_BIN, \
         or install Google Chrome at a standard location."
    ))
}

fn standard_chrome_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    #[cfg(target_os = "macos")]
    paths.extend([
        PathBuf::from("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        PathBuf::from("/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"),
        PathBuf::from("/Applications/Chromium.app/Contents/MacOS/Chromium"),
    ]);

    #[cfg(target_os = "linux")]
    paths.extend(
        [
            "google-chrome",
            "google-chrome-stable",
            "chromium-browser",
            "chromium",
        ]
        .into_iter()
        .filter_map(find_in_path),
    );
    paths
}

fn existing_file(path: &Path) -> Option<PathBuf> {
    path.is_file().then(|| path.to_path_buf())
}

/// Linux Chrome path resolver: walks `$PATH` for an executable file matching
/// `name`. Returns `None` if not found.
///
/// Compiled only on Linux because macOS uses absolute `.app` bundle paths
/// (see `standard_chrome_paths`). Keeping this cfg-gated avoids a
/// dead-code warning on macOS and keeps the resolution policy explicit
/// per platform.
#[cfg(target_os = "linux")]
fn find_in_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Build a headed `BrowserConfig` for `chromiumoxide`. Exposed as a helper so
/// tests can inspect the resulting configuration without launching a real
/// browser process.
#[cfg(test)]
fn build_chrome_config(chrome_bin: &Path, user_data_dir: &Path) -> Result<BrowserConfig, String> {
    build_chrome_config_with_vpn(chrome_bin, user_data_dir, None, DisplayMode::Headed)
}

fn build_chrome_config_with_vpn(
    chrome_bin: &Path,
    user_data_dir: &Path,
    vpn_selection: Option<&PoolVpnInstance>,
    display_mode: DisplayMode,
) -> Result<BrowserConfig, String> {
    build_chrome_config_with_vpn_and_env(
        chrome_bin,
        user_data_dir,
        vpn_selection,
        display_mode,
        &ProcessEnv,
    )
}

fn build_chrome_config_with_vpn_and_env(
    chrome_bin: &Path,
    user_data_dir: &Path,
    vpn_selection: Option<&PoolVpnInstance>,
    display_mode: DisplayMode,
    env: &impl EnvLookup,
) -> Result<BrowserConfig, String> {
    // For Xvfb mode we redirect chromiumoxide at a generated shim script that
    // execs `xvfb-run -a -- <chrome_bin> "$@"`. chromiumoxide's argument
    // builder hard-prepends `--` to every arg token, so we cannot inject the
    // `-a -- <chrome_bin>` prefix through `.arg(...)`; a shim sidesteps that
    // restriction and keeps the chromiumoxide launch path untouched.
    //
    // The shim lives under `user_data_dir` so it shares the profile's
    // lifecycle (cleaned up when the auth login flow tears the profile down)
    // and contains the literal string "xvfb-run" in its file name so the
    // resulting BrowserConfig Debug output advertises the wrapper.
    let chrome_executable_path: PathBuf = match display_mode {
        DisplayMode::Xvfb => {
            let xvfb_run = resolve_command_path(env, "xvfb-run").ok_or_else(|| {
                "xvfb-run not found on PATH for --display xvfb; install xvfb-run or wrap rev-auth with xvfb-run -a"
                    .to_string()
            })?;
            write_xvfb_run_shim(user_data_dir, &xvfb_run, chrome_bin)?
        }
        _ => chrome_bin.to_path_buf(),
    };

    let mut builder = BrowserConfig::builder()
        .chrome_executable(&chrome_executable_path)
        .user_data_dir(user_data_dir)
        .window_size(1280, 800)
        .arg(("disable-blink-features", "AutomationControlled"))
        .arg("no-first-run")
        .arg("no-default-browser-check")
        .arg("disable-breakpad")
        .arg("disable-crash-reporter")
        .arg("disable-crashpad")
        // suppress macOS LaunchServices abnormal-exit detection
        .arg("noerrdialogs")
        .arg("no-crash-upload")
        .arg("disable-component-update")
        .arg("disable-domain-reliability")
        .arg("use-mock-keychain")
        .arg((
            "disable-features",
            "Crashpad,CrashpadReporter,ChromeWhatsNewUI",
        ));

    match display_mode {
        DisplayMode::Auto => {
            return Err("display mode must be resolved before building Chrome config".to_string());
        }
        DisplayMode::Headed => {
            builder = builder.with_head();
        }
        DisplayMode::Headless => {
            builder = builder.new_headless_mode().arg("headless=new");
        }
        DisplayMode::Xvfb => {
            // chrome runs as a headed process inside the Xvfb display managed
            // by xvfb-run, so disable chromiumoxide's headless flag emission.
            builder = builder.with_head();
        }
    }

    #[cfg(target_os = "macos")]
    {
        builder = builder.env("CFFIXED_USER_HOME", user_data_dir.display().to_string());
    }

    if let Some(selection) = vpn_selection {
        let proxy_server = format!("http://127.0.0.1:{}", selection.http_proxy_port);
        builder = builder
            .arg(("proxy-server", proxy_server.as_str()))
            .arg(("proxy-bypass-list", "127.0.0.1;localhost"));
    }

    builder.build()
}

async fn wait_for_user_or_pattern(
    page: &chromiumoxide::Page,
    pattern: Option<&str>,
    monitor: Option<&LeakMonitor>,
) -> Result<(), AppError> {
    eprintln!("Sign in in the opened Chrome window. Press ENTER here when done.");
    let regex = match pattern {
        Some(pattern) => Some(
            Regex::new(pattern)
                .map_err(|error| AppError::new(EXIT_USER, format!("invalid regex: {error}")))?,
        ),
        None => None,
    };
    let mut line = String::new();
    let mut reader = BufReader::new(tokio::io::stdin());
    let stdin = reader.read_line(&mut line);
    tokio::pin!(stdin);

    loop {
        tokio::select! {
            result = &mut stdin => {
                result.map_err(|error| AppError::new(EXIT_ABORTED, format!("stdin: {error}")))?;
                return Ok(());
            }
            _ = tokio::signal::ctrl_c() => {
                return Err(AppError::new(EXIT_ABORTED, "user aborted"));
            }
            _ = tokio::time::sleep(Duration::from_secs(1)), if regex.is_some() => {
                let current_url = page
                    .url()
                    .await
                    .map_err(|error| AppError::new(EXIT_USER, format!("completion URL poll: {error}")))?;
                if let (Some(url_str), Some(regex)) = (current_url.as_deref(), regex.as_ref()) {
                    if regex.is_match(url_str) {
                        return Ok(());
                    }
                }
            }
            _ = async {
                if let Some(monitor) = monitor {
                    monitor.notify_clone().notified().await;
                } else {
                    std::future::pending::<()>().await;
                }
            } => {
                return Err(AppError::new(EXIT_LEAK, "vpn leak detected during capture"));
            }
        }
    }
}

async fn prepare_vpn_context() -> anyhow::Result<VpnContext> {
    if std::env::var("REV_SCRAPING_TEST_SKIP_VPN").ok().as_deref() == Some("1") {
        return Ok(VpnContext {
            selection: None,
            monitor: None,
        });
    }
    let policy = load_policy()?.with_env_overrides();
    let require_vpn = effective_require_vpn(&policy);
    if !require_vpn {
        return Ok(VpnContext {
            selection: None,
            monitor: None,
        });
    }
    if policy.vpn_instances.is_empty() {
        return Err(anyhow!(
            "require_vpn=true but no VPN instances configured (VPN_INSTANCES env / ~/.rev_scraping/policy.toml is empty)"
        ));
    }
    let descriptors: Vec<InstanceDescriptor> = policy
        .vpn_instances
        .iter()
        .map(|instance| InstanceDescriptor {
            name: instance.name.clone(),
            http_proxy_port: instance.http_proxy_port,
            control_port: instance.control_port,
        })
        .collect();
    probe_all(&descriptors, policy.vpn_required_country.as_deref())
        .await
        .map_err(|error| anyhow!("{error}"))?;

    let pool_instances: Vec<PoolVpnInstance> = policy
        .vpn_instances
        .iter()
        .map(|instance| PoolVpnInstance {
            name: instance.name.clone(),
            http_proxy_port: instance.http_proxy_port,
            control_port: instance.control_port,
        })
        .collect();
    let pool = InstancePool::new(pool_instances.clone());
    let selection = pool
        .pick(&Uuid::new_v4().to_string())
        .cloned()
        .ok_or_else(|| anyhow!("vpn pool has no healthy instances"))?;
    let monitor = LeakMonitor::spawn(
        pool_instances,
        policy.vpn_required_country,
        Duration::from_secs(30),
    );
    Ok(VpnContext {
        selection: Some(selection),
        monitor: Some(monitor),
    })
}

fn effective_require_vpn(policy: &Policy) -> bool {
    if std::env::var("REV_SCRAPING_REQUIRE_VPN").ok().as_deref() == Some("1") {
        return true;
    }
    policy.require_vpn
}

fn load_policy() -> anyhow::Result<Policy> {
    let Some(home) = dirs::home_dir() else {
        return Ok(Policy {
            require_vpn: true,
            vpn_required_country: None,
            vpn_instances: Vec::new(),
        });
    };
    let path = home.join(".rev_scraping").join("policy.toml");
    if !path.exists() {
        return Ok(Policy {
            require_vpn: true,
            vpn_required_country: None,
            vpn_instances: Vec::new(),
        });
    }
    let raw = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))
}

impl Policy {
    fn with_env_overrides(mut self) -> Self {
        if let Ok(raw) = std::env::var("VPN_INSTANCES") {
            let parsed = parse_vpn_instances_env(&raw);
            if !parsed.is_empty() {
                self.vpn_instances = parsed;
            }
        }
        self
    }
}

fn parse_vpn_instances_env(raw: &str) -> Vec<PolicyVpnInstance> {
    raw.split(',')
        .filter_map(|item| {
            let parts: Vec<&str> = item.trim().split(':').collect();
            if parts.len() != 3 {
                return None;
            }
            Some(PolicyVpnInstance {
                name: parts[0].trim().to_string(),
                http_proxy_port: parts[1].trim().parse().ok()?,
                control_port: parts[2].trim().parse().ok()?,
            })
        })
        .collect()
}

struct ProfileDir {
    temp: Option<tempfile::TempDir>,
    path: PathBuf,
}

impl ProfileDir {
    fn prepare(user_data_dir: Option<&Path>) -> anyhow::Result<Self> {
        if let Some(path) = user_data_dir {
            fs::create_dir_all(path)?;
            storage::set_dir_permissions_0700(path)?;
            return Ok(Self {
                temp: None,
                path: path.to_path_buf(),
            });
        }
        let temp = tempfile::Builder::new()
            .prefix("rev-auth-profile-")
            .tempdir()?;
        storage::set_dir_permissions_0700(temp.path())?;
        Ok(Self {
            path: temp.path().to_path_buf(),
            temp: Some(temp),
        })
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn cleanup(self) {
        if self.temp.is_some() {
            let _ = shred_tree(&self.path);
        }
    }
}

fn shred_tree(path: &Path) -> anyhow::Result<()> {
    if !path.exists() {
        return Ok(());
    }
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let child = entry.path();
        if child.is_dir() {
            shred_tree(&child)?;
            let _ = fs::remove_dir(&child);
        } else {
            storage::shred_delete(&child)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration as ChronoDuration;
    use clap::Parser;
    use secrecy::ExposeSecret;
    use std::sync::Mutex;

    fn login_args() -> LoginArgs {
        LoginArgs {
            profile: "instagram_personal".to_string(),
            url: "https://login.example.com/".to_string(),
            domain: "example.com".to_string(),
            user_data_dir: None,
            completion_pattern: None,
            aad_context: "ctx".to_string(),
            obscura_bin: None,
            chrome_bin: None,
            mcp_session_token: None,
            display: DisplayMode::Auto,
            headless: false,
            xvfb: false,
        }
    }

    #[derive(Default)]
    struct FakeEnv {
        values: Vec<(&'static str, String)>,
    }

    impl FakeEnv {
        fn with(mut self, key: &'static str, value: impl Into<String>) -> Self {
            self.values.push((key, value.into()));
            self
        }
    }

    impl EnvLookup for FakeEnv {
        fn get(&self, key: &str) -> Option<String> {
            self.values
                .iter()
                .rev()
                .find_map(|(name, value)| (*name == key).then(|| value.clone()))
        }
    }

    fn cdp_cookie(name: &str, value: &str, domain: &str) -> CdpCookie {
        serde_json::from_value(serde_json::json!({
            "name": name,
            "value": value,
            "domain": domain,
            "path": "/",
            "expires": -1.0,
            "size": value.len(),
            "httpOnly": true,
            "secure": true,
            "session": true,
            "priority": "Medium",
            "sourceScheme": "Secure",
            "sourcePort": 443
        }))
        .unwrap()
    }

    #[test]
    fn cli_parses_login_subcommand() {
        let cli = Cli::try_parse_from([
            "rev-auth",
            "login",
            "--profile",
            "instagram_personal",
            "--url",
            "https://instagram.com/accounts/login/",
            "--domain",
            "instagram.com",
        ])
        .unwrap();
        let Command::Login(args) = cli.command;
        assert_eq!(args.profile, "instagram_personal");
        assert_eq!(args.domain, "instagram.com");
    }

    #[test]
    fn cli_rejects_missing_required_args() {
        assert!(Cli::try_parse_from([
            "rev-auth",
            "login",
            "--url",
            "https://example.com/",
            "--domain",
            "example.com",
        ])
        .is_err());
        assert!(Cli::try_parse_from([
            "rev-auth",
            "login",
            "--profile",
            "p",
            "--domain",
            "example.com",
        ])
        .is_err());
    }

    #[test]
    fn aup_enforcement_still_required() {
        let list = auth_aup::AuthorizedFile {
            targets: vec![auth_aup::Target {
                url_pattern: r"^https://example\.com/".to_string(),
                auth_allowed: Some(false),
            }],
        };
        let decision = auth_aup::decide("example.com", "https://example.com/login", Some(&list));
        assert!(matches!(decision, AuthAupDecision::Rejected { .. }));
    }

    #[test]
    fn aup_allows_auth_allowed_target() {
        let list = auth_aup::AuthorizedFile {
            targets: vec![auth_aup::Target {
                url_pattern: r"^https://example\.com/".to_string(),
                auth_allowed: Some(true),
            }],
        };
        let decision = auth_aup::decide("example.com", "https://example.com/login", Some(&list));
        assert_eq!(decision, AuthAupDecision::Allowed);
    }

    #[test]
    fn cookie_extraction_via_filter_cdp_cookies_unchanged() {
        let mut raw = [
            cdp_cookie("sid", "SECRET_VALUE_1234567890", ".example.com"),
            cdp_cookie("pref", "SECRET_VALUE_ABCDEFGHIJ", "login.example.com"),
            cdp_cookie("other", "SECRET_VALUE_ZZZZZZZZZZ", "example.org"),
        ];
        let filtered = filter_cdp_cookies(raw.iter_mut(), "example.com").unwrap();
        assert_eq!(filtered.len(), 2);
        assert!(filtered.iter().all(|cookie| {
            registrable_domain(&cookie.domain).as_deref() == Some("example.com")
        }));
    }

    #[test]
    fn cookie_extraction_skips_third_party_domains() {
        let mut raw = [
            cdp_cookie("sid", "SECRET_VALUE_1234567890", "example.com"),
            cdp_cookie("trk", "SECRET_VALUE_TRACKERXXX", "tracker.net"),
        ];
        let filtered = filter_cdp_cookies(raw.iter_mut(), "example.com").unwrap();
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].name, "sid");
    }

    #[test]
    fn completion_pattern_regex_validates() {
        let mut args = login_args();
        args.completion_pattern = Some("(".to_string());
        assert!(validate_login_args(&args).is_err());
    }

    #[test]
    fn display_mode_auto_macos_resolves_headed() {
        let mode = resolve_display_mode(&FakeEnv::default(), TargetOs::Macos);
        assert_eq!(mode, DisplayMode::Headed);
    }

    #[test]
    fn display_mode_auto_linux_with_display_resolves_headed() {
        let env = FakeEnv::default().with("DISPLAY", ":99");
        let mode = resolve_display_mode(&env, TargetOs::Linux);
        assert_eq!(mode, DisplayMode::Headed);
    }

    #[test]
    fn display_mode_auto_linux_no_display_no_xvfb_resolves_headless() {
        let decision = resolve_auto_display_mode(&FakeEnv::default(), TargetOs::Linux);
        assert_eq!(decision.mode, DisplayMode::Headless);
        assert!(
            decision
                .warnings
                .iter()
                .any(|warning| warning.contains("DISPLAY is unset")),
            "expected DISPLAY warning, got: {:?}",
            decision.warnings
        );
    }

    #[test]
    fn display_mode_auto_linux_no_display_with_xvfb_optin_resolves_xvfb() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("xvfb-run"), b"fake").unwrap();
        let env = FakeEnv::default()
            .with("REV_AUTH_AUTO_XVFB", "1")
            .with("PATH", temp.path().display().to_string());
        let mode = resolve_display_mode(&env, TargetOs::Linux);
        assert_eq!(mode, DisplayMode::Xvfb);
    }

    #[test]
    fn display_mode_explicit_headless_overrides_macos_default() {
        let mut args = login_args();
        args.display = DisplayMode::Headless;
        let decision =
            resolve_login_display_mode_decision(&args, &FakeEnv::default(), TargetOs::Macos);
        assert_eq!(decision.mode, DisplayMode::Headless);
        assert!(decision.warnings.is_empty());
    }

    #[test]
    fn legacy_rev_auth_headless_env_alias_maps_to_headless() {
        let args = login_args();
        let env = FakeEnv::default().with("REV_AUTH_HEADLESS", "1");
        let decision = resolve_login_display_mode_decision(&args, &env, TargetOs::Linux);
        assert_eq!(decision.mode, DisplayMode::Headless);
        assert!(
            decision
                .warnings
                .iter()
                .any(|warning| warning.contains("REV_AUTH_HEADLESS is deprecated")),
            "expected legacy deprecation warning, got: {:?}",
            decision.warnings
        );
    }

    struct RecordingStore {
        aad: Mutex<Option<String>>,
    }

    impl CookieStore for RecordingStore {
        fn save_cookies(
            &self,
            _profile: &str,
            _cookies: &[Cookie],
            aad_context: &str,
        ) -> anyhow::Result<()> {
            *self.aad.lock().unwrap() = Some(aad_context.to_string());
            Ok(())
        }
    }

    #[test]
    fn save_cookies_invokes_authstore_with_correct_aad() {
        let store = RecordingStore {
            aad: Mutex::new(None),
        };
        let cookie = Cookie {
            name: "sid".to_string(),
            value: SecretString::from("SECRET_VALUE_1234567890".to_string()),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: true,
            http_only: true,
            same_site: SameSite::Lax,
        };
        save_cookies_with_store(&store, "p", &[cookie], "aad-route-1").unwrap();
        assert_eq!(store.aad.lock().unwrap().as_deref(), Some("aad-route-1"));
    }

    #[test]
    fn exit_code_4_on_authexpired_path() {
        let expired = Utc::now() - ChronoDuration::minutes(5);
        let cookies = vec![Cookie {
            name: "sid".to_string(),
            value: SecretString::from("SECRET_VALUE_1234567890".to_string()),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: Some(expired),
            secure: true,
            http_only: true,
            same_site: SameSite::Lax,
        }];
        assert!(all_cookies_expired(&cookies, Utc::now()));
        assert_eq!(EXIT_AUTH_EXPIRED, 4);
    }

    // ----- Phase 9 hotfix-1: chrome rewire tests -----

    /// Serialize env-mutating tests so they don't race each other.
    fn env_test_lock() -> &'static std::sync::Mutex<()> {
        static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
        LOCK.get_or_init(|| std::sync::Mutex::new(()))
    }

    fn restore_env_var(name: &str, old_value: Option<std::ffi::OsString>) {
        if let Some(value) = old_value {
            std::env::set_var(name, value);
        } else {
            std::env::remove_var(name);
        }
    }

    #[test]
    fn chrome_binary_resolves_from_env_var() {
        let _g = env_test_lock().lock().unwrap();
        let old_chrome = std::env::var_os("REV_AUTH_CHROME_BIN");
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::env::set_var("REV_AUTH_CHROME_BIN", tmp.path());
        let resolved = resolve_chrome_binary(None).unwrap();
        restore_env_var("REV_AUTH_CHROME_BIN", old_chrome);
        assert_eq!(resolved, tmp.path());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn chrome_binary_resolves_from_macos_standard_paths() {
        let _g = env_test_lock().lock().unwrap();
        let old_chrome = std::env::var_os("REV_AUTH_CHROME_BIN");
        std::env::remove_var("REV_AUTH_CHROME_BIN");
        // We cannot reliably assert the hardcoded path exists in every CI env,
        // so this test only fires when Chrome is actually installed locally.
        let Some(expected) = standard_chrome_paths()
            .into_iter()
            .find(|path| path.is_file())
        else {
            restore_env_var("REV_AUTH_CHROME_BIN", old_chrome);
            return;
        };
        let resolved = resolve_chrome_binary(None).expect("macOS Chrome should resolve");
        restore_env_var("REV_AUTH_CHROME_BIN", old_chrome);
        assert_eq!(resolved, expected);
    }

    #[test]
    fn chrome_binary_returns_error_when_missing() {
        let _g = env_test_lock().lock().unwrap();
        let old_chrome = std::env::var_os("REV_AUTH_CHROME_BIN");
        let old_path = std::env::var_os("PATH");
        let empty_path = tempfile::tempdir().unwrap();
        std::env::set_var(
            "REV_AUTH_CHROME_BIN",
            "/nonexistent/path/to/chrome-xyzzy-not-here",
        );
        std::env::set_var("PATH", empty_path.path());
        let err = resolve_chrome_binary(None).unwrap_err();
        restore_env_var("REV_AUTH_CHROME_BIN", old_chrome);
        restore_env_var("PATH", old_path);
        let msg = err.to_string();
        assert!(
            msg.contains("not found"),
            "expected not-found error, got: {msg}"
        );
    }

    #[test]
    fn display_mode_headed_config_uses_with_head() {
        let tmp_chrome = tempfile::NamedTempFile::new().unwrap();
        let tmp_profile = tempfile::tempdir().unwrap();
        let cfg = build_chrome_config_with_vpn_and_env(
            tmp_chrome.path(),
            tmp_profile.path(),
            None,
            DisplayMode::Headed,
            &FakeEnv::default(),
        )
        .expect("headed config should build");
        let dbg = format!("{cfg:?}");
        assert!(
            dbg.contains("headless: False"),
            "expected headed BrowserConfig, got: {dbg}"
        );
    }

    #[test]
    fn display_mode_headless_config_omits_with_head() {
        let tmp_chrome = tempfile::NamedTempFile::new().unwrap();
        let tmp_profile = tempfile::tempdir().unwrap();
        let cfg = build_chrome_config_with_vpn_and_env(
            tmp_chrome.path(),
            tmp_profile.path(),
            None,
            DisplayMode::Headless,
            &FakeEnv::default(),
        )
        .expect("headless config should build");
        let dbg = format!("{cfg:?}");
        assert!(
            dbg.contains("headless: New"),
            "expected new headless BrowserConfig, got: {dbg}"
        );
        assert!(
            !dbg.contains("headless: False"),
            "headless config must not call with_head(), got: {dbg}"
        );
    }

    #[test]
    fn display_mode_xvfb_requires_xvfb_run_on_path() {
        let tmp_chrome = tempfile::NamedTempFile::new().unwrap();
        let tmp_profile = tempfile::tempdir().unwrap();
        let err = build_chrome_config_with_vpn_and_env(
            tmp_chrome.path(),
            tmp_profile.path(),
            None,
            DisplayMode::Xvfb,
            &FakeEnv::default(),
        )
        .expect_err("xvfb mode must fail when xvfb-run is absent");
        assert!(
            err.contains("xvfb-run not found"),
            "unexpected xvfb error: {err}"
        );
    }

    #[test]
    fn display_mode_xvfb_config_uses_with_head_when_xvfb_run_exists() {
        let bin_dir = tempfile::tempdir().unwrap();
        fs::write(bin_dir.path().join("xvfb-run"), b"fake").unwrap();
        let env = FakeEnv::default().with("PATH", bin_dir.path().display().to_string());
        let tmp_chrome = tempfile::NamedTempFile::new().unwrap();
        let tmp_profile = tempfile::tempdir().unwrap();
        let cfg = build_chrome_config_with_vpn_and_env(
            tmp_chrome.path(),
            tmp_profile.path(),
            None,
            DisplayMode::Xvfb,
            &env,
        )
        .expect("xvfb config should build when xvfb-run exists");
        let dbg = format!("{cfg:?}");
        assert!(
            dbg.contains("headless: False"),
            "expected xvfb to use headed Chrome config, got: {dbg}"
        );
    }

    /// Regression: chromiumoxide must launch through the xvfb-run wrapper
    /// shim, not the raw Chrome binary. The shim path is materialised under
    /// the per-profile user_data_dir, contains the literal substring
    /// `xvfb-run`, and is set as the BrowserConfig executable so that
    /// chromiumoxide's spawn path runs `xvfb-run -a -- <chrome>` instead of
    /// starting Chrome directly against a non-existent DISPLAY.
    #[test]
    fn xvfb_mode_uses_xvfb_run_executable() {
        let bin_dir = tempfile::tempdir().unwrap();
        let xvfb_run = bin_dir.path().join("xvfb-run");
        fs::write(&xvfb_run, b"#!/bin/sh\nexec \"$@\"\n").unwrap();
        let env = FakeEnv::default().with("PATH", bin_dir.path().display().to_string());
        let tmp_chrome = tempfile::NamedTempFile::new().unwrap();
        let tmp_profile = tempfile::tempdir().unwrap();
        let cfg = build_chrome_config_with_vpn_and_env(
            tmp_chrome.path(),
            tmp_profile.path(),
            None,
            DisplayMode::Xvfb,
            &env,
        )
        .expect("xvfb config should build when xvfb-run is on PATH");
        let dbg = format!("{cfg:?}");
        assert!(
            dbg.contains("xvfb-run"),
            "expected xvfb wrapper to appear in BrowserConfig Debug, got: {dbg}"
        );
        // The shim must be a real file under the per-profile data dir so the
        // chromiumoxide canonicalize step succeeds at launch time.
        let shim = tmp_profile.path().join("rev-auth-xvfb-run.sh");
        assert!(
            shim.is_file(),
            "expected xvfb-run shim to be materialised at {}",
            shim.display()
        );
        let script = fs::read_to_string(&shim).expect("shim must be readable");
        assert!(
            script.contains("xvfb-run") && script.contains("-a") && script.contains("--"),
            "shim must invoke xvfb-run with -a and a `--` separator, got: {script}"
        );
        assert!(
            script.contains(tmp_chrome.path().to_str().unwrap()),
            "shim must forward to the requested chrome binary, got: {script}"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&shim).unwrap().permissions().mode() & 0o777;
            assert_eq!(
                mode, 0o700,
                "xvfb-run shim must be owner-only executable, got mode {mode:o}"
            );
        }
    }

    /// Regression: requesting `--display xvfb` on a host that lacks
    /// `xvfb-run` must fail closed instead of silently producing a config
    /// that launches a raw, headed Chrome against an empty DISPLAY.
    #[test]
    fn xvfb_mode_falls_back_to_error_when_xvfb_run_missing() {
        // Point PATH at a directory that exists but contains nothing — so
        // resolve_command_path returns None even though PATH is set.
        let empty_dir = tempfile::tempdir().unwrap();
        let env = FakeEnv::default().with("PATH", empty_dir.path().display().to_string());
        let tmp_chrome = tempfile::NamedTempFile::new().unwrap();
        let tmp_profile = tempfile::tempdir().unwrap();
        let err = build_chrome_config_with_vpn_and_env(
            tmp_chrome.path(),
            tmp_profile.path(),
            None,
            DisplayMode::Xvfb,
            &env,
        )
        .expect_err("xvfb mode must fail when xvfb-run is missing");
        assert!(
            err.contains("xvfb-run not found"),
            "unexpected xvfb error: {err}"
        );
        // And no shim must have been written before the failure.
        let shim = tmp_profile.path().join("rev-auth-xvfb-run.sh");
        assert!(
            !shim.exists(),
            "xvfb-run shim must not be created when wrapper is missing"
        );
    }

    #[test]
    fn build_chrome_config_appends_vpn_proxy_args() {
        let tmp_chrome = tempfile::NamedTempFile::new().unwrap();
        let tmp_profile = tempfile::tempdir().unwrap();
        let selection = PoolVpnInstance {
            name: "test-vpn".to_string(),
            http_proxy_port: 18080,
            control_port: 19051,
        };
        let cfg = build_chrome_config_with_vpn(
            tmp_chrome.path(),
            tmp_profile.path(),
            Some(&selection),
            DisplayMode::Headed,
        )
        .unwrap();
        let dbg = format!("{cfg:?}");
        assert!(
            dbg.contains("proxy-server") && dbg.contains("127.0.0.1:18080"),
            "expected proxy-server arg to appear in config args, got: {dbg}"
        );
    }

    #[test]
    fn test_chrome_config_includes_macos_dialog_suppression_flags() {
        let tmp_chrome = tempfile::NamedTempFile::new().unwrap();
        let tmp_profile = tempfile::tempdir().unwrap();
        let cfg = build_chrome_config(tmp_chrome.path(), tmp_profile.path())
            .expect("build_chrome_config should succeed for valid inputs");
        let args = format!("{cfg:?}");
        for expected in [
            "noerrdialogs",
            "no-crash-upload",
            "disable-component-update",
            "disable-domain-reliability",
            "use-mock-keychain",
        ] {
            assert!(
                args.contains(expected),
                "expected Chrome arg containing {expected:?}, got: {args}"
            );
        }
        assert!(
            args.contains("disable-features")
                && args.contains("Crashpad")
                && args.contains("CrashpadReporter"),
            "expected Crashpad suppression in disable-features args, got: {args}"
        );
    }

    #[test]
    fn test_chrome_config_breakpad_flags_present() {
        let tmp_chrome = tempfile::NamedTempFile::new().unwrap();
        let tmp_profile = tempfile::tempdir().unwrap();
        let cfg = build_chrome_config(tmp_chrome.path(), tmp_profile.path())
            .expect("build_chrome_config should succeed for valid inputs");
        let args = format!("{cfg:?}");
        for expected in [
            "disable-breakpad",
            "disable-crash-reporter",
            "disable-crashpad",
        ] {
            assert!(
                args.contains(expected),
                "expected Chrome arg containing {expected:?}, got: {args}"
            );
        }
    }

    #[test]
    fn test_teardown_sleep_constant_is_1500ms() {
        assert_eq!(super::CHROME_TEARDOWN_FLUSH_MS, 1500);
    }

    #[test]
    fn test_chrome_config_debug_does_not_leak_cookie_value() {
        let tmp_chrome = tempfile::NamedTempFile::new().unwrap();
        let tmp_profile = tempfile::tempdir().unwrap();
        let cfg = build_chrome_config(tmp_chrome.path(), tmp_profile.path())
            .expect("build_chrome_config should succeed for valid inputs");
        let sentinel = "SENTINEL_COOKIE_VALUE_DO_NOT_LEAK";
        // ChromeConfig should not carry cookie material; this locks that in for
        // future refactors that might try to route cookies through launch args.
        let dbg = format!("{cfg:?}");
        assert!(
            !dbg.contains(sentinel),
            "ChromeConfig debug output unexpectedly contained sentinel cookie value"
        );
    }

    #[test]
    fn cli_accepts_chrome_bin_flag() {
        let cli = Cli::try_parse_from([
            "rev-auth",
            "login",
            "--profile",
            "p",
            "--url",
            "https://example.com/",
            "--domain",
            "example.com",
            "--chrome-bin",
            "/usr/local/bin/some-chrome",
        ])
        .unwrap();
        let Command::Login(args) = cli.command;
        assert_eq!(
            args.chrome_bin.as_deref(),
            Some(Path::new("/usr/local/bin/some-chrome"))
        );
    }

    #[test]
    #[ignore]
    fn e2e_headed_chrome_opens_window_against_about_blank() {
        // Run with: REV_AUTH_RUN_HEADED_E2E=1 cargo test -- --ignored
        if std::env::var("REV_AUTH_RUN_HEADED_E2E").as_deref() != Ok("1") {
            return;
        }
        let chrome = resolve_chrome_binary(None).expect("chrome must be installed for e2e");
        let tmp_profile = tempfile::tempdir().unwrap();
        let cfg = build_chrome_config(&chrome, tmp_profile.path()).unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async move {
            let (mut browser, mut handler) = Browser::launch(cfg).await.unwrap();
            let task = tokio::spawn(async move { while handler.next().await.is_some() {} });
            let page = browser.new_page("about:blank").await.unwrap();
            let _ = page.close().await;
            let _ = browser.close().await;
            let _ = browser.wait().await;
            task.abort();
        });
    }

    #[test]
    #[ignore = "requires REV_AUTH_RUN_XVFB_E2E=1, xvfb-run, and local Chrome"]
    fn xvfb_login_smoke() {
        if std::env::var("REV_AUTH_RUN_XVFB_E2E").as_deref() != Ok("1") {
            return;
        }
        if !command_on_path(&ProcessEnv, "xvfb-run") {
            return;
        }
        let chrome = resolve_chrome_binary(None).expect("chrome must be installed for xvfb smoke");
        let tmp_profile = tempfile::tempdir().unwrap();
        let cfg =
            build_chrome_config_with_vpn(&chrome, tmp_profile.path(), None, DisplayMode::Xvfb)
                .expect("xvfb config should build when xvfb-run is present");
        let dbg = format!("{cfg:?}");
        assert!(
            dbg.contains("headless: False"),
            "expected xvfb smoke to use headed config, got: {dbg}"
        );
    }

    #[test]
    fn panic_hook_redacts_cookie_value() {
        let value = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890";
        let redacted = stealth_auth::redact::redact_text(value);
        assert_eq!(redacted, "<redacted>");
        let cookie = Cookie {
            name: "sid".to_string(),
            value: SecretString::from(value.to_string()),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: true,
            http_only: true,
            same_site: SameSite::Lax,
        };
        assert_eq!(cookie.value.expose_secret(), value);
        assert!(!format!("{cookie:?}").contains(value));
    }

    // ---------------------------------------------------------------------
    // P6 / B5 — Linux parity tests
    //
    // These tests are gated on `target_os = "linux"` and verify that the
    // Chrome binary discovery logic resolves real binaries on PATH using the
    // canonical Linux package names. They mirror the existing macOS
    // `chrome_binary_resolves_from_macos_standard_paths` test.
    // ---------------------------------------------------------------------

    #[cfg(target_os = "linux")]
    fn linux_create_fake_chrome(dir: &Path, name: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join(name);
        fs::write(&path, b"#!/bin/sh\necho fake-chrome\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn chrome_binary_resolves_via_which_google_chrome_on_linux() {
        let _g = env_test_lock().lock().unwrap();
        let old_chrome = std::env::var_os("REV_AUTH_CHROME_BIN");
        let old_path = std::env::var_os("PATH");
        std::env::remove_var("REV_AUTH_CHROME_BIN");

        let tmp = tempfile::tempdir().unwrap();
        let expected = linux_create_fake_chrome(tmp.path(), "google-chrome");
        std::env::set_var("PATH", tmp.path());

        let resolved = resolve_chrome_binary(None);
        restore_env_var("REV_AUTH_CHROME_BIN", old_chrome);
        restore_env_var("PATH", old_path);
        let resolved = resolved.expect("google-chrome on PATH must resolve");
        assert_eq!(resolved, expected);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn chrome_binary_resolves_via_which_chromium_browser_on_linux() {
        let _g = env_test_lock().lock().unwrap();
        let old_chrome = std::env::var_os("REV_AUTH_CHROME_BIN");
        let old_path = std::env::var_os("PATH");
        std::env::remove_var("REV_AUTH_CHROME_BIN");

        let tmp = tempfile::tempdir().unwrap();
        // Only install `chromium-browser`, not `google-chrome`. The resolver
        // must fall through to the third candidate.
        let expected = linux_create_fake_chrome(tmp.path(), "chromium-browser");
        std::env::set_var("PATH", tmp.path());

        let resolved = resolve_chrome_binary(None);
        restore_env_var("REV_AUTH_CHROME_BIN", old_chrome);
        restore_env_var("PATH", old_path);
        let resolved = resolved.expect("chromium-browser on PATH must resolve");
        assert_eq!(resolved, expected);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn chrome_binary_env_override_wins_on_linux() {
        // Even when PATH contains google-chrome, REV_AUTH_CHROME_BIN must win.
        let _g = env_test_lock().lock().unwrap();
        let old_chrome = std::env::var_os("REV_AUTH_CHROME_BIN");
        let old_path = std::env::var_os("PATH");

        let path_dir = tempfile::tempdir().unwrap();
        let _path_chrome = linux_create_fake_chrome(path_dir.path(), "google-chrome");

        let override_file = tempfile::NamedTempFile::new().unwrap();
        std::env::set_var("REV_AUTH_CHROME_BIN", override_file.path());
        std::env::set_var("PATH", path_dir.path());

        let resolved = resolve_chrome_binary(None);
        restore_env_var("REV_AUTH_CHROME_BIN", old_chrome);
        restore_env_var("PATH", old_path);
        let resolved = resolved.expect("env override must resolve");
        assert_eq!(resolved, override_file.path());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn chrome_binary_returns_error_when_nothing_on_path_linux() {
        // No env override, empty PATH → BinaryNotFound style error.
        let _g = env_test_lock().lock().unwrap();
        let old_chrome = std::env::var_os("REV_AUTH_CHROME_BIN");
        let old_path = std::env::var_os("PATH");
        std::env::remove_var("REV_AUTH_CHROME_BIN");

        let empty = tempfile::tempdir().unwrap();
        std::env::set_var("PATH", empty.path());

        let err = resolve_chrome_binary(None);
        restore_env_var("REV_AUTH_CHROME_BIN", old_chrome);
        restore_env_var("PATH", old_path);
        let err = err.expect_err("must error when no chrome on PATH");
        let msg = err.to_string();
        assert!(
            msg.contains("not found") || msg.contains("Chrome"),
            "unexpected error message: {msg}"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn auth_file_perm_0600_on_linux() {
        // Verify storage helper applies 0600 to a regular file under Linux,
        // mirroring the macOS guarantee. Uses the shared
        // `set_file_permissions_0600` helper to avoid coupling the test to
        // any specific filename layout.
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("creds.enc");
        fs::write(&path, b"x").unwrap();
        // Start with permissive mode to prove the helper tightens it.
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        storage::set_file_permissions_0600(&path).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o7777;
        assert_eq!(mode, 0o600, "file mode must be 0600 on Linux, got {mode:o}");

        // And dir 0700 for the profile directory.
        let dir = tmp.path().join("profile-dir");
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        storage::set_dir_permissions_0700(&dir).unwrap();
        let dmode = fs::metadata(&dir).unwrap().permissions().mode() & 0o7777;
        assert_eq!(
            dmode, 0o700,
            "dir mode must be 0700 on Linux, got {dmode:o}"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    #[ignore = "requires headed Chrome on Linux; run with --ignored when chrome is installed"]
    fn linux_chrome_supports_with_head_flag() {
        // Smoke test: build_chrome_config wires `.with_head()` (headless=False)
        // and a Linux-resolved binary works through the same path as macOS.
        let chrome = resolve_chrome_binary(None).expect("chrome must be installed for ignored e2e");
        let tmp_profile = tempfile::tempdir().unwrap();
        let cfg = build_chrome_config(&chrome, tmp_profile.path()).unwrap();
        let dbg = format!("{cfg:?}");
        assert!(
            dbg.contains("headless: False"),
            "expected headed mode on Linux"
        );
    }
}
