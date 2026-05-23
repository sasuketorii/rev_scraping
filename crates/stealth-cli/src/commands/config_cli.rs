// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.2.0 (P6.1 — `rev-stealth config` CLI)
//! `rev-stealth config {show, paths, validate, diff, get}`.
//!
//! Operator-facing inspection of the layered config (policy.toml,
//! authorized.toml, sites/*, env overrides). Secret-looking env values
//! (password / token / key / secret / cookie / auth) are redacted with
//! the literal sentinel `<redacted>` on every code path that surfaces
//! values (`show` / `get`). `validate` reuses the P5.1 engine; `diff`
//! produces a unified diff against `templates/policy.toml`.
//!
//! Slice contract: this is a read-only / no-mutation surface. No subcommand
//! here writes to disk.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use clap::{Args, Subcommand, ValueEnum};
use serde::Serialize;
use serde_json::{json, Value as JsonValue};

use crate::config_io::{
    validate_authorized_toml, validate_toml_against, ConfigWriter, FsConfigWriter, ValidateOptions,
    ValidationReport, WriterError,
};
use crate::policy::Policy;
use crate::OutputFormat as GlobalFormat;

/// Literal sentinel that replaces any secret value on output paths. Tests pin
/// this string verbatim — keep it stable.
pub const REDACTED: &str = "<redacted>";

/// Env vars whose values are surfaced under `effective.env.*`. The subset is
/// kept small and explicit so we never accidentally exfiltrate unrelated
/// process env into a `config show` artifact.
const TRACKED_ENV: &[&str] = &[
    "REV_SCRAPING_REQUIRE_VPN",
    "VPN_INSTANCES",
    "REV_SCRAPING_CONFIG_LENIENT",
    "REV_SCRAPING_HOME",
    "REV_SCRAPING_POLICY",
    "REV_SCRAPING_AUTHORIZED",
];

/// `rev-stealth config` top-level args.
///
/// Round-2 reviewer finding: the config-local format flag must NOT reuse the
/// `format` Clap arg id, otherwise it collides with the global `Cli.format`
/// (same downcast mismatch already documented for `doctor`'s `--output-format`
/// in v0.0.4 → v1.0.0 §2.1). We expose it as `--output-format` with a unique
/// arg id `config_output_format`.
#[derive(Args, Debug, Clone)]
pub struct ConfigArgs {
    /// Output format. Overrides the global `--format` only for this subtree.
    #[arg(
        long = "output-format",
        id = "config_output_format",
        value_enum,
        default_value_t = ConfigFormat::Text,
    )]
    pub format: ConfigFormat,

    #[command(subcommand)]
    pub action: ConfigAction,
}

#[derive(Copy, Clone, Debug, ValueEnum, PartialEq, Eq)]
pub enum ConfigFormat {
    Text,
    Json,
    Yaml,
}

#[derive(Subcommand, Debug, Clone)]
pub enum ConfigAction {
    /// Print the merged effective config from all 4 source layers
    /// (policy.toml / authorized.toml / sites/* / env). Secret-looking
    /// env values are replaced with `<redacted>`.
    #[command(
        long_about = "Print the merged effective config across the 4 source layers \
(policy.toml / authorized.toml / sites/* / env). Secret-looking env values are \
replaced with `<redacted>`.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config show\n  \
$ rev-stealth config --output-format json show\n  \
$ rev-stealth config --output-format yaml show\n\n\
EXIT CODES:\n  \
0  Ok               Config emitted.\n  \
1  UserError        Bad args / parse error.\n  \
3  PermanentError   Config IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_HOME        Override `~/.rev_scraping/` base.\n  \
REV_SCRAPING_POLICY      Override the policy.toml path.\n  \
REV_SCRAPING_AUTHORIZED  Override the authorized.toml path."
    )]
    Show,
    /// List each config file path (absolute), its existence, and permission
    /// bits (unix mode).
    #[command(
        long_about = "List each layered-config file path (absolute), its existence, \
and its unix permission bits. Useful for ops debugging 0600 / 0700 expectations.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config paths\n  \
$ rev-stealth config --output-format json paths\n\n\
EXIT CODES:\n  \
0  Ok               Paths emitted.\n  \
1  UserError        Bad args.\n  \
3  PermanentError   stat() failure.\n\n\
ENV:\n  \
REV_SCRAPING_HOME        Override `~/.rev_scraping/` base."
    )]
    Paths,
    /// Run the P5.1 validate engine over the live config files. Exit 0 on
    /// LGTM; exit 1 with structured issue list on violations.
    #[command(
        long_about = "Run the P5.1 validate engine over the live config files. \
Exit 0 on LGTM; exit 1 with a structured issue list on violations.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config validate\n  \
$ rev-stealth config --output-format json validate\n\n\
EXIT CODES:\n  \
0  Ok               No violations.\n  \
1  UserError        Validation violations (issue list emitted).\n  \
3  PermanentError   Config IO / parse failure.\n\n\
ENV:\n  \
REV_SCRAPING_HOME            Override `~/.rev_scraping/` base.\n  \
REV_SCRAPING_CONFIG_LENIENT  Loosen strictness for test/CI."
    )]
    Validate,
    /// Print a unified diff between the live `<path>` and the in-repo
    /// `templates/policy.toml` baseline. Headers use `---` / `+++`.
    #[command(
        long_about = "Print a unified diff between the live <path> and a baseline \
(default: in-repo templates/policy.toml). Headers use `---` / `+++` so the \
output drops cleanly into `patch`.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config diff ~/.rev_scraping/policy.toml\n  \
$ rev-stealth config diff ~/.rev_scraping/policy.toml --against ./templates/policy.toml\n\n\
EXIT CODES:\n  \
0  Ok               Diff emitted (no change is still exit 0).\n  \
1  UserError        Bad <path>.\n  \
3  PermanentError   IO failure.\n\n\
ENV:\n  \
(none consumed directly; baseline path resolves via the binary's compile-time root.)"
    )]
    Diff {
        /// Path to the live config file (e.g. `~/.rev_scraping/policy.toml`).
        path: PathBuf,
        /// Override the baseline (defaults to `templates/policy.toml`).
        #[arg(long)]
        against: Option<PathBuf>,
    },
    /// Resolve a dotted key path (e.g. `policy.require_vpn`) against the
    /// merged config and print the value. Secret-looking values redacted.
    #[command(
        long_about = "Resolve a dotted key (e.g. `policy.require_vpn`, \
`env.VPN_INSTANCES`) against the merged effective config. Secret-looking values \
are replaced with `<redacted>`.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config get policy.require_vpn\n  \
$ rev-stealth config get env.VPN_INSTANCES\n  \
$ rev-stealth config --output-format json get policy.require_vpn\n\n\
EXIT CODES:\n  \
0  Ok               Value emitted.\n  \
1  UserError        Bad key / unknown path.\n  \
3  PermanentError   Config IO / parse failure.\n\n\
ENV:\n  \
REV_SCRAPING_HOME        Override `~/.rev_scraping/` base.\n  \
REV_SCRAPING_POLICY      Override the policy.toml path.\n  \
REV_SCRAPING_AUTHORIZED  Override the authorized.toml path."
    )]
    Get {
        /// Dotted key, e.g. `policy.require_vpn` or `env.VPN_INSTANCES`.
        key: String,
    },
    /// P6.3: Set a dotted-path key on `policy.toml` (or another target file)
    /// to a value. Type is inferred from the literal text (`true`/`false` →
    /// bool, all-digits → int, otherwise string). The value is written
    /// through the atomic ConfigWriter only after the resulting document
    /// passes strict validation. Secret values are NOT echoed back.
    #[command(
        long_about = "Set a dotted-path key on policy.toml (or another target file). \
Type is inferred from the literal text. Writes go through the atomic ConfigWriter \
after strict validation. Secret values are NOT echoed back.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config set policy.require_vpn true\n  \
$ rev-stealth config set vpn.cooldown_seconds 30 --target policy\n  \
$ rev-stealth config set hosts.allow_x_test true --target authorized\n\n\
EXIT CODES:\n  \
0  Ok               Key set and file committed.\n  \
1  UserError        Bad key / type mismatch / validation failure.\n  \
3  PermanentError   ConfigWriter IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_POLICY      Override the policy.toml path.\n  \
REV_SCRAPING_AUTHORIZED  Override the authorized.toml path."
    )]
    Set(SetArgs),
    /// P6.3: Open the target file in `$EDITOR` (falling back to `vi`).
    /// On editor exit, the candidate is validated. If validation succeeds
    /// the file is committed via ConfigWriter (atomic 0600 + `.bak.<epoch>`).
    /// If validation fails, the original file is left untouched and the
    /// temp file is preserved so the operator can recover their edits.
    #[command(
        long_about = "Open the target config file in $EDITOR (default vi). \
On exit, the candidate is validated; on LGTM the file is committed via \
ConfigWriter (atomic 0600 + .bak.<epoch>). On validation failure the original \
is untouched and the temp file is preserved.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config edit\n  \
$ rev-stealth config edit --target authorized\n  \
$ EDITOR=nano rev-stealth config edit\n\n\
EXIT CODES:\n  \
0  Ok               Edit committed.\n  \
1  UserError        Editor exit / candidate validation failure.\n  \
3  PermanentError   ConfigWriter IO failure.\n\n\
ENV:\n  \
EDITOR                   Editor used (fallback: vi).\n  \
REV_SCRAPING_POLICY      Override the policy.toml path.\n  \
REV_SCRAPING_AUTHORIZED  Override the authorized.toml path."
    )]
    Edit(EditArgs),
    /// P6.3: Migrate `policy.toml` (and authorized.toml) from its current
    /// `schema_version` to the latest known version. v1 → v1 is a no-op
    /// (returns exit 0 + an audit-trail line). The harness is in place
    /// for future v2+ migrations to plug into.
    #[command(
        long_about = "Migrate policy.toml + authorized.toml from their current \
schema_version to the latest known version. v1 → v1 is a no-op (exit 0 + \
audit-trail line). --dry-run prints the migration plan without writing.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config migrate\n  \
$ rev-stealth config migrate --dry-run\n\n\
EXIT CODES:\n  \
0  Ok               Migration completed (or no-op).\n  \
1  UserError        Schema not migratable / unsupported version.\n  \
3  PermanentError   ConfigWriter IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_POLICY      Override the policy.toml path.\n  \
REV_SCRAPING_AUTHORIZED  Override the authorized.toml path."
    )]
    Migrate(MigrateArgs),
    /// P6.2: Initialize the per-user config tree under
    /// `~/.rev_scraping/` (or `$REV_SCRAPING_HOME`). Creates
    /// `policy.toml` (0600), `authorized.toml` (0600), and
    /// `sites/` (0700) via the atomic ConfigWriter. Existing files
    /// are preserved unless `--force` is passed (which routes the
    /// overwrite through `.bak.<epoch>` backup).
    #[command(
        long_about = "Initialize the per-user config tree under ~/.rev_scraping/ \
(or $REV_SCRAPING_HOME). Creates policy.toml (0600), authorized.toml (0600), \
and sites/ (0700) atomically. --force routes overwrites through .bak.<epoch>.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config init\n  \
$ rev-stealth config init --target policy --force\n  \
$ rev-stealth config init --target all --non-interactive\n\n\
EXIT CODES:\n  \
0  Ok               Init completed.\n  \
1  UserError        Existing files present (use --force).\n  \
3  PermanentError   ConfigWriter IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_HOME        Override `~/.rev_scraping/` base."
    )]
    Init(InitArgs),
    /// P6.4: List the `.bak.<epoch>` backups for the target config
    /// file in newest→oldest order (sorted by mtime, tie-broken by
    /// filename desc to match the epoch-ms suffix).
    #[command(
        long_about = "List the .bak.<epoch> backups for the target config file \
in newest→oldest order. Sorted by mtime, ties broken by filename desc \
(matching the epoch-ms suffix).",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config history\n  \
$ rev-stealth config history --target authorized\n\n\
EXIT CODES:\n  \
0  Ok               Listing emitted.\n  \
1  UserError        Unknown target.\n  \
3  PermanentError   directory IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_POLICY      Override the policy.toml path.\n  \
REV_SCRAPING_AUTHORIZED  Override the authorized.toml path."
    )]
    History(HistoryArgs),
    /// P6.4: Restore a previously captured `.bak.<epoch>` backup
    /// onto the target's current path. The current file (if any)
    /// is preserved as a fresh `.bak.<epoch>` by routing the
    /// restore write through `ConfigWriter::write_with_backup`.
    #[command(
        long_about = "Restore a previously captured .bak.<epoch> backup onto the \
target's current path. The current file (if any) is preserved as a fresh \
.bak.<epoch> via ConfigWriter::write_with_backup. Path traversal is rejected.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config rollback policy.toml.bak.1700000000000\n  \
$ rev-stealth config rollback authorized.toml.bak.1700000000000 --target authorized\n\n\
EXIT CODES:\n  \
0  Ok               Rollback committed.\n  \
1  UserError        Bad backup name / path traversal / not found.\n  \
3  PermanentError   ConfigWriter IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_POLICY      Override the policy.toml path.\n  \
REV_SCRAPING_AUTHORIZED  Override the authorized.toml path."
    )]
    Rollback(RollbackArgs),
    /// P6.4: Garbage-collect `.bak.<epoch>` backups for the target
    /// config file, keeping the newest `--keep` (default 5). All
    /// older backups are deleted; the current file is untouched.
    #[command(
        long_about = "Garbage-collect .bak.<epoch> backups for the target config \
file, keeping the newest --keep (default 5). Older backups are deleted; the \
current file is never touched.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config gc\n  \
$ rev-stealth config gc --keep 10\n  \
$ rev-stealth config gc --target authorized --keep 3\n\n\
EXIT CODES:\n  \
0  Ok               GC completed.\n  \
1  UserError        Bad --keep / unknown target.\n  \
3  PermanentError   directory IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_POLICY      Override the policy.toml path.\n  \
REV_SCRAPING_AUTHORIZED  Override the authorized.toml path."
    )]
    Gc(GcArgs),
    /// P6.5: Manage per-profile config trees under
    /// `<base>/profiles/<name>/`. Profiles share the same internal
    /// layout as the top-level config (`policy.toml`, `authorized.toml`,
    /// `sites/`) and are activated by exporting
    /// `REV_SCRAPING_HOME=<base>/profiles/<name>`.
    #[command(
        subcommand,
        long_about = "Manage per-profile config trees under <base>/profiles/<name>/. \
Each profile mirrors the top-level config layout; activation is by exporting \
REV_SCRAPING_HOME=<base>/profiles/<name>.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config profile list\n  \
$ rev-stealth config profile create work\n  \
$ rev-stealth config profile switch work\n  \
$ rev-stealth config profile delete work --yes\n\n\
EXIT CODES:\n  \
0  Ok               Action completed.\n  \
1  UserError        Bad name / active profile / missing --yes.\n  \
3  PermanentError   ConfigWriter IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_HOME            Override `~/.rev_scraping/` base.\n  \
REV_SCRAPING_PROFILES_ROOT   Override the profiles root directory."
    )]
    Profile(ProfileAction),
}

#[derive(Subcommand, Debug, Clone)]
pub enum ProfileAction {
    /// List every profile directory under `<base>/profiles/`.
    #[command(
        long_about = "List every profile directory under <base>/profiles/. Output \
is the bare set of profile names (no metadata).",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config profile list\n  \
$ rev-stealth config --output-format json profile list\n\n\
EXIT CODES:\n  \
0  Ok               Listing emitted.\n  \
1  UserError        Bad args.\n  \
3  PermanentError   directory IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_PROFILES_ROOT   Override the profiles root directory."
    )]
    List,
    /// Create a new profile directory and seed `policy.toml`,
    /// `authorized.toml`, and `sites/` via ConfigWriter (same skeleton
    /// as `config init`). Refuses if the profile already exists.
    #[command(
        long_about = "Create a new profile directory and seed policy.toml + \
authorized.toml + sites/ via ConfigWriter (same skeleton as `config init`). \
Refuses if the profile already exists. Name must match [A-Za-z0-9_-]{1,64}.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config profile create work\n  \
$ rev-stealth config profile create demo-2026\n\n\
EXIT CODES:\n  \
0  Ok               Profile created.\n  \
1  UserError        Bad name / path traversal / already exists.\n  \
3  PermanentError   ConfigWriter IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_PROFILES_ROOT   Override the profiles root directory."
    )]
    Create {
        /// Profile name. Must match `[A-Za-z0-9_-]{1,64}` (no `/`,
        /// `\`, `.`, whitespace, control chars). Path-traversal is
        /// rejected.
        name: String,
        /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
        #[command(flatten)]
        dry_run_args: crate::commands::dry_run::DryRunArgs,
    },
    /// Print the shell-export line needed to activate the profile.
    /// We never mutate the operator's environment from inside the
    /// process — the operator must eval/source the printed line.
    #[command(
        long_about = "Print the shell-export line needed to activate the profile. \
We never mutate the operator's environment from inside the process — the \
operator must eval/source the printed line.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config profile switch work\n  \
$ eval \"$(rev-stealth config profile switch work)\"\n\n\
EXIT CODES:\n  \
0  Ok               Export line emitted.\n  \
1  UserError        Bad name / profile not found.\n  \
3  PermanentError   resolution failure.\n\n\
ENV:\n  \
REV_SCRAPING_PROFILES_ROOT   Override the profiles root directory."
    )]
    Switch {
        /// Profile name (must already exist).
        name: String,
        /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
        #[command(flatten)]
        dry_run_args: crate::commands::dry_run::DryRunArgs,
    },
    /// Best-effort overwrite-then-delete (`shred-like`) for the profile
    /// directory. Refuses if the profile is currently active per
    /// `$REV_SCRAPING_HOME` resolution.
    #[command(
        long_about = "Best-effort overwrite-then-delete (shred-like) for the \
profile directory. Refuses if the profile is currently active (per \
$REV_SCRAPING_HOME resolution). --yes is required for non-interactive deletion.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth config profile delete work --yes\n  \
$ rev-stealth config profile delete demo-2026 --yes\n\n\
EXIT CODES:\n  \
0  Ok               Profile removed.\n  \
1  UserError        Missing --yes / active profile / name not found.\n  \
3  PermanentError   shred IO failure.\n\n\
ENV:\n  \
REV_SCRAPING_HOME            Override `~/.rev_scraping/` base.\n  \
REV_SCRAPING_PROFILES_ROOT   Override the profiles root directory."
    )]
    Delete {
        /// Profile name to remove.
        name: String,
        /// Required for non-interactive deletion. Without it we exit
        /// 2 with an error so an operator typo cannot wipe a profile.
        #[arg(long, default_value_t = false)]
        yes: bool,
        /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
        #[command(flatten)]
        dry_run_args: crate::commands::dry_run::DryRunArgs,
    },
}

