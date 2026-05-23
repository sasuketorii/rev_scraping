// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! `rev-stealth doctor` — pre-flight leak-prevention self-test.
//!
//! Runs four fail-closed checks before the operator routes any real
//! traffic:
//!
//! 1. VPN container kill-switch (CAP_ADD = NET_ADMIN + FIREWALL=on).
//! 2. DNS-over-TLS lock (DOT=on, provider in {cloudflare, quad9},
//!    DNS_KEEP_NAMESERVER != on).
//! 3. IPv6 disabled in the container kernel.
//! 4. WebRTC / Battery / connection guard JS payload is well-formed.
//!
//! Optionally the exit IP is fetched from `https://ipinfo.io/json` and
//! the country is enforced against `--expected-country`.
//!
//! Exit-code contract:
//!
//! * `0` — every check passed.
//! * `1` — argument / config error (clap-level).
//! * `7` — at least one leak check failed (fail-closed signal).
//!
//! `7` is intentionally distinct from the workspace-wide `2` (transient)
//! / `3` (permanent) codes so a calling agent can distinguish "the run
//! aborted because we'd leak" from "the run aborted because something
//! crashed".

use clap::{Args, ValueEnum};
use serde::Serialize;
use stealth_core::ExitCode;
use vpn_rotate::leak_guard::{IpInfo, LeakGuard};

use crate::OutputFormat as CliOutputFormat;

/// Exit-code mnemonic for "leak detected / fail-closed". Kept as a
/// module-level `pub const` so docs / tests / sibling modules can
/// reference the same number.
pub const EXIT_LEAK_DETECTED: i32 = 7;

#[derive(Args, Debug)]
pub(crate) struct DoctorArgs {
    /// VPN container name to inspect.
    #[arg(long, default_value = "gluetun")]
    pub container: String,

    /// Expected VPN exit country (ISO-2, e.g. "JP"). Skipped when omitted.
    #[arg(long)]
    pub expected_country: Option<String>,

    // Implementation note (not user-facing): `id = "doctor_format"` is
    // required to avoid colliding with the global `Cli::format`
    // (`OutputFormat`) clap arg-id. clap derives the arg id from the
    // Rust field name by default; without this override, both args
    // register under id `"format"` and clap panics at runtime with
    // "Could not downcast to rev_stealth::OutputFormat, need to
    // downcast to rev_stealth::doctor::DoctorFormat". Tracked in
    // HANDOFF v0.0.4 §2.1 P0.
    /// Output format for doctor diagnostic results: `json` (machine-parseable,
    /// default) or `text` (human-readable).
    #[arg(
        id = "doctor_format",
        long = "output-format",
        value_name = "OUTPUT_FORMAT",
        value_enum,
        default_value_t = DoctorFormat::Json,
    )]
    pub format: DoctorFormat,

    /// Skip the live `ipinfo.io` exit-IP probe (offline / CI mode).
    #[arg(long)]
    pub skip_exit_ip: bool,

    /// v1.1.0 (P16): run extended stack health checks (obscura binary,
    /// VPN instance pool, sites recipe count, auth profile validity,
    /// AuthStore key source). The default check set stays minimal so
    /// the existing fail-closed contract (exit 7 on leak) is unchanged;
    /// `--deep` adds non-leak diagnostic WARN/FAIL items.
    #[arg(long, default_value_t = false)]
    pub deep: bool,

    /// P10.3: run VPS deploy readiness checks (systemd unit prerequisites,
    /// dedicated user, /var/log + /var/lib dir permissions, credstore,
    /// chrome/xvfb-run on PATH, docker + gluetun image, DISPLAY env).
    /// FAIL items exit 3 (permanent); WARN-only stays exit 0. Independent
    /// from the leak-fail-closed contract used by the base checks.
    #[arg(long, default_value_t = false)]
    pub vps: bool,
}

#[derive(Copy, Clone, Debug, ValueEnum)]
pub(crate) enum DoctorFormat {
    Json,
    Text,
}

#[derive(Serialize)]
pub struct DoctorReport {
    pub kill_switch: bool,
    pub dns_lock: bool,
    pub ipv6_disabled: bool,
    pub webrtc_guard_present: bool,
    /// Exit-IP probe verdict.
    ///
    /// Semantics (fail-closed):
    ///
    /// * `true` when the probe succeeded (country match, or no
    ///   `--expected-country` constraint), or when the probe was
    ///   intentionally skipped via `--skip-exit-ip` (skipped ≠ failed).
    /// * `false` when the probe ran and returned `Err` for any reason
    ///   (timeout, non-200 response, parse error, country mismatch,
    ///   ASN-deny, …). In that case `errors` carries a human-readable
    ///   explanation and `all_pass()` returns `false` so the process
    ///   exits with the leak-detected code.
    ///
    /// Default `true` means an un-probed report does not flip the
    /// verdict on its own; the four explicit checks must still pass.
    pub exit_ip_ok: bool,
    pub exit_ip: Option<IpInfo>,
    /// Per-check failure detail (populated only on FAIL).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub errors: Vec<String>,
}

impl Default for DoctorReport {
    fn default() -> Self {
        Self {
            kill_switch: false,
            dns_lock: false,
            ipv6_disabled: false,
            webrtc_guard_present: false,
            // Default `true` so a skipped / not-yet-probed exit IP
            // does not flip the verdict on its own. The four explicit
            // checks above still default to `false`, so a
            // freshly-defaulted report still fails `all_pass()`.
            exit_ip_ok: true,
            exit_ip: None,
            errors: Vec::new(),
        }
    }
}

impl DoctorReport {
    pub fn all_pass(&self) -> bool {
        self.kill_switch
            && self.dns_lock
            && self.ipv6_disabled
            && self.webrtc_guard_present
            && self.exit_ip_ok
    }
}

pub(crate) async fn run(_global_format: CliOutputFormat, args: DoctorArgs) -> ExitCode {
    match run_doctor(args).await {
        Ok(true) => ExitCode::Ok,
        // Use the dedicated leak-detected exit code via std::process::exit
        // so the value `7` reaches the shell. The Cli::main wrapper maps
        // ExitCode::Ok / UserError / Transient / Permanent to 0/1/2/3, so
        // any leak-failure path bypasses that mapping.
        Ok(false) => {
            std::process::exit(EXIT_LEAK_DETECTED);
        }
        Err(code) => code,
    }
}

