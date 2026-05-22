// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9d (rev-stealth auth CLI surface)
//! `rev-stealth auth <subcommand>` boilerplate.
//!
//! Boilerplate scope only: clap dispatch + `AuthStore` wiring + JSON output.
//! All cryptography, capture, and replay logic lives in `stealth-auth`
//! (Phase 9a) and the `rev-auth` helper binary (Phase 9b). `auth login` and
//! `auth refresh` shell out to `rev-auth` so the headed browser stays in an
//! isolated subprocess.
//!
//! Cookie *values* are never printed, logged, or serialized by this module.
//! Only `ProfileMeta`-level metadata (domain list, sha256 prefixes, expiry
//! buckets) is surfaced. The `Cookie::Debug` impl in `stealth-auth` enforces
//! `<redacted>` at the type boundary.

use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::process::Command as ProcessCommand;

use clap::{Args, Subcommand};
use serde_json::json;
use stealth_auth::auth_aup::{self, AuthAupDecision};
use stealth_auth::{AuthStore, AuthStoreError, ProfileStatus};

use crate::commands::auth_replay::default_auth_store_dir;
use crate::OutputFormat;

const EXIT_OK: i32 = 0;
const EXIT_USER: i32 = 1;
const EXIT_TRANSIENT: i32 = 2;
const EXIT_PERMANENT: i32 = 3;
const EXIT_AUTH_EXPIRED: i32 = 4;
const EXIT_LEAK: i32 = 7;
const EXIT_ABORTED: i32 = 12;

#[derive(Args, Debug)]
pub struct AuthArgs {
    /// v1.3 Lane G.4: per-subcommand `--output-format` override of the
    /// global `--format`. JSON schema: `docs/json-schemas/cli/auth.output.json`.
    /// Position-tolerant: `rev-stealth auth --output-format json list` works.
    #[command(flatten)]
    pub output_format: crate::commands::output_format::OutputFormatOverride,
    #[command(subcommand)]
    pub action: AuthAction,
}