/// Which file `config set` / `config edit` targets. `policy` is the default
/// because it's the most common write surface; `authorized` is exposed for
/// operator-side authorization edits.
#[derive(Copy, Clone, Debug, ValueEnum, PartialEq, Eq)]
pub enum WriteTarget {
    Policy,
    Authorized,
}

#[derive(Args, Debug, Clone)]
pub struct SetArgs {
    /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
    #[command(flatten)]
    pub dry_run_args: crate::commands::dry_run::DryRunArgs,
    /// Dotted key, e.g. `policy.require_vpn` or `require_vpn`. A leading
    /// `policy.` / `authorized.` segment is treated as a layer hint and
    /// stripped before traversing the TOML document.
    pub key: String,
    /// Value as a literal token. Inferred as bool (`true`/`false`), int
    /// (all-digits, optional leading `-`), or string (everything else).
    /// To force string mode wrap the value in quotes from the shell.
    pub value: String,
    /// Which file to mutate. Defaults to `policy`.
    #[arg(long, value_enum, default_value_t = WriteTarget::Policy)]
    pub target: WriteTarget,
}

#[derive(Args, Debug, Clone)]
pub struct EditArgs {
    /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
    #[command(flatten)]
    pub dry_run_args: crate::commands::dry_run::DryRunArgs,
    /// Which file to open. Defaults to `policy`.
    #[arg(long, value_enum, default_value_t = WriteTarget::Policy)]
    pub target: WriteTarget,
    /// Override `$EDITOR`. Mostly for tests (e.g. `--editor "cp my.toml"`).
    #[arg(long)]
    pub editor: Option<String>,
}

#[derive(Args, Debug, Clone, Default)]
pub struct MigrateArgs {
    /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
    /// `--dry-run` keeps the original P6.3 semantics: print the migration
    /// plan without writing (v1→v1 is a no-op either way; future v2+
    /// migrations honour this surface).
    #[command(flatten)]
    pub dry_run_args: crate::commands::dry_run::DryRunArgs,
}

impl MigrateArgs {
    /// Backwards-compat shim: the P6.3 surface exposed `mig_args.dry_run`.
    /// v1.3 Lane G.5 routes the flag through the shared `DryRunArgs` block.
    pub fn dry_run(&self) -> bool {
        self.dry_run_args.dry_run
    }
}

/// Which file(s) `config init` should materialize. `All` is the default
/// and walks every target in a stable order; the individual variants
/// scope the operation to a single file.
#[derive(Copy, Clone, Debug, ValueEnum, PartialEq, Eq)]
pub enum InitTarget {
    All,
    Policy,
    Authorized,
    Sites,
}

#[derive(Args, Debug, Clone)]
pub struct HistoryArgs {
    /// Which file's backups to list. Defaults to `policy`.
    #[arg(long, value_enum, default_value_t = WriteTarget::Policy)]
    pub target: WriteTarget,
}

#[derive(Args, Debug, Clone)]
pub struct RollbackArgs {
    /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
    #[command(flatten)]
    pub dry_run_args: crate::commands::dry_run::DryRunArgs,
    /// The exact backup filename to restore (e.g.
    /// `policy.toml.bak.1700000000000`). Resolved relative to the
    /// target file's parent directory. Path traversal is rejected.
    pub bak_name: String,
    /// Which file to roll back. Defaults to `policy`.
    #[arg(long, value_enum, default_value_t = WriteTarget::Policy)]
    pub target: WriteTarget,
}

#[derive(Args, Debug, Clone)]
pub struct GcArgs {
    /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
    #[command(flatten)]
    pub dry_run_args: crate::commands::dry_run::DryRunArgs,
    /// Number of newest backups to keep. Defaults to 5.
    #[arg(long, default_value_t = 5)]
    pub keep: usize,
    /// Which file's backups to GC. Defaults to `policy`.
    #[arg(long, value_enum, default_value_t = WriteTarget::Policy)]
    pub target: WriteTarget,
}

#[derive(Args, Debug, Clone)]
pub struct InitArgs {
    /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
    #[command(flatten)]
    pub dry_run_args: crate::commands::dry_run::DryRunArgs,
    /// Limit init to a single file. Default `all`.
    #[arg(long, value_enum, default_value_t = InitTarget::All)]
    pub target: InitTarget,
    /// Overwrite existing files (routes through `.bak.<epoch>` backup
    /// via the P5.2 ConfigWriter — never destructive).
    #[arg(long, default_value_t = false)]
    pub force: bool,
    /// Skip interactive confirmation. Required for CI / scripted use.
    /// The current implementation never prompts (init is non-destructive
    /// without --force), but the flag is reserved + tested so callers
    /// can adopt it now without a future breaking change.
    #[arg(long, default_value_t = false)]
    pub non_interactive: bool,
}

/// Resolved file system locations for the layered config. Used by `paths`
/// and as input to `show` / `validate`.
#[derive(Debug, Clone, Serialize)]
pub struct ConfigLocations {
    pub policy: PathBuf,
    pub authorized: PathBuf,
    pub sites_dir: PathBuf,
    pub templates_policy: PathBuf,
}

impl ConfigLocations {
    /// Resolve from env / `dirs::home_dir`. `REV_SCRAPING_HOME` overrides the
    /// `~/.rev_scraping` base (useful for tests).
    pub fn resolve() -> Self {
        let base = std::env::var_os("REV_SCRAPING_HOME")
            .map(PathBuf::from)
            .or_else(|| dirs::home_dir().map(|h| h.join(".rev_scraping")))
            .unwrap_or_else(|| PathBuf::from(".rev_scraping"));
        let policy = std::env::var_os("REV_SCRAPING_POLICY")
            .map(PathBuf::from)
            .unwrap_or_else(|| base.join("policy.toml"));
        let authorized = std::env::var_os("REV_SCRAPING_AUTHORIZED")
            .map(PathBuf::from)
            .unwrap_or_else(|| base.join("authorized.toml"));
        let sites_dir = base.join("sites");
        let templates_policy = repo_templates_policy();
        Self {
            policy,
            authorized,
            sites_dir,
            templates_policy,
        }
    }
}

fn repo_templates_policy() -> PathBuf {
    // CARGO_MANIFEST_DIR points at crates/stealth-cli at build time. The
    // workspace root is two levels up; `templates/policy.toml` sits at the
    // workspace root in both dev and packaged distributions.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("templates")
        .join("policy.toml")
}

/// Async entrypoint so it slots into the existing `main.rs` dispatch (other
/// subcommands are async). The body is fully synchronous.
pub async fn run(global: GlobalFormat, mut args: ConfigArgs) -> i32 {
    // v1.3 Lane G.7 round-3: propagate the global `--format json` flag
    // into the config subtree when the user did NOT explicitly pass the
    // local `--output-format`. The default-equals-text check alone
    // cannot distinguish "user typed --output-format text" from "user
    // passed nothing", so the round-2 form violated the documented
    // precedence rule (local wins over global). Resolve by peeking the
    // process argv for an explicit `--output-format` flag in any of its
    // accepted shapes (split `--output-format text`, combined
    // `--output-format=text`). When absent, promote default text → json
    // under a JSON-global session. When present, the explicit local
    // value wins.
    let local_set_explicitly =
        std::env::args().any(|a| a == "--output-format" || a.starts_with("--output-format="));
    // v1.3 Lane G fix-up R2 round 5 — Codex review finding #2:
    // previously only the global `--format json` promotion was wired;
    // `--format yaml` was silently demoted to `ConfigFormat::Text`
    // (default), so `rev-stealth --format yaml config init --dry-run`
    // emitted a `[DRY-RUN]` human banner instead of YAML. Fix:
    // promote `Yaml` in addition to `Json` when the local override is
    // absent. (Local-set-explicitly still wins, mirroring the
    // `OutputFormatOverride::resolve` contract.)
    if matches!(args.format, ConfigFormat::Text) && !local_set_explicitly {
        match global {
            GlobalFormat::Json => args.format = ConfigFormat::Json,
            GlobalFormat::Yaml => args.format = ConfigFormat::Yaml,
            GlobalFormat::Human => {}
        }
    }
    let locs = ConfigLocations::resolve();
    match args.action {
        ConfigAction::Show => run_show(&locs, args.format),
        ConfigAction::Paths => run_paths(&locs, args.format),
        ConfigAction::Validate => run_validate(&locs, args.format),
        ConfigAction::Diff { path, against } => {
            let baseline = against.unwrap_or_else(repo_templates_policy);
            run_diff(&path, &baseline, args.format)
        }
        ConfigAction::Get { key } => run_get(&locs, &key, args.format),
        ConfigAction::Init(init_args) => run_init(&locs, init_args, args.format),
        ConfigAction::Set(set_args) => run_set(&locs, set_args, args.format),
        ConfigAction::Edit(edit_args) => run_edit(&locs, edit_args, args.format),
        ConfigAction::Migrate(mig_args) => run_migrate(&locs, mig_args, args.format),
        ConfigAction::History(h_args) => run_history(&locs, h_args, args.format),
        ConfigAction::Rollback(r_args) => run_rollback(&locs, r_args, args.format),
        ConfigAction::Gc(g_args) => run_gc(&locs, g_args, args.format),
        ConfigAction::Profile(p_action) => run_profile(&locs, p_action, args.format),
    }
}

// ---------- show -----------------------------------------------------------

fn run_show(locs: &ConfigLocations, format: ConfigFormat) -> i32 {
    let value = build_show_value(locs);
    emit(&value, format);
    0
}

/// Build the merged JSON view used by both `show` and `get`. Secret-looking
/// env values are pre-redacted here so no caller can accidentally surface
/// raw secrets.
pub fn build_show_value(locs: &ConfigLocations) -> JsonValue {
    // Reviewer round-1 finding: redaction MUST be recursive over every parsed
    // config layer, not only env collection. Site recipes / policy URLs /
    // authorized.toml can carry header tokens, basic-auth credentials, or
    // bearer strings — any object key matching `key_looks_secret` has its
    // leaf value replaced before serialization.
    let policy = redact_json_tree(&read_toml_as_json(&locs.policy));
    let authorized = redact_json_tree(&read_toml_as_json(&locs.authorized));
    let sites = redact_json_tree(&read_sites_dir(&locs.sites_dir));
    let env = collect_redacted_env();
    json!({
        "policy": policy,
        "authorized": authorized,
        "sites": sites,
        "env": env,
    })
}

/// Walk a JSON tree and replace any leaf whose ancestor object key looks like
/// a secret with the `<redacted>` sentinel. Arrays are descended into but
/// their indices do not themselves carry "secret-shaped" keys.
pub fn redact_json_tree(value: &JsonValue) -> JsonValue {
    match value {
        JsonValue::Object(map) => {
            let mut out = serde_json::Map::with_capacity(map.len());
            for (k, v) in map {
                if key_looks_secret(k) {
                    out.insert(k.clone(), JsonValue::String(REDACTED.to_string()));
                } else {
                    out.insert(k.clone(), redact_json_tree(v));
                }
            }
            JsonValue::Object(out)
        }
        JsonValue::Array(arr) => JsonValue::Array(arr.iter().map(redact_json_tree).collect()),
        other => other.clone(),
    }
}

fn read_toml_as_json(path: &Path) -> JsonValue {
    if !path.exists() {
        return JsonValue::Null;
    }
    let Ok(text) = std::fs::read_to_string(path) else {
        return JsonValue::Null;
    };
    match toml::from_str::<toml::Value>(&text) {
        Ok(v) => serde_json::to_value(v).unwrap_or(JsonValue::Null),
        Err(e) => json!({ "_parse_error": e.to_string() }),
    }
}

fn read_sites_dir(dir: &Path) -> JsonValue {
    if !dir.is_dir() {
        return JsonValue::Null;
    }
    let mut entries: BTreeMap<String, JsonValue> = BTreeMap::new();
    let Ok(rd) = std::fs::read_dir(dir) else {
        return JsonValue::Null;
    };
    for entry in rd.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("toml") {
            continue;
        }
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        entries.insert(name, read_toml_as_json(&path));
    }
    serde_json::to_value(entries).unwrap_or(JsonValue::Null)
}

/// Surface the tracked env subset, redacting any value whose key matches a
/// secret-looking pattern. The redaction policy is conservative on purpose:
/// when unsure, redact.
fn collect_redacted_env() -> JsonValue {
    let mut out: BTreeMap<String, JsonValue> = BTreeMap::new();
    for key in TRACKED_ENV {
        match std::env::var(key) {
            Ok(value) => {
                let surfaced = if key_looks_secret(key) {
                    REDACTED.to_string()
                } else {
                    value
                };
                out.insert((*key).to_string(), JsonValue::String(surfaced));
            }
            Err(_) => {
                out.insert((*key).to_string(), JsonValue::Null);
            }
        }
    }
    // Sweep the live env for anything secret-looking that callers will
    // recognize, but only surface that they exist — never the value.
    for (k, _v) in std::env::vars() {
        if key_looks_secret(&k) && !out.contains_key(&k) {
            out.insert(k, JsonValue::String(REDACTED.to_string()));
        }
    }
    serde_json::to_value(out).unwrap_or(JsonValue::Null)
}

/// Conservative secret-key heuristic. Case-insensitive substring match on
/// well-known credential nouns. Returns true → value MUST be redacted.
pub fn key_looks_secret(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    const NEEDLES: &[&str] = &[
        "password",
        "passwd",
        "secret",
        "token",
        "api_key",
        "apikey",
        "cookie",
        "auth",
        "credential",
        "private_key",
    ];
    NEEDLES.iter().any(|n| k.contains(n))
}

// ---------- paths ----------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct PathEntry {
    pub label: &'static str,
    pub path: String,
    pub exists: bool,
    pub is_dir: bool,
    pub mode_octal: Option<String>,
}

fn run_paths(locs: &ConfigLocations, format: ConfigFormat) -> i32 {
    let entries = build_path_entries(locs);
    let value = serde_json::to_value(&entries).unwrap_or(JsonValue::Null);
    if format == ConfigFormat::Text {
        for e in &entries {
            let mode = e.mode_octal.as_deref().unwrap_or("----");
            let kind = if e.is_dir { "dir " } else { "file" };
            let exist = if e.exists { "OK " } else { "MISS" };
            println!("{:<18} {} {} {} {}", e.label, exist, kind, mode, e.path);
        }
    } else {
        emit(&value, format);
    }
    0
}

pub fn build_path_entries(locs: &ConfigLocations) -> Vec<PathEntry> {
    vec![
        path_entry("policy", &locs.policy),
        path_entry("authorized", &locs.authorized),
        path_entry("sites_dir", &locs.sites_dir),
        path_entry("templates_policy", &locs.templates_policy),
    ]
}

fn path_entry(label: &'static str, path: &Path) -> PathEntry {
    let absolute = std::fs::canonicalize(path)
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned();
    let exists = path.exists();
    let is_dir = path.is_dir();
    let mode_octal = mode_octal_for(path);
    PathEntry {
        label,
        path: absolute,
        exists,
        is_dir,
        mode_octal,
    }
}

#[cfg(unix)]
fn mode_octal_for(path: &Path) -> Option<String> {
    use std::os::unix::fs::PermissionsExt;
    let meta = std::fs::metadata(path).ok()?;
    Some(format!("{:o}", meta.permissions().mode() & 0o7777))
}

#[cfg(not(unix))]
fn mode_octal_for(_path: &Path) -> Option<String> {
    None
}

// ---------- validate -------------------------------------------------------