async fn run_doctor(args: DoctorArgs) -> Result<bool, ExitCode> {
    let mut report = DoctorReport::default();

    // 1-3: VPN container leak-guard checks.
    let lg = match LeakGuard::new(&args.container).await {
        Ok(g) => Some(g),
        Err(e) => {
            report.errors.push(format!("docker-connect: {e}"));
            None
        }
    };

    if let Some(lg) = lg.as_ref() {
        match lg.enforce_kill_switch().await {
            Ok(()) => report.kill_switch = true,
            Err(e) => report.errors.push(format!("kill-switch: {e}")),
        }
        match lg.enforce_dns_lock().await {
            Ok(()) => report.dns_lock = true,
            Err(e) => report.errors.push(format!("dns-lock: {e}")),
        }
        match lg.enforce_ipv6_disable().await {
            Ok(()) => report.ipv6_disabled = true,
            Err(e) => report.errors.push(format!("ipv6: {e}")),
        }
    }

    // 4. WebRTC / Battery / connection guard JS sanity check.
    use stealth_core::leak_guard::WEBRTC_LEAK_GUARD_JS;
    report.webrtc_guard_present = WEBRTC_LEAK_GUARD_JS.contains("RTCPeerConnection")
        && WEBRTC_LEAK_GUARD_JS.contains("mediaDevices")
        && WEBRTC_LEAK_GUARD_JS.contains("getBattery")
        && WEBRTC_LEAK_GUARD_JS.contains("navigator.connection");
    if !report.webrtc_guard_present {
        report.errors.push(
            "webrtc-guard: WEBRTC_LEAK_GUARD_JS missing one of \
             RTCPeerConnection / mediaDevices / getBattery / navigator.connection"
                .into(),
        );
    }

    // Optional: live exit-IP probe.
    //
    // Fail-closed contract: when the probe runs and returns Err, we
    // flip `exit_ip_ok = false` so `all_pass()` returns false and the
    // calling process exits with EXIT_LEAK_DETECTED (7). When
    // `--skip-exit-ip` is set, the probe does not run and `exit_ip_ok`
    // stays at its default `true` (skipped ≠ failed). Closes the
    // adversarial-audit finding where a network failure silently let
    // doctor exit 0 (fail-OPEN).
    if !args.skip_exit_ip {
        if let Some(lg) = lg.as_ref() {
            match lg.verify_exit_ip(args.expected_country.as_deref()).await {
                Ok(info) => report.exit_ip = Some(info),
                Err(e) => {
                    report.exit_ip_ok = false;
                    report.errors.push(format!("exit-ip: {e}"));
                }
            }
        } else {
            // Probe was requested but the docker connection failed
            // earlier; treat that as a probe failure too rather than
            // silently passing.
            report.exit_ip_ok = false;
            report
                .errors
                .push("exit-ip: skipped (docker unavailable; cannot probe)".into());
        }
    }

    // v1.1.0 (P16): optional --deep diagnostics. Attached to the JSON
    // envelope alongside the existing report so downstream consumers
    // can opt-in without parsing a different shape.
    let deep_report = if args.deep {
        Some(run_deep_diagnostics().await)
    } else {
        None
    };

    // P10.3: optional --vps deploy readiness diagnostics. Reuses the
    // DeepCheck row shape for JSON parity with --deep.
    let vps_report = if args.vps {
        Some(run_vps_checks())
    } else {
        None
    };

    // P10.3 JSON output contract: when --vps is set with JSON format,
    // emit a single top-level JSON array of DeepCheck rows so downstream
    // consumers can pipe through `jq` / `json.tool` without "Extra data"
    // errors and rely on a stable array shape. If --deep is also set,
    // deep rows are concatenated ahead of vps rows in the same array.
    // The base leak/doctor report is intentionally NOT merged into the
    // JSON payload — leak verdicts are surfaced via exit code 7. Text
    // mode keeps its multi-section human-readable format. The plain
    // (no-vps) JSON path keeps the historical multi-document shape so
    // existing --deep consumers are not broken.
    if args.vps && matches!(args.format, DoctorFormat::Json) {
        let mut combined: Vec<DeepCheck> = Vec::new();
        if let Some(d) = deep_report.as_ref() {
            combined.extend(deep_report_rows(d));
        }
        if let Some(v) = vps_report.as_ref() {
            combined.extend(v.iter().cloned());
        }
        match serde_json::to_string_pretty(&combined) {
            Ok(s) => println!("{s}"),
            Err(e) => {
                eprintln!("[ERROR] doctor --vps: serialise rows: {e}");
                return Err(ExitCode::PermanentError);
            }
        }
    } else {
        emit_report(&report, args.format)?;
        if let Some(d) = deep_report.as_ref() {
            emit_deep_report(d, args.format)?;
        }
    }
    // Text-mode --vps still prints its own section (the JSON envelope
    // path above already covered JSON).
    if args.vps && matches!(args.format, DoctorFormat::Text) {
        if let Some(v) = vps_report.as_ref() {
            emit_vps_report(v, args.format)?;
        }
    }

    // Exit code aggregation (shared across JSON + Text):
    // * --deep FAIL with leak checks passing → exit 3.
    // * --vps  FAIL with leak checks passing → exit 3.
    // Leak failures still take precedence (exit 7) via Ok(false) below.
    if let Some(d) = deep_report.as_ref() {
        if d.has_fail() && report.all_pass() {
            std::process::exit(3);
        }
    }
    if let Some(v) = vps_report.as_ref() {
        if vps_has_fail(v) && report.all_pass() {
            std::process::exit(3);
        }
    }
    Ok(report.all_pass())
}

/// P10.3 JSON-array helper: flatten a `DeepReport` into its row vec in
/// the canonical declaration order so `--deep --vps` can emit a single
/// top-level array combining deep + vps rows.
fn deep_report_rows(d: &DeepReport) -> Vec<DeepCheck> {
    vec![
        d.obscura_binary.clone(),
        d.vpn_pool_instances.clone(),
        d.sites_recipes.clone(),
        d.auth_profiles.clone(),
        d.auth_key_source.clone(),
    ]
}

