// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.2.0 (P7.3 — `rev-stealth hermes`).
//! `rev-stealth hermes {install, uninstall, verify}`.
//!
//! Operator-facing wrapper around the Hermes plugin scaffold shipped in
//! `dist/hermes/rev-scraping-mcp/`. The subcommand:
//!
//! * `install` — recursive copy of the scaffold into the Hermes plugin
//!   directory (default `$HOME/.hermes/plugins/rev-scraping-mcp`;
//!   override with `--prefix <dir>`). Refuses to overwrite a non-empty
//!   target unless `--force` is set.
//! * `uninstall` — remove the plugin directory; refuses if `plugin.yaml`
//!   is missing (we will not delete an unrelated dir).
//! * `verify` — assert `plugin.yaml` and `__init__.py` exist at the
//!   install location and (when possible) probe `python3 -c "import
//!   ast; ast.parse(open(...).read())"` to confirm the entrypoint is
//!   syntactically valid.
//!
//! The scaffold source defaults to `<repo>/dist/hermes/rev-scraping-mcp`
//! relative to `CARGO_MANIFEST_DIR`. Operators running the released
//! binary can override with `--source <dir>` to point at the installed
//! data path (downstream packagers can wire this however they like).

use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

use clap::{Args, Subcommand};
use serde_json::json;

use crate::OutputFormat;

/// Top-level args for `rev-stealth hermes`.
#[derive(Args, Debug, Clone)]
pub struct HermesArgs {
    /// v1.3 Lane G.4: per-subcommand `--output-format` override of the
    /// global `--format`. JSON schema: `docs/json-schemas/cli/hermes.output.json`.
    #[command(flatten)]
    pub output_format: crate::commands::output_format::OutputFormatOverride,
    #[command(subcommand)]
    pub action: HermesAction,
}

/// Subcommands for `rev-stealth hermes`.
#[derive(Subcommand, Debug, Clone)]
pub enum HermesAction {
    /// Install the Hermes plugin scaffold into `<prefix>`.
    #[command(
        long_about = "Install the bundled Hermes MCP plugin scaffold into <prefix> \
(default: $HOME/.hermes/plugins/rev-scraping-mcp). --source overrides the \
scaffold origin. --force overwrites a non-empty destination.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth hermes install\n  \
$ rev-stealth hermes install --prefix /opt/hermes/plugins/rev-scraping-mcp\n  \
$ rev-stealth hermes install --force --source ./dist/hermes/rev-scraping-mcp\n\n\
EXIT CODES:\n  \
0  Ok               Install completed.\n  \
1  UserError        Destination non-empty (use --force) / bad --source.\n  \
3  PermanentError   scaffold IO failure.\n\n\
ENV:\n  \
(none consumed directly; respects HOME for default --prefix.)"
    )]
    Install(InstallArgs),
    /// Remove a previously installed Hermes plugin.
    #[command(
        long_about = "Remove a previously installed Hermes plugin directory at \
<prefix> (default: $HOME/.hermes/plugins/rev-scraping-mcp). No-op if the \
directory is absent.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth hermes uninstall\n  \
$ rev-stealth hermes uninstall --prefix /opt/hermes/plugins/rev-scraping-mcp\n\n\
EXIT CODES:\n  \
0  Ok               Uninstall completed (or no-op).\n  \
1  UserError        Bad --prefix.\n  \
3  PermanentError   directory IO failure.\n\n\
ENV:\n  \
(none consumed directly; respects HOME for default --prefix.)"
    )]
    Uninstall(UninstallArgs),
    /// Verify a Hermes plugin install on disk.
    #[command(
        long_about = "Verify a Hermes plugin install on disk. Checks the required \
files are present and (by default) runs a python3 ast.parse syntax probe on \
__init__.py. Use --skip-python-check on hosts without python3.",
        after_help = "EXAMPLES:\n  \
$ rev-stealth hermes verify\n  \
$ rev-stealth hermes verify --prefix /opt/hermes/plugins/rev-scraping-mcp\n  \
$ rev-stealth hermes verify --skip-python-check\n\n\
EXIT CODES:\n  \
0  Ok               Plugin verified.\n  \
1  UserError        Bad --prefix.\n  \
3  PermanentError   Required files missing or python3 ast.parse failed.\n\n\
ENV:\n  \
(none consumed directly; respects HOME for default --prefix.)"
    )]
    Verify(VerifyArgs),
}