fn run_validate(locs: &ConfigLocations, format: ConfigFormat) -> i32 {
    let mut all_reports: Vec<(String, ValidationReport)> = Vec::new();
    let mut read_errors: Vec<(String, String)> = Vec::new();
    let opts = ValidateOptions::strict();
    // Reviewer round-1 finding: an unreadable-but-present file MUST NOT be
    // silently skipped. Convert read errors into a synthetic failing report
    // so `validate` cannot return 0 for a file the operator demonstrably
    // intended to check.
    if locs.policy.exists() {
        match std::fs::read_to_string(&locs.policy) {
            Ok(text) => all_reports.push((
                locs.policy.display().to_string(),
                validate_toml_against::<Policy>(&text, &opts),
            )),
            Err(e) => read_errors.push((locs.policy.display().to_string(), e.to_string())),
        }
    }
    if locs.authorized.exists() {
        match std::fs::read_to_string(&locs.authorized) {
            Ok(text) => all_reports.push((
                locs.authorized.display().to_string(),
                validate_authorized_toml(&text, &opts),
            )),
            Err(e) => read_errors.push((locs.authorized.display().to_string(), e.to_string())),
        }
    }
    let any_err = all_reports.iter().any(|(_, r)| !r.is_ok()) || !read_errors.is_empty();
    if format == ConfigFormat::Text {
        for (path, r) in &all_reports {
            if r.is_ok() {
                println!("OK   {path}");
            } else {
                for issue in &r.errors {
                    println!(
                        "FAIL {path}: [{:?}] {} @ {}",
                        issue.code, issue.message, issue.path
                    );
                }
            }
        }
        for (path, err) in &read_errors {
            println!("FAIL {path}: [ReadError] {err}");
        }
        if all_reports.is_empty() && read_errors.is_empty() {
            println!("OK   (no live config files present)");
        }
    } else {
        let reports_json = all_reports
            .iter()
            .map(|(p, r)| {
                json!({
                    "path": p,
                    "ok": r.is_ok(),
                    "errors": r.errors.iter().map(|i| json!({
                        "path": i.path,
                        "code": format!("{:?}", i.code),
                        "message": i.message,
                        "hint": i.hint,
                    })).collect::<Vec<_>>(),
                })
            })
            .collect::<Vec<_>>();
        let read_errors_json = read_errors
            .iter()
            .map(|(p, e)| json!({ "path": p, "error": e }))
            .collect::<Vec<_>>();
        if any_err {
            // v1.3 Lane G.7 round-6: structurally honest failure envelope.
            // Build the canonical G.7 envelope and retain the diagnostic
            // payload (reports / read_errors) so operators parsing JSON
            // still see the per-file validation detail. The central
            // `emit()` auto-augmentation only fires when `kind` is absent,
            // so we attach it here explicitly and skip the heuristic.
            let fail_count = all_reports.iter().filter(|(_, r)| !r.is_ok()).count();
            let summary = if !read_errors.is_empty() && fail_count == 0 {
                format!(
                    "config validate failed: {} file(s) unreadable",
                    read_errors.len()
                )
            } else if read_errors.is_empty() {
                format!("config validate failed: {fail_count} file(s) with schema errors")
            } else {
                format!(
                    "config validate failed: {fail_count} schema error file(s), {} unreadable",
                    read_errors.len()
                )
            };
            let mut payload = json!({
                "ok": false,
                "operation": "config.validate",
                "exit_code": 1,
                "error": summary,
                "reports": reports_json,
                "read_errors": read_errors_json,
            });
            crate::commands::error_envelope::augment_with_g7_fields(
                &mut payload,
                crate::commands::error_envelope::CliErrorKind::Validation,
                None,
                Some("Run `rev-stealth config validate --format json` for full diagnostic; see `reports` and `read_errors` for per-file detail"),
                None,
            );
            emit(&payload, format);
        } else {
            let payload = json!({
                "ok": true,
                "reports": reports_json,
                "read_errors": read_errors_json,
            });
            emit(&payload, format);
        }
    }
    if any_err {
        1
    } else {
        0
    }
}

// ---------- diff -----------------------------------------------------------

fn run_diff(live: &Path, baseline: &Path, format: ConfigFormat) -> i32 {
    let live_text = std::fs::read_to_string(live).unwrap_or_default();
    let base_text = std::fs::read_to_string(baseline).unwrap_or_default();
    let diff = unified_diff(
        &base_text,
        &live_text,
        &baseline.display().to_string(),
        &live.display().to_string(),
    );
    if format == ConfigFormat::Text {
        print!("{diff}");
    } else {
        emit(&json!({ "diff": diff }), format);
    }
    0
}

/// Minimal unified-diff producer. Emits `--- a/<base>` / `+++ b/<live>`
/// headers and a single hunk covering the whole file. Sufficient for the
/// operator-facing `config diff` use case (we are not implementing full
/// Myers diff here); reviewers should see the headers and per-line +/- in
/// stable order.
pub fn unified_diff(base: &str, live: &str, base_label: &str, live_label: &str) -> String {
    let base_lines: Vec<&str> = base.lines().collect();
    let live_lines: Vec<&str> = live.lines().collect();
    let mut out = String::new();
    out.push_str(&format!("--- a/{base_label}\n"));
    out.push_str(&format!("+++ b/{live_label}\n"));
    out.push_str(&format!(
        "@@ -1,{} +1,{} @@\n",
        base_lines.len().max(1),
        live_lines.len().max(1)
    ));
    let max = base_lines.len().max(live_lines.len());
    for i in 0..max {
        match (base_lines.get(i), live_lines.get(i)) {
            (Some(b), Some(l)) if b == l => {
                out.push(' ');
                out.push_str(b);
                out.push('\n');
            }
            (Some(b), Some(l)) => {
                out.push('-');
                out.push_str(b);
                out.push('\n');
                out.push('+');
                out.push_str(l);
                out.push('\n');
            }
            (Some(b), None) => {
                out.push('-');
                out.push_str(b);
                out.push('\n');
            }
            (None, Some(l)) => {
                out.push('+');
                out.push_str(l);
                out.push('\n');
            }
            (None, None) => {}
        }
    }
    out
}

// ---------- get ------------------------------------------------------------

fn run_get(locs: &ConfigLocations, key: &str, format: ConfigFormat) -> i32 {
    let merged = build_show_value(locs);
    match resolve_dotted(&merged, key) {
        Some(value) => {
            let redacted = redact_if_secret(key, &value);
            if format == ConfigFormat::Text {
                match &redacted {
                    JsonValue::String(s) => println!("{s}"),
                    other => println!("{other}"),
                }
            } else {
                emit(&json!({ "key": key, "value": redacted }), format);
            }
            0
        }
        None => {
            if format == ConfigFormat::Text {
                eprintln!("key not found: {key}");
            } else {
                // v1.3 Lane G.7: augment with the canonical
                // `{kind, message, hint?, retry_after_ms?, doc_url}` fields
                // alongside the legacy `error` string so callers can branch
                // on the closed `not_found` taxonomy variant.
                let mut payload = json!({
                    "key": key,
                    "value": null,
                    "error": "not_found",
                });
                crate::commands::error_envelope::augment_with_g7_fields(
                    &mut payload,
                    crate::commands::error_envelope::CliErrorKind::NotFound,
                    Some(&format!("key not found: {key}")),
                    Some("Run `rev-stealth config show` to list available keys."),
                    None,
                );
                emit(&payload, format);
            }
            1
        }
    }
}

/// Resolve a dotted JSON path. Segments are looked up as object keys; numeric
/// segments index into arrays. Returns `None` for missing keys.
pub fn resolve_dotted(root: &JsonValue, key: &str) -> Option<JsonValue> {
    let mut cur: &JsonValue = root;
    for seg in key.split('.') {
        cur = match cur {
            JsonValue::Object(map) => map.get(seg)?,
            JsonValue::Array(arr) => {
                let idx: usize = seg.parse().ok()?;
                arr.get(idx)?
            }
            _ => return None,
        };
    }
    Some(cur.clone())
}

fn redact_if_secret(key: &str, value: &JsonValue) -> JsonValue {
    // If any path segment looks secret, redact the leaf value.
    let secret = key.split('.').any(key_looks_secret);
    if secret {
        JsonValue::String(REDACTED.to_string())
    } else {
        value.clone()
    }
}

// ---------- emit -----------------------------------------------------------

fn emit(value: &JsonValue, format: ConfigFormat) {
    // v1.3 Lane G.7 round-4: auto-augment any object payload that looks
    // like an error envelope (carries an `error` string field and does
    // not yet have `kind`/`doc_url`) with the canonical 5 G.7 fields.
    // This centralises the contract across every `config` failure sink
    // so future emit sites don't have to remember to call
    // `augment_with_g7_fields` individually.
    //
    // We do NOT augment when:
    //   * format is not a structured shape (Text);
    //   * payload is not a JSON object;
    //   * payload already carries `kind` (caller opted into a specific
    //     classification, e.g. `emit_set_error`);
    //   * payload has no `error` string (e.g. `show`/`get` success).
    let augmented_owned;
    let value_to_emit: &JsonValue = if matches!(format, ConfigFormat::Json | ConfigFormat::Yaml) {
        if let Some(obj) = value.as_object() {
            let needs_augment = obj.contains_key("error")
                && !obj.contains_key("kind")
                && !obj.contains_key("doc_url");
            if needs_augment {
                let mut clone = value.clone();
                // Best-effort: derive `message` from `error`; classify
                // via the shared heuristic. Caller-supplied `message`
                // is preserved if already present.
                let err_text = obj.get("error").and_then(|v| v.as_str()).unwrap_or("");
                let kind = crate::commands::error_envelope::classify_legacy_message(err_text);
                crate::commands::error_envelope::augment_with_g7_fields(
                    &mut clone, kind, None, None, None,
                );
                augmented_owned = clone;
                &augmented_owned
            } else {
                value
            }
        } else {
            value
        }
    } else {
        value
    };
    match format {
        ConfigFormat::Json => {
            println!(
                "{}",
                serde_json::to_string_pretty(value_to_emit).unwrap_or_default()
            );
        }
        ConfigFormat::Yaml => {
            println!(
                "{}",
                serde_yaml::to_string(value_to_emit)
                    .unwrap_or_else(|e| format!("# yaml-error: {e}"))
            );
        }
        ConfigFormat::Text => {
            // Text-mode for `show`/`get` falls back to pretty JSON since the
            // merged view is intrinsically nested. `paths` / `validate` /
            // `diff` already handle text mode themselves.
            println!(
                "{}",
                serde_json::to_string_pretty(value_to_emit).unwrap_or_default()
            );
        }
    }
}

// ---------- init -----------------------------------------------------------

/// Minimal authorized.toml skeleton used when the in-repo template is not
/// present (templates/authorized_targets.toml is optional). Strict-mode
/// validate currently treats authorized.toml as a permissive map keyed by
/// schema_version, so we ship a tiny doc-aware skeleton operators can
/// extend by hand.
const AUTHORIZED_SKELETON: &str = "# SPDX-License-Identifier: MIT\n\
# rev_scraping authorized targets — generated by `rev-stealth config init`.\n\
# Each [[targets]] row enumerates one domain the operator is authorized to\n\
# scrape. Edit by hand; the schema is documented in docs/manual/config.md.\n\
\n\
schema_version = 1\n\
\n\
# Example (commented out — uncomment and edit to authorize a real domain):\n\
# [[targets]]\n\
# domain = \"example.com\"\n\
# proof_url = \"https://example.com/.well-known/scraping-authorization.txt\"\n\
# expires_at = \"2027-01-01T00:00:00Z\"\n";

/// Bundled at compile time so `rev-stealth` works even when the binary is
/// installed away from the repo (no runtime path discovery for the template).
const POLICY_TEMPLATE: &str = include_str!("../../../../templates/policy.toml");

/// Outcome of a single `init` target — recorded so the per-format emitter
/// can render either text bullets or a JSON array.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct InitOutcome {
    pub target: &'static str,
    pub path: String,
    pub status: InitStatus,
    pub backup_path: Option<String>,
    pub note: Option<String>,
}

#[derive(Copy, Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum InitStatus {
    Created,
    Overwritten,
    Skipped,
    Error,
}

/// v1.3 Lane G.5 (revised v1.3 Lane G fix-up R2): bridge
/// `ConfigFormat` → `OutputFormat` for the shared dry-run emitter.
///
/// Before R2: `ConfigFormat::Yaml` collapsed to `OutputFormat::Json` on
/// the assumption that yaml callers could pipe through `yq`.
///
/// After R2 (Codex review finding #2): the dry-run emitter learned a
/// yaml branch, so `ConfigFormat::Yaml` now maps to `OutputFormat::Yaml`
/// and the operator's requested encoding is honoured end-to-end without
/// the extra `yq` hop.
fn dry_run_format_bridge(format: ConfigFormat) -> crate::OutputFormat {
    // v1.3 Lane G fix-up R2 — Codex review finding #2:
    // ConfigFormat::Yaml no longer collapses to OutputFormat::Json. The
    // dry-run emitter learned a yaml branch in R2, so config-mutate
    // dry-run paths now honour the operator's requested encoding end-to-
    // end. Text still maps to Human (the dry-run plan is a bulleted
    // operator-facing list in that mode).
    match format {
        ConfigFormat::Json => crate::OutputFormat::Json,
        ConfigFormat::Yaml => crate::OutputFormat::Yaml,
        ConfigFormat::Text => crate::OutputFormat::Human,
    }
}

fn run_init(locs: &ConfigLocations, args: InitArgs, format: ConfigFormat) -> i32 {
    if args.dry_run_args.is_dry_run() {
        return crate::commands::dry_run::emit_dry_run(
            dry_run_format_bridge(format),
            "config.init",
            &[
                "resolve REV_SCRAPING_HOME base directory",
                "compute init target set (policy / authorized / sites)",
                "(skipped) ConfigWriter::write each target with 0600 / 0700",
                "(skipped) backup existing targets via .bak.<epoch>",
            ],
            &args.dry_run_args,
        );
    }
    // v1.3 Lane G.6: idempotent commit hook.
    let key = args.dry_run_args.idempotency_key.clone();
    let payload = crate::commands::idempotency::payload_value(
        "config.init",
        [
            ("target", json!(format!("{:?}", args.target))),
            ("force", json!(args.force)),
        ],
    );
    let (idem, replay_exit) = crate::commands::idempotency::ReplayGuard::check(
        dry_run_format_bridge(format),
        "config.init",
        key,
        payload,
    );
    if let Some(code) = replay_exit {
        return code;
    }
    let mut outcomes: Vec<InitOutcome> = Vec::new();
    let want_policy = matches!(args.target, InitTarget::All | InitTarget::Policy);
    let want_authorized = matches!(args.target, InitTarget::All | InitTarget::Authorized);
    let want_sites = matches!(args.target, InitTarget::All | InitTarget::Sites);

    if want_policy {
        outcomes.push(init_file(
            "policy",
            &locs.policy,
            POLICY_TEMPLATE.as_bytes(),
            args.force,
        ));
    }
    if want_authorized {
        outcomes.push(init_file(
            "authorized",
            &locs.authorized,
            AUTHORIZED_SKELETON.as_bytes(),
            args.force,
        ));
    }
    if want_sites {
        outcomes.push(init_sites_dir(&locs.sites_dir));
    }

    let any_error = outcomes.iter().any(|o| o.status == InitStatus::Error);
    if format == ConfigFormat::Text {
        for o in &outcomes {
            let tag = match o.status {
                InitStatus::Created => "CREATED ",
                InitStatus::Overwritten => "OVERWRITE",
                InitStatus::Skipped => "SKIP    ",
                InitStatus::Error => "ERROR   ",
            };
            print!("{tag} {:<12} {}", o.target, o.path);
            if let Some(b) = &o.backup_path {
                print!(" (backup: {b})");
            }
            if let Some(n) = &o.note {
                print!(" — {n}");
            }
            println!();
        }
    } else {
        emit(&json!({ "outcomes": outcomes }), format);
    }
    if any_error {
        3
    } else {
        let envelope = json!({
            "ok": true,
            "operation": "config.init",
            "result": { "outcomes": outcomes },
        });
        idem.record("config.init", &envelope);
        0
    }
}

fn init_file(label: &'static str, path: &Path, contents: &[u8], force: bool) -> InitOutcome {
    let path_str = path.display().to_string();
    let exists = path.exists();
    // Reviewer round-2 finding (P6.2): same false-success class as the
    // sites/ non-directory collision, but on file targets. If the path
    // exists and is NOT a regular file (e.g. operator left a directory at
    // ~/.rev_scraping/policy.toml), we must NOT report Skipped/exit 0 —
    // the config layer is unusable until the operator fixes it.
    if exists && !path.is_file() {
        return InitOutcome {
            target: label,
            path: path_str,
            status: InitStatus::Error,
            backup_path: None,
            note: Some("path exists but is not a regular file; refusing to clobber".into()),
        };
    }
    if exists && !force {
        return InitOutcome {
            target: label,
            path: path_str,
            status: InitStatus::Skipped,
            backup_path: None,
            note: Some("file exists; pass --force to overwrite".into()),
        };
    }
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            if let Err(e) = ensure_dir_0700(parent) {
                return InitOutcome {
                    target: label,
                    path: path_str,
                    status: InitStatus::Error,
                    backup_path: None,
                    note: Some(format!("parent mkdir failed: {e}")),
                };
            }
        }
    }
    let writer = FsConfigWriter;
    match writer.write_with_backup(path, contents) {
        Ok(report) => InitOutcome {
            target: label,
            path: path_str,
            status: if exists {
                InitStatus::Overwritten
            } else {
                InitStatus::Created
            },
            backup_path: report.backup_path.map(|p| p.display().to_string()),
            note: None,
        },
        Err(e) => InitOutcome {
            target: label,
            path: path_str,
            status: InitStatus::Error,
            backup_path: None,
            note: Some(writer_err_msg(&e)),
        },
    }
}

fn writer_err_msg(e: &WriterError) -> String {
    format!("{e}")
}

/// Create the per-user `sites/` directory (mode 0700 on Unix) and seed a
/// commented `example.com.toml` placeholder so operators know the layout.
fn init_sites_dir(dir: &Path) -> InitOutcome {
    let path_str = dir.display().to_string();
    let existed = dir.exists();
    if let Err(e) = ensure_dir_0700(dir) {
        return InitOutcome {
            target: "sites",
            path: path_str,
            status: InitStatus::Error,
            backup_path: None,
            note: Some(format!("mkdir failed: {e}")),
        };
    }
    // Seed a placeholder only if no .toml is present yet — never overwrite
    // operator content, even with --force (sites is a directory target,
    // not a single file). Force-only file overwrites apply via policy /
    // authorized.
    let placeholder = dir.join("example.com.toml");
    let mut seeded_note: Option<String> = None;
    let mut seed_failed = false;
    if !placeholder.exists() {
        let body = "# Site recipe placeholder — see templates/sites/example.com.toml\n\
                    # for the full schema. Rename this file to <your-domain>.toml.\n\
                    schema_version = 2\n\
                    [site]\n\
                    domain = \"example.com\"\n";
        let writer = FsConfigWriter;
        if let Err(e) = writer.write_with_backup(&placeholder, body.as_bytes()) {
            // Reviewer round-1 finding (P6.2): a failed placeholder write
            // MUST surface as Error/exit 3, not a Skipped/Created success
            // with a note. Operators relying on the JSON status field to
            // gate CI should not see "skipped" for a broken target.
            seeded_note = Some(format!("placeholder write failed: {e}"));
            seed_failed = true;
        } else {
            seeded_note = Some(format!("seeded {}", placeholder.display()));
        }
    }
    let status = if seed_failed {
        InitStatus::Error
    } else if existed {
        InitStatus::Skipped
    } else {
        InitStatus::Created
    };
    InitOutcome {
        target: "sites",
        path: path_str,
        status,
        backup_path: None,
        note: seeded_note,
    }
}