/// v1.1.0 (P16): extended doctor diagnostic result.
#[derive(Serialize, Debug, Clone)]
pub struct DeepReport {
    pub obscura_binary: DeepCheck,
    pub vpn_pool_instances: DeepCheck,
    pub sites_recipes: DeepCheck,
    pub auth_profiles: DeepCheck,
    pub auth_key_source: DeepCheck,
}

/// One row of the deep report. `status` is one of "pass" / "warn" / "fail".
#[derive(Serialize, Debug, Clone)]
pub struct DeepCheck {
    pub name: String,
    pub status: DeepStatus,
    pub detail: String,
}

#[derive(Serialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DeepStatus {
    Pass,
    Warn,
    Fail,
}

impl DeepReport {
    pub fn has_fail(&self) -> bool {
        [
            &self.obscura_binary,
            &self.vpn_pool_instances,
            &self.sites_recipes,
            &self.auth_profiles,
            &self.auth_key_source,
        ]
        .iter()
        .any(|c| c.status == DeepStatus::Fail)
    }

    #[allow(dead_code)]
    pub fn has_warn(&self) -> bool {
        [
            &self.obscura_binary,
            &self.vpn_pool_instances,
            &self.sites_recipes,
            &self.auth_profiles,
            &self.auth_key_source,
        ]
        .iter()
        .any(|c| c.status == DeepStatus::Warn)
    }
}

async fn run_deep_diagnostics() -> DeepReport {
    DeepReport {
        obscura_binary: check_obscura_binary(),
        vpn_pool_instances: check_vpn_pool().await,
        sites_recipes: check_sites_recipes(),
        auth_profiles: check_auth_profiles(),
        auth_key_source: check_auth_key_source(),
    }
}

fn check_obscura_binary() -> DeepCheck {
    let name = "obscura_binary".to_string();
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join("obscura");
            if candidate.is_file() {
                return DeepCheck {
                    name,
                    status: DeepStatus::Pass,
                    detail: format!("found at {}", candidate.display()),
                };
            }
        }
    }
    DeepCheck {
        name,
        status: DeepStatus::Warn,
        detail: "obscura binary not on PATH (rev-stealth uses CDP through chromiumoxide; obscura optional)".to_string(),
    }
}

async fn check_vpn_pool() -> DeepCheck {
    let name = "vpn_pool_instances".to_string();
    // We cannot connect to docker from inside a unit test without a
    // live daemon. We only check the policy.toml pool size as a
    // proxy for "the operator configured a multi-instance pool".
    let policy_path = config_home().join("policy.toml");
    if !policy_path.is_file() {
        return DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: format!(
                "policy.toml not found at {} — using built-in defaults",
                policy_path.display()
            ),
        };
    }
    match std::fs::read_to_string(&policy_path) {
        Ok(raw) => match toml::from_str::<toml::Value>(&raw) {
            Ok(v) => {
                let count = v
                    .get("pool")
                    .and_then(|p| p.get("instances"))
                    .and_then(|i| i.as_array())
                    .map(|a| a.len())
                    .or_else(|| {
                        v.get("instances")
                            .and_then(|a| a.as_array())
                            .map(|a| a.len())
                    })
                    .unwrap_or(0);
                if count >= 3 {
                    DeepCheck {
                        name,
                        status: DeepStatus::Pass,
                        detail: format!("{count} VPN instances configured"),
                    }
                } else if count >= 1 {
                    DeepCheck {
                        name,
                        status: DeepStatus::Warn,
                        detail: format!(
                            "only {count} VPN instance(s) configured — recommend ≥3 for rotation"
                        ),
                    }
                } else {
                    DeepCheck {
                        name,
                        status: DeepStatus::Warn,
                        detail: "no VPN pool instances configured".to_string(),
                    }
                }
            }
            Err(e) => DeepCheck {
                name,
                status: DeepStatus::Fail,
                detail: format!("policy.toml parse error: {e}"),
            },
        },
        Err(e) => DeepCheck {
            name,
            status: DeepStatus::Fail,
            detail: format!("policy.toml read error: {e}"),
        },
    }
}

fn check_sites_recipes() -> DeepCheck {
    let name = "sites_recipes".to_string();
    let dir = config_home().join("sites");
    if !dir.is_dir() {
        return DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: format!(
                "sites recipe dir not found at {} — fresh installs are fine",
                dir.display()
            ),
        };
    }
    let count = std::fs::read_dir(&dir)
        .map(|it| {
            it.filter_map(|e| e.ok())
                .filter(|e| e.path().extension().map(|x| x == "toml").unwrap_or(false))
                .count()
        })
        .unwrap_or(0);
    DeepCheck {
        name,
        status: DeepStatus::Pass,
        detail: format!("{count} site recipe(s) at {}", dir.display()),
    }
}

fn check_auth_profiles() -> DeepCheck {
    let name = "auth_profiles".to_string();
    let dir = config_home().join("auth");
    if !dir.is_dir() {
        return DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: format!("no auth store at {} (no profiles saved yet)", dir.display()),
        };
    }
    let count = std::fs::read_dir(&dir)
        .map(|it| {
            it.filter_map(|e| e.ok())
                .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
                .count()
        })
        .unwrap_or(0);
    DeepCheck {
        name,
        status: DeepStatus::Pass,
        detail: format!("{count} auth profile file(s) on disk"),
    }
}

fn check_auth_key_source() -> DeepCheck {
    let name = "auth_key_source".to_string();
    // We do not actually touch the keyring here — that would prompt
    // the user for a credential. We only report which path the
    // store *would* take.
    let has_passphrase_env = std::env::var_os("REV_SCRAPING_AUTH_PASSPHRASE").is_some();
    if has_passphrase_env {
        DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: "AuthStore would use REV_SCRAPING_AUTH_PASSPHRASE (keyring bypassed)"
                .to_string(),
        }
    } else {
        DeepCheck {
            name,
            status: DeepStatus::Pass,
            detail: "AuthStore would use OS keyring (preferred path)".to_string(),
        }
    }
}