#[derive(Subcommand, Debug)]
pub enum AuthAction {
    /// Spawn `rev-auth` for interactive login; AUP-gated.
    #[command(
        long_about = "Spawn the rev-auth helper to perform an interactive login \
against --url for the given --profile. The captured cookie blob is sealed and \
written to AuthStore. AUP-gated; --i-have-authorization is required for hosts \
outside the authorized.toml allowlist.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth auth login --profile work --url https://x.test\n  \
$ rev-stealth auth login --profile work --url https://x.test --domain x.test --require-vpn\n  \
$ rev-stealth auth login --profile demo --url https://x.test --rev-auth-bin /usr/local/bin/rev-auth\n\n\
EXIT CODES:\n  \
0  Ok               Profile saved.\n  \
1  UserError        Bad args / AUP rejection / unknown profile mode.\n  \
3  PermanentError   rev-auth missing / AuthStore IO failure.\n  \
4  AuthExpired      Captured profile is empty/unusable.\n\n\
ENV:\n  \
REV_OBSCURA_BIN              Override the obscura binary path.\n  \
REV_AUTH_BIN                 Override the rev-auth helper binary.\n  \
REV_SCRAPING_AUTH_DIR        Override the AuthStore directory.\n  \
REV_SCRAPING_AUTH_PASSPHRASE Sealed-store passphrase (else keystore-derived).\n  \
REV_SCRAPING_REQUIRE_VPN     When `1`, enforces VPN-required guard."
    )]
    Login(LoginArgs),
    /// List saved profiles (metadata only, cookie values never disclosed).
    #[command(
        long_about = "List every saved AuthStore profile. Only metadata is emitted \
(profile name, domain, created_at, expires_at, source); cookie values are \
never disclosed.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth auth list\n  \
$ rev-stealth --format json auth list\n\n\
EXIT CODES:\n  \
0  Ok               Listing emitted.\n  \
1  UserError        Bad args.\n  \
3  PermanentError   AuthStore unavailable.\n\n\
ENV:\n  \
REV_SCRAPING_AUTH_DIR        Override the AuthStore directory."
    )]
    List(ListArgs),
    /// Show a single profile's metadata (redacted).
    #[command(
        long_about = "Show a single profile's metadata. Cookie values are redacted; \
only domain / timestamps / source / AAD context are returned.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth auth show --profile work\n  \
$ rev-stealth --format json auth show --profile work\n\n\
EXIT CODES:\n  \
0  Ok               Metadata emitted.\n  \
1  UserError        Bad args / unknown profile.\n  \
3  PermanentError   AuthStore unavailable.\n\n\
ENV:\n  \
REV_SCRAPING_AUTH_DIR        Override the AuthStore directory."
    )]
    Show(ShowArgs),
    /// Delete a profile with shred-on-delete.
    #[command(
        long_about = "Delete a profile with best-effort shred-on-delete (overwrite \
then unlink). Refuses without --force when stdin is a TTY; --force is required \
for non-interactive use.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth auth delete --profile work\n  \
$ rev-stealth auth delete --profile work --force\n\n\
EXIT CODES:\n  \
0  Ok               Profile removed.\n  \
1  UserError        Bad args / user declined / unknown profile.\n  \
3  PermanentError   AuthStore unavailable / shred IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_AUTH_DIR        Override the AuthStore directory."
    )]
    Delete(DeleteArgs),
    /// Report freshness/expiry status for a profile.
    #[command(
        long_about = "Report freshness / expiry status for the given profile. \
Returns exit 4 when the stored profile is expired or empty, so callers can \
distinguish refresh-needed from hard failures.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth auth status --profile work\n  \
$ rev-stealth --format json auth status --profile work\n\n\
EXIT CODES:\n  \
0  Ok               Profile is fresh.\n  \
1  UserError        Bad args / unknown profile.\n  \
3  PermanentError   AuthStore unavailable.\n  \
4  AuthExpired      Profile expired / unusable.\n\n\
ENV:\n  \
REV_SCRAPING_AUTH_DIR        Override the AuthStore directory."
    )]
    Status(StatusArgs),
    /// Re-run interactive login, overwriting an existing profile.
    #[command(
        long_about = "Re-run the rev-auth interactive login flow, overwriting an \
existing profile. Same surface as `auth login` but treats an existing profile \
as expected.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth auth refresh --profile work --url https://x.test\n  \
$ rev-stealth auth refresh --profile work --url https://x.test --require-vpn\n\n\
EXIT CODES:\n  \
0  Ok               Profile refreshed.\n  \
1  UserError        Bad args / AUP rejection.\n  \
3  PermanentError   rev-auth missing / AuthStore IO failure.\n  \
4  AuthExpired      Captured profile is empty/unusable after refresh.\n\n\
ENV:\n  \
REV_OBSCURA_BIN              Override the obscura binary path.\n  \
REV_AUTH_BIN                 Override the rev-auth helper binary.\n  \
REV_SCRAPING_AUTH_DIR        Override the AuthStore directory.\n  \
REV_SCRAPING_AUTH_PASSPHRASE Sealed-store passphrase (else keystore-derived).\n  \
REV_SCRAPING_REQUIRE_VPN     When `1`, enforces VPN-required guard."
    )]
    Refresh(RefreshArgs),
}

#[derive(Args, Debug, Clone)]
pub struct LoginArgs {
    #[arg(long)]
    pub profile: String,
    #[arg(long)]
    pub url: String,
    #[arg(long)]
    pub domain: Option<String>,
    #[arg(long)]
    pub completion_pattern: Option<String>,
    #[arg(long, env = "REV_OBSCURA_BIN")]
    pub obscura_bin: Option<PathBuf>,
    /// Override the `rev-auth` helper binary path (defaults to `which rev-auth`).
    #[arg(long, env = "REV_AUTH_BIN")]
    pub rev_auth_bin: Option<PathBuf>,
    /// Additional AAD context (e.g. proxy route) bound to the cookie blob.
    #[arg(long, default_value = "")]
    pub aad_context: String,
    /// Force the VPN-required guard ON for this invocation. Wins over
    /// `policy.toml`. Loses to env `REV_SCRAPING_REQUIRE_VPN=1`.
    #[arg(
        long = "require-vpn",
        conflicts_with = "allow_no_vpn",
        default_value_t = false
    )]
    pub require_vpn: bool,
    /// Allow this invocation to proceed without a VPN. Loses to env
    /// `REV_SCRAPING_REQUIRE_VPN=1`.
    #[arg(
        long = "allow-no-vpn",
        conflicts_with = "require_vpn",
        default_value_t = false
    )]
    pub allow_no_vpn: bool,
}