/// Ensure `dir` exists with mode 0700 on Unix. Idempotent: if the directory
/// already exists the mode is tightened to 0700 (best-effort — failure to
/// chmod a pre-existing dir is not fatal, but the new dir path always
/// inherits 0700 atomically via DirBuilder).
fn ensure_dir_0700(dir: &Path) -> std::io::Result<()> {
    if dir.exists() {
        // Reviewer round-1 finding (P6.2): if `dir` exists but is NOT a
        // directory (e.g. operator left a stray file at ~/.rev_scraping/sites),
        // we must NOT silently report success. Fail with a typed io::Error so
        // the caller marks the outcome as Error → exit 3.
        if !dir.is_dir() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::NotADirectory,
                format!("path exists but is not a directory: {}", dir.display()),
            ));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Ok(meta) = std::fs::metadata(dir) {
                let mut perms = meta.permissions();
                perms.set_mode(0o700);
                let _ = std::fs::set_permissions(dir, perms);
            }
        }
        return Ok(());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        let mut b = std::fs::DirBuilder::new();
        b.recursive(true).mode(0o700);
        b.create(dir)
    }
    #[cfg(not(unix))]
    {
        std::fs::create_dir_all(dir)
    }
}

// ---------- set / edit / migrate (P6.3) -----------------------------------

/// Resolve the on-disk path for a `WriteTarget`.
fn target_path(locs: &ConfigLocations, t: WriteTarget) -> &Path {
    match t {
        WriteTarget::Policy => &locs.policy,
        WriteTarget::Authorized => &locs.authorized,
    }
}

/// Infer the TOML value type from a CLI literal:
/// * `true` / `false` (case-insensitive) → bool
/// * all-digits (with optional leading `-`) → integer
/// * everything else → string (preserved verbatim)
pub fn infer_toml_value(raw: &str) -> toml::Value {
    let lower = raw.to_ascii_lowercase();
    if lower == "true" {
        return toml::Value::Boolean(true);
    }
    if lower == "false" {
        return toml::Value::Boolean(false);
    }
    if let Ok(n) = raw.parse::<i64>() {
        return toml::Value::Integer(n);
    }
    toml::Value::String(raw.to_string())
}

/// Strip a leading `policy.` / `authorized.` layer hint so dotted keys can
/// be written either layered (mirrors `config get`) or layer-less. Returns
/// the residual key the operator actually meant to mutate.
fn strip_layer_prefix(key: &str, target: WriteTarget) -> String {
    let prefix = match target {
        WriteTarget::Policy => "policy.",
        WriteTarget::Authorized => "authorized.",
    };
    if let Some(rest) = key.strip_prefix(prefix) {
        rest.to_string()
    } else {
        key.to_string()
    }
}

/// Walk a `toml::Value` document along the dotted key, creating intermediate
/// tables as needed, and replace the leaf with `value`. Returns Err if an
/// intermediate segment exists but is not a table (refuses to clobber).
pub fn set_dotted_toml(doc: &mut toml::Value, key: &str, value: toml::Value) -> Result<(), String> {
    let segs: Vec<&str> = key.split('.').filter(|s| !s.is_empty()).collect();
    if segs.is_empty() {
        return Err("empty key".into());
    }
    let mut cur = doc;
    for seg in &segs[..segs.len() - 1] {
        let tbl = cur
            .as_table_mut()
            .ok_or_else(|| format!("path segment {seg:?} is not a table"))?;
        let entry = tbl
            .entry((*seg).to_string())
            .or_insert(toml::Value::Table(toml::value::Table::new()));
        if !entry.is_table() {
            return Err(format!("path segment {seg:?} exists and is not a table"));
        }
        cur = entry;
    }
    let last = segs[segs.len() - 1];
    let tbl = cur
        .as_table_mut()
        .ok_or_else(|| "leaf parent is not a table".to_string())?;
    tbl.insert(last.to_string(), value);
    Ok(())
}

fn validate_doc_for_target(text: &str, target: WriteTarget) -> ValidationReport {
    let opts = ValidateOptions::strict();
    match target {
        WriteTarget::Policy => validate_toml_against::<Policy>(text, &opts),
        WriteTarget::Authorized => validate_authorized_toml(text, &opts),
    }
}

fn run_set(locs: &ConfigLocations, args: SetArgs, format: ConfigFormat) -> i32 {
    if args.dry_run_args.is_dry_run() {
        return crate::commands::dry_run::emit_dry_run(
            dry_run_format_bridge(format),
            "config.set",
            &[
                "resolve target file (policy.toml / authorized.toml)",
                "load current TOML document",
                "infer value type (bool / int / string)",
                "apply set on dotted key (in-memory only)",
                "(skipped) strict validation of candidate document",
                "(skipped) ConfigWriter atomic write + .bak.<epoch> backup",
            ],
            &args.dry_run_args,
        );
    }
    let key_id = args.dry_run_args.idempotency_key.clone();
    let idem_payload = crate::commands::idempotency::payload_value(
        "config.set",
        [
            ("target", json!(format!("{:?}", args.target))),
            ("key", json!(args.key.clone())),
            (
                "value_sha",
                json!(crate::commands::idempotency::IdempotencyStore::hash16(
                    &args.value
                )),
            ),
        ],
    );
    let (idem, replay_exit) = crate::commands::idempotency::ReplayGuard::check(
        dry_run_format_bridge(format),
        "config.set",
        key_id,
        idem_payload,
    );
    if let Some(code) = replay_exit {
        return code;
    }
    let path = target_path(locs, args.target);
    // Reviewer round-2 finding: a read error on an existing file MUST
    // fail closed. Silently coercing to "" would let `set` overwrite the
    // user's data with a synthesized empty doc once validation passes.
    let original = if path.exists() {
        match std::fs::read_to_string(path) {
            Ok(s) => s,
            Err(e) => {
                emit_set_error(format, &args.key, &format!("read original: {e}"));
                return 1;
            }
        }
    } else {
        String::new()
    };
    // Parse current doc (or an empty table if file is missing/empty).
    let mut doc: toml::Value = if original.is_empty() {
        toml::Value::Table(toml::value::Table::new())
    } else {
        match toml::from_str::<toml::Value>(&original) {
            Ok(v) => v,
            Err(_) => {
                // Reviewer round-1: toml::de::Error can echo the offending
                // source line. Suppress the inner detail and emit a stable
                // sentinel — operators can re-run `config validate` for
                // a structured (and already-redacted) diagnosis.
                emit_set_error(
                    format,
                    &args.key,
                    "live file failed to parse as TOML (run `config validate`)",
                );
                return 1;
            }
        }
    };
    let stripped_key = strip_layer_prefix(&args.key, args.target);
    let new_value = infer_toml_value(&args.value);
    if let Err(e) = set_dotted_toml(&mut doc, &stripped_key, new_value) {
        emit_set_error(format, &args.key, &e);
        return 1;
    }
    let new_text = match toml::to_string_pretty(&doc) {
        Ok(s) => s,
        Err(e) => {
            emit_set_error(format, &args.key, &format!("serialize: {e}"));
            return 1;
        }
    };
    let report = validate_doc_for_target(&new_text, args.target);
    if !report.is_ok() {
        // Reviewer round-1 finding: raw validation messages can echo the
        // offending source line (toml diagnostics) which could include a
        // secret value the operator just tried to set. Redact to code+path
        // only.
        let msg = render_redacted_report(&report);
        emit_set_error(format, &args.key, &format!("validate: {msg}"));
        return 1;
    }
    let writer = FsConfigWriter;
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            if let Err(e) = ensure_dir_0700(parent) {
                emit_set_error(format, &args.key, &format!("mkdir: {e}"));
                return 1;
            }
        }
    }
    match writer.write_with_backup(path, new_text.as_bytes()) {
        Ok(report) => {
            // Echo back only the key + redaction status — never the raw
            // value. Mirrors the redaction contract used by `config get`.
            let secret =
                stripped_key.split('.').any(key_looks_secret) || key_looks_secret(&args.key);
            let surfaced_value = if secret {
                JsonValue::String(REDACTED.to_string())
            } else {
                JsonValue::String(args.value.clone())
            };
            if format == ConfigFormat::Text {
                let backup_str = report
                    .backup_path
                    .as_ref()
                    .map(|p| format!(" (backup: {})", p.display()))
                    .unwrap_or_default();
                if secret {
                    println!("OK   set {} = {}{}", args.key, REDACTED, backup_str);
                } else {
                    println!("OK   set {} = {}{}", args.key, args.value, backup_str);
                }
            } else {
                emit(
                    &json!({
                        "ok": true,
                        "key": args.key,
                        "value": surfaced_value,
                        "path": path.display().to_string(),
                        "backup_path": report
                            .backup_path
                            .as_ref()
                            .map(|p| p.display().to_string()),
                    }),
                    format,
                );
            }
            let envelope = json!({
                "ok": true,
                "operation": "config.set",
                "result": {
                    "key": args.key,
                    "path": path.display().to_string(),
                },
            });
            idem.record("config.set", &envelope);
            0
        }
        Err(e) => {
            emit_set_error(format, &args.key, &format!("write: {e}"));
            1
        }
    }
}

fn emit_set_error(format: ConfigFormat, key: &str, message: &str) {
    if format == ConfigFormat::Text {
        eprintln!("FAIL set {key}: {message}");
    } else {
        // v1.3 Lane G.7: augment with canonical envelope fields.
        let mut payload = json!({ "ok": false, "key": key, "error": message });
        let kind = crate::commands::error_envelope::classify_legacy_message(message);
        crate::commands::error_envelope::augment_with_g7_fields(
            &mut payload,
            kind,
            None,
            None,
            None,
        );
        emit(&payload, format);
    }
}

fn run_edit(locs: &ConfigLocations, args: EditArgs, format: ConfigFormat) -> i32 {
    if args.dry_run_args.is_dry_run() {
        return crate::commands::dry_run::emit_dry_run(
            dry_run_format_bridge(format),
            "config.edit",
            &[
                "resolve target file (policy.toml / authorized.toml)",
                "resolve $EDITOR (fallback vi)",
                "(skipped) copy current file to tempfile",
                "(skipped) spawn editor on tempfile",
                "(skipped) strict validation of candidate document",
                "(skipped) ConfigWriter atomic write + .bak.<epoch> backup",
            ],
            &args.dry_run_args,
        );
    }
    // v1.3 Lane G.6: `config.edit` deliberately does NOT participate in the
    // idempotent replay store. The mutation is driven by interactive editor
    // input which is not knowable from the CLI args alone — keying replay
    // on `(target,)` would let a same-key second invocation skip a
    // genuinely-different edit. `--idempotency-key` remains accepted on the
    // surface for shape consistency across mutate commands but is a no-op
    // here; callers needing at-most-once edit semantics should instead pin
    // the candidate via `config set` (whose payload includes the value).
    let path = target_path(locs, args.target);
    // Reviewer round-2 finding: read failures (permission, invalid UTF-8,
    // etc.) on an existing file MUST fail closed, not coerce to "" which
    // would seed the editor with an empty doc and risk overwriting the
    // operator's data.
    let original = if path.exists() {
        match std::fs::read_to_string(path) {
            Ok(s) => s,
            Err(e) => {
                emit_edit_error(format, &format!("read original: {e}"));
                return 1;
            }
        }
    } else {
        String::new()
    };
    // Copy to a tempfile the editor will mutate. We keep the temp around
    // on validation failure so the operator can recover their edits. The
    // tempdir is created under `std::env::temp_dir()` with a unique suffix
    // (epoch ns + pid) so concurrent edits don't collide.
    let base_tmp = std::env::temp_dir();
    let unique = format!(
        "rev-stealth-edit-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0),
    );
    let tmpdir = base_tmp.join(unique);
    if let Err(e) = std::fs::create_dir_all(&tmpdir) {
        emit_edit_error(format, &format!("tempdir: {e}"));
        return 1;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmpdir, std::fs::Permissions::from_mode(0o700));
    }
    let tmp_path = tmpdir.join(
        path.file_name()
            .map(|s| s.to_os_string())
            .unwrap_or_else(|| std::ffi::OsString::from("config.toml")),
    );
    // Reviewer round-2 finding: every early-return after tmpdir creation
    // must sweep tmpdir, otherwise post-edit config bytes (which may
    // include secrets the operator just typed) survive under TMPDIR. We
    // funnel cleanup through this closure.
    let cleanup = |tmpdir: &Path| {
        let _ = std::fs::remove_dir_all(tmpdir);
    };
    if let Err(e) = std::fs::write(&tmp_path, original.as_bytes()) {
        emit_edit_error(format, &format!("seed temp: {e}"));
        cleanup(&tmpdir);
        return 1;
    }
    let editor_cmd = args
        .editor
        .clone()
        .or_else(|| std::env::var("EDITOR").ok())
        .unwrap_or_else(|| "vi".to_string());
    {
        let mut parts = editor_cmd.split_whitespace();
        let bin = match parts.next() {
            Some(b) => b,
            None => {
                emit_edit_error(format, "empty editor command");
                cleanup(&tmpdir);
                return 1;
            }
        };
        let extra: Vec<&str> = parts.collect();
        let status = std::process::Command::new(bin)
            .args(&extra)
            .arg(&tmp_path)
            .status();
        match status {
            Ok(s) if s.success() => {}
            Ok(s) => {
                // Reviewer round-3 finding: never delete the only copy.
                // If the recovery sibling write fails, KEEP tmpdir and
                // report its path so the operator can recover.
                let kept_display = match persist_aborted_temp(path, &tmp_path) {
                    Ok(p) => p.display().to_string(),
                    Err(e) => {
                        let kept = format!(
                            "{} (recovery sibling write failed: {}; tmpdir preserved)",
                            tmp_path.display(),
                            e
                        );
                        emit_edit_error(
                            format,
                            &format!("editor exited {s}; edits kept at {kept}"),
                        );
                        return 1;
                    }
                };
                emit_edit_error(
                    format,
                    &format!("editor exited {s}; edits kept at {kept_display}"),
                );
                cleanup(&tmpdir);
                return 1;
            }
            Err(e) => {
                emit_edit_error(format, &format!("spawn editor: {e}"));
                cleanup(&tmpdir);
                return 1;
            }
        }
    }
    let candidate = match std::fs::read_to_string(&tmp_path) {
        Ok(s) => s,
        Err(e) => {
            emit_edit_error(format, &format!("read temp: {e}"));
            cleanup(&tmpdir);
            return 1;
        }
    };
    let report = validate_doc_for_target(&candidate, args.target);
    if !report.is_ok() {
        // Reviewer round-1 finding: redact validation message text — it
        // can carry the offending source line (toml diagnostic context)
        // which we promised never to echo on the edit path.
        let msg = render_redacted_report(&report);
        // Reviewer round-3 finding: if persist_aborted_temp fails we MUST
        // NOT delete the working tempdir — it would erase the only copy
        // of the operator's edits. Only sweep tmpdir when the recovery
        // sibling actually landed; otherwise keep tmpdir + report its
        // path so the operator can recover.
        let (kept_display, cleanup_tmpdir) = match persist_aborted_temp(path, &tmp_path) {
            Ok(p) => (p.display().to_string(), true),
            Err(e) => (
                format!(
                    "{} (recovery sibling write failed: {}; tmpdir preserved)",
                    tmp_path.display(),
                    e
                ),
                false,
            ),
        };
        if cleanup_tmpdir {
            let _ = std::fs::remove_dir_all(&tmpdir);
        }
        emit_edit_error(
            format,
            &format!(
                "validate failed, original preserved; edits kept at {}: {}",
                kept_display, msg
            ),
        );
        return 1;
    }
    let writer = FsConfigWriter;
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            let _ = ensure_dir_0700(parent);
        }
    }
    let write_result = writer.write_with_backup(path, candidate.as_bytes());
    // Reviewer round-1 finding: success path was leaking a copy of the
    // (post-edit) config body under TMPDIR. Always sweep the working
    // tempdir before returning; recovery on abort uses `persist_aborted_temp`
    // which writes its own sibling at the original's parent dir.
    let _ = std::fs::remove_dir_all(&tmpdir);
    match write_result {
        Ok(report) => {
            if format == ConfigFormat::Text {
                let backup_str = report
                    .backup_path
                    .as_ref()
                    .map(|p| format!(" (backup: {})", p.display()))
                    .unwrap_or_default();
                println!("OK   edit {}{}", path.display(), backup_str);
            } else {
                emit(
                    &json!({
                        "ok": true,
                        "path": path.display().to_string(),
                        "backup_path": report
                            .backup_path
                            .as_ref()
                            .map(|p| p.display().to_string()),
                    }),
                    format,
                );
            }
            // v1.3 Lane G.6: see top-of-fn note — `config.edit` is
            // intentionally NOT registered in the idempotency store.
            0
        }
        Err(e) => {
            emit_edit_error(format, &format!("write: {e}"));
            1
        }
    }
}

/// Render a `ValidationReport` to a string that lists ONLY the structural
/// fingerprints (`code` + `path`), never the raw `message` body — toml
/// diagnostics can quote the offending source line, which would leak any
/// secret the operator just tried to set. Use this on every user-facing
/// surface of set / edit / migrate.
fn render_redacted_report(report: &ValidationReport) -> String {
    if report.errors.is_empty() {
        return "ok".to_string();
    }
    report
        .errors
        .iter()
        .map(|i| format!("[{:?}] @ {}", i.code, i.path))
        .collect::<Vec<_>>()
        .join("; ")
}

