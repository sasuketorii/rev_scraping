// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! rev-stealth CLI
//!
//! Subcommands:
//!   captcha solve / verify
//!   browser launch / stealth-test
//!   vpn rotate / status
//!
//! Output format: human-readable (default) or `--format=json` for agent consumers.
//!
//! Exit codes (see `stealth_core::ExitCode`):
//!   0 = ok
//!   1 = user error (bad args / config)
//!   2 = transient error (retryable: network / VPN flap)
//!   3 = permanent error (unsupported / not implemented)
//!   7 = leak detected / fail-closed (emitted by `doctor`)

#![forbid(unsafe_code)]

mod adapters;
mod aup;
mod browser_cmd;
mod captcha_cmd;
mod commands;
mod doctor;
mod policy;
mod vpn_cmd;
mod vpn_guard;
mod vpn_selector;

use clap::{Parser, Subcommand, ValueEnum};

#[derive(Parser, Debug)]
#[command(
    name = "rev-stealth",
    version,
    about = "Defender-facing evaluation toolkit: captcha resilience / browser stealth / VPN rotation / adaptive scraping (authorized targets only)",
    long_about = None,
)]
struct Cli {
    /// Output format.
    #[arg(long, value_enum, default_value_t = OutputFormat::Human, global = true)]
    format: OutputFormat,

    /// Verbose logging (`-v`, `-vv`, `-vvv`).
    #[arg(short, long, action = clap::ArgAction::Count, global = true)]
    verbose: u8,

    #[command(subcommand)]
    command: Command,
}

#[derive(Copy, Clone, Debug, ValueEnum)]
pub(crate) enum OutputFormat {
    Human,
    Json,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// CAPTCHA bypass operations (reCAPTCHA v2 / v3 / hCaptcha / Turnstile).
    Captcha {
        #[command(subcommand)]
        action: captcha_cmd::CaptchaAction,
    },
    /// Stealth browser operations (launch a profile, run a stealth-test sweep).
    Browser {
        #[command(subcommand)]
        action: browser_cmd::BrowserAction,
    },
    /// VPN IP rotation operations (Surfshark / Gluetun lazy-rotate-on-fail).
    Vpn {
        #[command(subcommand)]
        action: vpn_cmd::VpnAction,
    },
    /// Pre-flight leak-prevention checks (kill-switch / DNS / IPv6 / WebRTC).
    /// Exits with code 7 when any check fails (fail-closed).
    Doctor(doctor::DoctorArgs),
    /// AUP-gated browse + optional CF eval + optional adaptive relocate.
    Spider(commands::spider::SpiderArgs),
    /// Locate a previously fingerprinted element in a saved HTML or fresh URL.
    Relocate(commands::relocate::RelocateArgs),
    /// Defender-testbed evaluation of Cloudflare Turnstile resilience.
    #[command(name = "cf-evaluate")]
    CfEvaluate(commands::cf_evaluate::CfEvaluateArgs),
    /// Authenticated session capture / lifecycle (Phase 9d).
    /// Subcommands: login / list / show / delete / status / refresh.
    Auth(commands::auth::AuthArgs),
    /// v1.1.0 (P15): local fingerprint diagnostics for monitoring.
    /// External SaaS calls are opt-in via `--enable-external`.
    Measure(commands::measure::MeasureArgs),
}

fn init_tracing(verbose: u8) {
    let level = match verbose {
        0 => "warn",
        1 => "info",
        2 => "debug",
        _ => "trace",
    };
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(level)),
        )
        .with_target(false)
        .try_init();
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    init_tracing(cli.verbose);

    let exit_code: i32 = match cli.command {
        Command::Captcha { action } => captcha_cmd::run(cli.format, action).await.as_i32(),
        Command::Browser { action } => browser_cmd::run(cli.format, action).await.as_i32(),
        Command::Vpn { action } => vpn_cmd::run(cli.format, action).await.as_i32(),
        Command::Doctor(args) => doctor::run(cli.format, args).await.as_i32(),
        Command::Spider(args) => commands::spider::run(cli.format, args).await,
        Command::Relocate(args) => commands::relocate::run(cli.format, args).await,
        Command::CfEvaluate(args) => commands::cf_evaluate::run(cli.format, args).await,
        Command::Auth(args) => commands::auth::run(cli.format, args).await,
        Command::Measure(args) => commands::measure::run(cli.format, args).await,
    };

    std::process::exit(exit_code);
}