#[derive(Args, Debug, Clone)]
pub struct InstallArgs {
    /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
    #[command(flatten)]
    pub dry_run_args: crate::commands::dry_run::DryRunArgs,
    /// Destination directory. Defaults to `$HOME/.hermes/plugins/rev-scraping-mcp`.
    #[arg(long)]
    pub prefix: Option<PathBuf>,

    /// Override the scaffold source directory (defaults to the
    /// `dist/hermes/rev-scraping-mcp` shipped with the repo).
    #[arg(long)]
    pub source: Option<PathBuf>,

    /// Overwrite an existing non-empty destination.
    #[arg(long, default_value_t = false)]
    pub force: bool,
}

#[derive(Args, Debug, Clone)]
pub struct UninstallArgs {
    /// v1.3 Lane G.5: `--dry-run` / `--explain` / `--idempotency-key`.
    #[command(flatten)]
    pub dry_run_args: crate::commands::dry_run::DryRunArgs,
    /// Plugin directory to remove. Defaults to
    /// `$HOME/.hermes/plugins/rev-scraping-mcp`.
    #[arg(long)]
    pub prefix: Option<PathBuf>,
}

#[derive(Args, Debug, Clone)]
pub struct VerifyArgs {
    /// Plugin directory to verify. Defaults to
    /// `$HOME/.hermes/plugins/rev-scraping-mcp`.
    #[arg(long)]
    pub prefix: Option<PathBuf>,

    /// Skip the `python3 -c "import ast; ast.parse(...)"` syntax probe
    /// of `__init__.py`. The probe runs by default; pass this flag in
    /// environments without `python3` on `$PATH` (minimal containers,
    /// CI workers without the Python toolchain).
    #[arg(long, default_value_t = false, alias = "no-python-check")]
    pub skip_python_check: bool,
}

impl VerifyArgs {
    /// Whether the verify path should run the `python3` syntax probe.
    pub fn python_check_enabled(&self) -> bool {
        !self.skip_python_check
    }
}

/// Files that any valid install must contain. The verify path checks
/// these unconditionally; missing files yield a structured error.
const REQUIRED_FILES: &[&str] = &[
    "plugin.yaml",
    "__init__.py",
    "mcp_client.py",
    "lifecycle.py",
    "tool_proxy.py",
    "schema_bridge.py",
];

/// Default plugin directory name (the dash-form Hermes expects).
const PLUGIN_DIR_NAME: &str = "rev-scraping-mcp";