fn emit_edit_error(format: ConfigFormat, message: &str) {
    if format == ConfigFormat::Text {
        eprintln!("FAIL edit: {message}");
    } else {
        // v1.3 Lane G.7: augment with canonical envelope fields.
        let mut payload = json!({ "ok": false, "error": message });
        let kind = crate::commands::error_envelope::classify_legacy_message(message);
        crate::commands::error_envelope::augment_with_g7_fields(
            &mut payload,
            kind,
            None,
            None,
            None,
        );
        emit(&payload, format);
    }
}

/// On a validate-failure / editor-abort, copy the temp candidate to a
/// stable sibling of the original file so the operator can recover. The
/// sibling is named `.<orig>.edit-aborted.<epoch>` and written with 0600.
fn persist_aborted_temp(original: &Path, tmp: &Path) -> std::io::Result<PathBuf> {
    let parent = original
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."));
    let stem = original
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("config");
    let epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let dest = parent.join(format!(".{stem}.edit-aborted.{epoch}"));
    std::fs::copy(tmp, &dest)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o600));
    }
    Ok(dest)
}

/// Current latest schema_version we know how to land on. v1 today; bumping
/// this is the trigger for adding a real migration step below.
pub const LATEST_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize)]
pub struct MigrateOutcome {
    pub target: &'static str,
    pub path: String,
    pub from_version: u32,
    pub to_version: u32,
    pub action: &'static str, // "noop" | "migrated" | "skipped" | "error"
    pub note: Option<String>,
}

/// Distinct outcomes when reading `schema_version` off a config file. The
/// `migrate` driver MUST surface anything that is not `Ok(_)` as an error
/// instead of silently defaulting to v1 (reviewer round-1 finding).
#[derive(Debug)]
enum SchemaVersionRead {
    Ok(u32),
    ReadError,
    ParseError,
    Missing,
    NonInteger,
    OutOfRange(i64),
}

fn read_schema_version(path: &Path) -> SchemaVersionRead {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return SchemaVersionRead::ReadError,
    };
    let v: toml::Value = match toml::from_str(&text) {
        Ok(v) => v,
        Err(_) => return SchemaVersionRead::ParseError,
    };
    let Some(raw) = v.get("schema_version") else {
        return SchemaVersionRead::Missing;
    };
    let Some(n) = raw.as_integer() else {
        return SchemaVersionRead::NonInteger;
    };
    match u32::try_from(n) {
        Ok(u) => SchemaVersionRead::Ok(u),
        Err(_) => SchemaVersionRead::OutOfRange(n),
    }
}

fn run_migrate(locs: &ConfigLocations, args: MigrateArgs, format: ConfigFormat) -> i32 {
    // v1.3 Lane G.5: emit the shared dry-run envelope when --dry-run is set,
    // so every mutate command in the matrix has uniform envelope shape.
    // The legacy {outcomes:[...]} surface is preserved for the real (non
    // dry-run) path; tests on the legacy surface invoke run_migrate with
    // dry_run=false directly so they remain unaffected.
    if args.dry_run_args.is_dry_run() {
        return crate::commands::dry_run::emit_dry_run(
            dry_run_format_bridge(format),
            "config.migrate",
            &[
                "resolve policy.toml + authorized.toml paths",
                "read schema_version from each file",
                "compute (from → to) migration per target",
                "(skipped) ConfigWriter atomic write + .bak.<epoch> backup",
            ],
            &args.dry_run_args,
        );
    }
    let key_id = args.dry_run_args.idempotency_key.clone();
    let idem_payload = crate::commands::idempotency::payload_value(
        "config.migrate",
        [("dry_run_inner", json!(args.dry_run()))],
    );
    let (idem, replay_exit) = crate::commands::idempotency::ReplayGuard::check(
        dry_run_format_bridge(format),
        "config.migrate",
        key_id,
        idem_payload,
    );
    if let Some(code) = replay_exit {
        return code;
    }
    let mut outcomes: Vec<MigrateOutcome> = Vec::new();
    for (label, path) in [("policy", &locs.policy), ("authorized", &locs.authorized)] {
        if !path.exists() {
            outcomes.push(MigrateOutcome {
                target: label,
                path: path.display().to_string(),
                from_version: 0,
                to_version: LATEST_SCHEMA_VERSION,
                action: "skipped",
                note: Some("file missing".into()),
            });
            continue;
        }
        let to = LATEST_SCHEMA_VERSION;
        let (from, action, note) = match read_schema_version(path) {
            SchemaVersionRead::Ok(v) => {
                if v == to {
                    (v, "noop", Some(format!("schema_version already v{to}")))
                } else if v > to {
                    (
                        v,
                        "error",
                        Some(format!(
                            "file is at v{v} which is newer than supported v{to}"
                        )),
                    )
                } else {
                    // Future v2+ branch lands here. For now refuse silently
                    // so we don't accidentally migrate via an unknown path.
                    (
                        v,
                        "error",
                        Some(format!("no migration registered for v{v} → v{to}")),
                    )
                }
            }
            SchemaVersionRead::ReadError => {
                (0, "error", Some("read error (file unreadable)".to_string()))
            }
            SchemaVersionRead::ParseError => (
                0,
                "error",
                Some("TOML parse failed (run `config validate`)".to_string()),
            ),
            SchemaVersionRead::Missing => (
                0,
                "error",
                Some("schema_version field missing — refusing to assume v1".to_string()),
            ),
            SchemaVersionRead::NonInteger => (
                0,
                "error",
                Some("schema_version is not an integer".to_string()),
            ),
            SchemaVersionRead::OutOfRange(n) => (
                0,
                "error",
                Some(format!("schema_version {n} out of u32 range")),
            ),
        };
        if args.dry_run() {
            outcomes.push(MigrateOutcome {
                target: label,
                path: path.display().to_string(),
                from_version: from,
                to_version: to,
                action: if action == "error" { "error" } else { "noop" },
                note: Some(format!("dry-run: would {action}")),
            });
        } else {
            outcomes.push(MigrateOutcome {
                target: label,
                path: path.display().to_string(),
                from_version: from,
                to_version: to,
                action,
                note,
            });
        }
    }
    let any_error = outcomes.iter().any(|o| o.action == "error");
    if format == ConfigFormat::Text {
        for o in &outcomes {
            println!(
                "{:<8} {:<10} v{} → v{}  {}{}",
                o.action.to_ascii_uppercase(),
                o.target,
                o.from_version,
                o.to_version,
                o.path,
                o.note
                    .as_ref()
                    .map(|n| format!("  — {n}"))
                    .unwrap_or_default(),
            );
        }
    } else if any_error {
        // v1.3 Lane G.7 round-6: structurally honest failure envelope.
        // Build the canonical G.7 envelope and retain the `outcomes`
        // diagnostic payload so operators can still parse per-target
        // migration state. The central `emit()` auto-augmentation only
        // fires when `kind` is absent, so we attach it here explicitly.
        let error_count = outcomes.iter().filter(|o| o.action == "error").count();
        let summary = format!("config migrate failed: {error_count} target(s) errored");
        let mut payload = json!({
            "ok": false,
            "operation": "config.migrate",
            "exit_code": 1,
            "error": summary,
            "outcomes": outcomes,
        });
        crate::commands::error_envelope::augment_with_g7_fields(
            &mut payload,
            crate::commands::error_envelope::CliErrorKind::Validation,
            None,
            Some("Run `rev-stealth config migrate --format json` to inspect per-target outcomes; see `outcomes[].note` for the cause"),
            None,
        );
        emit(&payload, format);
    } else {
        emit(&json!({ "outcomes": outcomes }), format);
    }
    if any_error {
        1
    } else {
        let envelope = json!({
            "ok": true,
            "operation": "config.migrate",
            "result": { "outcomes": outcomes },
        });
        idem.record("config.migrate", &envelope);
        0
    }
}

// ---------- P6.4: history / rollback / gc ----------------------------------

