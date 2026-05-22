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
#[cfg(not(test))]
pub mod config_io;
mod doctor;
#[cfg(not(test))]
mod policy;
#[cfg(test)]
pub use stealth_cli::{config_io, policy};
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
    #[command(
        long_about = "CAPTCHA resilience evaluation. Drives the captcha-bypass solver \
against reCAPTCHA v2/v3, hCaptcha, or Turnstile, and verifies tokens via the \
provider's server-side endpoint. AUTHORIZED TARGETS ONLY.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth captcha solve --type recaptcha-v2 --site-url https://example.com\n  \
$ rev-stealth captcha verify --type hcaptcha --token <TOKEN>\n\n\
EXIT CODES:\n  \
0  Ok               Action completed.\n  \
1  UserError        Bad args (unknown --type / missing --site-url).\n  \
2  TransientError   Solver or provider transient failure.\n  \
3  PermanentError   Solver not configured / challenge unsupported.\n\n\
ENV:\n  \
REV_STEALTH_CAPTCHA_SECRET  Provider secret used by `captcha verify`."
    )]
    Captcha {
        #[command(subcommand)]
        action: captcha_cmd::CaptchaAction,
    },
    /// Stealth browser operations (launch a profile, run a stealth-test sweep).
    #[command(
        long_about = "Stealth-browser operations via chromiumoxide. `launch` boots a \
fingerprint-cloaked Chrome, navigates, and dumps page metadata; `stealth-test` \
runs a detection-page sweep (default bot.sannysoft.com).",
        after_help = "EXAMPLES:\n  \
$ rev-stealth browser launch --profile mobile-ios --url https://example.com\n  \
$ rev-stealth browser stealth-test --dwell 5\n\n\
EXIT CODES:\n  \
0  Ok               Browser action completed.\n  \
1  UserError        Unknown --profile or --stealth slug.\n  \
2  TransientError   Chrome launch / CDP transient failure.\n  \
3  PermanentError   Chrome binary missing or stealth level unsupported.\n\n\
ENV:\n  \
REV_STEALTH_CHROME  Override the chrome executable path."
    )]
    Browser {
        #[command(subcommand)]
        action: browser_cmd::BrowserAction,
    },
    /// VPN IP rotation operations (Surfshark / Gluetun lazy-rotate-on-fail).
    #[command(
        long_about = "VPN exit-IP control. `rotate` triggers a provider rotation with \
the chosen strategy (lazy-on-fail / every-n / interval); `status` probes the \
current public IP and the VPN container state. All actions are audit-logged.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth vpn rotate --strategy lazy-on-fail --reason scrape-failure\n  \
$ rev-stealth vpn status\n\n\
EXIT CODES:\n  \
0  Ok               Action completed.\n  \
1  UserError        Bad --provider / --strategy.\n  \
2  TransientError   Provider/container transient failure.\n  \
3  PermanentError   Provider unsupported in this build.\n  \
7  Leak             Post-action leak detected (fail-closed).\n\n\
ENV:\n  \
REV_SCRAPING_REQUIRE_VPN  When `1`, enforces VPN-required guard policy-wide.\n  \
VPN_INSTANCES             Pool of named VPN instances (config.vpn_instances)."
    )]
    Vpn {
        #[command(subcommand)]
        action: vpn_cmd::VpnAction,
    },
    /// Pre-flight leak-prevention checks (kill-switch / DNS / IPv6 / WebRTC).
    /// Exits with code 7 when any check fails (fail-closed).
    #[command(
        long_about = "Pre-flight leak-prevention diagnostics: kill-switch, DNS lock, \
IPv6 disabled, WebRTC guard, and optional exit-IP probe (ipinfo.io). \
Fail-closed: any check failing yields exit code 7. `--deep` runs extended \
stack health checks; `--vps` adds VPS-deploy readiness checks.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth doctor\n  \
$ rev-stealth doctor --expected-country JP --output-format text\n  \
$ rev-stealth doctor --deep --skip-exit-ip\n  \
$ rev-stealth doctor --vps\n\n\
EXIT CODES:\n  \
0  Ok               All checks passed.\n  \
1  UserError        Bad args (unknown --container, malformed country code).\n  \
7  Leak             One or more leak checks failed (fail-closed).\n\n\
ENV:\n  \
REV_STEALTH_CHROME  WebRTC guard probe respects this override."
    )]
    Doctor(doctor::DoctorArgs),
    /// AUP-gated browse + optional CF eval + optional adaptive relocate.
    #[command(
        long_about = "AUP-gated browser fetch with optional Cloudflare Turnstile \
evaluation and adaptive element relocation. Honours the layered config / \
recipe cache; falls back from obscura to reqwest unless --no-auto-fallback \
is set. Replays stored auth cookies via --use-auth. AUTHORIZED TARGETS ONLY.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth spider --url https://example.com --i-have-authorization\n  \
$ rev-stealth spider --url https://x.test --use-auth my-profile --require-vpn\n  \
$ rev-stealth spider --url https://x.test --http-only --dump-html out.html\n\n\
EXIT CODES:\n  \
0  Ok               Fetch + (optional) relocate succeeded.\n  \
1  UserError        Bad args / AUP rejection / config validation failure.\n  \
2  TransientError   Network / obscura / VPN flap (retryable).\n  \
3  PermanentError   Permanent fetch failure or unsupported config.\n  \
4  AuthExpired      Stored auth profile missing/expired (Phase 9a).\n  \
7  Leak             Leak detected (fail-closed when --require-vpn).\n\n\
ENV:\n  \
REV_STEALTH_OBSCURA       Override the obscura binary path.\n  \
REV_SCRAPING_HOME         Override `~/.rev_scraping/` base.\n  \
REV_SCRAPING_REQUIRE_VPN  When `1`, enforces VPN-required guard."
    )]
    Spider(commands::spider::SpiderArgs),
    /// Locate a previously fingerprinted element in a saved HTML or fresh URL.
    #[command(
        long_about = "Locate a previously fingerprinted element by stable_id against \
either a local HTML file (--html-file) or a fresh fetch (--url, HTTP-only). \
Returns the best CSS selector + similarity score from ParseStore.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth relocate --stable-id abc123 --html-file saved.html\n  \
$ rev-stealth relocate --stable-id abc123 --url https://example.com --i-have-authorization\n  \
$ rev-stealth relocate --stable-id abc123 --html-file saved.html --strict --threshold 0.9\n\n\
EXIT CODES:\n  \
0  Ok               Match found above threshold.\n  \
1  UserError        Bad args / AUP rejection / missing stable_id.\n  \
3  PermanentError   ParseStore open failure or no candidate found.\n\n\
ENV:\n  \
REV_SCRAPING_HOME  Override `~/.rev_scraping/` (ParseStore location)."
    )]
    Relocate(commands::relocate::RelocateArgs),
    /// Defender-testbed evaluation of Cloudflare Turnstile resilience.
    #[command(
        name = "cf-evaluate",
        long_about = "Defender-testbed evaluation of Cloudflare Turnstile resilience. \
Launches the stealth browser against --url and records the Turnstile challenge \
trajectory without invoking any solver. Requires explicit AUP authorization.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth cf-evaluate --url https://example.com --i-have-authorization\n  \
$ rev-stealth cf-evaluate --url https://x.test --i-have-authorization --use-auth my-profile\n  \
$ rev-stealth cf-evaluate --url https://x.test --i-have-authorization --require-vpn\n\n\
EXIT CODES:\n  \
0  Ok               Evaluation completed.\n  \
1  UserError        Bad --url / AUP rejection / config error.\n  \
2  TransientError   Browser / network transient failure.\n  \
3  PermanentError   Obscura missing or evaluation unsupported.\n\n\
ENV:\n  \
REV_STEALTH_OBSCURA       Override the obscura binary path.\n  \
REV_SCRAPING_REQUIRE_VPN  When `1`, enforces VPN-required guard."
    )]
    CfEvaluate(commands::cf_evaluate::CfEvaluateArgs),
    /// Authenticated session capture / lifecycle (Phase 9d).
    /// Subcommands: login / list / show / delete / status / refresh.
    #[command(
        long_about = "Authenticated session lifecycle (Phase 9d). Login captures \
cookies via rev-auth and stores them sealed under AuthStore; list/show emit \
redacted metadata; status reports freshness; refresh re-runs login; delete \
shreds the profile.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth auth login --profile work --url https://x.test\n  \
$ rev-stealth auth list\n  \
$ rev-stealth auth status --profile work\n  \
$ rev-stealth auth delete --profile work --force\n\n\
EXIT CODES:\n  \
0  Ok               Action completed.\n  \
1  UserError        Bad args / unknown profile / AUP rejection.\n  \
3  PermanentError   AuthStore unavailable / rev-auth not installed.\n  \
4  AuthExpired      Profile expired or unusable (login/status/refresh paths).\n\n\
ENV:\n  \
REV_OBSCURA_BIN              Override the obscura binary path.\n  \
REV_AUTH_BIN                 Override the rev-auth helper binary.\n  \
REV_SCRAPING_AUTH_DIR        Override the AuthStore directory.\n  \
REV_SCRAPING_AUTH_PASSPHRASE Sealed-store passphrase (else keystore-derived).\n  \
REV_SCRAPING_REQUIRE_VPN     When `1`, enforces VPN-required guard."
    )]
    Auth(commands::auth::AuthArgs),
    /// v1.1.0 (P15): local fingerprint diagnostics for monitoring.
    /// External SaaS calls are opt-in via `--enable-external`.
    #[command(
        long_about = "Local fingerprint diagnostics for monitoring (P15). Validates \
the target --url and emits a deterministic fingerprint snapshot. External \
SaaS probes (CreepJS / bot.sannysoft) require --enable-external. The VPS \
egress probe requires --enable-egress-probe AND the `vps-egress-probe` Cargo \
feature.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth measure --url https://example.com\n  \
$ rev-stealth measure --url https://x.test --enable-external\n  \
$ rev-stealth measure --url https://x.test --enable-egress-probe\n\n\
EXIT CODES:\n  \
0  Ok               Measurement emitted.\n  \
1  UserError        Bad args.\n  \
2  TransientError   External probe transient failure (when --enable-external).\n  \
3  PermanentError   Bad --url / measurement path unavailable.\n\n\
ENV:\n  \
REV_STEALTH_EGRESS_PROBE_URL  Override the egress probe endpoint."
    )]
    Measure(commands::measure::MeasureArgs),
    /// v1.2.0 (P6.1): inspect the layered config
    /// (`show` / `paths` / `validate` / `diff` / `get`).
    #[command(
        long_about = "Layered config inspection + mutation (P6.x). show/paths/validate/diff/get \
are read-only; set/edit/migrate/init/history/rollback/gc write through the \
atomic ConfigWriter (0600 + `.bak.<epoch>` backups). `profile` manages \
per-profile config trees.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config show\n  \
$ rev-stealth config validate\n  \
$ rev-stealth config set policy.require_vpn true\n  \
$ rev-stealth config init --target all\n\n\
EXIT CODES:\n  \
0  Ok               Action completed.\n  \
1  UserError        Bad args / validation failure / unknown key.\n  \
3  PermanentError   Config IO failure / unsupported target.\n\n\
ENV:\n  \
REV_SCRAPING_HOME            Override `~/.rev_scraping/` base.\n  \
REV_SCRAPING_POLICY          Override the policy.toml path.\n  \
REV_SCRAPING_AUTHORIZED      Override the authorized.toml path.\n  \
REV_SCRAPING_PROFILES_ROOT   Override the profiles root directory.\n  \
REV_SCRAPING_CONFIG_LENIENT  Loosen validate strictness (test/CI).\n  \
EDITOR                       Editor used by `config edit` (fallback: vi)."
    )]
    Config(commands::config_cli::ConfigArgs),
    /// v1.2.0 (P7.3): manage the Hermes plugin scaffold
    /// (`install` / `uninstall` / `verify`).
    #[command(
        long_about = "Manage the Hermes MCP plugin scaffold (P7.3). install copies \
the bundled scaffold to <prefix>; uninstall removes it; verify checks the \
required files + (by default) runs a python3 ast.parse syntax probe on \
__init__.py.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth hermes install\n  \
$ rev-stealth hermes verify\n  \
$ rev-stealth hermes uninstall --prefix /opt/hermes/plugins/rev-scraping-mcp\n\n\
EXIT CODES:\n  \
0  Ok               Action completed.\n  \
1  UserError        Bad --prefix / install conflict (use --force).\n  \
3  PermanentError   Scaffold IO failure / python3 syntax check failed.\n\n\
ENV:\n  \
(none consumed directly; respects HOME for default --prefix.)"
    )]
    Hermes(commands::hermes::HermesArgs),
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
        Command::Config(args) => commands::config_cli::run(cli.format, args).await,
        Command::Hermes(args) => commands::hermes::run(cli.format, args).await,
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
    fn config_subcommand_parses_with_global_format() {
        // P6.1 round-2 reviewer finding: `rev-stealth config` previously
        // panicked at runtime because the config-local `--format` flag
        // reused Clap arg id `format`, colliding with the global
        // `Cli.format`. After renaming to `--output-format` with id
        // `config_output_format`, both `config validate` and
        // `--format json config validate` must parse without panic.
        let cli = Cli::try_parse_from(["rev-stealth", "config", "validate"])
            .expect("`config validate` must parse");
        assert!(matches!(cli.command, Command::Config(_)));
        let cli = Cli::try_parse_from(["rev-stealth", "--format", "json", "config", "validate"])
            .expect("global --format json + config validate must parse");
        assert!(matches!(cli.command, Command::Config(_)));
        let cli = Cli::try_parse_from([
            "rev-stealth",
            "config",
            "--output-format",
            "json",
            "validate",
        ])
        .expect("config --output-format must parse");
        match cli.command {
            Command::Config(args) => {
                assert_eq!(
                    args.format
                        .to_possible_value()
                        .expect("variant has a value")
                        .get_name(),
                    "json",
                );
            }
            other => panic!("expected Config subcommand, got {other:?}"),
        }
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
