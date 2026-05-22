// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! `rev-stealth vpn ...` subcommand handlers.
//!
//! Wave 2.1 ships the CLI surface only. The bollard-backed implementation
//! lands in Wave 3 in the `vpn-rotate` crate.

use clap::Subcommand;
use serde_json::json;
use stealth_core::ExitCode;

use crate::OutputFormat;

#[derive(Subcommand, Debug)]
pub(crate) enum VpnAction {
    /// Trigger a VPN rotation. With `lazy-on-fail`, rotation is skipped
    /// unless the failure counter has crossed the threshold.
    #[command(
        long_about = "Trigger a VPN exit-IP rotation through the configured provider \
(Surfshark / Gluetun). Strategy `lazy-on-fail` skips when the failure counter is \
under threshold; `every-n` / `interval` rotate unconditionally on cadence. \
The action is recorded to the audit log with the supplied --reason.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth vpn rotate\n  \
$ rev-stealth vpn rotate --strategy every-n --region jp --reason scheduled\n  \
$ rev-stealth vpn rotate --provider surfshark --strategy interval --reason failover\n\n\
EXIT CODES:\n  \
0  Ok               Rotation completed (or correctly skipped under lazy-on-fail).\n  \
1  UserError        Unknown --provider / --strategy.\n  \
2  TransientError   Provider/container transient failure.\n  \
3  PermanentError   Provider unsupported in this build.\n  \
7  Leak             Post-rotation leak check failed (fail-closed).\n\n\
ENV:\n  \
REV_SCRAPING_REQUIRE_VPN  When `1`, enforces VPN-required guard policy-wide."
    )]
    Rotate {
        /// VPN provider slug (currently only `surfshark`).
        #[arg(long, default_value = "surfshark")]
        provider: String,
        /// Rotation strategy: `lazy-on-fail`, `every-n`, `interval`.
        #[arg(long, default_value = "lazy-on-fail")]
        strategy: String,
        /// Optional region (`jp`, `us-west`, `de`, ...). Cycled through
        /// when omitted.
        #[arg(long)]
        region: Option<String>,
        /// Reason hint; recorded in the audit log for forensics.
        #[arg(long, default_value = "manual")]
        reason: String,
        /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
        #[command(flatten)]
        dry_run_args: crate::commands::dry_run::DryRunArgs,
    },
    /// Show the current public IP and the VPN container state.
    #[command(
        long_about = "Probe the current public IP via ipinfo.io and report the VPN \
container state (running / exit country / exit ASN) for the chosen provider. \
Useful as a 'before-rotate' diagnostic; pairs with `doctor` for leak checks.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth vpn status\n  \
$ rev-stealth vpn status --provider surfshark\n  \
$ rev-stealth --format json vpn status\n\n\
EXIT CODES:\n  \
0  Ok               Status probe completed.\n  \
1  UserError        Unknown --provider slug.\n  \
2  TransientError   ipinfo / provider transient failure.\n  \
3  PermanentError   Provider unsupported in this build.\n  \
7  Leak             Exit-IP probe revealed a leak (fail-closed).\n\n\
ENV:\n  \
(none consumed directly by this subcommand.)"
    )]
    Status {
        /// Provider slug to scope the status query.
        #[arg(long, default_value = "surfshark")]
        provider: String,
    },
}

pub(crate) async fn run(format: OutputFormat, action: VpnAction) -> ExitCode {
    match action {
        VpnAction::Rotate {
            provider,
            strategy,
            region,
            reason,
            dry_run_args,
        } => {
            if dry_run_args.is_dry_run() {
                // v1.3 Lane G.5: side-effect-free plan emission. No bollard
                // call, no leak probe, no audit-log write.
                let _ = crate::commands::dry_run::emit_dry_run(
                    format,
                    "vpn.rotate",
                    &[
                        "validate strategy slug",
                        "build RotationRequest envelope",
                        "(skipped) call vpn_rotate::rotate",
                        "(skipped) post-rotation leak probe",
                        "(skipped) audit-log write",
                    ],
                    &dry_run_args,
                );
                return ExitCode::Ok;
            }
            rotate(format, &provider, &strategy, region.as_deref(), &reason).await
        }
        VpnAction::Status { provider } => status(format, &provider).await,
    }
}

async fn rotate(
    format: OutputFormat,
    provider: &str,
    strategy: &str,
    region: Option<&str>,
    reason: &str,
) -> ExitCode {
    let strat = match vpn_rotate::RotationStrategy::from_slug(strategy) {
        Some(s) => s,
        None => {
            return emit_error(
                format,
                ExitCode::UserError,
                "vpn.rotate",
                &format!("unknown strategy {strategy:?}; valid: lazy-on-fail, every-n, interval"),
            );
        }
    };
    let req = vpn_rotate::RotationRequest {
        provider: provider.to_string(),
        strategy: strat,
        region: region.map(str::to_string),
        reason: reason.to_string(),
    };
    match vpn_rotate::rotate(req).await {
        Ok(report) => {
            emit_ok(
                format,
                "vpn.rotate",
                json!({
                    "rotated": report.rotated,
                    "container": report.container,
                    "previous_ip": report.previous_ip,
                    "new_ip": report.new_ip,
                    "elapsed_ms": report.elapsed_ms,
                    "reason": reason,
                }),
            );
            ExitCode::Ok
        }
        Err(e) => emit_error(format, e.exit_code(), "vpn.rotate", &format!("{e}")),
    }
}

async fn status(format: OutputFormat, provider: &str) -> ExitCode {
    match vpn_rotate::status(provider).await {
        Ok(s) => {
            emit_ok(
                format,
                "vpn.status",
                json!({
                    "provider": provider,
                    "container": s.container,
                    "running": s.running,
                    "current_ip": s.current_ip,
                }),
            );
            ExitCode::Ok
        }
        Err(e) => emit_error(format, e.exit_code(), "vpn.status", &format!("{e}")),
    }
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

fn emit_error(format: OutputFormat, exit: ExitCode, op: &str, message: &str) -> ExitCode {
    match format {
        OutputFormat::Json => {
            println!(
                "{}",
                json!({
                    "ok": false,
                    "operation": op,
                    "exit_code": exit.as_i32(),
                    "error": message,
                })
            );
        }
        OutputFormat::Human => {
            eprintln!("[ERROR] {op}: {message}");
        }
    }
    exit
}