#[derive(Args, Debug, Clone)]
pub struct ListArgs {}

#[derive(Args, Debug, Clone)]
pub struct ShowArgs {
    #[arg(long)]
    pub profile: String,
}

#[derive(Args, Debug, Clone)]
pub struct DeleteArgs {
    #[arg(long)]
    pub profile: String,
    /// Skip the interactive confirmation prompt.
    #[arg(long)]
    pub force: bool,
}

#[derive(Args, Debug, Clone)]
pub struct StatusArgs {
    #[arg(long)]
    pub profile: String,
}

#[derive(Args, Debug, Clone)]
pub struct RefreshArgs {
    #[arg(long)]
    pub profile: String,
    #[arg(long)]
    pub url: String,
    #[arg(long)]
    pub domain: Option<String>,
    #[arg(long)]
    pub completion_pattern: Option<String>,
    #[arg(long, env = "REV_OBSCURA_BIN")]
    pub obscura_bin: Option<PathBuf>,
    #[arg(long, env = "REV_AUTH_BIN")]
    pub rev_auth_bin: Option<PathBuf>,
    #[arg(long, default_value = "")]
    pub aad_context: String,
    /// Force the VPN-required guard ON for this invocation. Wins over
    /// `policy.toml`. Loses to env `REV_SCRAPING_REQUIRE_VPN=1`.
    #[arg(
        long = "require-vpn",
        conflicts_with = "allow_no_vpn",
        default_value_t = false
    )]
    pub require_vpn: bool,
    /// Allow this invocation to proceed without a VPN. Loses to env
    /// `REV_SCRAPING_REQUIRE_VPN=1`.
    #[arg(
        long = "allow-no-vpn",
        conflicts_with = "require_vpn",
        default_value_t = false
    )]
    pub allow_no_vpn: bool,
}

pub async fn run(format: OutputFormat, args: AuthArgs) -> i32 {
    match args.action {
        AuthAction::Login(a) => run_login(format, a).await,
        AuthAction::List(_) => run_list(format),
        AuthAction::Show(a) => run_show(format, a),
        AuthAction::Delete(a) => run_delete(format, a, &mut StdinConfirm),
        AuthAction::Status(a) => run_status(format, a),
        AuthAction::Refresh(a) => run_refresh(format, a).await,
    }
}

async fn run_login(format: OutputFormat, args: LoginArgs) -> i32 {
    let domain = match resolve_domain(&args.url, args.domain.as_deref()) {
        Ok(d) => d,
        Err(msg) => {
            emit_err(format, "auth.login", EXIT_USER, &msg);
            return EXIT_USER;
        }
    };
    match auth_aup::enforce(&domain, &args.url) {
        AuthAupDecision::Allowed => {}
        AuthAupDecision::Rejected { message } => {
            emit_err(format, "auth.login", EXIT_USER, &format!("AUP: {message}"));
            return EXIT_USER;
        }
    }
    let policy = match crate::policy::Policy::load() {
        Ok(p) => p.with_env_overrides(),
        Err(e) => {
            emit_err(
                format,
                "auth.login",
                EXIT_PERMANENT,
                &format!("policy load: {e}"),
            );
            return EXIT_PERMANENT;
        }
    };
    let cli_tri = crate::policy::cli_flags_to_tristate(args.require_vpn, args.allow_no_vpn);
    let require_vpn = crate::policy::effective_require_vpn(cli_tri, &policy);
    if let Err(e) = crate::vpn_guard::run_startup_probe(require_vpn, &policy).await {
        let code = e.exit_code().as_i32();
        emit_err(format, "auth.login", code, &format!("{e}"));
        return code;
    }
    spawn_rev_auth_login(
        format,
        "auth.login",
        &args.profile,
        &args.url,
        &domain,
        args.completion_pattern.as_deref(),
        args.obscura_bin.as_deref(),
        args.rev_auth_bin.as_deref(),
        &args.aad_context,
    )
}

