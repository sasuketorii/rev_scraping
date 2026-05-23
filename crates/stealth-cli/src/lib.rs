// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! rev-stealth CLI library surface.
//!
//! v1.3 (Lane H Slice A): the CLI entrypoint moved from a thin binary
//! into this library so that:
//!   * the `rev-stealth` binary at `src/main.rs` is a 1-line forwarder; and
//!   * `cargo install rev-stealth` from crates.io builds against this same
//!     library + binary surface (no separate publish-wrapper crate).
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
//!   4 = auth expired (Phase 9a)
//!   7 = leak detected / fail-closed (emitted by `doctor`)

#![forbid(unsafe_code)]

mod adapters;
mod aup;
mod browser_cmd;
mod captcha_cmd;
mod commands;
// v1.3 Lane G.7: expose the public-safe G.7 lint surface (the
// `CliErrorKind` taxonomy and `DOC_URL_BASE`) so
// `tests/error_template_uniform.rs` can walk every variant without
// needing the whole `commands` module to be public. The emitter
// helpers (`emit_err_envelope`, `augment_with_g7_fields`) intentionally
// reference the crate-private `OutputFormat` type and are NOT
// re-exported here — they are reached internally via `crate::commands`.
#[doc(hidden)]
pub mod __error_envelope_for_test {
    pub use crate::commands::error_envelope::{CliErrorKind, DOC_URL_BASE};
}
pub mod config_io;
mod doctor;
pub mod policy;
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
    /// Output format for agent / human consumers. Default `human`; pass
    /// `json` for machine-parseable output.
    ///
    /// v1.3 Lane G.4: the global flag remains `--format` (Human|Json) for
    /// backward compatibility with v1.2.x. Most subcommands also expose a
    /// per-subcommand `--output-format` flag with the same value enum, which
    /// shadows the global within the subtree. Two subcommands extend the
    /// enum locally — `doctor --output-format {json|text}` and
    /// `config --output-format {text|json|yaml}` — because those surfaces
    /// pre-date the unified flag. The full matrix and JSON schemas live
    /// under `docs/json-schemas/cli/`.
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
        /// v1.3 Lane G.4: per-subcommand `--output-format` override of the
        /// global `--format`. Schema: `docs/json-schemas/cli/captcha.output.json`.
        #[command(flatten)]
        output_format: commands::output_format::OutputFormatOverride,
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
        /// v1.3 Lane G.4: per-subcommand `--output-format` override of the
        /// global `--format`. Schema: `docs/json-schemas/cli/browser.output.json`.
        #[command(flatten)]
        output_format: commands::output_format::OutputFormatOverride,
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
        /// v1.3 Lane G.4: per-subcommand `--output-format` override of the
        /// global `--format`. Schema: `docs/json-schemas/cli/vpn.output.json`.
        #[command(flatten)]
        output_format: commands::output_format::OutputFormatOverride,
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
    /// v1.3 (G.3): generate shell completion script for the requested shell on
    /// stdout. Hidden from `--help` because it is a build-time tool consumed by
    /// `scripts/gen_completions.sh` and the `completion-drift` CI gate, not a
    /// user-facing operation. Output goes to stdout so the caller (script or
    /// shell `source <(...)`) decides where it lands.
    #[command(
        hide = true,
        long_about = "Generate shell completion script for the requested shell to stdout. \
Used by scripts/gen_completions.sh and the completion-drift CI gate."
    )]
    Completions(CompletionsArgs),
}

#[derive(clap::Args, Debug)]
struct CompletionsArgs {
    /// Target shell. Supported: bash, zsh, fish, nushell (elvish is intentionally
    /// excluded from the v1.3 supported matrix — add if/when CI gains coverage).
    #[arg(value_enum)]
    shell: CompletionShell,
}

#[derive(Copy, Clone, Debug, clap::ValueEnum)]
enum CompletionShell {
    Bash,
    Zsh,
    Fish,
    Nushell,
}