pub async fn run(format: OutputFormat, args: HermesArgs) -> i32 {
    match args.action {
        HermesAction::Install(a) => {
            if a.dry_run_args.is_dry_run() {
                return crate::commands::dry_run::emit_dry_run(
                    format,
                    "hermes.install",
                    &[
                        "resolve destination prefix",
                        "resolve scaffold source directory",
                        "verify source exists",
                        "check destination empty (or --force)",
                        "recursive copy scaffold to prefix",
                    ],
                    &a.dry_run_args,
                );
            }
            // v1.3 Lane G.6: idempotent commit hook.
            let key = a.dry_run_args.idempotency_key.clone();
            let payload = crate::commands::idempotency::payload_value(
                "hermes.install",
                [
                    (
                        "prefix",
                        json!(a.prefix.as_ref().map(|p| p.display().to_string())),
                    ),
                    (
                        "source",
                        json!(a.source.as_ref().map(|p| p.display().to_string())),
                    ),
                    ("force", json!(a.force)),
                ],
            );
            let store = crate::commands::idempotency::IdempotencyStore::from_env_or_default();
            if let Some((_h, env)) = crate::commands::idempotency::maybe_replay(
                &store,
                "hermes.install",
                key.as_deref(),
                &payload,
            ) {
                return crate::commands::idempotency::emit_replay(format, "hermes.install", &env);
            }
            match install(&a) {
                Ok(report) => {
                    let exit = emit_ok(format, "install", &report);
                    if exit == 0 {
                        let envelope = json!({
                            "kind": "hermes",
                            "action": "install",
                            "status": "ok",
                            "report": &report,
                        });
                        crate::commands::idempotency::record_success(
                            &store,
                            "hermes.install",
                            key.as_deref(),
                            &payload,
                            &envelope,
                        );
                    }
                    exit
                }
                Err(e) => emit_err(format, "install", &e),
            }
        }
        HermesAction::Uninstall(a) => {
            if a.dry_run_args.is_dry_run() {
                return crate::commands::dry_run::emit_dry_run(
                    format,
                    "hermes.uninstall",
                    &[
                        "resolve destination prefix",
                        "verify prefix is a valid rev-scraping-mcp install",
                        "recursive remove plugin directory",
                    ],
                    &a.dry_run_args,
                );
            }
            let key = a.dry_run_args.idempotency_key.clone();
            let payload = crate::commands::idempotency::payload_value(
                "hermes.uninstall",
                [(
                    "prefix",
                    json!(a.prefix.as_ref().map(|p| p.display().to_string())),
                )],
            );
            let store = crate::commands::idempotency::IdempotencyStore::from_env_or_default();
            if let Some((_h, env)) = crate::commands::idempotency::maybe_replay(
                &store,
                "hermes.uninstall",
                key.as_deref(),
                &payload,
            ) {
                return crate::commands::idempotency::emit_replay(format, "hermes.uninstall", &env);
            }
            match uninstall(&a) {
                Ok(report) => {
                    let exit = emit_ok(format, "uninstall", &report);
                    if exit == 0 {
                        let envelope = json!({
                            "kind": "hermes",
                            "action": "uninstall",
                            "status": "ok",
                            "report": &report,
                        });
                        crate::commands::idempotency::record_success(
                            &store,
                            "hermes.uninstall",
                            key.as_deref(),
                            &payload,
                            &envelope,
                        );
                    }
                    exit
                }
                Err(e) => emit_err(format, "uninstall", &e),
            }
        }
        HermesAction::Verify(a) => match verify(&a) {
            Ok(report) => emit_ok(format, "verify", &report),
            Err(e) => emit_err(format, "verify", &e),
        },
    }
}

/// Structured per-action report. Kept narrow so JSON output is stable.
#[derive(Debug, serde::Serialize)]
pub struct HermesReport {
    pub prefix: PathBuf,
    pub source: Option<PathBuf>,
    pub files_copied: usize,
    pub python_check_ok: Option<bool>,
}