#[cfg(test)]
mod cli_tests {
    //! Regression tests for the global `--format` vs doctor `--output-format`
    //! clap arg-name collision (HANDOFF v0.0.4 → v1.0.0 §2.1 P0 fix).
    //!
    //! Before the fix, `Cli::parse_from(["rev-stealth", "doctor", ...])`
    //! panicked at runtime with:
    //!
    //! > Mismatch between definition and access of `format`. Could not
    //! > downcast to rev_stealth::OutputFormat, need to downcast to
    //! > rev_stealth::doctor::DoctorFormat
    //!
    //! These tests lock the contract that:
    //!  1. `doctor --output-format json` parses without panic.
    //!  2. `doctor --output-format text` parses without panic.
    //!  3. The global `--format json` still parses for non-doctor subcommands.
    //!  4. clap's internal `debug_assert` (CommandFactory::command().debug_assert())
    //!     does not flag any duplicate-arg-id collisions.
    use super::*;
    use clap::CommandFactory;
    use clap::Parser;
    use clap::ValueEnum;

    #[test]
    fn clap_command_passes_debug_assert() {
        // clap's `debug_assert` walks the whole command tree and panics on
        // duplicate arg ids / type mismatches. This is the most direct
        // structural assertion.
        Cli::command().debug_assert();
    }

    #[test]
    fn doctor_parses_with_output_format_json() {
        let cli = Cli::try_parse_from([
            "rev-stealth",
            "doctor",
            "--skip-exit-ip",
            "--output-format",
            "json",
        ])
        .expect("doctor --output-format json must parse");
        match cli.command {
            Command::Doctor(args) => {
                assert!(args.skip_exit_ip);
                // Use the discriminant via ValueEnum::to_possible_value to avoid
                // depending on PartialEq / Eq derives we don't own.
                assert_eq!(
                    args.format
                        .to_possible_value()
                        .expect("variant has a value")
                        .get_name(),
                    "json",
                );
            }
            other => panic!("expected Doctor subcommand, got {other:?}"),
        }
    }

    #[test]
    fn doctor_parses_with_output_format_text() {
        let cli = Cli::try_parse_from([
            "rev-stealth",
            "doctor",
            "--skip-exit-ip",
            "--output-format",
            "text",
        ])
        .expect("doctor --output-format text must parse");
        match cli.command {
            Command::Doctor(args) => {
                assert_eq!(
                    args.format
                        .to_possible_value()
                        .expect("variant has a value")
                        .get_name(),
                    "text",
                );
            }
            other => panic!("expected Doctor subcommand, got {other:?}"),
        }
    }

    #[test]
    fn doctor_default_output_format_is_json() {
        // No --output-format flag → default Json.
        let cli = Cli::try_parse_from(["rev-stealth", "doctor", "--skip-exit-ip"])
            .expect("doctor must parse without --output-format");
        match cli.command {
            Command::Doctor(args) => {
                assert_eq!(
                    args.format
                        .to_possible_value()
                        .expect("variant has a value")
                        .get_name(),
                    "json",
                );
            }
            other => panic!("expected Doctor subcommand, got {other:?}"),
        }
    }

    #[test]
    fn global_format_json_still_parses_for_non_doctor_subcommand() {
        // The global `--format` (Human|Json) must still work on other
        // subcommands. We use `vpn status` which is a leaf with no own
        // `--format`. Whatever args VpnAction::Status requires, we only
        // care that clap parses without panicking and that
        // `cli.format == OutputFormat::Json`.
        let cli = Cli::try_parse_from(["rev-stealth", "--format", "json", "vpn", "status"])
            .expect("global --format json must parse on vpn status");
        assert_eq!(
            cli.format
                .to_possible_value()
                .expect("variant has a value")
                .get_name(),
            "json",
        );
    }

    #[test]
    fn help_lists_phase2_subcommands() {
        // "snapshot" via substring contains: the help text MUST advertise
        // spider / relocate / cf-evaluate.
        let mut cmd = Cli::command();
        let mut buf: Vec<u8> = Vec::new();
        cmd.write_long_help(&mut buf).unwrap();
        let help = String::from_utf8(buf).unwrap();
        assert!(help.contains("spider"), "help missing spider:\n{help}");
        assert!(help.contains("relocate"), "help missing relocate:\n{help}");
        assert!(
            help.contains("cf-evaluate"),
            "help missing cf-evaluate:\n{help}"
        );
    }

    #[test]
    fn global_format_can_precede_doctor_without_conflict() {
        // Belt-and-suspenders: global `--format` and doctor `--output-format`
        // coexist on the same invocation.
        let cli = Cli::try_parse_from([
            "rev-stealth",
            "--format",
            "json",
            "doctor",
            "--skip-exit-ip",
            "--output-format",
            "text",
        ])
        .expect("global --format + doctor --output-format must coexist");
        assert_eq!(
            cli.format
                .to_possible_value()
                .expect("variant has a value")
                .get_name(),
            "json",
        );
        match cli.command {
            Command::Doctor(args) => {
                assert_eq!(
                    args.format
                        .to_possible_value()
                        .expect("variant has a value")
                        .get_name(),
                    "text",
                );
            }
            other => panic!("expected Doctor subcommand, got {other:?}"),
        }
    }
}