fn config_home() -> std::path::PathBuf {
    if let Some(p) = std::env::var_os("REV_SCRAPING_HOME") {
        return std::path::PathBuf::from(p);
    }
    if let Some(h) = std::env::var_os("HOME") {
        return std::path::PathBuf::from(h).join(".rev_scraping");
    }
    std::path::PathBuf::from(".rev_scraping")
}

fn emit_deep_report(d: &DeepReport, format: DoctorFormat) -> Result<(), ExitCode> {
    match format {
        DoctorFormat::Json => match serde_json::to_string_pretty(d) {
            Ok(s) => {
                println!("{s}");
                Ok(())
            }
            Err(e) => {
                eprintln!("[ERROR] doctor --deep: serialise: {e}");
                Err(ExitCode::PermanentError)
            }
        },
        DoctorFormat::Text => {
            print_deep_text(d);
            Ok(())
        }
    }
}

fn print_deep_text(d: &DeepReport) {
    println!("rev-stealth doctor --deep report");
    for c in [
        &d.obscura_binary,
        &d.vpn_pool_instances,
        &d.sites_recipes,
        &d.auth_profiles,
        &d.auth_key_source,
    ] {
        let tag = match c.status {
            DeepStatus::Pass => "PASS",
            DeepStatus::Warn => "WARN",
            DeepStatus::Fail => "FAIL",
        };
        println!("  [{tag}] {:<22} {}", c.name, c.detail);
    }
}

fn emit_report(report: &DoctorReport, format: DoctorFormat) -> Result<(), ExitCode> {
    match format {
        DoctorFormat::Json => match serde_json::to_value(report) {
            Ok(mut value) => {
                // v1.3 Lane G.7: when doctor detects a leak (non-zero
                // exit ahead), augment the report JSON with the canonical
                // `{kind, message, hint?, retry_after_ms?, doc_url}` so
                // callers branching on doctor's exit get the same wire
                // contract as every other failure surface.
                if !report.all_pass() {
                    let msg = if report.errors.is_empty() {
                        "doctor: leak/integrity check failed".to_string()
                    } else {
                        format!("doctor: {}", report.errors.join("; "))
                    };
                    crate::commands::error_envelope::augment_with_g7_fields(
                        &mut value,
                        crate::commands::error_envelope::CliErrorKind::VpnLeak,
                        Some(&msg),
                        Some("Run `rev-stealth doctor` again after bringing the VPN/kill-switch up."),
                        None,
                    );
                }
                match serde_json::to_string_pretty(&value) {
                    Ok(s) => {
                        println!("{s}");
                        Ok(())
                    }
                    Err(e) => {
                        eprintln!("[ERROR] doctor: serialise report: {e}");
                        Err(ExitCode::PermanentError)
                    }
                }
            }
            Err(e) => {
                eprintln!("[ERROR] doctor: serialise report: {e}");
                Err(ExitCode::PermanentError)
            }
        },
        DoctorFormat::Text => {
            print_text(report);
            Ok(())
        }
    }
}

fn print_text(r: &DoctorReport) {
    let pf = |b: bool| if b { "PASS" } else { "FAIL" };
    println!("rev-stealth doctor report");
    println!("  kill_switch         : {}", pf(r.kill_switch));
    println!("  dns_lock            : {}", pf(r.dns_lock));
    println!("  ipv6_disabled       : {}", pf(r.ipv6_disabled));
    println!("  webrtc_guard_present: {}", pf(r.webrtc_guard_present));
    println!("  exit_ip_ok          : {}", pf(r.exit_ip_ok));
    if let Some(ip) = &r.exit_ip {
        println!(
            "  exit_ip             : {} ({}, {})",
            ip.ip,
            ip.country.as_deref().unwrap_or("-"),
            ip.asn.as_deref().unwrap_or("-"),
        );
    }
    if !r.errors.is_empty() {
        println!("  errors:");
        for e in &r.errors {
            println!("    - {e}");
        }
    }
    if r.all_pass() {
        println!("  result              : PASS");
    } else {
        println!("  result              : FAIL (exit code {EXIT_LEAK_DETECTED})");
    }
}

// ---- P10.3: doctor --vps deploy readiness checks ----
//
// These checks reuse the `DeepCheck` row shape from --deep so JSON
// consumers see one consistent schema across both feature flags. The
// check set targets a Linux VPS (systemd + dedicated `rev-stealth` user
// + chroot-friendly paths under /var/lib + /var/log + an encrypted
// credstore + docker host with gluetun image pulled). Each check is
// pure-host-introspection: no docker exec, no network probe, so it is
// safe to run from CI / Makefile smoke without side effects.

/// Run all VPS-deploy readiness checks. Returns a list of DeepCheck
/// rows in stable order. Pure function over the host environment;
/// dependency-injected helpers (`run_cmd`, `stat_dir`) are isolated so
/// unit tests can drive failure paths without touching real /var.
pub(crate) fn run_vps_checks() -> Vec<DeepCheck> {
    vec![
        vps_check_systemd(),
        vps_check_user("rev-stealth"),
        vps_check_dir_perm("/var/log/rev-stealth", 0o750, "rev-stealth"),
        vps_check_dir_perm("/var/lib/rev-stealth", 0o700, "rev-stealth"),
        vps_check_credstore("/etc/credstore.encrypted"),
        vps_check_chrome_xvfb(),
        vps_check_docker(),
        vps_check_gluetun_image(),
        vps_check_display_env(),
    ]
}

pub(crate) fn vps_has_fail(rows: &[DeepCheck]) -> bool {
    rows.iter().any(|c| c.status == DeepStatus::Fail)
}

fn vps_check_systemd() -> DeepCheck {
    let name = "systemd".to_string();
    match run_cmd("systemctl", &["--version"]) {
        Some((true, out)) => {
            let first = out.lines().next().unwrap_or("").trim().to_string();
            DeepCheck {
                name,
                status: DeepStatus::Pass,
                detail: if first.is_empty() {
                    "systemctl present".into()
                } else {
                    first
                },
            }
        }
        _ => DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: "systemctl not found (host is not systemd-based; unit files will not load)"
                .into(),
        },
    }
}

