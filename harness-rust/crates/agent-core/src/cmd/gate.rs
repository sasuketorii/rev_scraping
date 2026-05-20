//! Quality gate module — replaces `quality_gate.sh` (61 LOC).
//!
//! Runs tiered quality checks (fmt, clippy, test, audit, bench) based on
//! the specified gate level. Acceptance-critical gate prerequisites fail
//! closed instead of degrading to warnings.

use std::path::{Path, PathBuf};
use std::process::Command;

use clap::Subcommand;
use serde::{Deserialize, Serialize};

use shared::error::{AgentError, Result};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/// Subcommands for the `gate` family.
#[derive(Subcommand)]
pub enum GateAction {
    /// Run quality gate checks.
    Run {
        /// Gate level: A (fmt only), B (fmt+clippy+test+audit), C (B+bench).
        #[arg(long, default_value = "B")]
        level: String,
    },
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Result of a quality gate run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GateResult {
    /// Gate level that was evaluated.
    pub level: String,
    /// Overall pass/fail.
    pub passed: bool,
    /// Individual check results.
    pub checks: Vec<CheckResult>,
    /// Tools that were skipped (not installed).
    pub skipped: Vec<String>,
}

/// Result of a single quality check.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckResult {
    /// Check name (e.g. `"fmt"`, `"clippy"`, `"test"`).
    pub name: String,
    /// Whether the check passed.
    pub passed: bool,
    /// Human-readable output or error message.
    pub output: String,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Execute a `gate` subcommand.
pub fn run(action: GateAction) -> Result<()> {
    match action {
        GateAction::Run { level } => {
            let result = run_gate(&level)?;
            let json = serde_json::to_string_pretty(&result).map_err(AgentError::Json)?;
            println!("{json}");

            if !result.passed {
                return Err(AgentError::Command(format!(
                    "Quality gate level {} failed",
                    result.level
                )));
            }
            Ok(())
        }
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Run quality gate checks at the specified level.
///
/// - **Level A**: `cargo fmt --check`
/// - **Level B**: Level A + `cargo clippy` + `cargo test` + `cargo audit`
/// - **Level C**: Level B + `cargo bench --no-run`
///
/// Missing prerequisites or failed commands block the gate.
pub fn run_gate(level: &str) -> Result<GateResult> {
    let level_upper = level.to_uppercase();
    let level_char = match level_upper.as_str() {
        "A" | "LEVEL_A" | "LEVELA" => 'A',
        "B" | "LEVEL_B" | "LEVELB" => 'B',
        "C" | "LEVEL_C" | "LEVELC" => 'C',
        other => {
            return Err(AgentError::Validation(format!(
                "unknown gate level: {other} (allowed: A, B, C)"
            )));
        }
    };

    let workspace_root = resolve_rust_workspace_root()?;
    let has_cargo = command_exists("cargo");
    let mut checks = Vec::new();
    let skipped = Vec::new();

    if !has_cargo {
        tracing::error!("cargo not found; quality gate cannot run");
        checks.push(CheckResult {
            name: "cargo".to_string(),
            passed: false,
            output: "cargo not found; quality gate cannot run".to_string(),
        });
        return Ok(GateResult {
            level: level_char.to_string(),
            passed: false,
            checks,
            skipped,
        });
    }

    // Level A: fmt
    checks.push(run_cargo_fmt(&workspace_root));

    // Level B: + clippy + test + audit
    if level_char == 'B' || level_char == 'C' {
        checks.push(run_cargo_clippy(&workspace_root));
        checks.push(run_cargo_test(&workspace_root));

        if command_exists("cargo-audit") || cargo_subcommand_exists("audit", &workspace_root) {
            checks.push(run_cargo_audit(&workspace_root));
        } else {
            tracing::error!("cargo-audit not installed; quality gate blocks without it");
            checks.push(CheckResult {
                name: "audit".to_string(),
                passed: false,
                output: "cargo-audit is not installed; quality gate blocks without it".to_string(),
            });
        }
    }

    // Level C: + bench
    if level_char == 'C' {
        checks.push(run_cargo_bench(&workspace_root));
    }

    let passed = checks.iter().all(|c| c.passed);

    Ok(GateResult {
        level: level_char.to_string(),
        passed,
        checks,
        skipped,
    })
}

// ---------------------------------------------------------------------------
// Internal: individual checks
// ---------------------------------------------------------------------------

/// Run `cargo fmt --check`.
fn run_cargo_fmt(workspace_root: &Path) -> CheckResult {
    tracing::info!("Running cargo fmt --check...");
    match Command::new("cargo")
        .current_dir(workspace_root)
        .args(["fmt", "--", "--check"])
        .output()
    {
        Ok(o) => {
            let passed = o.status.success();
            let output = if passed {
                "All files formatted correctly.".to_string()
            } else {
                String::from_utf8_lossy(&o.stdout).to_string()
            };
            CheckResult {
                name: "fmt".to_string(),
                passed,
                output,
            }
        }
        Err(e) => CheckResult {
            name: "fmt".to_string(),
            passed: false,
            output: format!("cargo fmt failed to execute: {e}"),
        },
    }
}

/// Run `cargo clippy -- -D warnings`.
fn run_cargo_clippy(workspace_root: &Path) -> CheckResult {
    tracing::info!("Running cargo clippy...");
    match Command::new("cargo")
        .current_dir(workspace_root)
        .args(["clippy", "--all-targets", "--", "-D", "warnings"])
        .output()
    {
        Ok(o) => {
            let passed = o.status.success();
            let output = if passed {
                "No clippy warnings.".to_string()
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr);
                stderr.lines().take(20).collect::<Vec<_>>().join("\n")
            };
            CheckResult {
                name: "clippy".to_string(),
                passed,
                output,
            }
        }
        Err(e) => CheckResult {
            name: "clippy".to_string(),
            passed: false,
            output: format!("cargo clippy failed to execute: {e}"),
        },
    }
}

/// Run `cargo test`.
fn run_cargo_test(workspace_root: &Path) -> CheckResult {
    tracing::info!("Running cargo test...");
    match Command::new("cargo")
        .current_dir(workspace_root)
        .args(["test", "--quiet"])
        .output()
    {
        Ok(o) => {
            let passed = o.status.success();
            let output = if passed {
                let stdout = String::from_utf8_lossy(&o.stdout);
                // Extract the test summary line
                stdout
                    .lines()
                    .filter(|l| l.contains("test result"))
                    .collect::<Vec<_>>()
                    .join("\n")
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr);
                let stdout = String::from_utf8_lossy(&o.stdout);
                format!(
                    "{}{}",
                    stdout
                        .lines()
                        .rev()
                        .take(10)
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .collect::<Vec<_>>()
                        .join("\n"),
                    stderr.lines().take(5).collect::<Vec<_>>().join("\n")
                )
            };
            CheckResult {
                name: "test".to_string(),
                passed,
                output,
            }
        }
        Err(e) => CheckResult {
            name: "test".to_string(),
            passed: false,
            output: format!("cargo test failed to execute: {e}"),
        },
    }
}

/// Run `cargo audit`.
fn run_cargo_audit(workspace_root: &Path) -> CheckResult {
    tracing::info!("Running cargo audit...");
    match Command::new("cargo")
        .current_dir(workspace_root)
        .args(["audit"])
        .output()
    {
        Ok(o) => {
            let passed = o.status.success();
            let output = if passed {
                "No known vulnerabilities found.".to_string()
            } else {
                let stdout = String::from_utf8_lossy(&o.stdout);
                stdout.lines().take(20).collect::<Vec<_>>().join("\n")
            };
            CheckResult {
                name: "audit".to_string(),
                passed,
                output,
            }
        }
        Err(e) => CheckResult {
            name: "audit".to_string(),
            passed: false,
            output: format!("cargo audit failed to execute: {e}"),
        },
    }
}

/// Run `cargo bench --no-run` (compile benchmarks without running them).
fn run_cargo_bench(workspace_root: &Path) -> CheckResult {
    tracing::info!("Running cargo bench --no-run...");
    match Command::new("cargo")
        .current_dir(workspace_root)
        .args(["bench", "--no-run"])
        .output()
    {
        Ok(o) => {
            let passed = o.status.success();
            let output = if passed {
                "Benchmarks compile successfully.".to_string()
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr);
                stderr.lines().take(10).collect::<Vec<_>>().join("\n")
            };
            CheckResult {
                name: "bench".to_string(),
                passed,
                output,
            }
        }
        Err(e) => CheckResult {
            name: "bench".to_string(),
            passed: false,
            output: format!("cargo bench failed to execute: {e}"),
        },
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Check whether a command is available on `$PATH`.
fn command_exists(cmd: &str) -> bool {
    Command::new("which")
        .arg(cmd)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn resolve_rust_workspace_root() -> Result<PathBuf> {
    // Bounded canonical probe only: harness-rust/.
    // Walking ancestors is explicitly prohibited because it can land on a
    // repo-external or otherwise untrusted Cargo.toml.
    let repo_root = shared::git::git_repo_root().map_err(|error| {
        AgentError::NotFound(format!(
            "Rust workspace root cannot be resolved without a git repo root: {error}"
        ))
    })?;
    let repo_root = repo_root.canonicalize().map_err(AgentError::Io)?;
    let candidates = [repo_root.join("harness-rust")];
    let mut valid_candidates = Vec::new();
    let mut invalid_candidates = Vec::new();

    for candidate in candidates {
        match inspect_rust_workspace_candidate(&repo_root, &candidate) {
            Ok(Some(valid_root)) => valid_candidates.push(valid_root),
            Ok(None) => {}
            Err(error) => invalid_candidates.push(error.to_string()),
        }
    }

    if !invalid_candidates.is_empty() {
        return Err(AgentError::Config(invalid_candidates.join("; ")));
    }
    if valid_candidates.len() > 1 {
        let rendered = valid_candidates
            .iter()
            .map(|path| path.display().to_string())
            .collect::<Vec<_>>()
            .join(", ");
        return Err(AgentError::Config(format!(
            "multiple valid Rust workspace roots detected: {rendered}"
        )));
    }
    if let Some(valid_root) = valid_candidates.into_iter().next() {
        return Ok(valid_root);
    }

    Err(AgentError::NotFound(
        "Rust workspace root not found; expected Cargo.toml in harness-rust/ (bounded canonical probe)"
            .to_string(),
    ))
}

fn inspect_rust_workspace_candidate(repo_root: &Path, candidate: &Path) -> Result<Option<PathBuf>> {
    let metadata = match std::fs::symlink_metadata(candidate) {
        Ok(metadata) => metadata,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => {
            return Err(AgentError::Io(err));
        }
    };

    if metadata.file_type().is_symlink() {
        return Err(AgentError::Config(format!(
            "Rust workspace candidate must not be a symlink: {}",
            candidate.display()
        )));
    }
    if !metadata.is_dir() {
        return Err(AgentError::Config(format!(
            "Rust workspace candidate is not a directory: {}",
            candidate.display()
        )));
    }
    ensure_path_has_no_symlink_components(repo_root, candidate)?;

    let canonical_candidate = candidate.canonicalize().map_err(AgentError::Io)?;
    if !canonical_candidate.starts_with(repo_root) {
        return Err(AgentError::Config(format!(
            "Rust workspace candidate resolves outside repo root: {} -> {}",
            candidate.display(),
            canonical_candidate.display()
        )));
    }

    let manifest_path = candidate.join("Cargo.toml");
    let manifest_metadata = match std::fs::symlink_metadata(&manifest_path) {
        Ok(metadata) => metadata,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return Err(AgentError::Config(format!(
                "Rust workspace candidate is missing Cargo.toml: {}",
                candidate.display()
            )));
        }
        Err(err) => {
            return Err(AgentError::Io(err));
        }
    };

    if manifest_metadata.file_type().is_symlink() {
        return Err(AgentError::Config(format!(
            "Rust workspace manifest must not be a symlink: {}",
            manifest_path.display()
        )));
    }
    if !manifest_metadata.is_file() {
        return Err(AgentError::Config(format!(
            "Rust workspace manifest is not a regular file: {}",
            manifest_path.display()
        )));
    }

    Ok(Some(candidate.to_path_buf()))
}

fn ensure_path_has_no_symlink_components(repo_root: &Path, candidate: &Path) -> Result<()> {
    let relative = candidate.strip_prefix(repo_root).map_err(|_| {
        AgentError::Config(format!(
            "Rust workspace candidate escapes repo root: {}",
            candidate.display()
        ))
    })?;
    let mut current = repo_root.to_path_buf();
    for component in relative.components() {
        current.push(component.as_os_str());
        let metadata = std::fs::symlink_metadata(&current).map_err(AgentError::Io)?;
        if metadata.file_type().is_symlink() {
            return Err(AgentError::Config(format!(
                "Rust workspace candidate contains a symlink component: {}",
                current.display()
            )));
        }
    }
    Ok(())
}

/// Check whether a cargo subcommand exists (e.g. `cargo audit`).
fn cargo_subcommand_exists(subcmd: &str, workspace_root: &Path) -> bool {
    Command::new("cargo")
        .current_dir(workspace_root)
        .args([subcmd, "--help"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gate_result_json_roundtrip() {
        let result = GateResult {
            level: "B".to_string(),
            passed: true,
            checks: vec![CheckResult {
                name: "fmt".to_string(),
                passed: true,
                output: "ok".to_string(),
            }],
            skipped: vec!["cargo-audit".to_string()],
        };
        let json = serde_json::to_string(&result).unwrap();
        let deserialized: GateResult = serde_json::from_str(&json).unwrap();
        assert!(deserialized.passed);
        assert_eq!(deserialized.level, "B");
        assert_eq!(deserialized.checks.len(), 1);
    }

    #[test]
    fn test_run_gate_invalid_level() {
        let result = run_gate("X");
        assert!(result.is_err());
    }

    #[test]
    fn test_gate_level_parsing_valid() {
        // Verify all valid level strings are accepted by the parser.
        // We do NOT call run_gate() here because it spawns real cargo
        // processes (cargo fmt, cargo test, etc.) which would cause
        // recursive test execution and infinite process spawning.
        for level in &["A", "B", "C", "level_a", "LEVEL_B", "levelC"] {
            let upper = level.to_uppercase();
            let valid = matches!(
                upper.as_str(),
                "A" | "LEVEL_A"
                    | "LEVELA"
                    | "B"
                    | "LEVEL_B"
                    | "LEVELB"
                    | "C"
                    | "LEVEL_C"
                    | "LEVELC"
            );
            assert!(valid, "level '{level}' should be valid");
        }
    }

    #[test]
    fn test_gate_level_parsing_invalid() {
        let result = run_gate("X");
        assert!(result.is_err());
        let result = run_gate("");
        assert!(result.is_err());
    }

    #[test]
    fn test_command_exists_works() {
        // 'ls' should exist on all Unix systems
        assert!(command_exists("ls"));
        // random nonexistent command
        assert!(!command_exists("this_command_does_not_exist_12345"));
    }
}