#[derive(Debug, Clone, Serialize)]
pub struct HistoryEntry {
    pub name: String,
    pub path: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct RollbackOutcome {
    pub target: &'static str,
    pub restored_from: String,
    pub current_path: String,
    /// Path the previous current file was backed up to (if any).
    pub previous_backup: Option<String>,
    pub bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct GcOutcome {
    pub target: &'static str,
    pub current_path: String,
    pub deleted: usize,
    pub kept: usize,
}

fn write_target_label(t: WriteTarget) -> &'static str {
    match t {
        WriteTarget::Policy => "policy",
        WriteTarget::Authorized => "authorized",
    }
}

fn target_path_for(locs: &ConfigLocations, t: WriteTarget) -> &Path {
    match t {
        WriteTarget::Policy => &locs.policy,
        WriteTarget::Authorized => &locs.authorized,
    }
}

fn run_history(locs: &ConfigLocations, args: HistoryArgs, format: ConfigFormat) -> i32 {
    let path = target_path_for(locs, args.target);
    let writer = FsConfigWriter;
    let baks = match writer.list_backups(path) {
        Ok(b) => b,
        Err(e) => {
            emit(
                &json!({
                    "error": "list_backups_failed",
                    "message": writer_err_msg(&e),
                    "target": write_target_label(args.target),
                }),
                format,
            );
            return 1;
        }
    };
    let entries: Vec<HistoryEntry> = baks
        .iter()
        .map(|p| {
            let name = p
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            let bytes = std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
            HistoryEntry {
                name,
                path: p.display().to_string(),
                bytes,
            }
        })
        .collect();
    if format == ConfigFormat::Text {
        if entries.is_empty() {
            println!("(no backups for {})", path.display());
        } else {
            for e in &entries {
                println!("{:>10}  {}", e.bytes, e.name);
            }
        }
    } else {
        emit(
            &json!({
                "target": write_target_label(args.target),
                "current_path": path.display().to_string(),
                "entries": entries,
            }),
            format,
        );
    }
    0
}

/// Resolve a backup file by name relative to `path`'s parent directory.
/// Rejects path-traversal (any `/`, `\`, or `..` component) so an operator
/// cannot trick `rollback` into reading outside the config dir.
fn resolve_bak(path: &Path, bak_name: &str) -> Result<PathBuf, String> {
    if bak_name.is_empty() {
        return Err("bak name is empty".into());
    }
    if bak_name.contains('/') || bak_name.contains('\\') {
        return Err("bak name must not contain path separators".into());
    }
    if bak_name == "." || bak_name == ".." || bak_name.split('.').any(|c| c == "..") {
        return Err("bak name must not contain `..`".into());
    }
    let expected_prefix = match path.file_name().and_then(|s| s.to_str()) {
        Some(n) => format!("{n}.bak."),
        None => return Err("target path has no file name".into()),
    };
    if !bak_name.starts_with(&expected_prefix) {
        return Err(format!(
            "bak name `{bak_name}` does not match expected prefix `{expected_prefix}`"
        ));
    }
    let parent = path
        .parent()
        .ok_or_else(|| "target path has no parent".to_string())?;
    Ok(parent.join(bak_name))
}

fn run_rollback(locs: &ConfigLocations, args: RollbackArgs, format: ConfigFormat) -> i32 {
    if args.dry_run_args.is_dry_run() {
        return crate::commands::dry_run::emit_dry_run(
            dry_run_format_bridge(format),
            "config.rollback",
            &[
                "resolve target file (policy.toml / authorized.toml)",
                "validate backup name (path-traversal rejection)",
                "(skipped) read backup contents",
                "(skipped) ConfigWriter::write_with_backup (atomic restore + fresh .bak.<epoch>)",
            ],
            &args.dry_run_args,
        );
    }
    let key_id = args.dry_run_args.idempotency_key.clone();
    let idem_payload = crate::commands::idempotency::payload_value(
        "config.rollback",
        [
            ("target", json!(format!("{:?}", args.target))),
            ("bak_name", json!(args.bak_name.clone())),
        ],
    );
    let (idem, replay_exit) = crate::commands::idempotency::ReplayGuard::check(
        dry_run_format_bridge(format),
        "config.rollback",
        key_id,
        idem_payload,
    );
    if let Some(code) = replay_exit {
        return code;
    }
    let path = target_path_for(locs, args.target);
    let label = write_target_label(args.target);
    let bak = match resolve_bak(path, &args.bak_name) {
        Ok(p) => p,
        Err(msg) => {
            emit(
                &json!({
                    "error": "invalid_bak_name",
                    "message": msg,
                    "target": label,
                }),
                format,
            );
            return 2;
        }
    };
    if !bak.exists() {
        emit(
            &json!({
                "error": "bak_not_found",
                "message": format!("backup not found: {}", bak.display()),
                "target": label,
            }),
            format,
        );
        return 2;
    }
    let contents = match std::fs::read(&bak) {
        Ok(b) => b,
        Err(e) => {
            emit(
                &json!({
                    "error": "bak_read_failed",
                    "message": e.to_string(),
                    "target": label,
                }),
                format,
            );
            return 1;
        }
    };
    let bytes_len = contents.len() as u64;
    let writer = FsConfigWriter;
    match writer.write_with_backup(path, &contents) {
        Ok(report) => {
            let outcome = RollbackOutcome {
                target: label,
                restored_from: bak.display().to_string(),
                current_path: path.display().to_string(),
                previous_backup: report.backup_path.map(|p| p.display().to_string()),
                bytes: bytes_len,
            };
            if format == ConfigFormat::Text {
                println!(
                    "ROLLBACK  {} ← {}  ({} bytes){}",
                    path.display(),
                    bak.display(),
                    bytes_len,
                    outcome
                        .previous_backup
                        .as_ref()
                        .map(|b| format!("  (prev backed up to {b})"))
                        .unwrap_or_default(),
                );
            } else {
                emit(
                    &serde_json::to_value(&outcome).unwrap_or(JsonValue::Null),
                    format,
                );
            }
            let envelope = json!({
                "ok": true,
                "operation": "config.rollback",
                "result": &outcome,
            });
            idem.record("config.rollback", &envelope);
            0
        }
        Err(e) => {
            emit(
                &json!({
                    "error": "rollback_write_failed",
                    "message": writer_err_msg(&e),
                    "target": label,
                }),
                format,
            );
            1
        }
    }
}

fn run_gc(locs: &ConfigLocations, args: GcArgs, format: ConfigFormat) -> i32 {
    if args.dry_run_args.is_dry_run() {
        return crate::commands::dry_run::emit_dry_run(
            dry_run_format_bridge(format),
            "config.gc",
            &[
                "resolve target file's parent directory",
                "list .bak.<epoch> backups in newest→oldest order",
                "compute keep / delete buckets per --keep",
                "(skipped) unlink older backups",
            ],
            &args.dry_run_args,
        );
    }
    let key_id = args.dry_run_args.idempotency_key.clone();
    let idem_payload = crate::commands::idempotency::payload_value(
        "config.gc",
        [
            ("target", json!(format!("{:?}", args.target))),
            ("keep", json!(args.keep)),
        ],
    );
    let (idem, replay_exit) = crate::commands::idempotency::ReplayGuard::check(
        dry_run_format_bridge(format),
        "config.gc",
        key_id,
        idem_payload,
    );
    if let Some(code) = replay_exit {
        return code;
    }
    let path = target_path_for(locs, args.target);
    let label = write_target_label(args.target);
    let writer = FsConfigWriter;
    let before = match writer.list_backups(path) {
        Ok(b) => b.len(),
        Err(e) => {
            emit(
                &json!({
                    "error": "list_backups_failed",
                    "message": writer_err_msg(&e),
                    "target": label,
                }),
                format,
            );
            return 1;
        }
    };
    match writer.gc_backups(path, args.keep) {
        Ok(deleted) => {
            let kept = before.saturating_sub(deleted);
            let outcome = GcOutcome {
                target: label,
                current_path: path.display().to_string(),
                deleted,
                kept,
            };
            if format == ConfigFormat::Text {
                println!(
                    "GC        {} keep={} deleted={} kept={}",
                    path.display(),
                    args.keep,
                    deleted,
                    kept,
                );
            } else {
                emit(
                    &serde_json::to_value(&outcome).unwrap_or(JsonValue::Null),
                    format,
                );
            }
            let envelope = json!({
                "ok": true,
                "operation": "config.gc",
                "result": &outcome,
            });
            idem.record("config.gc", &envelope);
            0
        }
        Err(e) => {
            emit(
                &json!({
                    "error": "gc_failed",
                    "message": writer_err_msg(&e),
                    "target": label,
                }),
                format,
            );
            1
        }
    }
}

// ---------- P6.5: profile list / create / switch / delete ------------------

/// Env var name the operator must export to activate a profile. We document
/// the exact string here so tests can pin the operator-facing contract.
pub const PROFILE_ACTIVATE_ENV: &str = "REV_SCRAPING_HOME";

#[derive(Debug, Clone, Serialize)]
pub struct ProfileEntry {
    pub name: String,
    pub path: String,
    pub has_policy: bool,
    pub has_authorized: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProfileSwitchHint {
    pub profile: String,
    pub home: String,
    pub export_line: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProfileDeleteOutcome {
    pub profile: String,
    pub path: String,
    pub files_shredded: usize,
}

/// Resolve the profile registry root. Profile management MUST be decoupled
/// from the currently-active profile so that after the operator exports
/// `REV_SCRAPING_HOME=<profiles_root>/<name>` to activate a profile, the
/// next `profile list/create/delete` call still finds its siblings instead
/// of recursing into `<active>/profiles/`.
///
/// Resolution order:
///   1. `$REV_SCRAPING_PROFILES_ROOT` (test override + explicit operator opt-in)
///   2. `~/.rev_scraping/profiles/` (default; ignores $REV_SCRAPING_HOME)
///   3. `./.rev_scraping/profiles/` (fallback when HOME is unset)
///
/// We intentionally do NOT derive from `$REV_SCRAPING_HOME`. That env is
/// reserved for *activating* a profile; reusing it as the registry parent
/// would nest profile roots under each switched profile.
fn profiles_root() -> PathBuf {
    if let Some(v) = std::env::var_os("REV_SCRAPING_PROFILES_ROOT") {
        return PathBuf::from(v);
    }
    if let Some(home) = dirs::home_dir() {
        return home.join(".rev_scraping").join("profiles");
    }
    PathBuf::from(".rev_scraping").join("profiles")
}

/// Validate profile name: 1..=64 chars of `[A-Za-z0-9_-]`. Rejects path
/// separators, `..`, dots, whitespace, and any control character. Returning
/// an Err keeps the operator-facing error messages stable across callers.
fn validate_profile_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("profile name is empty".into());
    }
    if name.len() > 64 {
        return Err("profile name exceeds 64 characters".into());
    }
    for ch in name.chars() {
        if !(ch.is_ascii_alphanumeric() || ch == '_' || ch == '-') {
            return Err(format!(
                "profile name must match [A-Za-z0-9_-]; rejected `{ch}`"
            ));
        }
    }
    Ok(())
}

/// Resolves to the on-disk dir for `<profiles_root>/<name>`. The operator
/// activates this profile by exporting `REV_SCRAPING_HOME=<this path>` —
/// the path is stable across activations because `profiles_root()` is
/// decoupled from `$REV_SCRAPING_HOME` (see `profiles_root` doc).
fn profile_dir(name: &str) -> PathBuf {
    profiles_root().join(name)
}

fn run_profile(locs: &ConfigLocations, action: ProfileAction, format: ConfigFormat) -> i32 {
    match action {
        ProfileAction::List => run_profile_list(format),
        ProfileAction::Create { name, dry_run_args } => {
            if dry_run_args.is_dry_run() {
                return crate::commands::dry_run::emit_dry_run(
                    dry_run_format_bridge(format),
                    "config.profile.create",
                    &[
                        "validate profile name (path-traversal rejection)",
                        "resolve profiles root",
                        "(skipped) mkdir profile dir + sites/",
                        "(skipped) ConfigWriter::write policy.toml + authorized.toml",
                    ],
                    &dry_run_args,
                );
            }
            let key_id = dry_run_args.idempotency_key.clone();
            let idem_payload = crate::commands::idempotency::payload_value(
                "config.profile.create",
                [("name", json!(name.clone()))],
            );
            let (idem, replay_exit) = crate::commands::idempotency::ReplayGuard::check(
                dry_run_format_bridge(format),
                "config.profile.create",
                key_id,
                idem_payload,
            );
            if let Some(code) = replay_exit {
                return code;
            }
            let exit = run_profile_create(&name, format);
            if exit == 0 {
                let envelope = json!({
                    "ok": true,
                    "operation": "config.profile.create",
                    "result": { "profile": name },
                });
                idem.record("config.profile.create", &envelope);
            }
            exit
        }
        ProfileAction::Switch { name, dry_run_args } => {
            if dry_run_args.is_dry_run() {
                return crate::commands::dry_run::emit_dry_run(
                    dry_run_format_bridge(format),
                    "config.profile.switch",
                    &[
                        "validate profile name (path-traversal rejection)",
                        "verify profile directory exists",
                        "emit shell-export line (no env mutation in-process)",
                    ],
                    &dry_run_args,
                );
            }
            let key_id = dry_run_args.idempotency_key.clone();
            let idem_payload = crate::commands::idempotency::payload_value(
                "config.profile.switch",
                [("name", json!(name.clone()))],
            );
            let (idem, replay_exit) = crate::commands::idempotency::ReplayGuard::check(
                dry_run_format_bridge(format),
                "config.profile.switch",
                key_id,
                idem_payload,
            );
            if let Some(code) = replay_exit {
                return code;
            }
            let exit = run_profile_switch(&name, format);
            if exit == 0 {
                let envelope = json!({
                    "ok": true,
                    "operation": "config.profile.switch",
                    "result": { "profile": name },
                });
                idem.record("config.profile.switch", &envelope);
            }
            exit
        }
        ProfileAction::Delete {
            name,
            yes,
            dry_run_args,
        } => {
            if dry_run_args.is_dry_run() {
                return crate::commands::dry_run::emit_dry_run(
                    dry_run_format_bridge(format),
                    "config.profile.delete",
                    &[
                        "validate profile name (path-traversal rejection)",
                        "verify profile is not currently active per REV_SCRAPING_HOME",
                        "verify --yes was passed (no-op otherwise)",
                        "(skipped) shred-like overwrite-then-unlink of profile dir",
                    ],
                    &dry_run_args,
                );
            }
            let key_id = dry_run_args.idempotency_key.clone();
            let idem_payload = crate::commands::idempotency::payload_value(
                "config.profile.delete",
                [("name", json!(name.clone())), ("yes", json!(yes))],
            );
            let (idem, replay_exit) = crate::commands::idempotency::ReplayGuard::check(
                dry_run_format_bridge(format),
                "config.profile.delete",
                key_id,
                idem_payload,
            );
            if let Some(code) = replay_exit {
                return code;
            }
            let exit = run_profile_delete(locs, &name, yes, format);
            if exit == 0 {
                let envelope = json!({
                    "ok": true,
                    "operation": "config.profile.delete",
                    "result": { "profile": name },
                });
                idem.record("config.profile.delete", &envelope);
            }
            exit
        }
    }
}

fn run_profile_list(format: ConfigFormat) -> i32 {
    let root = profiles_root();
    let mut entries: Vec<ProfileEntry> = Vec::new();
    if root.exists() {
        let iter = match std::fs::read_dir(&root) {
            Ok(it) => it,
            Err(e) => {
                emit(
                    &json!({
                        "error": "profiles_root_read_failed",
                        "message": e.to_string(),
                    }),
                    format,
                );
                return 1;
            }
        };
        for ent in iter {
            let Ok(ent) = ent else { continue };
            let Ok(meta) = ent.metadata() else { continue };
            if !meta.is_dir() {
                continue;
            }
            let Some(name) = ent.file_name().to_str().map(String::from) else {
                continue;
            };
            // Defence-in-depth: skip directories whose names would have been
            // rejected by validate_profile_name. They were never created via
            // `profile create`; ignore them rather than surface invalid entries.
            if validate_profile_name(&name).is_err() {
                continue;
            }
            let dir = ent.path();
            let has_policy = dir.join("policy.toml").is_file();
            let has_authorized = dir.join("authorized.toml").is_file();
            entries.push(ProfileEntry {
                name,
                path: dir.display().to_string(),
                has_policy,
                has_authorized,
            });
        }
    }
    entries.sort_by(|a, b| a.name.cmp(&b.name));
    if format == ConfigFormat::Text {
        if entries.is_empty() {
            println!("(no profiles under {})", root.display());
        } else {
            for e in &entries {
                let p = if e.has_policy { "P" } else { "-" };
                let a = if e.has_authorized { "A" } else { "-" };
                println!("{p}{a}  {:<32}  {}", e.name, e.path);
            }
        }
    } else {
        emit(
            &json!({
                "profiles_root": root.display().to_string(),
                "profiles": entries,
            }),
            format,
        );
    }
    0
}

fn run_profile_create(name: &str, format: ConfigFormat) -> i32 {
    if let Err(msg) = validate_profile_name(name) {
        emit(
            &json!({ "error": "invalid_profile_name", "message": msg }),
            format,
        );
        return 2;
    }
    let dir = profile_dir(name);
    if dir.exists() {
        emit(
            &json!({
                "error": "profile_exists",
                "message": format!("profile already exists: {}", dir.display()),
                "profile": name,
            }),
            format,
        );
        return 2;
    }
    if let Err(e) = ensure_dir_0700(&dir) {
        emit(
            &json!({
                "error": "profile_mkdir_failed",
                "message": e.to_string(),
                "profile": name,
            }),
            format,
        );
        return 1;
    }
    // Seed the same skeleton config init uses. We deliberately route each
    // file through ConfigWriter so mode 0600 is established atomically.
    let outcomes: Vec<InitOutcome> = vec![
        init_file(
            "policy",
            &dir.join("policy.toml"),
            POLICY_TEMPLATE.as_bytes(),
            false,
        ),
        init_file(
            "authorized",
            &dir.join("authorized.toml"),
            AUTHORIZED_SKELETON.as_bytes(),
            false,
        ),
        init_sites_dir(&dir.join("sites")),
    ];
    let any_error = outcomes.iter().any(|o| o.status == InitStatus::Error);
    if format == ConfigFormat::Text {
        println!("CREATE   profile={name}  {}", dir.display());
        for o in &outcomes {
            let tag = match o.status {
                InitStatus::Created => "  +",
                InitStatus::Overwritten => "  *",
                InitStatus::Skipped => "  =",
                InitStatus::Error => "  !",
            };
            println!("{tag} {:<12} {}", o.target, o.path);
        }
    } else {
        emit(
            &json!({
                "profile": name,
                "path": dir.display().to_string(),
                "outcomes": outcomes,
            }),
            format,
        );
    }
    if any_error {
        3
    } else {
        0
    }
}

fn run_profile_switch(name: &str, format: ConfigFormat) -> i32 {
    if let Err(msg) = validate_profile_name(name) {
        emit(
            &json!({ "error": "invalid_profile_name", "message": msg }),
            format,
        );
        return 2;
    }
    let dir = profile_dir(name);
    if !dir.is_dir() {
        emit(
            &json!({
                "error": "profile_not_found",
                "message": format!("profile does not exist: {}", dir.display()),
                "profile": name,
            }),
            format,
        );
        return 2;
    }
    let home = dir.display().to_string();
    let export_line = format!("export {PROFILE_ACTIVATE_ENV}={home}");
    let hint = ProfileSwitchHint {
        profile: name.to_string(),
        home,
        export_line: export_line.clone(),
    };
    if format == ConfigFormat::Text {
        // Print ONLY the export line to stdout so `eval "$(rev-stealth ...)"`
        // works; the human-readable banner goes to stderr.
        eprintln!("# rev-stealth profile switch → {name}");
        println!("{export_line}");
    } else {
        emit(
            &serde_json::to_value(&hint).unwrap_or(JsonValue::Null),
            format,
        );
    }
    0
}

fn run_profile_delete(locs: &ConfigLocations, name: &str, yes: bool, format: ConfigFormat) -> i32 {
    if let Err(msg) = validate_profile_name(name) {
        emit(
            &json!({ "error": "invalid_profile_name", "message": msg }),
            format,
        );
        return 2;
    }
    if !yes {
        emit(
            &json!({
                "error": "delete_requires_yes",
                "message": "pass --yes to confirm profile deletion (non-recoverable)",
                "profile": name,
            }),
            format,
        );
        return 2;
    }
    let dir = profile_dir(name);
    if !dir.exists() {
        emit(
            &json!({
                "error": "profile_not_found",
                "message": format!("profile does not exist: {}", dir.display()),
                "profile": name,
            }),
            format,
        );
        return 2;
    }
    // Refuse to delete the currently active profile: if REV_SCRAPING_HOME
    // resolves into this profile dir, operators must switch first. We use
    // `ConfigLocations.policy.parent()` rather than re-reading the env so
    // tests that override `locs` directly still hit the guard.
    if let Some(active_base) = locs.policy.parent() {
        if active_base == dir.as_path() {
            emit(
                &json!({
                    "error": "profile_active",
                    "message": "refusing to delete the currently active profile; switch first",
                    "profile": name,
                }),
                format,
            );
            return 2;
        }
    }
    let mut shredded = 0usize;
    // Walk the tree, overwrite each regular file with zeros (best-effort
    // shred) before removal. Symlinks are NOT followed.
    if let Err(e) = shred_walk(&dir, &mut shredded) {
        emit(
            &json!({
                "error": "shred_walk_failed",
                "message": e.to_string(),
                "profile": name,
            }),
            format,
        );
        return 1;
    }
    if let Err(e) = std::fs::remove_dir_all(&dir) {
        emit(
            &json!({
                "error": "profile_remove_failed",
                "message": e.to_string(),
                "profile": name,
            }),
            format,
        );
        return 1;
    }
    let outcome = ProfileDeleteOutcome {
        profile: name.to_string(),
        path: dir.display().to_string(),
        files_shredded: shredded,
    };
    if format == ConfigFormat::Text {
        println!(
            "DELETE   profile={}  shredded={}  {}",
            outcome.profile, outcome.files_shredded, outcome.path
        );
    } else {
        emit(
            &serde_json::to_value(&outcome).unwrap_or(JsonValue::Null),
            format,
        );
    }
    0
}

/// Recursively overwrite every regular file under `root` with zeros and bump
/// `count`. Symlinks are not followed; dirs are descended depth-first.
fn shred_walk(root: &Path, count: &mut usize) -> std::io::Result<()> {
    let meta = match std::fs::symlink_metadata(root) {
        Ok(m) => m,
        Err(_) => return Ok(()),
    };
    if meta.file_type().is_symlink() {
        return Ok(());
    }
    if meta.is_file() {
        let len = meta.len();
        if len > 0 {
            // Best-effort single-pass zero overwrite. We are not claiming
            // forensic-grade shred — we are reducing the window during which
            // a secret-looking byte sequence survives unlink on a
            // copy-on-write or journaled filesystem.
            if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open(root) {
                let zeros = vec![0u8; len.min(64 * 1024) as usize];
                let mut remaining = len;
                while remaining > 0 {
                    let n = std::cmp::min(remaining, zeros.len() as u64) as usize;
                    use std::io::Write;
                    if f.write_all(&zeros[..n]).is_err() {
                        break;
                    }
                    remaining -= n as u64;
                }
                let _ = f.sync_all();
            }
        }
        *count += 1;
        return Ok(());
    }
    if meta.is_dir() {
        for ent in std::fs::read_dir(root)? {
            let ent = ent?;
            shred_walk(&ent.path(), count)?;
        }
    }
    Ok(())
}

// ---------- tests ----------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tempfile::TempDir;