fn vps_check_user(user: &str) -> DeepCheck {
    let name = format!("user_{user}");
    match run_cmd("getent", &["passwd", user]) {
        Some((true, out)) => {
            let line = out.lines().next().unwrap_or("").to_string();
            // passwd format: user:x:uid:gid:gecos:home:shell
            let shell = line.split(':').next_back().unwrap_or("").trim();
            let nologin = shell.contains("nologin") || shell.contains("false");
            if nologin {
                DeepCheck {
                    name,
                    status: DeepStatus::Pass,
                    detail: format!("{user} present with nologin shell ({shell})"),
                }
            } else {
                DeepCheck {
                    name,
                    status: DeepStatus::Warn,
                    detail: format!("{user} present but shell '{shell}' is interactive"),
                }
            }
        }
        _ => DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: format!("{user} user not found (create via dist/systemd/ install script)"),
        },
    }
}

fn vps_check_dir_perm(path: &str, want_mode: u32, want_owner: &str) -> DeepCheck {
    let name = format!("dir_{}", path.replace('/', "_"));
    match stat_dir(path) {
        Some(info) => {
            let mode_ok = info.mode_octal == want_mode;
            let owner_ok = info.owner == want_owner;
            if mode_ok && owner_ok {
                DeepCheck {
                    name,
                    status: DeepStatus::Pass,
                    detail: format!("{path} mode={:o} owner={}", info.mode_octal, info.owner),
                }
            } else {
                DeepCheck {
                    name,
                    status: DeepStatus::Fail,
                    detail: format!(
                        "{path} mode={:o} (want {:o}) owner={} (want {})",
                        info.mode_octal, want_mode, info.owner, want_owner
                    ),
                }
            }
        }
        None => DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: format!("{path} not found (run dist/systemd/install.sh on the VPS)"),
        },
    }
}

fn vps_check_credstore(path: &str) -> DeepCheck {
    let name = "credstore".to_string();
    match stat_dir(path) {
        Some(info) if info.mode_octal == 0o700 => DeepCheck {
            name,
            status: DeepStatus::Pass,
            detail: format!("{path} mode=700 owner={}", info.owner),
        },
        Some(info) => DeepCheck {
            name,
            status: DeepStatus::Fail,
            detail: format!(
                "{path} mode={:o} (want 700) owner={}",
                info.mode_octal, info.owner
            ),
        },
        None => DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: format!("{path} not found (encrypted credstore not provisioned)"),
        },
    }
}

fn vps_check_chrome_xvfb() -> DeepCheck {
    let name = "chrome_xvfb".to_string();
    let chrome = which_any(&["google-chrome", "chromium", "chromium-browser"]);
    let xvfb = which_any(&["xvfb-run"]);
    match (chrome, xvfb) {
        (Some(c), Some(x)) => DeepCheck {
            name,
            status: DeepStatus::Pass,
            detail: format!("chrome={c} xvfb-run={x}"),
        },
        (Some(c), None) => DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: format!("chrome={c}; xvfb-run missing (headless-only mode required)"),
        },
        (None, _) => DeepCheck {
            name,
            status: DeepStatus::Fail,
            detail: "no chrome/chromium binary on PATH".into(),
        },
    }
}

fn vps_check_docker() -> DeepCheck {
    let name = "docker".to_string();
    let d = run_cmd("docker", &["--version"]);
    let c = run_cmd("docker", &["compose", "version"]);
    match (d, c) {
        (Some((true, dv)), Some((true, cv))) => DeepCheck {
            name,
            status: DeepStatus::Pass,
            detail: format!(
                "{} / {}",
                dv.lines().next().unwrap_or("docker"),
                cv.lines().next().unwrap_or("compose")
            ),
        },
        (Some((true, dv)), _) => DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: format!(
                "{} present; `docker compose` plugin missing",
                dv.lines().next().unwrap_or("docker")
            ),
        },
        _ => DeepCheck {
            name,
            status: DeepStatus::Fail,
            detail: "docker not on PATH".into(),
        },
    }
}

fn vps_check_gluetun_image() -> DeepCheck {
    let name = "gluetun_image".to_string();
    match run_cmd(
        "docker",
        &[
            "image",
            "ls",
            "--format",
            "{{.Repository}}",
            "qmcgaw/gluetun",
        ],
    ) {
        Some((true, out)) if out.lines().any(|l| l.trim() == "qmcgaw/gluetun") => DeepCheck {
            name,
            status: DeepStatus::Pass,
            detail: "qmcgaw/gluetun image present".into(),
        },
        Some((true, _)) => DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: "qmcgaw/gluetun image not pulled (docker compose pull required)".into(),
        },
        _ => DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: "docker image ls failed (daemon not reachable from this user)".into(),
        },
    }
}

fn vps_check_display_env() -> DeepCheck {
    let name = "display_env".to_string();
    match std::env::var("DISPLAY") {
        Err(_) => DeepCheck {
            name,
            status: DeepStatus::Pass,
            detail: "DISPLAY unset (headless or Xvfb-managed; recommended on VPS)".into(),
        },
        Ok(v) => DeepCheck {
            name,
            status: DeepStatus::Warn,
            detail: format!("DISPLAY={v} — interactive X server attached (unexpected on VPS)"),
        },
    }
}

// --- low-level helpers (injection seams for tests) ---

/// Run a command and capture (success, stdout). Returns None if the
/// binary is not on PATH or the spawn itself failed. Test code can
/// rely on the fact that a missing binary → None → Warn/Fail without
/// touching the real process.
fn run_cmd(bin: &str, args: &[&str]) -> Option<(bool, String)> {
    let out = std::process::Command::new(bin).args(args).output().ok()?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    Some((out.status.success(), stdout))
}

fn which_any(candidates: &[&str]) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        for bin in candidates {
            let candidate = dir.join(bin);
            if candidate.is_file() {
                return Some(candidate.display().to_string());
            }
        }
    }
    None
}

#[derive(Debug, Clone)]
pub(crate) struct DirStat {
    pub mode_octal: u32,
    pub owner: String,
}