async fn run_refresh(format: OutputFormat, args: RefreshArgs) -> i32 {
    let domain = match resolve_domain(&args.url, args.domain.as_deref()) {
        Ok(d) => d,
        Err(msg) => {
            emit_err(format, "auth.refresh", EXIT_USER, &msg);
            return EXIT_USER;
        }
    };
    match auth_aup::enforce(&domain, &args.url) {
        AuthAupDecision::Allowed => {}
        AuthAupDecision::Rejected { message } => {
            emit_err(
                format,
                "auth.refresh",
                EXIT_USER,
                &format!("AUP: {message}"),
            );
            return EXIT_USER;
        }
    }
    let policy = match crate::policy::Policy::load() {
        Ok(p) => p.with_env_overrides(),
        Err(e) => {
            emit_err(
                format,
                "auth.refresh",
                EXIT_PERMANENT,
                &format!("policy load: {e}"),
            );
            return EXIT_PERMANENT;
        }
    };
    let cli_tri = crate::policy::cli_flags_to_tristate(args.require_vpn, args.allow_no_vpn);
    let require_vpn = crate::policy::effective_require_vpn(cli_tri, &policy);
    if let Err(e) = crate::vpn_guard::run_startup_probe(require_vpn, &policy).await {
        let code = e.exit_code().as_i32();
        emit_err(format, "auth.refresh", code, &format!("{e}"));
        return code;
    }
    spawn_rev_auth_login(
        format,
        "auth.refresh",
        &args.profile,
        &args.url,
        &domain,
        args.completion_pattern.as_deref(),
        args.obscura_bin.as_deref(),
        args.rev_auth_bin.as_deref(),
        &args.aad_context,
    )
}

#[allow(clippy::too_many_arguments)]
fn spawn_rev_auth_login(
    format: OutputFormat,
    op: &str,
    profile: &str,
    url: &str,
    domain: &str,
    completion_pattern: Option<&str>,
    obscura_bin: Option<&std::path::Path>,
    rev_auth_bin: Option<&std::path::Path>,
    aad_context: &str,
) -> i32 {
    let helper = match rev_auth_bin
        .map(std::path::Path::to_path_buf)
        .or_else(|| find_in_path("rev-auth"))
    {
        Some(p) => p,
        None => {
            emit_err(
                format,
                op,
                EXIT_PERMANENT,
                "rev-auth binary not found in PATH (use --rev-auth-bin)",
            );
            return EXIT_PERMANENT;
        }
    };
    let mut cmd = ProcessCommand::new(&helper);
    cmd.arg("login")
        .arg("--profile")
        .arg(profile)
        .arg("--url")
        .arg(url)
        .arg("--domain")
        .arg(domain)
        .arg("--aad-context")
        .arg(aad_context);
    if let Some(p) = completion_pattern {
        cmd.arg("--completion-pattern").arg(p);
    }
    if let Some(p) = obscura_bin {
        cmd.arg("--obscura-bin").arg(p);
    }
    // stdin/stdout/stderr inherited — rev-auth prints its own JSON on success.
    match cmd.status() {
        Ok(status) => status.code().unwrap_or(EXIT_PERMANENT),
        Err(error) => {
            emit_err(
                format,
                op,
                EXIT_TRANSIENT,
                &format!("rev-auth spawn failed: {error}"),
            );
            EXIT_TRANSIENT
        }
    }
}

fn run_list(format: OutputFormat) -> i32 {
    let store = match open_store(format, "auth.list") {
        Ok(s) => s,
        Err(code) => return code,
    };
    let profiles = match store.list_profiles() {
        Ok(p) => p,
        Err(error) => return emit_store_err(format, "auth.list", error),
    };
    let items: Vec<serde_json::Value> = profiles
        .iter()
        .map(|meta| {
            let status = store.status(&meta.profile);
            json!({
                "profile": meta.profile,
                "domains": meta.domains,
                "created_at": meta.created_at.to_rfc3339(),
                "last_used": meta.last_used.to_rfc3339(),
                "cookie_count": meta.cookie_name_sha256_prefixes.len(),
                "status": status_str(status),
                "cookie_values_returned": false,
            })
        })
        .collect();
    emit_ok(format, "auth.list", json!({ "profiles": items }));
    EXIT_OK
}

