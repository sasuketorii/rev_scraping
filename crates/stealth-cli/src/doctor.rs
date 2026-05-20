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

    emit_report(&report, args.format)?;
    if let Some(d) = deep_report.as_ref() {
        emit_deep_report(d, args.format)?;
        // FAIL items in the deep report do not flip the leak-fail-closed
        // exit code (that stays at 7 only for kill-switch / DNS / IPv6
        // / exit-IP). FAILs here surface as exit 3 (permanent). WARNs
        // stay at exit 0.
        if d.has_fail() && report.all_pass() {
            // Bypass the standard ExitCode::Ok mapping when deep fails.
            std::process::exit(3);
        }
    }
    Ok(report.all_pass())
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
        DoctorFormat::Json => match serde_json::to_string_pretty(report) {
            Ok(s) => {
                println!("{s}");
                Ok(())
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
}
