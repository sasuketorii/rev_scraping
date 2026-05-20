// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! `rev-stealth captcha ...` subcommand handlers.
//!
//! Wave 2.1 ships the CLI surface only. The actual solver wiring lands in
//! Wave 2.2 — this file delegates to `captcha-bypass` so the CLI grows
//! without further argument-parser churn.

use clap::Subcommand;
use serde_json::json;
use stealth_core::ExitCode;

use crate::OutputFormat;

#[derive(Subcommand, Debug)]
pub(crate) enum CaptchaAction {
    /// Solve a CAPTCHA challenge.
    Solve {
        /// Challenge type: `recaptcha-v2`, `recaptcha-v3`, `hcaptcha`, `turnstile`.
        #[arg(long, value_name = "TYPE")]
        r#type: String,
        /// Target site URL hosting the challenge.
        #[arg(long, value_name = "URL")]
        site_url: String,
        /// Sitekey (auto-detected if omitted on supported challenge types).
        #[arg(long, value_name = "KEY")]
        site_key: Option<String>,
        /// reCAPTCHA v3 action label.
        #[arg(long, default_value = "submit")]
        action: String,
        /// Skip the live solver and exercise the sidecar plumbing only.
        /// Useful for CI smoke tests.
        #[arg(long)]
        dry_run: bool,
    },
    /// Verify a previously-issued token (round-trips through the
    /// challenge provider's verify endpoint).
    Verify {
        /// Challenge type, same vocabulary as `solve --type`.
        #[arg(long, value_name = "TYPE")]
        r#type: String,
        /// Token returned by `solve`.
        #[arg(long, value_name = "TOKEN")]
        token: String,
        /// Provider secret (loaded from env in production).
        #[arg(long, env = "REV_STEALTH_CAPTCHA_SECRET", value_name = "SECRET")]
        secret: String,
    },
}

pub(crate) async fn run(format: OutputFormat, action: CaptchaAction) -> ExitCode {
    match action {
        CaptchaAction::Solve {
            r#type,
            site_url,
            site_key,
            action,
            dry_run,
        } => {
            solve(
                format,
                &r#type,
                &site_url,
                site_key.as_deref(),
                &action,
                dry_run,
            )
            .await
        }
        CaptchaAction::Verify {
            r#type,
            token,
            secret,
        } => verify(format, &r#type, &token, &secret).await,
    }
}

async fn solve(
    format: OutputFormat,
    kind: &str,
    site_url: &str,
    site_key: Option<&str>,
    action: &str,
    dry_run: bool,
) -> ExitCode {
    let captcha_kind = match captcha_bypass::CaptchaKind::from_slug(kind) {
        Some(k) => k,
        None => {
            return emit_error(
                format,
                ExitCode::UserError,
                "captcha.solve",
                &format!(
                    "unknown captcha type {kind:?}; valid: recaptcha-v2, recaptcha-v3, hcaptcha, turnstile"
                ),
            );
        }
    };

    let req = captcha_bypass::SolveRequest {
        kind: captcha_kind,
        site_url: site_url.to_string(),
        site_key: site_key.map(str::to_string),
        action: action.to_string(),
        dry_run,
    };

    match captcha_bypass::solve(req).await {
        Ok(resp) => {
            emit_ok(
                format,
                "captcha.solve",
                json!({
                    "type": kind,
                    "site_url": site_url,
                    "site_key": site_key,
                    "solver": resp.solver,
                    "elapsed_ms": resp.elapsed_ms,
                    "token_len": resp.token.len(),
                    "token_preview": preview(&resp.token, 32),
                    "dry_run": dry_run,
                }),
            );
            ExitCode::Ok
        }
        Err(e) => emit_error(format, e.exit_code(), "captcha.solve", &format!("{e}")),
    }
}

async fn verify(format: OutputFormat, kind: &str, token: &str, secret: &str) -> ExitCode {
    let captcha_kind = match captcha_bypass::CaptchaKind::from_slug(kind) {
        Some(k) => k,
        None => {
            return emit_error(
                format,
                ExitCode::UserError,
                "captcha.verify",
                &format!("unknown captcha type {kind:?}"),
            );
        }
    };
    match captcha_bypass::verify(captcha_kind, token, secret).await {
        Ok(report) => {
            emit_ok(
                format,
                "captcha.verify",
                json!({
                    "type": kind,
                    "valid": report.valid,
                    "score": report.score,
                    "action": report.action,
                    "errors": report.errors,
                }),
            );
            ExitCode::Ok
        }
        Err(e) => emit_error(format, e.exit_code(), "captcha.verify", &format!("{e}")),
    }
}

fn preview(s: &str, n: usize) -> String {
    if s.len() <= n {
        s.to_string()
    } else {
        format!("{}...", &s[..n])
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