fn run_show(format: OutputFormat, args: ShowArgs) -> i32 {
    let store = match open_store(format, "auth.show") {
        Ok(s) => s,
        Err(code) => return code,
    };
    let profiles = match store.list_profiles() {
        Ok(p) => p,
        Err(error) => return emit_store_err(format, "auth.show", error),
    };
    let Some(meta) = profiles.into_iter().find(|m| m.profile == args.profile) else {
        emit_err(
            format,
            "auth.show",
            EXIT_USER,
            &format!("profile not found: {}", args.profile),
        );
        return EXIT_USER;
    };
    let status = store.status(&meta.profile);
    emit_ok(
        format,
        "auth.show",
        json!({
            "profile": meta.profile,
            "domains": meta.domains,
            "created_at": meta.created_at.to_rfc3339(),
            "last_used": meta.last_used.to_rfc3339(),
            // sha256 prefixes only; cookie name plaintext and value never disclosed.
            "cookie_name_sha256_prefixes": meta.cookie_name_sha256_prefixes,
            "status": status_str(status),
            "cookie_values_returned": false,
        }),
    );
    EXIT_OK
}

fn run_delete(format: OutputFormat, args: DeleteArgs, confirm: &mut dyn Confirm) -> i32 {
    if !args.force && !confirm.confirm(&format!("Delete auth profile {:?}? [y/N]: ", args.profile))
    {
        emit_err(format, "auth.delete", EXIT_ABORTED, "user declined");
        return EXIT_ABORTED;
    }
    let store = match open_store(format, "auth.delete") {
        Ok(s) => s,
        Err(code) => return code,
    };
    match store.delete(&args.profile) {
        Ok(()) => {
            emit_ok(
                format,
                "auth.delete",
                json!({ "profile": args.profile, "deleted": true }),
            );
            EXIT_OK
        }
        Err(error) => emit_store_err(format, "auth.delete", error),
    }
}

fn run_status(format: OutputFormat, args: StatusArgs) -> i32 {
    let store = match open_store(format, "auth.status") {
        Ok(s) => s,
        Err(code) => return code,
    };
    let status = store.status(&args.profile);
    let exit = match status {
        ProfileStatus::Valid
        | ProfileStatus::ExpiringSoon
        | ProfileStatus::ExpiringCritical
        | ProfileStatus::PartiallyExpired => EXIT_OK,
        ProfileStatus::AllExpired => EXIT_AUTH_EXPIRED,
        ProfileStatus::Missing => EXIT_USER,
    };
    emit_ok(
        format,
        "auth.status",
        json!({
            "profile": args.profile,
            "status": status_str(status),
            "warn_level": warn_level_for(status),
            "exit_code": exit,
        }),
    );
    exit
}

/// v1.1.0 (P14): map ProfileStatus → user-facing warn level for JSON output.
fn warn_level_for(status: ProfileStatus) -> &'static str {
    match status {
        ProfileStatus::Valid => "ok",
        ProfileStatus::ExpiringSoon => "soon",
        ProfileStatus::ExpiringCritical => "critical",
        ProfileStatus::PartiallyExpired => "soon",
        ProfileStatus::AllExpired => "expired",
        ProfileStatus::Missing => "expired",
    }
}

fn open_store(format: OutputFormat, op: &str) -> Result<AuthStore, i32> {
    let dir = auth_dir_from_env_or_default();
    AuthStore::open(&dir).map_err(|error| emit_store_err(format, op, error))
}

fn auth_dir_from_env_or_default() -> PathBuf {
    if let Some(path) = std::env::var_os("REV_SCRAPING_AUTH_DIR") {
        return PathBuf::from(path);
    }
    default_auth_store_dir()
}

fn emit_store_err(format: OutputFormat, op: &str, error: AuthStoreError) -> i32 {
    let (code, msg) = map_store_error(&error);
    emit_err(format, op, code, &msg);
    code
}

fn map_store_error(error: &AuthStoreError) -> (i32, String) {
    match error {
        AuthStoreError::NotFound(p) => (EXIT_AUTH_EXPIRED, format!("profile not found: {p}")),
        AuthStoreError::BadKeyOrTamper => (EXIT_LEAK, error.to_string()),
        AuthStoreError::ProfileHashMismatch => (EXIT_LEAK, error.to_string()),
        AuthStoreError::KeyringUnavailable(_) => (EXIT_PERMANENT, error.to_string()),
        AuthStoreError::Io(_) => (EXIT_PERMANENT, error.to_string()),
        AuthStoreError::Serde(_) => (EXIT_PERMANENT, error.to_string()),
        AuthStoreError::Crypto(_) => (EXIT_PERMANENT, error.to_string()),
    }
}