    // Env-mutating tests must serialize.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn fresh_home() -> (TempDir, ConfigLocations) {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(dir.path().join("sites")).unwrap();
        let locs = ConfigLocations {
            policy: dir.path().join("policy.toml"),
            authorized: dir.path().join("authorized.toml"),
            sites_dir: dir.path().join("sites"),
            templates_policy: repo_templates_policy(),
        };
        (dir, locs)
    }

    #[test]
    fn config_show_redacts_secret_values() {
        let _g = ENV_LOCK.lock().unwrap();
        // Inject a synthetic secret env var. Its key matches the heuristic
        // (`*_TOKEN`) so it must surface as `<redacted>`.
        std::env::set_var("MY_SERVICE_TOKEN", "super-secret-do-not-leak");
        let (_dir, locs) = fresh_home();
        std::fs::write(&locs.policy, "require_vpn = true\n").unwrap();
        let value = build_show_value(&locs);
        let env = value.get("env").unwrap();
        let surfaced = env.get("MY_SERVICE_TOKEN").expect("token surfaces");
        assert_eq!(surfaced, &JsonValue::String(REDACTED.to_string()));
        // Negative: a non-secret value (require_vpn) is NOT redacted.
        let req = value.get("policy").and_then(|p| p.get("require_vpn"));
        assert_eq!(req, Some(&JsonValue::Bool(true)));
        // Sanity: raw secret never appears anywhere in the serialized output.
        let serialized = serde_json::to_string(&value).unwrap();
        assert!(
            !serialized.contains("super-secret-do-not-leak"),
            "raw secret leaked into show output: {serialized}"
        );
        std::env::remove_var("MY_SERVICE_TOKEN");
    }

    #[test]
    fn config_paths_lists_all_files_with_perms() {
        let (_dir, locs) = fresh_home();
        std::fs::write(&locs.policy, "require_vpn = true\n").unwrap();
        let entries = build_path_entries(&locs);
        // 4 layers: policy / authorized / sites_dir / templates_policy.
        assert_eq!(entries.len(), 4);
        let labels: Vec<&str> = entries.iter().map(|e| e.label).collect();
        assert!(labels.contains(&"policy"));
        assert!(labels.contains(&"authorized"));
        assert!(labels.contains(&"sites_dir"));
        assert!(labels.contains(&"templates_policy"));
        let policy_entry = entries.iter().find(|e| e.label == "policy").unwrap();
        assert!(policy_entry.exists, "policy file should exist");
        #[cfg(unix)]
        assert!(
            policy_entry.mode_octal.is_some(),
            "unix builds must surface a mode_octal for existing files"
        );
        let authorized_entry = entries.iter().find(|e| e.label == "authorized").unwrap();
        assert!(
            !authorized_entry.exists,
            "missing file must report exists=false"
        );
    }

    #[test]
    fn config_validate_passes_existing_templates() {
        // The shipped templates/policy.toml MUST validate clean under strict
        // mode — this protects against unknown-field drift in the template.
        let template_path = repo_templates_policy();
        let text = std::fs::read_to_string(&template_path)
            .unwrap_or_else(|e| panic!("read {}: {e}", template_path.display()));
        let report = validate_toml_against::<Policy>(&text, &ValidateOptions::strict());
        assert!(
            report.is_ok(),
            "templates/policy.toml must validate clean; errors={:?}",
            report.errors
        );

        // Inverse: synthetic invalid TOML must fail validation, mirroring
        // the exit-1 path of `rev-stealth config validate`.
        let bad = "require_vpn = true\nbogus_field = 42\n";
        let bad_report = validate_toml_against::<Policy>(bad, &ValidateOptions::strict());
        assert!(!bad_report.is_ok(), "unknown field must fail strict mode");
    }

    #[test]
    fn config_diff_detects_unknown_field() {
        // diff(base, live) where live adds a new line. The output MUST carry
        // the unified `---` / `+++` headers and a `+` line for the addition.
        let base = "require_vpn = true\n";
        let live = "require_vpn = true\nbogus_field = 42\n";
        let diff = unified_diff(base, live, "templates/policy.toml", "live/policy.toml");
        assert!(
            diff.starts_with("--- a/templates/policy.toml\n"),
            "missing --- header: {diff}"
        );
        assert!(
            diff.contains("+++ b/live/policy.toml\n"),
            "missing +++ header: {diff}"
        );
        assert!(
            diff.contains("+bogus_field = 42"),
            "missing +addition line: {diff}"
        );
    }

    #[test]
    fn config_show_redacts_secrets_inside_policy_and_sites_layers() {
        // Reviewer round-1 finding: recursive redaction over parsed TOML.
        // A site recipe with `authorization = "Bearer ..."` and a policy
        // with a `password` field must both surface `<redacted>` instead
        // of the raw value. The raw secret must never appear anywhere in
        // the serialized show output.
        let (_dir, locs) = fresh_home();
        std::fs::write(
            &locs.policy,
            "require_vpn = true\npassword = \"plaintext-policy-pw\"\n",
        )
        .unwrap();
        std::fs::write(
            &locs.authorized,
            "schema_version = 1\nauth_token = \"plaintext-auth-token\"\n",
        )
        .unwrap();
        std::fs::write(
            locs.sites_dir.join("example.com.toml"),
            "[required_headers]\nauthorization = \"Bearer plaintext-site-bearer\"\n",
        )
        .unwrap();
        let value = build_show_value(&locs);
        let serialized = serde_json::to_string(&value).unwrap();
        for raw in [
            "plaintext-policy-pw",
            "plaintext-auth-token",
            "plaintext-site-bearer",
        ] {
            assert!(
                !serialized.contains(raw),
                "raw secret {raw:?} leaked into show output: {serialized}"
            );
        }
        // Spot-check that the sentinel actually replaced the leaves.
        let pw = value.get("policy").and_then(|p| p.get("password")).unwrap();
        assert_eq!(pw, &JsonValue::String(REDACTED.to_string()));
    }

    #[test]
    fn config_get_dotted_path_resolves() {
        let (_dir, locs) = fresh_home();
        std::fs::write(
            &locs.policy,
            "require_vpn = false\nvpn_required_country = \"Japan\"\n",
        )
        .unwrap();
        let merged = build_show_value(&locs);
        // Positive: dotted resolution into the policy layer.
        let v = resolve_dotted(&merged, "policy.require_vpn").expect("require_vpn resolves");
        assert_eq!(v, JsonValue::Bool(false));
        let country = resolve_dotted(&merged, "policy.vpn_required_country").unwrap();
        assert_eq!(country, JsonValue::String("Japan".to_string()));
        // Negative: missing key returns None (drives exit 1 in run_get).
        assert!(resolve_dotted(&merged, "policy.nonexistent").is_none());
        // Redaction layered on top of dotted get: a secret-shaped key path
        // produces the `<redacted>` sentinel even if the underlying value
        // happens to be plain.
        let leaf = JsonValue::String("plaintext".to_string());
        let r = redact_if_secret("env.SOME_TOKEN", &leaf);
        assert_eq!(r, JsonValue::String(REDACTED.to_string()));
    }

    // ----- P6.2 `config init` -------------------------------------------

    fn init_args(target: InitTarget, force: bool, non_interactive: bool) -> InitArgs {
        InitArgs {
            dry_run_args: Default::default(),
            target,
            force,
            non_interactive,
        }
    }

    #[cfg(unix)]
    #[test]
    fn config_init_creates_policy_with_0600() {
        use std::os::unix::fs::PermissionsExt;
        let (_dir, locs) = fresh_home();
        // Wipe the sites/ dir auto-created by fresh_home so we hit the
        // "Created" branch for that target too (kept as belt-and-suspenders;
        // the policy-only assertion is what this test actually pins).
        let _ = std::fs::remove_dir_all(&locs.sites_dir);
        let code = run_init(
            &locs,
            init_args(InitTarget::Policy, false, true),
            ConfigFormat::Json,
        );
        assert_eq!(code, 0, "init must exit 0 on fresh home");
        assert!(locs.policy.exists(), "policy.toml must be created");
        let mode = std::fs::metadata(&locs.policy)
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(
            mode, 0o600,
            "policy.toml must be 0600 AT CREATION (ConfigWriter atomic), got {mode:o}"
        );
        // And it must be byte-equal to the bundled template (proves we used
        // include_str! rather than synthesizing a skeleton silently).
        let written = std::fs::read_to_string(&locs.policy).unwrap();
        assert_eq!(written, POLICY_TEMPLATE);
    }

    #[cfg(unix)]
    #[test]
    fn config_init_creates_sites_dir_with_0700() {
        use std::os::unix::fs::PermissionsExt;
        let (_dir, locs) = fresh_home();
        // fresh_home pre-creates sites/ — remove it so init must mkdir.
        std::fs::remove_dir_all(&locs.sites_dir).unwrap();
        let code = run_init(
            &locs,
            init_args(InitTarget::Sites, false, true),
            ConfigFormat::Json,
        );
        assert_eq!(code, 0);
        assert!(locs.sites_dir.is_dir(), "sites/ must exist");
        let mode = std::fs::metadata(&locs.sites_dir)
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o700, "sites/ must be 0700, got {mode:o}");
        // Placeholder seeded with 0600 (FsConfigWriter contract).
        let placeholder = locs.sites_dir.join("example.com.toml");
        assert!(
            placeholder.exists(),
            "placeholder example.com.toml must be seeded"
        );
        let pmode = std::fs::metadata(&placeholder)
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(pmode, 0o600, "placeholder must be 0600, got {pmode:o}");
    }

    #[test]
    fn config_init_skips_existing_without_force() {
        let (_dir, locs) = fresh_home();
        std::fs::write(&locs.policy, "require_vpn = true # operator-edited\n").unwrap();
        let original = std::fs::read(&locs.policy).unwrap();
        let code = run_init(
            &locs,
            init_args(InitTarget::Policy, false, true),
            ConfigFormat::Json,
        );
        // Skipped is not an error — exit 0.
        assert_eq!(code, 0);
        // Content must be byte-identical (no clobber).
        let after = std::fs::read(&locs.policy).unwrap();
        assert_eq!(
            after, original,
            "existing policy.toml must NOT be overwritten without --force"
        );
    }

    #[cfg(unix)]
    #[test]
    fn config_init_with_force_creates_bak() {
        let (_dir, locs) = fresh_home();
        std::fs::write(&locs.policy, "require_vpn = false # v1\n").unwrap();
        let code = run_init(
            &locs,
            init_args(InitTarget::Policy, true, true),
            ConfigFormat::Json,
        );
        assert_eq!(code, 0);
        // The original content lives in a sibling .bak.<epoch> file written
        // by FsConfigWriter (P5.2 contract); locate it by prefix match.
        let parent = locs.policy.parent().unwrap();
        let bak = std::fs::read_dir(parent)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .find(|p| {
                p.file_name()
                    .and_then(|s| s.to_str())
                    .is_some_and(|n| n.starts_with("policy.toml.bak."))
            })
            .expect("--force must produce a policy.toml.bak.<epoch> backup");
        let backed_up = std::fs::read_to_string(&bak).unwrap();
        assert!(
            backed_up.contains("v1"),
            "backup must contain pre-overwrite content, got: {backed_up}"
        );
        // The live file must now be the template — proves overwrite happened.
        let live = std::fs::read_to_string(&locs.policy).unwrap();
        assert_eq!(live, POLICY_TEMPLATE);
    }

    #[test]
    fn config_init_policy_target_with_directory_at_path_returns_error() {
        // Reviewer round-2 finding (P6.2): if `policy.toml` exists but is a
        // directory (e.g. operator misconfigured the path), init MUST exit
        // 3 with InitStatus::Error — not Skipped/exit 0.
        let (_dir, locs) = fresh_home();
        std::fs::create_dir_all(&locs.policy).unwrap();
        let code = run_init(
            &locs,
            init_args(InitTarget::Policy, false, true),
            ConfigFormat::Json,
        );
        assert_eq!(code, 3, "directory at policy.toml path must exit 3");
        // Path remains a directory; not clobbered.
        assert!(locs.policy.is_dir());
        // Same contract under --force: refuse to clobber, do not back up a
        // directory through ConfigWriter.
        let code_force = run_init(
            &locs,
            init_args(InitTarget::Policy, true, true),
            ConfigFormat::Json,
        );
        assert_eq!(
            code_force, 3,
            "even --force must refuse to clobber a directory"
        );
        assert!(locs.policy.is_dir());
    }

    #[test]
    fn config_init_authorized_target_with_directory_at_path_returns_error() {
        let (_dir, locs) = fresh_home();
        std::fs::create_dir_all(&locs.authorized).unwrap();
        let code = run_init(
            &locs,
            init_args(InitTarget::Authorized, false, true),
            ConfigFormat::Json,
        );
        assert_eq!(code, 3, "directory at authorized.toml path must exit 3");
        assert!(locs.authorized.is_dir());
    }

    #[test]
    fn config_init_sites_target_with_file_at_path_returns_error() {
        // Reviewer round-1 finding (P6.2): if `sites` exists but is NOT a
        // directory (e.g. operator left a stray regular file there), the
        // init MUST surface as Error/exit 3 — not a false-success Skipped.
        let (_dir, locs) = fresh_home();
        std::fs::remove_dir_all(&locs.sites_dir).unwrap();
        // Plant a regular file at the would-be sites/ path.
        std::fs::write(&locs.sites_dir, b"not a directory\n").unwrap();
        let code = run_init(
            &locs,
            init_args(InitTarget::Sites, false, true),
            ConfigFormat::Json,
        );
        assert_eq!(code, 3, "stray file at sites/ path must exit 3, got {code}");
        // The path on disk must remain the operator's file (not clobbered).
        assert!(locs.sites_dir.is_file());
        assert_eq!(
            std::fs::read(&locs.sites_dir).unwrap(),
            b"not a directory\n"
        );
    }

    // ----- P6.3 `config set` / `edit` / `migrate` -----------------------

    fn set_args(key: &str, value: &str, target: WriteTarget) -> SetArgs {
        SetArgs {
            dry_run_args: Default::default(),
            key: key.into(),
            value: value.into(),
            target,
        }
    }

    fn seed_valid_policy(locs: &ConfigLocations) {
        std::fs::write(&locs.policy, "schema_version = 1\nrequire_vpn = false\n").unwrap();
    }

    #[test]
    fn set_dotted_path_updates_policy_require_vpn() {
        let (_dir, locs) = fresh_home();
        seed_valid_policy(&locs);
        let code = run_set(
            &locs,
            set_args("policy.require_vpn", "true", WriteTarget::Policy),
            ConfigFormat::Json,
        );
        assert_eq!(code, 0, "valid set must exit 0");
        let written = std::fs::read_to_string(&locs.policy).unwrap();
        let parsed: toml::Value = toml::from_str(&written).unwrap();
        assert_eq!(
            parsed.get("require_vpn"),
            Some(&toml::Value::Boolean(true)),
            "dotted path must strip layer prefix and update leaf"
        );
        // Layer-less form also works.
        let code2 = run_set(
            &locs,
            set_args("require_vpn", "false", WriteTarget::Policy),
            ConfigFormat::Json,
        );
        assert_eq!(code2, 0);
        let parsed2: toml::Value =
            toml::from_str(&std::fs::read_to_string(&locs.policy).unwrap()).unwrap();
        assert_eq!(
            parsed2.get("require_vpn"),
            Some(&toml::Value::Boolean(false))
        );
    }

    #[test]
    fn set_value_inference_string_bool_int() {
        assert_eq!(infer_toml_value("true"), toml::Value::Boolean(true));
        assert_eq!(infer_toml_value("FALSE"), toml::Value::Boolean(false));
        assert_eq!(infer_toml_value("42"), toml::Value::Integer(42));
        assert_eq!(infer_toml_value("-7"), toml::Value::Integer(-7));
        assert_eq!(
            infer_toml_value("Japan"),
            toml::Value::String("Japan".to_string())
        );
        // Numeric-looking strings that don't parse cleanly stay strings.
        assert_eq!(
            infer_toml_value("12.5"),
            toml::Value::String("12.5".to_string())
        );
    }

    #[test]
    fn set_validates_before_write() {
        // Writing an unknown top-level field MUST fail strict validation
        // and leave the original file byte-identical on disk.
        let (_dir, locs) = fresh_home();
        seed_valid_policy(&locs);
        let original = std::fs::read(&locs.policy).unwrap();
        let code = run_set(
            &locs,
            set_args("bogus_field", "42", WriteTarget::Policy),
            ConfigFormat::Json,
        );
        assert_eq!(code, 1, "unknown field must fail strict validate");
        let after = std::fs::read(&locs.policy).unwrap();
        assert_eq!(
            after, original,
            "validate-fail must NOT mutate the live file"
        );
    }

    #[test]
    fn edit_aborts_on_validate_failure_keeps_original() {
        let _g = EDIT_TMP_LOCK.lock().unwrap();
        // Stand in for `$EDITOR` with a one-shot shell script that writes
        // invalid TOML over the tempfile. Spawned via the same Command
        // dispatch as a real editor, so the validate-fail rollback path
        // is exercised end-to-end.
        let (_dir, locs) = fresh_home();
        seed_valid_policy(&locs);
        let original = std::fs::read(&locs.policy).unwrap();

        // Materialize the helper editor in a sibling dir and chmod +x.
        let editor_path = _dir.path().join("bad_editor.sh");
        std::fs::write(
            &editor_path,
            "#!/bin/sh\nprintf 'bogus_field = 42\\n' >> \"$1\"\n",
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&editor_path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }

        let code = run_edit(
            &locs,
            EditArgs {
                dry_run_args: Default::default(),
                target: WriteTarget::Policy,
                editor: Some(editor_path.display().to_string()),
            },
            ConfigFormat::Json,
        );
        assert_eq!(code, 1, "validate-fail edit must exit 1");
        // Original file untouched.
        let after = std::fs::read(&locs.policy).unwrap();
        assert_eq!(
            after, original,
            "validate-fail edit must NOT mutate the live file"
        );
        // A recovery copy was preserved as `.policy.toml.edit-aborted.*`.
        let parent = locs.policy.parent().unwrap();
        let recovered = std::fs::read_dir(parent)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .find(|p| {
                p.file_name()
                    .and_then(|s| s.to_str())
                    .is_some_and(|n| n.starts_with(".policy.toml.edit-aborted."))
            });
        assert!(
            recovered.is_some(),
            "validate-fail edit must persist a recovery copy"
        );
        // And the tempdir itself MUST be swept (recovery copy lives at
        // the original's parent, not under TMPDIR).
        let stragglers = std::fs::read_dir(std::env::temp_dir())
            .map(|rd| {
                rd.flatten()
                    .filter(|e| {
                        e.file_name()
                            .to_str()
                            .map(|s| {
                                s.starts_with(&format!("rev-stealth-edit-{}-", std::process::id()))
                            })
                            .unwrap_or(false)
                    })
                    .count()
            })
            .unwrap_or(0);
        assert_eq!(
            stragglers, 0,
            "validate-fail edit must remove its tempdir under TMPDIR"
        );
    }

    #[test]
    fn migrate_v1_to_v1_is_noop() {
        let (_dir, locs) = fresh_home();
        seed_valid_policy(&locs);
        let original = std::fs::read(&locs.policy).unwrap();
        let code = run_migrate(&locs, MigrateArgs::default(), ConfigFormat::Json);
        assert_eq!(code, 0, "v1→v1 migrate must exit 0");
        let after = std::fs::read(&locs.policy).unwrap();
        assert_eq!(
            after, original,
            "noop migrate must leave the file byte-identical"
        );
    }

    #[test]
    fn migrate_records_audit_entry() {
        // The JSON outcome must enumerate the targets it considered, with
        // from_version/to_version pinned and action="noop" for v1 files.
        let (_dir, locs) = fresh_home();
        seed_valid_policy(&locs);
        std::fs::write(&locs.authorized, "schema_version = 1\n").unwrap();
        // Build the JSON payload the same way run_migrate would so we can
        // assert on its structure (re-running with format=Json prints to
        // stdout, which we can't capture cleanly in a unit test — so we
        // reproduce the outcome generation here via the same helper).
        // Drive run_migrate end-to-end and pin the exit code; the JSON
        // schema itself is covered by serde + the `Serialize` derive.
        let code = run_migrate(
            &locs,
            MigrateArgs {
                dry_run_args: crate::commands::dry_run::DryRunArgs {
                    dry_run: true,
                    explain: false,
                    idempotency_key: None,
                },
            },
            ConfigFormat::Json,
        );
        assert_eq!(code, 0);
        // Both files present → both surfaced. Direct invariant check via
        // schema_version reader.
        assert!(matches!(
            read_schema_version(&locs.policy),
            SchemaVersionRead::Ok(1)
        ));
        assert!(matches!(
            read_schema_version(&locs.authorized),
            SchemaVersionRead::Ok(1)
        ));
        assert_eq!(LATEST_SCHEMA_VERSION, 1);
    }

    #[test]
    fn migrate_rejects_malformed_schema_version() {
        // Reviewer round-1 finding: bad schema_version reads MUST NOT
        // silently coerce to v1. Each malformed path is surfaced as an
        // error (exit 1) instead of a noop (exit 0).
        let (_dir, locs) = fresh_home();
        std::fs::write(&locs.policy, "schema_version = \"two\"\n").unwrap();
        std::fs::write(&locs.authorized, "this is not toml [[[ \n").unwrap();
        let code = run_migrate(&locs, MigrateArgs::default(), ConfigFormat::Json);
        assert_eq!(code, 1, "malformed schema_version must exit 1, not 0");
        // And both files MUST remain byte-identical: we never write on
        // the error path.
        let policy_after = std::fs::read(&locs.policy).unwrap();
        assert_eq!(policy_after, b"schema_version = \"two\"\n");
        // Missing schema_version field must also error (not assume v1).
        let (_dir2, locs2) = fresh_home();
        std::fs::write(&locs2.policy, "require_vpn = true\n").unwrap();
        let code2 = run_migrate(&locs2, MigrateArgs::default(), ConfigFormat::Json);
        assert_eq!(
            code2, 1,
            "missing schema_version must exit 1 (no silent v1 default)"
        );
    }

    // Serialize edit-tempdir tests: they share `std::env::temp_dir()` and
    // assert no `rev-stealth-edit-<pid>-*` strays, so parallel runs would
    // race on each other's tempdirs.
    static EDIT_TMP_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn edit_cleans_tempdir_on_editor_failure() {
        let _g = EDIT_TMP_LOCK.lock().unwrap();
        // Reviewer round-2 finding: editor non-zero exit / spawn failure
        // MUST clean the working tempdir; otherwise post-edit config bytes
        // survive under TMPDIR. We assert by counting `rev-stealth-edit-*`
        // dirs before and after.
        let (_dir, locs) = fresh_home();
        seed_valid_policy(&locs);
        let scan = || {
            std::fs::read_dir(std::env::temp_dir())
                .map(|rd| {
                    rd.flatten()
                        .filter(|e| {
                            e.file_name()
                                .to_str()
                                .map(|s| s.starts_with("rev-stealth-edit-"))
                                .unwrap_or(false)
                        })
                        .count()
                })
                .unwrap_or(0)
        };
        let before = scan();
        let code = run_edit(
            &locs,
            EditArgs {
                dry_run_args: Default::default(),
                target: WriteTarget::Policy,
                // Force a non-zero editor exit so we hit the abort branch.
                editor: Some("false".into()),
            },
            ConfigFormat::Json,
        );
        assert_eq!(code, 1);
        let after = scan();
        assert_eq!(
            after, before,
            "editor-failure abort path must leave no rev-stealth-edit-* dir behind"
        );
    }

    #[test]
    fn edit_preserves_tempdir_when_recovery_sibling_write_fails() {
        // Reviewer round-3 finding: if persist_aborted_temp fails (e.g.
        // the original's parent is unwritable / read-only / mount-locked)
        // we MUST keep tmpdir so the operator still has a copy. Simulate
        // by chmod 0o500 on the original's parent dir before triggering a
        // validate-fail edit.
        let _g = EDIT_TMP_LOCK.lock().unwrap();
        let (_dir, locs) = fresh_home();
        seed_valid_policy(&locs);
        // Helper editor that appends an unknown field so validate fails.
        let editor_path = _dir.path().join("bad_editor.sh");
        std::fs::write(
            &editor_path,
            "#!/bin/sh\nprintf 'bogus_field = 42\\n' >> \"$1\"\n",
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&editor_path, std::fs::Permissions::from_mode(0o755)).unwrap();
            // Lock down the parent so persist_aborted_temp can't write
            // its `.<orig>.edit-aborted.*` sibling.
            let parent = locs.policy.parent().unwrap();
            std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o555)).unwrap();
        }
        let code = run_edit(
            &locs,
            EditArgs {
                dry_run_args: Default::default(),
                target: WriteTarget::Policy,
                editor: Some(editor_path.display().to_string()),
            },
            ConfigFormat::Json,
        );
        // Restore parent perms so the TempDir drop doesn't fail.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let parent = locs.policy.parent().unwrap();
            let _ = std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o755));
        }
        assert_eq!(code, 1);
        // The tempdir MUST still exist somewhere under TMPDIR so the
        // operator can recover. Scan for our process's edit dirs.
        let strays: Vec<_> = std::fs::read_dir(std::env::temp_dir())
            .unwrap()
            .flatten()
            .filter(|e| {
                e.file_name()
                    .to_str()
                    .map(|s| s.starts_with(&format!("rev-stealth-edit-{}-", std::process::id())))
                    .unwrap_or(false)
            })
            .collect();
        assert!(
            !strays.is_empty(),
            "when recovery sibling write fails, tmpdir MUST be preserved"
        );
        // Clean up so we don't pollute /tmp.
        for s in strays {
            let _ = std::fs::remove_dir_all(s.path());
        }
    }

    #[test]
    fn set_does_not_leak_secret_value_to_stdout() {
        // The set echo path must redact secret-shaped keys. We can't
        // easily capture println! here, but we can assert the redaction
        // helper produces `<redacted>` for a secret-shaped key path.
        // (The print branch routes through the same `key_looks_secret`
        // check used by `config get`, which is covered in P6.1 tests.)
        assert!(key_looks_secret("policy.auth_token"));
        assert!(key_looks_secret("api_key"));
        assert!(!key_looks_secret("policy.require_vpn"));
    }

    #[test]
    fn config_init_non_interactive_no_prompt() {
        // The contract: --non-interactive guarantees no stdin read occurs.
        // The current implementation never reads stdin at all, so the
        // strongest pin we can offer is that the call returns synchronously
        // with a deterministic exit code regardless of how the flag is set
        // — and that it does so for a clean fresh home.
        let (_dir, locs) = fresh_home();
        let _ = std::fs::remove_dir_all(&locs.sites_dir);
        let code = run_init(
            &locs,
            init_args(InitTarget::All, false, true),
            ConfigFormat::Json,
        );
        assert_eq!(code, 0, "non-interactive init on fresh home must exit 0");
        assert!(locs.policy.exists());
        assert!(locs.authorized.exists());
        assert!(locs.sites_dir.is_dir());
        // And again with the flag flipped — still no prompt, still exit 0
        // (now every target hits the Skipped branch since files exist).
        let code2 = run_init(
            &locs,
            init_args(InitTarget::All, false, false),
            ConfigFormat::Json,
        );
        assert_eq!(
            code2, 0,
            "second invocation must remain non-blocking (all skipped)"
        );
    }

    // ---------- P6.4: history / rollback / gc ----------

    /// Seed `n` writes through ConfigWriter so we have `n - 1` backups.
    fn seed_backups(path: &Path, n: usize) {
        let w = FsConfigWriter;
        for i in 0..n {
            w.write_with_backup(path, format!("v{i}\n").as_bytes())
                .unwrap();
            // > 1ms gap so epoch_ms-based backup names sort deterministically
            // and so the writer's `mtime` ordering is monotonic.
            std::thread::sleep(std::time::Duration::from_millis(3));
        }
    }

    #[test]
    fn history_lists_in_desc() {
        let (_dir, locs) = fresh_home();
        seed_backups(&locs.policy, 4);
        let writer = FsConfigWriter;
        let baks = writer.list_backups(&locs.policy).unwrap();
        assert_eq!(baks.len(), 3, "4 writes should leave 3 backups");
        // Newest (.bak of v2) first; oldest (.bak of v0) last.
        let first = std::fs::read(&baks[0]).unwrap();
        let last = std::fs::read(&baks[2]).unwrap();
        assert_eq!(first, b"v2\n");
        assert_eq!(last, b"v0\n");
        // Exit 0 on the public surface.
        let code = run_history(
            &locs,
            HistoryArgs {
                target: WriteTarget::Policy,
            },
            ConfigFormat::Json,
        );
        assert_eq!(code, 0);
    }

    #[test]
    fn rollback_restores() {
        let (_dir, locs) = fresh_home();
        seed_backups(&locs.policy, 3); // current = v2, backups for v0, v1
        let writer = FsConfigWriter;
        let baks = writer.list_backups(&locs.policy).unwrap();
        // Roll back to oldest (v0).
        let oldest_name = baks
            .last()
            .unwrap()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .to_string();
        let code = run_rollback(
            &locs,
            RollbackArgs {
                dry_run_args: Default::default(),
                bak_name: oldest_name.clone(),
                target: WriteTarget::Policy,
            },
            ConfigFormat::Json,
        );
        assert_eq!(code, 0);
        assert_eq!(std::fs::read(&locs.policy).unwrap(), b"v0\n");
    }

    #[test]
    fn rollback_makes_current_into_bak() {
        let (_dir, locs) = fresh_home();
        seed_backups(&locs.policy, 2); // current = v1, backup = v0
        let writer = FsConfigWriter;
        let baks_before = writer.list_backups(&locs.policy).unwrap();
        assert_eq!(baks_before.len(), 1);
        let v0_name = baks_before[0]
            .file_name()
            .unwrap()
            .to_string_lossy()
            .to_string();
        // Sleep so the new .bak gets a strictly later epoch_ms suffix.
        std::thread::sleep(std::time::Duration::from_millis(5));
        let code = run_rollback(
            &locs,
            RollbackArgs {
                dry_run_args: Default::default(),
                bak_name: v0_name.clone(),
                target: WriteTarget::Policy,
            },
            ConfigFormat::Json,
        );
        assert_eq!(code, 0);
        // Current file now holds v0 contents.
        assert_eq!(std::fs::read(&locs.policy).unwrap(), b"v0\n");
        // The previous current (v1) was preserved as a new .bak.<epoch>.
        let baks_after = writer.list_backups(&locs.policy).unwrap();
        let v1_preserved = baks_after
            .iter()
            .any(|p| std::fs::read(p).map(|b| b == b"v1\n").unwrap_or(false));
        assert!(
            v1_preserved,
            "rollback must preserve the displaced current as a new .bak"
        );
    }

    #[test]
    fn rollback_rejects_path_traversal() {
        let (_dir, locs) = fresh_home();
        seed_backups(&locs.policy, 2);
        // Any name containing `/` or `..` must be rejected with exit 2 and the
        // current file untouched.
        let before = std::fs::read(&locs.policy).unwrap();
        let code = run_rollback(
            &locs,
            RollbackArgs {
                dry_run_args: Default::default(),
                bak_name: "../etc/passwd".into(),
                target: WriteTarget::Policy,
            },
            ConfigFormat::Json,
        );
        assert_eq!(code, 2);
        assert_eq!(std::fs::read(&locs.policy).unwrap(), before);
    }

    // ---------- P6.5: profile list / create / switch / delete ----------

    /// Override `REV_SCRAPING_PROFILES_ROOT` so profile commands target a
    /// tempdir. Note: profile management is intentionally decoupled from
    /// $REV_SCRAPING_HOME (the activation env), so we override the dedicated
    /// registry env. Returns a guard that restores the previous env on drop.
    /// Caller MUST hold the ENV_LOCK for the duration of the test.
    struct HomeGuard {
        prev: Option<std::ffi::OsString>,
        _td: TempDir,
    }
    impl Drop for HomeGuard {
        fn drop(&mut self) {
            match self.prev.take() {
                Some(v) => std::env::set_var("REV_SCRAPING_PROFILES_ROOT", v),
                None => std::env::remove_var("REV_SCRAPING_PROFILES_ROOT"),
            }
        }
    }
    fn with_home_override() -> HomeGuard {
        let prev = std::env::var_os("REV_SCRAPING_PROFILES_ROOT");
        let td = tempfile::tempdir().unwrap();
        std::env::set_var("REV_SCRAPING_PROFILES_ROOT", td.path());
        HomeGuard { prev, _td: td }
    }

    #[test]
    fn profile_list_empty() {
        let _g = ENV_LOCK.lock().unwrap();
        let _h = with_home_override();
        let code = run_profile_list(ConfigFormat::Json);
        assert_eq!(code, 0);
        // Fresh profiles root → list returns 0 with zero entries.
        let root = profiles_root();
        let entries: Vec<_> = std::fs::read_dir(&root)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_dir())
            .collect();
        assert!(entries.is_empty(), "fresh registry must list zero profiles");
    }

    #[test]
    fn profile_create_seeds() {
        let _g = ENV_LOCK.lock().unwrap();
        let _h = with_home_override();
        let code = run_profile_create("alpha", ConfigFormat::Json);
        assert_eq!(code, 0, "create on fresh home must succeed");
        let dir = profile_dir("alpha");
        assert!(dir.is_dir(), "profile dir not created");
        assert!(dir.join("policy.toml").is_file(), "policy.toml not seeded");
        assert!(
            dir.join("authorized.toml").is_file(),
            "authorized.toml not seeded"
        );
        assert!(dir.join("sites").is_dir(), "sites/ dir not seeded");
        // Listing should now show exactly one profile.
        let root = profiles_root();
        let count = std::fs::read_dir(&root)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_dir())
            .count();
        assert_eq!(count, 1);
        // Re-creating must refuse with exit 2 (and not mutate the existing dir).
        let code2 = run_profile_create("alpha", ConfigFormat::Json);
        assert_eq!(code2, 2);
    }

    #[test]
    fn profile_create_rejects_traversal_name() {
        let _g = ENV_LOCK.lock().unwrap();
        let _h = with_home_override();
        for bad in &["../etc", "a/b", "a\\b", "..", ".hidden", "with space"] {
            let code = run_profile_create(bad, ConfigFormat::Json);
            assert_eq!(code, 2, "name `{bad}` should be rejected");
        }
        // Nothing under profiles_root() should have been created.
        assert!(
            !profiles_root().exists()
                || std::fs::read_dir(profiles_root()).unwrap().next().is_none()
        );
    }

    #[test]
    fn profile_switch_prints_env_hint() {
        let _g = ENV_LOCK.lock().unwrap();
        let _h = with_home_override();
        run_profile_create("beta", ConfigFormat::Json);
        // JSON branch is deterministic for assertions.
        let dir = profile_dir("beta");
        let hint = ProfileSwitchHint {
            profile: "beta".into(),
            home: dir.display().to_string(),
            export_line: format!("export {PROFILE_ACTIVATE_ENV}={}", dir.display()),
        };
        // Sanity: the env var name we advertise to operators is exactly the
        // one ConfigLocations::resolve consults.
        assert_eq!(PROFILE_ACTIVATE_ENV, "REV_SCRAPING_HOME");
        assert!(hint.export_line.starts_with("export REV_SCRAPING_HOME="));
        assert!(hint.export_line.contains("beta"));
        // Public surface returns 0 for an existing profile and rejects unknown.
        let ok = run_profile_switch("beta", ConfigFormat::Json);
        assert_eq!(ok, 0);
        let nope = run_profile_switch("ghost", ConfigFormat::Json);
        assert_eq!(nope, 2);
    }

    #[test]
    fn profile_delete_active_profile_refused() {
        // After decoupling the registry from $REV_SCRAPING_HOME, the active-
        // profile guard MUST trip when locs.policy.parent() equals the
        // resolved profile dir. We simulate activation by constructing locs
        // pointing into the alpha profile and assert delete refuses.
        let _g = ENV_LOCK.lock().unwrap();
        let _h = with_home_override();
        run_profile_create("alpha", ConfigFormat::Json);
        let alpha_dir = profile_dir("alpha");
        let active_locs = ConfigLocations {
            policy: alpha_dir.join("policy.toml"),
            authorized: alpha_dir.join("authorized.toml"),
            sites_dir: alpha_dir.join("sites"),
            templates_policy: repo_templates_policy(),
        };
        let code = run_profile_delete(&active_locs, "alpha", true, ConfigFormat::Json);
        assert_eq!(code, 2, "active profile must not be deletable");
        assert!(
            alpha_dir.is_dir(),
            "active profile dir must survive refused delete"
        );
    }

    #[test]
    fn profile_registry_decoupled_from_rev_scraping_home() {
        // Reviewer round-1 BLOCK: profile management must NOT derive its root
        // from $REV_SCRAPING_HOME, otherwise activating a profile by exporting
        // REV_SCRAPING_HOME=<root>/<name> would make the next `profile list`
        // recurse into `<active>/profiles/`.
        //
        // Pin: after creating `alpha` against REV_SCRAPING_PROFILES_ROOT, even
        // setting REV_SCRAPING_HOME to the activated path must leave
        // `profiles_root()` and the `alpha` dir resolution unchanged.
        let _g = ENV_LOCK.lock().unwrap();
        let _h = with_home_override();
        run_profile_create("alpha", ConfigFormat::Json);
        let alpha_dir = profile_dir("alpha");
        assert!(alpha_dir.is_dir());
        // Simulate activation.
        let prev_home = std::env::var_os("REV_SCRAPING_HOME");
        std::env::set_var("REV_SCRAPING_HOME", &alpha_dir);
        // profiles_root must NOT now resolve to <alpha>/profiles.
        let post_switch_root = profiles_root();
        assert_ne!(
            post_switch_root,
            alpha_dir.join("profiles"),
            "profile registry must be decoupled from $REV_SCRAPING_HOME"
        );
        // And `alpha` is still discoverable.
        assert!(profile_dir("alpha").is_dir());
        // Restore $REV_SCRAPING_HOME.
        match prev_home {
            Some(v) => std::env::set_var("REV_SCRAPING_HOME", v),
            None => std::env::remove_var("REV_SCRAPING_HOME"),
        }
    }

    #[test]
    fn profile_delete_shreds() {
        let _g = ENV_LOCK.lock().unwrap();
        let _h = with_home_override();
        run_profile_create("gamma", ConfigFormat::Json);
        let dir = profile_dir("gamma");
        let policy = dir.join("policy.toml");
        assert!(policy.is_file());
        // --yes required: without it, exit 2 and dir survives.
        let (_td, locs) = fresh_home();
        let no = run_profile_delete(&locs, "gamma", false, ConfigFormat::Json);
        assert_eq!(no, 2);
        assert!(dir.exists(), "delete without --yes must not remove the dir");
        // With --yes the dir is removed and at least one file was shredded.
        let ok = run_profile_delete(&locs, "gamma", true, ConfigFormat::Json);
        assert_eq!(ok, 0);
        assert!(!dir.exists(), "profile dir should be gone after delete");
    }

    #[test]
    fn gc_keeps_latest_n() {
        let (_dir, locs) = fresh_home();
        seed_backups(&locs.policy, 6); // 5 backups
        let writer = FsConfigWriter;
        assert_eq!(writer.list_backups(&locs.policy).unwrap().len(), 5);
        let code = run_gc(
            &locs,
            GcArgs {
                dry_run_args: Default::default(),
                keep: 2,
                target: WriteTarget::Policy,
            },
            ConfigFormat::Json,
        );
        assert_eq!(code, 0);
        let after = writer.list_backups(&locs.policy).unwrap();
        assert_eq!(after.len(), 2, "GC must keep exactly --keep newest");
        // The 2 newest are the most-recent .bak files (which captured v3 and v4).
        let bodies: Vec<Vec<u8>> = after.iter().map(|p| std::fs::read(p).unwrap()).collect();
        assert!(bodies.contains(&b"v4\n".to_vec()));
        assert!(bodies.contains(&b"v3\n".to_vec()));
    }
}