fn stat_dir(path: &str) -> Option<DirStat> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let md = std::fs::metadata(path).ok()?;
        if !md.is_dir() {
            return None;
        }
        let mode_octal = md.mode() & 0o777;
        let uid = md.uid();
        let owner = uid_to_name(uid).unwrap_or_else(|| uid.to_string());
        Some(DirStat { mode_octal, owner })
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

#[cfg(unix)]
fn uid_to_name(uid: u32) -> Option<String> {
    // `getent passwd <uid>` is the most portable way without pulling
    // libc nss bindings. Failure → fall back to numeric uid.
    let (ok, out) = run_cmd("getent", &["passwd", &uid.to_string()])?;
    if !ok {
        return None;
    }
    out.lines()
        .next()
        .and_then(|l| l.split(':').next().map(|s| s.to_string()))
}

fn emit_vps_report(rows: &[DeepCheck], format: DoctorFormat) -> Result<(), ExitCode> {
    match format {
        DoctorFormat::Json => match serde_json::to_string_pretty(rows) {
            Ok(s) => {
                println!("{s}");
                Ok(())
            }
            Err(e) => {
                eprintln!("[ERROR] doctor --vps: serialise: {e}");
                Err(ExitCode::PermanentError)
            }
        },
        DoctorFormat::Text => {
            println!("rev-stealth doctor --vps report");
            for c in rows {
                let tag = match c.status {
                    DeepStatus::Pass => "PASS",
                    DeepStatus::Warn => "WARN",
                    DeepStatus::Fail => "FAIL",
                };
                println!("  [{tag}] {:<24} {}", c.name, c.detail);
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn report_default_is_all_fail() {
        let r = DoctorReport::default();
        assert!(!r.all_pass());
        assert!(!r.kill_switch);
        assert!(!r.dns_lock);
        assert!(!r.ipv6_disabled);
        assert!(!r.webrtc_guard_present);
        // `exit_ip_ok` defaults to `true` (skipped ≠ failed), so an
        // un-probed report does not flip the verdict on its own.
        assert!(r.exit_ip_ok);
        assert!(r.exit_ip.is_none());
        assert!(r.errors.is_empty());
    }

    #[test]
    fn report_all_pass_when_every_check_true() {
        let r = DoctorReport {
            kill_switch: true,
            dns_lock: true,
            ipv6_disabled: true,
            webrtc_guard_present: true,
            ..Default::default()
        };
        assert!(r.all_pass());
    }

    #[test]
    fn all_pass_false_when_exit_ip_failed() {
        // Adversarial-audit regression: the four leak checks pass but
        // the live exit-IP probe failed (e.g. country mismatch). Prior
        // to v0.0.4.1, `all_pass()` ignored the probe result and the
        // process exited 0 — fail-OPEN against the documented
        // fail-closed contract. This test pins the fix.
        let r = DoctorReport {
            kill_switch: true,
            dns_lock: true,
            ipv6_disabled: true,
            webrtc_guard_present: true,
            exit_ip_ok: false,
            errors: vec!["exit-ip: country mismatch (got US, want JP)".into()],
            ..Default::default()
        };
        assert!(!r.all_pass(), "exit_ip_ok=false must veto all_pass()");
    }

    #[test]
    fn all_pass_true_when_exit_ip_skipped_or_ok() {
        // Skipped path: --skip-exit-ip leaves `exit_ip_ok` at its
        // default `true` so the four leak checks alone can pass.
        let skipped = DoctorReport {
            kill_switch: true,
            dns_lock: true,
            ipv6_disabled: true,
            webrtc_guard_present: true,
            ..Default::default()
        };
        assert!(skipped.exit_ip_ok);
        assert!(skipped.all_pass());

        // OK path: probe ran and succeeded; `exit_ip_ok` is set true
        // explicitly. Both shapes must yield all_pass() == true.
        let ok_explicit = DoctorReport {
            kill_switch: true,
            dns_lock: true,
            ipv6_disabled: true,
            webrtc_guard_present: true,
            exit_ip_ok: true,
            ..Default::default()
        };
        assert!(ok_explicit.all_pass());
    }

    #[test]
    fn report_serialises_to_expected_json_shape() {
        let r = DoctorReport {
            kill_switch: true,
            dns_lock: false,
            ipv6_disabled: true,
            webrtc_guard_present: true,
            exit_ip_ok: true,
            exit_ip: None,
            errors: vec!["dns-lock: DOT=off".into()],
        };
        let s = serde_json::to_string(&r).unwrap();
        // Field ordering of `serde` derive is declaration order.
        assert!(s.contains("\"kill_switch\":true"));
        assert!(s.contains("\"dns_lock\":false"));
        assert!(s.contains("\"ipv6_disabled\":true"));
        assert!(s.contains("\"webrtc_guard_present\":true"));
        assert!(s.contains("\"exit_ip_ok\":true"));
        assert!(s.contains("\"errors\":[\"dns-lock: DOT=off\"]"));
        // exit_ip is None and serialised as null.
        assert!(s.contains("\"exit_ip\":null"));
    }

    #[test]
    fn report_omits_empty_errors_in_pass_case() {
        let r = DoctorReport {
            kill_switch: true,
            dns_lock: true,
            ipv6_disabled: true,
            webrtc_guard_present: true,
            ..Default::default()
        };
        let s = serde_json::to_string(&r).unwrap();
        // skip_serializing_if = "Vec::is_empty" => no `errors` key on pass.
        assert!(!s.contains("\"errors\""));
    }

    // ---- P16 SHOULD: doctor --deep ----

    #[test]
    fn deep_report_pass_only_has_no_fail_or_warn() {
        let d = DeepReport {
            obscura_binary: DeepCheck {
                name: "a".into(),
                status: DeepStatus::Pass,
                detail: "".into(),
            },
            vpn_pool_instances: DeepCheck {
                name: "b".into(),
                status: DeepStatus::Pass,
                detail: "".into(),
            },
            sites_recipes: DeepCheck {
                name: "c".into(),
                status: DeepStatus::Pass,
                detail: "".into(),
            },
            auth_profiles: DeepCheck {
                name: "d".into(),
                status: DeepStatus::Pass,
                detail: "".into(),
            },
            auth_key_source: DeepCheck {
                name: "e".into(),
                status: DeepStatus::Pass,
                detail: "".into(),
            },
        };
        assert!(!d.has_fail());
        assert!(!d.has_warn());
    }

    #[test]
    fn deep_report_detects_any_fail() {
        let d = DeepReport {
            obscura_binary: DeepCheck {
                name: "a".into(),
                status: DeepStatus::Pass,
                detail: "".into(),
            },
            vpn_pool_instances: DeepCheck {
                name: "b".into(),
                status: DeepStatus::Fail,
                detail: "boom".into(),
            },
            sites_recipes: DeepCheck {
                name: "c".into(),
                status: DeepStatus::Pass,
                detail: "".into(),
            },
            auth_profiles: DeepCheck {
                name: "d".into(),
                status: DeepStatus::Pass,
                detail: "".into(),
            },
            auth_key_source: DeepCheck {
                name: "e".into(),
                status: DeepStatus::Warn,
                detail: "".into(),
            },
        };
        assert!(d.has_fail());
        assert!(d.has_warn());
    }

    #[test]
    fn deep_status_serialises_lowercase() {
        let pass = serde_json::to_string(&DeepStatus::Pass).unwrap();
        let warn = serde_json::to_string(&DeepStatus::Warn).unwrap();
        let fail = serde_json::to_string(&DeepStatus::Fail).unwrap();
        assert_eq!(pass, "\"pass\"");
        assert_eq!(warn, "\"warn\"");
        assert_eq!(fail, "\"fail\"");
    }

    #[test]
    fn deep_check_obscura_binary_runs_without_panic() {
        // Whether it's installed or not on the test host, the function
        // must return a structured DeepCheck (never panic, never
        // unbounded I/O).
        let c = check_obscura_binary();
        assert_eq!(c.name, "obscura_binary");
        assert!(matches!(
            c.status,
            DeepStatus::Pass | DeepStatus::Warn | DeepStatus::Fail
        ));
        assert!(!c.detail.is_empty());
    }

    #[test]
    fn deep_report_serialises_pretty_json() {
        let d = DeepReport {
            obscura_binary: DeepCheck {
                name: "obscura_binary".into(),
                status: DeepStatus::Pass,
                detail: "found at /opt/obscura".into(),
            },
            vpn_pool_instances: DeepCheck {
                name: "vpn_pool_instances".into(),
                status: DeepStatus::Warn,
                detail: "1 VPN instance".into(),
            },
            sites_recipes: DeepCheck {
                name: "sites_recipes".into(),
                status: DeepStatus::Pass,
                detail: "3 site recipe(s)".into(),
            },
            auth_profiles: DeepCheck {
                name: "auth_profiles".into(),
                status: DeepStatus::Pass,
                detail: "2 auth profile file(s)".into(),
            },
            auth_key_source: DeepCheck {
                name: "auth_key_source".into(),
                status: DeepStatus::Pass,
                detail: "keyring".into(),
            },
        };
        let s = serde_json::to_string(&d).unwrap();
        // Every check name must appear; status enum must serialise
        // lower-case so consumers can pattern-match on string.
        assert!(s.contains("\"obscura_binary\""));
        assert!(s.contains("\"vpn_pool_instances\""));
        assert!(s.contains("\"sites_recipes\""));
        assert!(s.contains("\"auth_profiles\""));
        assert!(s.contains("\"auth_key_source\""));
        assert!(s.contains("\"warn\""));
        assert!(d.has_warn());
        assert!(!d.has_fail());
    }

    #[test]
    fn exit_leak_detected_is_seven() {
        // Lock the contract: callers / agents key off this number.
        assert_eq!(EXIT_LEAK_DETECTED, 7);
    }

    // ---- P10.3 SHOULD: doctor --vps ----

    mod vps {
        use super::*;

        #[test]
        fn vps_check_systemd_present_or_warns() {
            // Either the test host has systemctl (Pass) or it doesn't
            // (Warn). FAIL is not a valid output for this check; the
            // function must never panic regardless of host.
            let c = super::vps_check_systemd();
            assert_eq!(c.name, "systemd");
            assert!(
                matches!(c.status, DeepStatus::Pass | DeepStatus::Warn),
                "systemd check returned unexpected status {:?}",
                c.status
            );
            assert!(!c.detail.is_empty());
        }

        #[test]
        fn vps_check_rev_stealth_user_returns_warn_when_missing() {
            // Use a username that definitely does not exist on any
            // CI/dev host. `getent` returns non-zero exit and the
            // check must collapse to Warn (not Fail, since the user
            // can fix this by running install.sh).
            let c = super::vps_check_user("rev-stealth-nonexistent-xyz-abc");
            assert_eq!(c.name, "user_rev-stealth-nonexistent-xyz-abc");
            // Either Warn (binary present, user missing) or Warn
            // (binary missing entirely). Never Pass.
            assert_eq!(c.status, DeepStatus::Warn);
            assert!(c.detail.contains("rev-stealth-nonexistent-xyz-abc"));
        }

        #[test]
        fn vps_check_dir_perm_detects_wrong_mode() {
            // Drive the helper against a real tempdir whose mode is
            // 0o755 (rust default on most umasks). Want 0o750 +
            // owner=rev-stealth → both mismatch → Fail row with the
            // observed values surfaced in `detail`.
            let tmp =
                std::env::temp_dir().join(format!("rev-stealth-vps-test-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&tmp);
            std::fs::create_dir(&tmp).expect("create tempdir");
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))
                    .expect("chmod");
            }
            let c = super::vps_check_dir_perm(
                tmp.to_str().expect("tmp utf-8"),
                0o750,
                "rev-stealth-nonexistent-xyz-abc",
            );
            assert!(c.name.starts_with("dir_"));
            #[cfg(unix)]
            {
                assert_eq!(
                    c.status,
                    DeepStatus::Fail,
                    "wrong mode + wrong owner must fail: detail={}",
                    c.detail
                );
                assert!(c.detail.contains("want 750"));
            }
            #[cfg(not(unix))]
            {
                // Non-unix hosts can only return Warn (dir-stat
                // unsupported); that's acceptable for the contract.
                assert!(matches!(c.status, DeepStatus::Warn | DeepStatus::Fail));
            }
            let _ = std::fs::remove_dir_all(&tmp);
        }

        #[test]
        fn vps_doctor_exit_code_aggregates_correctly() {
            // The `vps_has_fail` aggregator is what `run_doctor`
            // consults to decide between exit 0 and exit 3. Pin its
            // contract:
            //   * all Pass → false (exit 0)
            //   * Warn-only → false (exit 0)
            //   * any Fail → true  (exit 3)
            let mk = |s: DeepStatus| DeepCheck {
                name: "x".into(),
                status: s,
                detail: "".into(),
            };
            assert!(!super::vps_has_fail(&[
                mk(DeepStatus::Pass),
                mk(DeepStatus::Pass)
            ]));
            assert!(!super::vps_has_fail(&[
                mk(DeepStatus::Warn),
                mk(DeepStatus::Pass)
            ]));
            assert!(super::vps_has_fail(&[
                mk(DeepStatus::Pass),
                mk(DeepStatus::Fail)
            ]));
            assert!(super::vps_has_fail(&[mk(DeepStatus::Fail)]));
            assert!(!super::vps_has_fail(&[]));
        }

        #[test]
        fn vps_check_set_has_at_least_nine_rows_in_stable_order() {
            // Snapshot the names of every row emitted by run_vps_checks
            // so downstream consumers (JSON parsers, dashboards) can
            // rely on the order. New checks must be appended, not
            // inserted in the middle.
            let rows = super::run_vps_checks();
            assert!(
                rows.len() >= 9,
                "P10.3 contract: ≥9 vps checks, got {}",
                rows.len()
            );
            let names: Vec<&str> = rows.iter().map(|c| c.name.as_str()).collect();
            assert_eq!(names[0], "systemd");
            assert_eq!(names[1], "user_rev-stealth");
            assert!(names[2].starts_with("dir_"));
            assert!(names[3].starts_with("dir_"));
            assert_eq!(names[4], "credstore");
            assert_eq!(names[5], "chrome_xvfb");
            assert_eq!(names[6], "docker");
            assert_eq!(names[7], "gluetun_image");
            assert_eq!(names[8], "display_env");
            // Every row must carry a non-empty detail and a valid status.
            for r in &rows {
                assert!(!r.detail.is_empty(), "row {} has empty detail", r.name);
                assert!(matches!(
                    r.status,
                    DeepStatus::Pass | DeepStatus::Warn | DeepStatus::Fail
                ));
            }
        }

        #[test]
        fn vps_json_output_is_single_top_level_array() {
            // P10.3 reviewer regression: when --vps is set, the JSON
            // stdout must be ONE top-level array of DeepCheck rows so
            // `jq` / json.tool can parse it and downstream consumers
            // can iterate without unwrapping an envelope. The base
            // leak/doctor report is intentionally not merged here —
            // leak status is surfaced via exit code 7.
            let vps_rows = vec![
                DeepCheck {
                    name: "systemd".into(),
                    status: DeepStatus::Pass,
                    detail: "systemd 255".into(),
                },
                DeepCheck {
                    name: "credstore".into(),
                    status: DeepStatus::Fail,
                    detail: "mode=755".into(),
                },
            ];
            let s = serde_json::to_string(&vps_rows).unwrap();
            assert!(s.starts_with('['), "JSON must start with '[' (array): {s}");
            let v: serde_json::Value = serde_json::from_str(&s).expect("single parseable json");
            assert!(v.is_array(), "top-level JSON must be an array");
            let arr = v.as_array().unwrap();
            assert_eq!(arr.len(), 2);
            assert_eq!(arr[0]["name"], "systemd");
            assert_eq!(arr[0]["status"], "pass");
            assert_eq!(arr[1]["name"], "credstore");
            assert_eq!(arr[1]["status"], "fail");
        }

        #[test]
        fn deep_plus_vps_json_concatenates_rows_in_order() {
            // P10.3: when --deep and --vps are both set, the JSON
            // output must be a single flat array containing deep rows
            // followed by vps rows. Validates the deep_report_rows
            // helper preserves DeepReport declaration order.
            let mk = |name: &str| DeepCheck {
                name: name.into(),
                status: DeepStatus::Pass,
                detail: "ok".into(),
            };
            let deep = DeepReport {
                obscura_binary: mk("obscura_binary"),
                vpn_pool_instances: mk("vpn_pool_instances"),
                sites_recipes: mk("sites_recipes"),
                auth_profiles: mk("auth_profiles"),
                auth_key_source: mk("auth_key_source"),
            };
            let vps = [mk("systemd"), mk("credstore")];
            let mut combined: Vec<DeepCheck> = super::deep_report_rows(&deep);
            combined.extend(vps.iter().cloned());
            let s = serde_json::to_string(&combined).unwrap();
            assert!(s.starts_with('['));
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            let names: Vec<&str> = v
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r["name"].as_str().unwrap())
                .collect();
            assert_eq!(
                names,
                vec![
                    "obscura_binary",
                    "vpn_pool_instances",
                    "sites_recipes",
                    "auth_profiles",
                    "auth_key_source",
                    "systemd",
                    "credstore",
                ]
            );
        }

        #[test]
        fn vps_rows_serialise_to_array_of_objects() {
            // JSON parity with --deep: each row has {name,status,detail}
            // with status as a lower-case string.
            let rows = vec![
                DeepCheck {
                    name: "systemd".into(),
                    status: DeepStatus::Pass,
                    detail: "systemd 255".into(),
                },
                DeepCheck {
                    name: "credstore".into(),
                    status: DeepStatus::Fail,
                    detail: "mode=755".into(),
                },
            ];
            let s = serde_json::to_string(&rows).unwrap();
            assert!(s.starts_with('['));
            assert!(s.contains("\"name\":\"systemd\""));
            assert!(s.contains("\"status\":\"pass\""));
            assert!(s.contains("\"status\":\"fail\""));
            assert!(s.contains("\"detail\":\"mode=755\""));
        }
    }
}