fn status_str(status: ProfileStatus) -> &'static str {
    match status {
        ProfileStatus::Valid => "Valid",
        ProfileStatus::ExpiringSoon => "ExpiringSoon",
        ProfileStatus::ExpiringCritical => "ExpiringCritical",
        ProfileStatus::PartiallyExpired => "PartiallyExpired",
        ProfileStatus::AllExpired => "AllExpired",
        ProfileStatus::Missing => "Missing",
    }
}

fn resolve_domain(url: &str, explicit: Option<&str>) -> Result<String, String> {
    if let Some(d) = explicit {
        let trimmed = d.trim();
        if trimmed.is_empty() {
            return Err("--domain must not be empty".to_string());
        }
        return Ok(trimmed.to_string());
    }
    let parsed = url::Url::parse(url).map_err(|error| format!("invalid --url {url:?}: {error}"))?;
    parsed
        .host_str()
        .map(|s| s.to_string())
        .ok_or_else(|| format!("--url {url:?} has no host"))
}

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

fn emit_ok(format: OutputFormat, op: &str, payload: serde_json::Value) {
    match format {
        OutputFormat::Json => {
            println!(
                "{}",
                json!({ "ok": true, "operation": op, "result": payload })
            );
        }
        OutputFormat::Human => {
            println!("[OK] {op}");
            if let Ok(s) = serde_json::to_string_pretty(&payload) {
                println!("{s}");
            }
        }
    }
}

fn emit_err(format: OutputFormat, op: &str, exit: i32, msg: &str) {
    match format {
        OutputFormat::Json => {
            println!(
                "{}",
                json!({
                    "ok": false,
                    "operation": op,
                    "exit_code": exit,
                    "error": msg,
                })
            );
        }
        OutputFormat::Human => {
            eprintln!("[ERROR] {op}: {msg}");
        }
    }
}

trait Confirm {
    fn confirm(&mut self, prompt: &str) -> bool;
}

struct StdinConfirm;

