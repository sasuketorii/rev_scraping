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
    ///
    /// Drives the captcha-bypass solver against a target site for the
    /// chosen challenge type. Used for defender-side resilience evaluation
    /// on authorized targets only.
    #[command(
        long_about = "Solve a CAPTCHA challenge by delegating to the configured \
captcha-bypass solver. Supports reCAPTCHA v2/v3, hCaptcha, and Turnstile. \
Token output is JSON when --format=json. AUTHORIZED TARGETS ONLY.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth captcha solve --type recaptcha-v2 --site-url https://example.com\n  \
$ rev-stealth captcha solve --type turnstile --site-url https://x.test --site-key 0x4 --dry-run\n  \
$ rev-stealth --format json captcha solve --type hcaptcha --site-url https://h.test\n\n\
EXIT CODES:\n  \
0  Ok               Token solved successfully.\n  \
1  UserError        Bad args (unknown --type, malformed --site-url).\n  \
2  TransientError   Solver network/provider transient failure.\n  \
3  PermanentError   Solver not configured or challenge unsupported.\n\n\
ENV:\n  \
REV_STEALTH_CAPTCHA_SECRET  Provider secret used by `verify` (see captcha verify --help)."
    )]
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
    #[command(
        long_about = "Verify a CAPTCHA token by calling the challenge provider's \
server-side verify endpoint. Returns the provider's structured verdict; the \
exit code reflects RPC outcome only (not the verdict itself).",
        after_help = "EXAMPLES:\n  \
$ rev-stealth captcha verify --type recaptcha-v2 --token <TOKEN>\n  \
$ rev-stealth captcha verify --type hcaptcha --token <TOKEN> --secret <SECRET>\n  \
$ REV_STEALTH_CAPTCHA_SECRET=... rev-stealth captcha verify --type turnstile --token <TOKEN>\n\n\
EXIT CODES:\n  \
0  Ok               Verify RPC completed (read verdict from output).\n  \
1  UserError        Bad args (unknown --type, missing --secret).\n  \
2  TransientError   Provider network/timeout (retryable).\n  \
3  PermanentError   Provider permanently rejected (unsupported type, bad config).\n\n\
ENV:\n  \
REV_STEALTH_CAPTCHA_SECRET  Provider secret. Preferred over `--secret` for ops use."
    )]
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
    // v1.3 Lane G fix-up R2: delegate to centralized multi-format renderer
    // (handles human/text/json/yaml uniformly so the yaml branch lives in one place).
    crate::commands::output_render::emit_ok(format, op, payload);
}

fn emit_error(format: OutputFormat, exit: ExitCode, op: &str, message: &str) -> ExitCode {
    // v1.3 Lane G.7: canonical error envelope (see commands/error_envelope.rs).
    let kind = crate::commands::error_envelope::classify_legacy_message(message);
    let _ = crate::commands::error_envelope::emit_err_envelope(
        format,
        op,
        exit.as_i32(),
        kind,
        message,
        None,
        None,
    );
    exit
}