#[derive(Debug, thiserror::Error)]
pub enum HermesError {
    #[error("home directory not found; pass --prefix explicitly")]
    HomeUnavailable,
    #[error("scaffold source not found at {0}")]
    SourceMissing(PathBuf),
    #[error("destination {0} is not empty (pass --force to overwrite)")]
    DestNotEmpty(PathBuf),
    #[error("install dir {0} missing required file {1}")]
    MissingRequired(PathBuf, String),
    #[error("install dir {0} does not look like a rev-scraping-mcp install (no plugin.yaml)")]
    NotAnInstall(PathBuf),
    #[error("python3 syntax check failed: {0}")]
    PythonCheck(String),
    #[error("io error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

// ---------------------------------------------------------------- install

/// Resolve the default Hermes prefix `<home>/.hermes/plugins/rev-scraping-mcp`.
pub fn default_prefix() -> Result<PathBuf, HermesError> {
    let home = std::env::var_os("HOME").ok_or(HermesError::HomeUnavailable)?;
    Ok(PathBuf::from(home)
        .join(".hermes")
        .join("plugins")
        .join(PLUGIN_DIR_NAME))
}

/// Default scaffold source path inside the repo.
pub fn default_source() -> PathBuf {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    PathBuf::from(manifest_dir)
        .parent() // crates/
        .and_then(Path::parent) // workspace root
        .map(|root| root.join("dist").join("hermes").join(PLUGIN_DIR_NAME))
        .unwrap_or_else(|| {
            PathBuf::from(manifest_dir)
                .join("../../dist/hermes")
                .join(PLUGIN_DIR_NAME)
        })
}

fn install(args: &InstallArgs) -> Result<HermesReport, HermesError> {
    let prefix = args.prefix.clone().map_or_else(default_prefix, Ok)?;
    let source = args.source.clone().unwrap_or_else(default_source);

    if !source.is_dir() {
        return Err(HermesError::SourceMissing(source));
    }
    // Empty-or-absent target gate.
    if prefix.exists() {
        let is_empty = match fs::read_dir(&prefix) {
            Ok(mut it) => it.next().is_none(),
            Err(e) => {
                return Err(HermesError::Io {
                    path: prefix.clone(),
                    source: e,
                });
            }
        };
        if !is_empty && !args.force {
            return Err(HermesError::DestNotEmpty(prefix));
        }
        if !is_empty && args.force {
            remove_recursive(&prefix)?;
        }
    }
    fs::create_dir_all(&prefix).map_err(|e| HermesError::Io {
        path: prefix.clone(),
        source: e,
    })?;

    let copied = copy_recursive(&source, &prefix)?;
    Ok(HermesReport {
        prefix,
        source: Some(source),
        files_copied: copied,
        python_check_ok: None,
    })
}

// ---------------------------------------------------------------- uninstall

fn uninstall(args: &UninstallArgs) -> Result<HermesReport, HermesError> {
    let prefix = args.prefix.clone().map_or_else(default_prefix, Ok)?;
    if !prefix.exists() {
        return Err(HermesError::NotAnInstall(prefix));
    }
    // Refuse to delete a dir that is not actually a plugin install.
    if !prefix.join("plugin.yaml").is_file() {
        return Err(HermesError::NotAnInstall(prefix));
    }
    remove_recursive(&prefix)?;
    Ok(HermesReport {
        prefix,
        source: None,
        files_copied: 0,
        python_check_ok: None,
    })
}

// ---------------------------------------------------------------- verify

fn verify(args: &VerifyArgs) -> Result<HermesReport, HermesError> {
    let prefix = args.prefix.clone().map_or_else(default_prefix, Ok)?;
    if !prefix.is_dir() {
        return Err(HermesError::NotAnInstall(prefix));
    }
    for required in REQUIRED_FILES {
        let p = prefix.join(required);
        if !p.is_file() {
            return Err(HermesError::MissingRequired(
                prefix.clone(),
                (*required).to_string(),
            ));
        }
    }

    let python_check_ok = if args.python_check_enabled() {
        Some(python_syntax_ok(&prefix.join("__init__.py"))?)
    } else {
        None
    };

    Ok(HermesReport {
        prefix,
        source: None,
        files_copied: REQUIRED_FILES.len(),
        python_check_ok,
    })
}

// ---------------------------------------------------------------- helpers

/// Recursive copy. Returns the number of regular files copied.
fn copy_recursive(src: &Path, dst: &Path) -> Result<usize, HermesError> {
    let mut count = 0usize;
    let entries = fs::read_dir(src).map_err(|e| HermesError::Io {
        path: src.to_path_buf(),
        source: e,
    })?;
    for entry in entries {
        let entry = entry.map_err(|e| HermesError::Io {
            path: src.to_path_buf(),
            source: e,
        })?;
        let file_type = entry.file_type().map_err(|e| HermesError::Io {
            path: entry.path(),
            source: e,
        })?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        // Skip __pycache__ / *.pyc dev artifacts.
        if from.file_name() == Some(OsStr::new("__pycache__")) {
            continue;
        }
        if file_type.is_dir() {
            fs::create_dir_all(&to).map_err(|e| HermesError::Io {
                path: to.clone(),
                source: e,
            })?;
            count += copy_recursive(&from, &to)?;
        } else if file_type.is_file() {
            fs::copy(&from, &to).map_err(|e| HermesError::Io {
                path: to.clone(),
                source: e,
            })?;
            count += 1;
        }
        // Symlinks and other entry types are intentionally skipped.
    }
    Ok(count)
}

fn remove_recursive(p: &Path) -> Result<(), HermesError> {
    fs::remove_dir_all(p).map_err(|e| HermesError::Io {
        path: p.to_path_buf(),
        source: e,
    })
}

fn python_syntax_ok(path: &Path) -> Result<bool, HermesError> {
    let path_str = path.to_string_lossy().into_owned();
    let script = format!(
        "import ast,sys; ast.parse(open({:?},'r',encoding='utf-8').read()); sys.exit(0)",
        path_str
    );
    let output = match Command::new("python3").arg("-c").arg(&script).output() {
        Ok(o) => o,
        Err(e) => {
            // python3 not on PATH — treat as non-fatal "not checked".
            // The verify path opts into this; we surface as a soft error.
            return Err(HermesError::PythonCheck(format!(
                "python3 not available ({}); pass --no-python-check to skip",
                e
            )));
        }
    };
    if output.status.success() {
        Ok(true)
    } else {
        Err(HermesError::PythonCheck(
            String::from_utf8_lossy(&output.stderr).trim().to_string(),
        ))
    }
}

// ---------------------------------------------------------------- output

fn emit_ok(format: OutputFormat, action: &str, report: &HermesReport) -> i32 {
    match format {
        OutputFormat::Json => {
            let payload = json!({
                "kind": "hermes",
                "action": action,
                "status": "ok",
                "report": report,
            });
            println!("{}", payload);
        }
        OutputFormat::Human => {
            println!("hermes {}: ok", action);
            println!("  prefix:        {}", report.prefix.display());
            if let Some(s) = &report.source {
                println!("  source:        {}", s.display());
            }
            println!("  files_copied:  {}", report.files_copied);
            if let Some(ok) = report.python_check_ok {
                println!("  python_check:  {}", if ok { "ok" } else { "failed" });
            }
        }
    }
    0
}

fn emit_err(format: OutputFormat, action: &str, err: &HermesError) -> i32 {
    match format {
        OutputFormat::Json => {
            let payload = json!({
                "kind": "hermes",
                "action": action,
                "status": "error",
                "error": err.to_string(),
            });
            eprintln!("{}", payload);
        }
        OutputFormat::Human => {
            eprintln!("hermes {} failed: {}", action, err);
        }
    }
    1
}

// ====================================================================
// Tests
// ====================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn fixture_scaffold() -> TempDir {
        let dir = TempDir::new().unwrap();
        let root = dir.path();
        fs::write(root.join("plugin.yaml"), "name: rev-scraping-mcp\n").unwrap();
        fs::write(
            root.join("__init__.py"),
            "def register(ctx):\n    return {}\n",
        )
        .unwrap();
        fs::write(root.join("mcp_client.py"), "# stub\n").unwrap();
        fs::write(root.join("lifecycle.py"), "# stub\n").unwrap();
        fs::write(root.join("tool_proxy.py"), "# stub\n").unwrap();
        fs::write(root.join("schema_bridge.py"), "REDACTED='<redacted>'\n").unwrap();
        fs::create_dir_all(root.join("tests")).unwrap();
        fs::write(root.join("tests").join("__init__.py"), "").unwrap();
        dir
    }

    #[test]
    fn install_happy_path_copies_required_files() {
        let scaffold = fixture_scaffold();
        let dest_root = TempDir::new().unwrap();
        let dest = dest_root.path().join("plugin");
        let args = InstallArgs {
            dry_run_args: Default::default(),
            prefix: Some(dest.clone()),
            source: Some(scaffold.path().to_path_buf()),
            force: false,
        };
        let report = install(&args).expect("install ok");
        assert!(report.files_copied >= REQUIRED_FILES.len());
        for required in REQUIRED_FILES {
            assert!(dest.join(required).is_file(), "missing {required}");
        }
        assert!(dest.join("tests").join("__init__.py").is_file());
    }

    #[test]
    fn install_refuses_non_empty_dest_without_force() {
        let scaffold = fixture_scaffold();
        let dest_root = TempDir::new().unwrap();
        let dest = dest_root.path().join("plugin");
        fs::create_dir_all(&dest).unwrap();
        fs::write(dest.join("pre-existing.txt"), "x").unwrap();
        let args = InstallArgs {
            dry_run_args: Default::default(),
            prefix: Some(dest.clone()),
            source: Some(scaffold.path().to_path_buf()),
            force: false,
        };
        let err = install(&args).unwrap_err();
        match err {
            HermesError::DestNotEmpty(p) => assert_eq!(p, dest),
            other => panic!("expected DestNotEmpty, got {other:?}"),
        }
    }

    #[test]
    fn install_force_overwrites_existing_dir() {
        let scaffold = fixture_scaffold();
        let dest_root = TempDir::new().unwrap();
        let dest = dest_root.path().join("plugin");
        fs::create_dir_all(&dest).unwrap();
        fs::write(dest.join("stale.txt"), "old").unwrap();
        let args = InstallArgs {
            dry_run_args: Default::default(),
            prefix: Some(dest.clone()),
            source: Some(scaffold.path().to_path_buf()),
            force: true,
        };
        install(&args).expect("install ok");
        assert!(!dest.join("stale.txt").exists());
        assert!(dest.join("plugin.yaml").is_file());
    }

    #[test]
    fn install_rejects_missing_source() {
        let dest_root = TempDir::new().unwrap();
        let missing = dest_root.path().join("nope");
        let args = InstallArgs {
            dry_run_args: Default::default(),
            prefix: Some(dest_root.path().join("plugin")),
            source: Some(missing.clone()),
            force: false,
        };
        let err = install(&args).unwrap_err();
        match err {
            HermesError::SourceMissing(p) => assert_eq!(p, missing),
            other => panic!("expected SourceMissing, got {other:?}"),
        }
    }

    #[test]
    fn uninstall_happy_path_removes_install() {
        let scaffold = fixture_scaffold();
        let dest_root = TempDir::new().unwrap();
        let dest = dest_root.path().join("plugin");
        install(&InstallArgs {
            dry_run_args: Default::default(),
            prefix: Some(dest.clone()),
            source: Some(scaffold.path().to_path_buf()),
            force: false,
        })
        .unwrap();
        let report = uninstall(&UninstallArgs {
            dry_run_args: Default::default(),
            prefix: Some(dest.clone()),
        })
        .expect("uninstall ok");
        assert_eq!(report.prefix, dest);
        assert!(!dest.exists());
    }

    #[test]
    fn uninstall_rejects_non_install_dir() {
        let dest_root = TempDir::new().unwrap();
        let dest = dest_root.path().join("not-a-plugin");
        fs::create_dir_all(&dest).unwrap();
        fs::write(dest.join("random.txt"), "x").unwrap();
        let err = uninstall(&UninstallArgs {
            dry_run_args: Default::default(),
            prefix: Some(dest.clone()),
        })
        .unwrap_err();
        match err {
            HermesError::NotAnInstall(p) => assert_eq!(p, dest),
            other => panic!("expected NotAnInstall, got {other:?}"),
        }
    }

    #[test]
    fn uninstall_rejects_missing_dir() {
        let dest_root = TempDir::new().unwrap();
        let dest = dest_root.path().join("nope");
        let err = uninstall(&UninstallArgs {
            dry_run_args: Default::default(),
            prefix: Some(dest.clone()),
        })
        .unwrap_err();
        match err {
            HermesError::NotAnInstall(p) => assert_eq!(p, dest),
            other => panic!("expected NotAnInstall, got {other:?}"),
        }
    }

    #[test]
    fn verify_happy_path_no_python_check() {
        let scaffold = fixture_scaffold();
        let dest_root = TempDir::new().unwrap();
        let dest = dest_root.path().join("plugin");
        install(&InstallArgs {
            dry_run_args: Default::default(),
            prefix: Some(dest.clone()),
            source: Some(scaffold.path().to_path_buf()),
            force: false,
        })
        .unwrap();
        let report = verify(&VerifyArgs {
            prefix: Some(dest.clone()),
            skip_python_check: true,
        })
        .expect("verify ok");
        assert_eq!(report.prefix, dest);
        assert_eq!(report.python_check_ok, None);
    }

    #[test]
    fn verify_detects_missing_required_file() {
        let scaffold = fixture_scaffold();
        let dest_root = TempDir::new().unwrap();
        let dest = dest_root.path().join("plugin");
        install(&InstallArgs {
            dry_run_args: Default::default(),
            prefix: Some(dest.clone()),
            source: Some(scaffold.path().to_path_buf()),
            force: false,
        })
        .unwrap();
        fs::remove_file(dest.join("schema_bridge.py")).unwrap();
        let err = verify(&VerifyArgs {
            prefix: Some(dest.clone()),
            skip_python_check: true,
        })
        .unwrap_err();
        match err {
            HermesError::MissingRequired(p, name) => {
                assert_eq!(p, dest);
                assert_eq!(name, "schema_bridge.py");
            }
            other => panic!("expected MissingRequired, got {other:?}"),
        }
    }

    #[test]
    fn cli_parses_skip_python_check_and_alias() {
        // Pin the clap contract: both `--skip-python-check` and the
        // documented `--no-python-check` alias parse without error, and
        // both set `skip_python_check=true` (i.e. python_check_enabled()
        // returns false). Regression test for the round-1 P7.3
        // reviewer's `--python-check=false` finding.
        use clap::Parser;

        #[derive(Parser, Debug)]
        struct Probe {
            #[command(subcommand)]
            cmd: ProbeCmd,
        }
        #[derive(clap::Subcommand, Debug)]
        enum ProbeCmd {
            Hermes(HermesArgs),
        }

        let parsed = Probe::try_parse_from([
            "rev-stealth",
            "hermes",
            "verify",
            "--skip-python-check",
            "--prefix",
            "/tmp/p",
        ])
        .expect("--skip-python-check must parse");
        match parsed.cmd {
            ProbeCmd::Hermes(h) => match h.action {
                HermesAction::Verify(v) => {
                    assert!(v.skip_python_check);
                    assert!(!v.python_check_enabled());
                }
                other => panic!("expected Verify, got {other:?}"),
            },
        }

        let parsed = Probe::try_parse_from([
            "rev-stealth",
            "hermes",
            "verify",
            "--no-python-check",
            "--prefix",
            "/tmp/p",
        ])
        .expect("--no-python-check alias must parse");
        match parsed.cmd {
            ProbeCmd::Hermes(h) => match h.action {
                HermesAction::Verify(v) => {
                    assert!(v.skip_python_check);
                    assert!(!v.python_check_enabled());
                }
                other => panic!("expected Verify, got {other:?}"),
            },
        }

        // Default: probe enabled.
        let parsed = Probe::try_parse_from(["rev-stealth", "hermes", "verify"]).unwrap();
        match parsed.cmd {
            ProbeCmd::Hermes(h) => match h.action {
                HermesAction::Verify(v) => {
                    assert!(!v.skip_python_check);
                    assert!(v.python_check_enabled());
                }
                other => panic!("expected Verify, got {other:?}"),
            },
        }
    }

    #[test]
    fn verify_rejects_non_directory() {
        let dest_root = TempDir::new().unwrap();
        let dest = dest_root.path().join("nope");
        let err = verify(&VerifyArgs {
            prefix: Some(dest.clone()),
            skip_python_check: true,
        })
        .unwrap_err();
        match err {
            HermesError::NotAnInstall(p) => assert_eq!(p, dest),
            other => panic!("expected NotAnInstall, got {other:?}"),
        }
    }
}