impl Confirm for StdinConfirm {
    fn confirm(&mut self, prompt: &str) -> bool {
        let stderr = io::stderr();
        let mut handle = stderr.lock();
        let _ = handle.write_all(prompt.as_bytes());
        let _ = handle.flush();
        let stdin = io::stdin();
        let mut line = String::new();
        if stdin.lock().read_line(&mut line).is_err() {
            return false;
        }
        matches!(line.trim().to_ascii_lowercase().as_str(), "y" | "yes")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[derive(Parser, Debug)]
    #[command(name = "rev-stealth")]
    struct TestCli {
        #[command(subcommand)]
        command: TestRoot,
    }

    #[derive(Subcommand, Debug)]
    enum TestRoot {
        Auth(AuthArgs),
    }

    fn parse(args: &[&str]) -> Result<TestCli, clap::Error> {
        let mut v = vec!["rev-stealth"];
        v.extend(args);
        TestCli::try_parse_from(v)
    }

    #[test]
    fn cli_parses_auth_login_subcommand() {
        let cli = parse(&[
            "auth",
            "login",
            "--profile",
            "work",
            "--url",
            "https://example.com/login",
        ])
        .unwrap();
        let TestRoot::Auth(args) = cli.command;
        match args.action {
            AuthAction::Login(a) => {
                assert_eq!(a.profile, "work");
                assert_eq!(a.url, "https://example.com/login");
            }
            other => panic!("expected Login, got {other:?}"),
        }
    }

    #[test]
    fn cli_parses_auth_login_allow_no_vpn() {
        let cli = parse(&[
            "auth",
            "login",
            "--profile",
            "p",
            "--url",
            "https://example.com/login",
            "--allow-no-vpn",
        ])
        .unwrap();
        let TestRoot::Auth(args) = cli.command;
        match args.action {
            AuthAction::Login(a) => {
                assert!(a.allow_no_vpn);
                assert!(!a.require_vpn);
            }
            other => panic!("expected Login, got {other:?}"),
        }
    }

    #[test]
    fn cli_parses_auth_login_require_vpn() {
        let cli = parse(&[
            "auth",
            "login",
            "--profile",
            "p",
            "--url",
            "https://example.com/login",
            "--require-vpn",
        ])
        .unwrap();
        let TestRoot::Auth(args) = cli.command;
        match args.action {
            AuthAction::Login(a) => {
                assert!(a.require_vpn);
                assert!(!a.allow_no_vpn);
            }
            other => panic!("expected Login, got {other:?}"),
        }

        assert!(parse(&[
            "auth",
            "login",
            "--profile",
            "p",
            "--url",
            "https://x/",
            "--require-vpn",
            "--allow-no-vpn",
        ])
        .is_err());
    }

    #[tokio::test]
    async fn auth_login_with_allow_no_vpn_skips_probe() {
        let policy = crate::policy::Policy {
            require_vpn: false,
            vpn_instances: vec![],
            ..crate::policy::Policy::default()
        };
        let require_vpn = crate::policy::effective_require_vpn(Some(false), &policy);
        assert!(!require_vpn);
        let report = crate::vpn_guard::run_startup_probe(false, &policy)
            .await
            .unwrap();
        assert!(report.is_none());
    }

    #[test]
    fn auth_login_with_env_require_vpn_overrides_allow_no_vpn() {
        let _guard = ENV_LOCK.lock().unwrap();
        std::env::remove_var(crate::policy::ENV_REQUIRE_VPN);
        let result = std::panic::catch_unwind(|| {
            std::env::set_var(crate::policy::ENV_REQUIRE_VPN, "1");
            let require_vpn = crate::policy::effective_require_vpn(
                Some(false),
                &crate::policy::Policy::default(),
            );
            assert!(require_vpn);
        });
        std::env::remove_var(crate::policy::ENV_REQUIRE_VPN);
        if let Err(panic) = result {
            std::panic::resume_unwind(panic);
        }
    }

    #[test]
    fn cli_parses_auth_list() {
        let cli = parse(&["auth", "list"]).unwrap();
        let TestRoot::Auth(args) = cli.command;
        assert!(matches!(args.action, AuthAction::List(_)));
    }

    #[test]
    fn cli_parses_auth_show_requires_profile() {
        assert!(parse(&["auth", "show"]).is_err());
        let cli = parse(&["auth", "show", "--profile", "work"]).unwrap();
        let TestRoot::Auth(args) = cli.command;
        match args.action {
            AuthAction::Show(a) => assert_eq!(a.profile, "work"),
            other => panic!("expected Show, got {other:?}"),
        }
    }

    #[test]
    fn cli_parses_auth_delete_with_force() {
        let cli = parse(&["auth", "delete", "--profile", "work", "--force"]).unwrap();
        let TestRoot::Auth(args) = cli.command;
        match args.action {
            AuthAction::Delete(a) => {
                assert_eq!(a.profile, "work");
                assert!(a.force);
            }
            other => panic!("expected Delete, got {other:?}"),
        }
    }

    #[test]
    fn cli_parses_auth_status() {
        let cli = parse(&["auth", "status", "--profile", "work"]).unwrap();
        let TestRoot::Auth(args) = cli.command;
        match args.action {
            AuthAction::Status(a) => assert_eq!(a.profile, "work"),
            other => panic!("expected Status, got {other:?}"),
        }
    }

    #[test]
    fn cli_parses_auth_refresh() {
        let cli = parse(&[
            "auth",
            "refresh",
            "--profile",
            "work",
            "--url",
            "https://example.com/login",
        ])
        .unwrap();
        let TestRoot::Auth(args) = cli.command;
        match args.action {
            AuthAction::Refresh(a) => {
                assert_eq!(a.profile, "work");
                assert_eq!(a.url, "https://example.com/login");
            }
            other => panic!("expected Refresh, got {other:?}"),
        }
    }

    #[test]
    fn auth_login_rejects_unauthorized_domain() {
        // No allowlist entries → AUP must reject.
        let list = auth_aup::AuthorizedFile { targets: vec![] };
        let decision = auth_aup::decide("example.com", "https://example.com/login", Some(&list));
        assert!(matches!(decision, AuthAupDecision::Rejected { .. }));

        // auth_allowed=false also rejects.
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
    fn auth_list_redacts_cookie_values() {
        // The list/show payloads never include a cookie value field.
        // Use the build_list_item-equivalent construction (sha256 prefixes only).
        use chrono::Utc;
        use stealth_auth::ProfileMeta;
        let meta = ProfileMeta {
            profile: "work".to_string(),
            domains: vec!["example.com".to_string()],
            created_at: Utc::now(),
            last_used: Utc::now(),
            cookie_name_sha256_prefixes: vec!["abc12345".to_string()],
        };
        let payload = json!({
            "profile": meta.profile,
            "domains": meta.domains,
            "created_at": meta.created_at.to_rfc3339(),
            "last_used": meta.last_used.to_rfc3339(),
            "cookie_count": meta.cookie_name_sha256_prefixes.len(),
            "status": status_str(ProfileStatus::Valid),
            "cookie_values_returned": false,
        });
        let s = serde_json::to_string(&payload).unwrap();
        // Must not surface a raw cookie `"value"` field. The boolean
        // disclosure-banner field `cookie_values_returned` is permitted and
        // expected; check for the value-key form explicitly.
        assert!(
            !s.contains("\"value\""),
            "must not surface a value field: {s}"
        );
        assert!(s.contains("\"cookie_values_returned\":false"));
    }

    #[test]
    fn auth_show_redacts_cookie_values() {
        use chrono::Utc;
        use stealth_auth::ProfileMeta;
        let meta = ProfileMeta {
            profile: "work".to_string(),
            domains: vec!["example.com".to_string()],
            created_at: Utc::now(),
            last_used: Utc::now(),
            cookie_name_sha256_prefixes: vec!["abc12345".to_string()],
        };
        let payload = json!({
            "profile": meta.profile,
            "domains": meta.domains,
            "cookie_name_sha256_prefixes": meta.cookie_name_sha256_prefixes,
            "status": status_str(ProfileStatus::Valid),
            "cookie_values_returned": false,
        });
        let s = serde_json::to_string(&payload).unwrap();
        // sha256 prefix is acceptable; raw cookie value/name must not appear.
        assert!(s.contains("cookie_name_sha256_prefixes"));
        assert!(!s.contains("\"value\""));
    }

    struct NoConfirm {
        called: bool,
    }
    impl Confirm for NoConfirm {
        fn confirm(&mut self, _prompt: &str) -> bool {
            self.called = true;
            false
        }
    }

    #[test]
    fn auth_delete_confirms_without_force_flag() {
        // Without --force, a "no" answer aborts with EXIT_ABORTED and the
        // store is never opened.
        let mut prompt = NoConfirm { called: false };
        let code = run_delete(
            OutputFormat::Json,
            DeleteArgs {
                profile: "nonexistent_profile_for_test".to_string(),
                force: false,
            },
            &mut prompt,
        );
        assert!(
            prompt.called,
            "prompt must be invoked when --force is absent"
        );
        assert_eq!(code, EXIT_ABORTED);
    }

    #[test]
    fn resolve_domain_uses_url_host_when_no_explicit_domain() {
        let d = resolve_domain("https://example.com/login", None).unwrap();
        assert_eq!(d, "example.com");
    }

    #[test]
    fn resolve_domain_prefers_explicit_override() {
        let d = resolve_domain("https://login.example.com/x", Some("example.com")).unwrap();
        assert_eq!(d, "example.com");
    }

    #[test]
    fn map_store_error_routes_notfound_to_auth_expired() {
        let (code, _) = map_store_error(&AuthStoreError::NotFound("missing".to_string()));
        assert_eq!(code, EXIT_AUTH_EXPIRED);
    }

    #[test]
    fn map_store_error_routes_tamper_to_leak() {
        let (code, _) = map_store_error(&AuthStoreError::BadKeyOrTamper);
        assert_eq!(code, EXIT_LEAK);
    }

    // ---- P14 SHOULD: warn_level mapping ----

    #[test]
    fn warn_level_for_maps_all_variants() {
        assert_eq!(warn_level_for(ProfileStatus::Valid), "ok");
        assert_eq!(warn_level_for(ProfileStatus::ExpiringSoon), "soon");
        assert_eq!(warn_level_for(ProfileStatus::ExpiringCritical), "critical");
        assert_eq!(warn_level_for(ProfileStatus::PartiallyExpired), "soon");
        assert_eq!(warn_level_for(ProfileStatus::AllExpired), "expired");
        assert_eq!(warn_level_for(ProfileStatus::Missing), "expired");
    }
}
