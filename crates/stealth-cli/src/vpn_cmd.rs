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
    },
    /// Show the current public IP and the VPN container state.
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
        } => rotate(format, &provider, &strategy, region.as_deref(), &reason).await,
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