/// v1.3 (G.8): args for the hidden `manpages` subcommand. Single positional
/// `<output-dir>` keeps the surface identical to the historical
/// `cargo xtask manpages <dir>` referenced from
/// `crates/stealth-cli/Cargo.toml` (cargo-deb / cargo-rpm comments).
#[derive(clap::Args, Debug)]
struct ManpagesArgs {
    /// Output directory. Created if missing. One `<bin>.1` file per command.
    output_dir: std::path::PathBuf,
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

/// CLI entrypoint exposed for both the local `main.rs` forwarder and
/// downstream embedders that want to drive `rev-stealth` programmatically.
///
/// Returns the process exit code as an `i32` matching
/// [`stealth_core::ExitCode`]. Builds an owned multi-thread Tokio runtime
/// per call; do not call from inside an existing Tokio runtime.
pub fn run() -> i32 {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("build tokio runtime for rev-stealth CLI");
    runtime.block_on(run_async())
}

/// Async core of [`run`]. Parses argv, initialises tracing, and dispatches
/// to the requested subcommand. Returns the exit code without calling
/// `std::process::exit` so callers can perform cleanup.
pub async fn run_async() -> i32 {
    // v1.3 Lane G.7: route clap parse failures through the canonical
    // error envelope. `Cli::parse()` would `exit(2)` with a free-form
    // clap-rendered message that bypasses the G.7 contract entirely;
    // we use `try_parse` and translate the error ourselves.
    let cli = match Cli::try_parse() {
        Ok(c) => c,
        Err(e) => {
            // clap exposes the kind discriminant; "informational" exits
            // (--help / --version) keep clap's stdout output and exit 0.
            use clap::error::ErrorKind as ClapKind;
            let kind = e.kind();
            if matches!(
                kind,
                ClapKind::DisplayHelp
                    | ClapKind::DisplayVersion
                    | ClapKind::DisplayHelpOnMissingArgumentOrSubcommand
            ) {
                let _ = e.print();
                return 0;
            }
            // Heuristic JSON detection: emit a G.7 envelope when the user
            // asked for JSON output; otherwise let clap render its
            // friendly human error. We do NOT call clap's `.exit()`
            // (which terminates the process) so callers retain control.
            let argv: Vec<String> = std::env::args().collect();
            // Accept both split (`--format json`) and combined
            // (`--format=json`) clap forms. Round-2 reviewer finding:
            // the previous heuristic only covered the split form.
            let wants_json = argv.iter().any(|a| {
                a == "--format=json"
                    || a == "--output-format=json"
            }) || argv.windows(2).any(|w| {
                matches!(w[0].as_str(), "--format" | "--output-format") && w[1] == "json"
            });
            if wants_json {
                let msg = e.to_string();
                let kind_e = commands::error_envelope::classify_legacy_message(&msg);
                let _ = commands::error_envelope::emit_err_envelope(
                    OutputFormat::Json,
                    "cli.parse",
                    2,
                    kind_e,
                    &msg,
                    None,
                    None,
                );
            } else {
                let _ = e.print();
            }
            return 2;
        }
    };
    init_tracing(cli.verbose);

    // v1.3 Lane G.4: each subcommand that owns an Args struct now flattens an
    // `OutputFormatOverride` shim, so `--output-format` works both at the root
    // (via global `--format`'s positional-tolerant alias is *not* used — global
    // remains `--format`) and per-subcommand. The shim resolves to the global
    // value when the user did not pass `--output-format`.
    match cli.command {
        Command::Captcha {
            action,
            output_format,
        } => captcha_cmd::run(output_format.resolve(cli.format), action)
            .await
            .as_i32(),
        Command::Browser {
            action,
            output_format,
        } => browser_cmd::run(output_format.resolve(cli.format), action)
            .await
            .as_i32(),
        Command::Vpn {
            action,
            output_format,
        } => vpn_cmd::run(output_format.resolve(cli.format), action)
            .await
            .as_i32(),
        Command::Doctor(args) => doctor::run(cli.format, args).await.as_i32(),
        Command::Spider(args) => {
            let fmt = args.output_format.resolve(cli.format);
            commands::spider::run(fmt, args).await
        }
        Command::Relocate(args) => {
            let fmt = args.output_format.resolve(cli.format);
            commands::relocate::run(fmt, args).await
        }
        Command::CfEvaluate(args) => {
            let fmt = args.output_format.resolve(cli.format);
            commands::cf_evaluate::run(fmt, args).await
        }
        Command::Auth(args) => {
            let fmt = args.output_format.resolve(cli.format);
            commands::auth::run(fmt, args).await
        }
        Command::Measure(args) => {
            let fmt = args.output_format.resolve(cli.format);
            commands::measure::run(fmt, args).await
        }
        Command::Config(args) => commands::config_cli::run(cli.format, args).await,
        Command::Hermes(args) => {
            let fmt = args.output_format.resolve(cli.format);
            commands::hermes::run(fmt, args).await
        }
        Command::Completions(args) => {
            generate_completions(args.shell);
            0
        }
        Command::Manpages(args) => match generate_manpages(&args.output_dir) {
            Ok(n) => {
                // Mirror gen_completions: silent success on the happy path so
                // the build-script consumer (`scripts/gen_manpages.sh`) has a
                // clean stdout/stderr signal. A summary line on stderr keeps
                // the interactive `cargo run -- manpages ./tmp` discoverable
                // without polluting the script-driven contract.
                eprintln!("wrote {n} man page(s) to {}", args.output_dir.display());
                0
            }
            Err(e) => {
                eprintln!("rev-stealth manpages: {e}");
                3
            }
        },
    }
}

/// Generate a shell completion script for the requested shell and write it to
/// stdout. Lane G.3 (v1.3 Black-Belt CLI) — drives the
/// `scripts/gen_completions.sh` build-time generator and the `completion-drift`
/// CI gate. Reads the clap `Command` tree directly via `CommandFactory` so the
/// completion stays in lockstep with the actual `--help` surface.
///
/// The internal `completions` subcommand itself is stripped from the tree
/// before generation: it is `#[command(hide=true)]` so it is suppressed from
/// `--help`, but `clap_complete::generate` (round 1 reviewer finding) still
/// emits it as a tab-completion suggestion. Filtering at generation time keeps
/// user-facing shell completion in lockstep with `--help`'s public surface.
fn generate_completions(shell: CompletionShell) {
    use clap::CommandFactory;
    let mut cmd = strip_internal_subcommands(Cli::command());
    let bin_name = "rev-stealth";
    let stdout = &mut std::io::stdout();
    match shell {
        CompletionShell::Bash => {
            clap_complete::generate(clap_complete::shells::Bash, &mut cmd, bin_name, stdout);
        }
        CompletionShell::Zsh => {
            clap_complete::generate(clap_complete::shells::Zsh, &mut cmd, bin_name, stdout);
        }
        CompletionShell::Fish => {
            clap_complete::generate(clap_complete::shells::Fish, &mut cmd, bin_name, stdout);
        }
        CompletionShell::Nushell => {
            clap_complete::generate(clap_complete_nushell::Nushell, &mut cmd, bin_name, stdout);
        }
    }
}

/// v1.3 Lane G.8: generate roff(7) man(1) pages for `rev-stealth` and every
/// public subcommand into `output_dir`. Drives the `scripts/gen_manpages.sh`
/// build-time generator and the `manpage-drift` CI gate. Reads the clap
/// `Command` tree directly via `CommandFactory` so the man pages stay in
/// lockstep with `--help` (long_about + after_help → DESCRIPTION + EXAMPLES /
/// EXIT CODES / ENV sections, populated by clap_mangen).
///
/// Strips internal subcommands (`completions`, `manpages`) from the tree
/// before walking it — same contract as `generate_completions`.
///
/// Output: one file per command using the canonical `<bin>-<sub>-...-<leaf>.1`
/// naming. Returns the number of files written so the dispatcher can emit a
/// short progress line.
fn generate_manpages(output_dir: &std::path::Path) -> std::io::Result<usize> {
    use clap::CommandFactory;
    std::fs::create_dir_all(output_dir)?;
    // Disable clap's auto-injected `help` subcommand tree-wide BEFORE the
    // walker hands the Command to clap_mangen. Round-1 reviewer (G.8) finding
    // #2: simply skipping `name == "help"` during DFS still leaves clap's own
    // SUBCOMMANDS rendering emitting `rev-stealth-help(1)` cross-refs that
    // point to non-existent `.1` files (`whatis` / `apropos` regression).
    // `disable_help_subcommand(true)` removes the auto-injected node from
    // the entire subtree.
    let root = strip_internal_subcommands(Cli::command()).disable_help_subcommand(true);
    let mut count = 0usize;
    write_man_recursive(&root, output_dir, &[], &mut count)?;
    Ok(count)
}

/// Walk the clap `Command` tree depth-first. For each node, render one
/// `<path-joined-by-dashes>.1` file using `clap_mangen::Man::render`. The
/// `path` slice carries the ancestor command names so nested subcommands
/// become `rev-stealth-config-set.1` etc. — matching the convention used by
/// `man(1)` lookup tables.
///
/// Note on clap+mangen ownership: `clap_mangen::Man::new` consumes its input
/// `Command`, so each recursive call clones the child node. The whole walk
/// runs at build time (~ms), so the clone cost is irrelevant compared to the
/// resulting determinism — every render starts from a pristine copy of the
/// subtree.
fn write_man_recursive(
    cmd: &clap::Command,
    output_dir: &std::path::Path,
    path: &[String],
    count: &mut usize,
) -> std::io::Result<()> {
    // Compose this node's file name. The root command is just `rev-stealth.1`;
    // children become `rev-stealth-<a>-<b>.1`.
    let mut segments: Vec<String> = path.to_vec();
    segments.push(cmd.get_name().to_string());
    let file_name = format!("{}.1", segments.join("-"));
    let target = output_dir.join(&file_name);

    // `Man::new` consumes the Command, so clone the subtree. We also force a
    // stable bin/display name so nested commands render with the
    // dash-separated invocation users actually type (`rev-stealth config set`,
    // not just `set`).
    // `clap::Command::{name,bin_name}` only accept `impl Into<Str>`, and
    // `Str` does not impl `From<String>`. Leak the per-node strings (one-time,
    // generator lives ~tens of ms; we don't ship this binary into a long-
    // running process). Mirrors the same `Box::leak` trick used by
    // `strip_internal_subcommands` above and by clap's own derive output.
    //
    // Round-1 reviewer (G.8) finding #1: `name` must be the FULL dash-joined
    // page stem (e.g. `rev-stealth-auth-login`), NOT the bare leaf (`login`).
    // clap_mangen writes the `name` into the `.TH` title heading verbatim
    // AND uses it when rendering subcommand cross-references in the parent's
    // `.SH SUBCOMMANDS` block. A bare-leaf name produces `.TH login` and
    // dangling refs like `config-set(1)` that `man`/`whatis` can't resolve.
    // The dash-joined stem matches the committed filename and gives `whatis`
    // the right anchor.
    let stem_leaked: &'static str = Box::leak(segments.join("-").into_boxed_str());
    let display_leaked: &'static str = Box::leak(segments.join(" ").into_boxed_str());
    // `disable_help_subcommand(true)` is applied per-node (not just the root)
    // because clap auto-injects the `help` subcommand on every node that has
    // children. Without per-node disable, `rev-stealth-config.1` would still
    // advertise `config-help(1)` in its SUBCOMMANDS block even though the
    // walker skips writing the corresponding `.1` file — leaving a dangling
    // cross-ref. See round-1 reviewer (G.8) finding #2.
    let owned = cmd
        .clone()
        .name(stem_leaked)
        .bin_name(display_leaked)
        .disable_help_subcommand(true);
    let man = clap_mangen::Man::new(owned);
    let mut buf: Vec<u8> = Vec::with_capacity(4096);
    man.render(&mut buf)?;
    std::fs::write(&target, &buf)?;
    *count += 1;

    // Recurse into children. Filter out clap-injected `help` subcommands
    // (every clap command auto-generates a `help` subcommand for printing
    // sub-help; emitting a man page for it would be noise and would drift
    // every time clap's help text changes).
    for sub in cmd.get_subcommands() {
        if sub.get_name() == "help" {
            continue;
        }
        write_man_recursive(sub, output_dir, &segments, count)?;
    }
    Ok(())
}

/// Names of subcommands that exist only for build/CI tooling and must NOT be
/// surfaced as tab-completion suggestions to end users. Centralised here so
/// future internal commands (`__dump-schema`, etc.) opt in by adding their
/// name to one list rather than re-deriving the filter logic.
const INTERNAL_HIDDEN_SUBCOMMANDS: &[&str] = &["completions", "manpages"];

/// Rebuild a clap `Command` tree with the names listed in
/// [`INTERNAL_HIDDEN_SUBCOMMANDS`] removed from the top level. Returns the
/// pruned tree; the input is consumed because `clap::Command::mut_subcommand`
/// only re-decorates a node — it does not remove it from the completion tree.
///
/// Implementation note: clap 4.x has no public `remove_subcommand` and no
/// `take_subcommands` taking ownership of the children. The portable trick
/// is to call `mut_subcommand(name, |sc| sc.hide(true))` on each unwanted
/// node — but `clap_complete::generate` already ignores `hide` flags. The
/// next-best portable approach is to rebuild the top-level Command keeping
/// only the wanted children: we clone the source Command, collect owned
/// keepers, and re-attach. We use `Cli::command()` again as the structural
/// source of truth because the input `cmd` may have been partially mutated
/// by earlier callers in the future.
fn strip_internal_subcommands(_cmd: clap::Command) -> clap::Command {
    use clap::CommandFactory;
    let src = Cli::command();
    let keepers: Vec<clap::Command> = src
        .get_subcommands()
        .filter(|sc| !INTERNAL_HIDDEN_SUBCOMMANDS.contains(&sc.get_name()))
        .cloned()
        .collect();
    // Re-build via `clap::Command::new(<name>)` and re-attach top-level
    // metadata + args + filtered subcommands. `Str` (clap's interned string
    // type) is the canonical input form for these setters, so we clone from
    // the source `Command`'s already-interned getters.
    // `clap::Command::new` accepts `impl Into<Str>`; `Str: From<&'static str>`
    // only, so we keep a longer-lived owned String and pass a borrow when
    // constructing other fields. For the name itself, `Box::leak` is the
    // canonical workaround used by clap's own derive-generated code.
    let leaked_name: &'static str = Box::leak(src.get_name().to_string().into_boxed_str());
    let mut fresh = clap::Command::new(leaked_name);
    if let Some(about) = src.get_about() {
        fresh = fresh.about(about.clone());
    }
    if let Some(long_about) = src.get_long_about() {
        fresh = fresh.long_about(long_about.clone());
    }
    if let Some(ver) = src.get_version() {
        // `version` wants `IntoResettable<Str>`; `Str: From<&'static str>` only.
        // Leak the version string (one-time, generator lives ~10ms).
        let leaked_ver: &'static str = Box::leak(ver.to_string().into_boxed_str());
        fresh = fresh.version(leaked_ver);
    }
    for arg in src.get_arguments() {
        fresh = fresh.arg(arg.clone());
    }
    for sc in keepers {
        fresh = fresh.subcommand(sc);
    }
    fresh
}

/// v1.3 Lane G.4 test-utility: parse a full argv slice (including the
/// `rev-stealth` program name at position 0) through the same clap derive
/// surface the binary uses, returning a unit-or-error so integration tests
/// in `tests/` can assert flag-surface contracts without spawning a process.
///
/// This is intentionally `pub` and prefixed with `__` to mark it as a
/// crate-private surface for our own integration tests. External callers
/// should drive the CLI through `run` or by spawning the binary.
#[doc(hidden)]
pub fn __cli_parse_for_test(argv: &[&str]) -> Result<(), clap::Error> {
    Cli::try_parse_from(argv).map(|_| ())
}

/// v1.3 Lane G.4 test-utility: hand the integration test the live clap
/// `Command` tree (post-derive) so it can call `debug_assert()` on it.
#[doc(hidden)]
pub fn __cli_command_for_test() -> clap::Command {
    use clap::CommandFactory;
    Cli::command()
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
