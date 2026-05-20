//! Shadow verification module — replaces `shadow_verify.sh` (1,865 LOC).
//!
//! Runs machine verification (lint, typecheck, test, SAST) **before** human
//! review. Acceptance-critical step failures are surfaced as blocking
//! findings instead of being silently ignored.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use harness_cache::{helpers as cache_helpers, CacheManager};
use clap::Subcommand;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use shared::error::{AgentError, Result};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/// Subcommands for the `verify` family.
#[derive(Subcommand)]
pub enum VerifyAction {
    /// Run shadow verification.
    Run {
        /// Orchestration phase name.
        #[arg(long)]
        phase: String,
        /// Path to the execution plan.
        #[arg(long)]
        plan: String,
        /// Path to write the verification report.
        #[arg(long)]
        output: String,
        /// Quality gate level (level_a / level_b / level_c).
        #[arg(long, default_value = "level_b")]
        gate_level: String,
    },
    /// Run verification loop with retry and escalation.
    Loop {
        /// Orchestration phase name.
        #[arg(long)]
        phase: String,
        /// Path to the execution plan.
        #[arg(long)]
        plan: String,
        /// Path to write the verification report.
        #[arg(long)]
        output: String,
        /// Maximum number of retry attempts.
        #[arg(long, default_value = "3")]
        max_retries: u32,
    },
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Result of a full shadow-verify run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerifyResult {
    /// Overall pass/fail/error/skipped.
    pub status: VerifyStatus,
    /// Quality gate level that was applied.
    pub gate_level: String,
    /// Individual findings from all tools.
    pub findings: Vec<VerifyFinding>,
    /// Unique run identifier.
    pub run_id: String,
    /// Wall-clock duration of the run, in seconds.
    pub duration_secs: u64,
    /// Languages that were auto-detected.
    pub languages_detected: Vec<String>,
    /// Deletion-guard impacts for removed files.
    pub deletion_impacts: Vec<DeletionImpact>,
}

/// Overall verification status.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum VerifyStatus {
    /// All checks passed at the requested gate level.
    Passed,
    /// One or more checks failed.
    Failed,
    /// A tool error prevented verification from completing.
    Error,
    /// Verification was skipped (e.g. no files changed).
    Skipped,
}

/// A single finding emitted by a verification tool.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerifyFinding {
    /// Tool name (e.g. `"eslint"`, `"clippy"`, `"pytest"`).
    pub tool: String,
    /// Severity label (`"error"`, `"warning"`, `"info"`).
    pub severity: String,
    /// Human-readable description.
    pub message: String,
    /// Source file, if applicable.
    pub file: Option<String>,
    /// Line number, if applicable.
    pub line: Option<u32>,
    /// Lint/check rule identifier, if applicable.
    pub rule: Option<String>,
}

/// Impact assessment for a deleted file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeletionImpact {
    /// Path of the deleted file.
    pub file: String,
    /// Category that triggered the guard.
    pub category: DeletionCategory,
    /// `"BLOCK"` or `"WARN"`.
    pub verdict: String,
}

/// Categories for the deletion guard.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeletionCategory {
    /// CI/build entry-points — deletion is a blocker.
    CiEntrypoint,
    /// Lock files, config, env — deletion is a warning.
    ConfigLock,
    /// Supported but non-primary language files — deletion is a warning.
    UnsupportedLang,
}

/// Quality gate strictness.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateLevel {
    /// Lint only (format check).
    A,
    /// Lint + typecheck + test + SAST (default).
    B,
    /// Level B + benchmarks.
    C,
}

// ---------------------------------------------------------------------------
// Constants — deletion guard patterns
// ---------------------------------------------------------------------------

/// Patterns that match CI / build entry-points.  Deletion → BLOCK.
const CI_ENTRYPOINT_PATTERNS: &[&str] = &[
    ".github/workflows/",
    "Makefile",
    "Dockerfile",
    "Jenkinsfile",
    "docker-compose",
    ".gitlab-ci",
    "Taskfile",
];

/// Patterns that match config / lock files.  Deletion → WARN.
const CONFIG_LOCK_PATTERNS: &[&str] = &[
    ".lock",
    ".toml",
    ".env",
    "tsconfig.json",
    "package.json",
    "Cargo.toml",
    "go.mod",
    "requirements.txt",
    "pyproject.toml",
];

/// File-scoped tools that participate in verify caching.
const FILE_LEVEL_TOOLS: &[&str] = &["eslint", "ruff", "shellcheck", "semgrep"];

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Execute a `verify` subcommand.
pub fn run(action: VerifyAction) -> Result<()> {
    match action {
        VerifyAction::Run {
            phase,
            plan,
            output,
            gate_level,
        } => {
            let result = shadow_verify_run(
                &phase,
                Path::new(&plan),
                Path::new(&output),
                &gate_level,
                None,
            )?;
            let json = serde_json::to_string_pretty(&result).map_err(AgentError::Json)?;
            println!("{json}");
            Ok(())
        }
        VerifyAction::Loop {
            phase,
            plan,
            output,
            max_retries,
        } => {
            let result = shadow_verify_loop(
                &phase,
                Path::new(&plan),
                Path::new(&output),
                max_retries,
                None,
            )?;
            let json = serde_json::to_string_pretty(&result).map_err(AgentError::Json)?;
            println!("{json}");
            Ok(())
        }
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Determine files changed relative to HEAD (staged + unstaged + untracked).
pub fn determine_changed_files() -> Result<Vec<PathBuf>> {
    let mut files: Vec<PathBuf> = Vec::new();

    // staged + unstaged
    if let Ok(diff) = shared::git::git_changed_files() {
        files.extend(diff.into_iter().map(PathBuf::from));
    }

    // untracked
    if let Ok(untracked) = shared::git::git_ls_files_untracked() {
        files.extend(untracked.into_iter().map(PathBuf::from));
    }

    // deduplicate
    files.sort();
    files.dedup();

    Ok(files)
}

/// Select test files that may be affected by the given source changes.
///
/// Heuristic: for each changed source file `src/foo/bar.ts`, look for
/// `test/foo/bar.test.ts`, `tests/foo/bar_test.py`, `src/foo/bar_test.rs`,
/// etc.
pub fn select_affected_tests(changed_files: &[PathBuf]) -> Result<Vec<PathBuf>> {
    let mut test_files: Vec<PathBuf> = Vec::new();

    for f in changed_files {
        let fname = match f.file_name().and_then(|n| n.to_str()) {
            Some(n) => n.to_string(),
            None => continue,
        };

        // Already a test file
        if is_test_file(&fname) {
            if f.exists() {
                test_files.push(f.clone());
            }
            continue;
        }

        // Try common test-file naming conventions
        let stem = match f.file_stem().and_then(|s| s.to_str()) {
            Some(s) => s.to_string(),
            None => continue,
        };
        let ext = f.extension().and_then(|e| e.to_str()).unwrap_or("");
        let parent = f.parent().unwrap_or(Path::new(""));

        let mut candidates: Vec<PathBuf> = vec![
            // JS/TS: foo.test.ts, foo.spec.ts
            parent.join(format!("{stem}.test.{ext}")),
            parent.join(format!("{stem}.spec.{ext}")),
            // Rust: foo_test.rs alongside foo.rs
            parent.join(format!("{stem}_test.{ext}")),
            // Python: test_foo.py
            parent.join(format!("test_{stem}.{ext}")),
        ];
        // Replace src/ with test/ or tests/
        if let Some(p) = replace_prefix(f, "src", "test") {
            candidates.push(p);
        }
        if let Some(p) = replace_prefix(f, "src", "tests") {
            candidates.push(p);
        }

        for c in candidates.into_iter() {
            if c.exists() && !test_files.contains(&c) {
                test_files.push(c);
            }
        }
    }

    test_files.sort();
    test_files.dedup();
    Ok(test_files)
}

/// Detect project languages based on file extensions.
pub fn detect_project_languages(files: &[PathBuf]) -> Vec<String> {
    let mut langs = std::collections::HashSet::new();

    for f in files {
        if let Some(ext) = f.extension().and_then(|e| e.to_str()) {
            match ext {
                "ts" | "tsx" | "mts" | "cts" => {
                    langs.insert("typescript".to_string());
                }
                "js" | "jsx" | "mjs" | "cjs" => {
                    langs.insert("javascript".to_string());
                }
                "rs" => {
                    langs.insert("rust".to_string());
                }
                "py" | "pyi" => {
                    langs.insert("python".to_string());
                }
                "go" => {
                    langs.insert("go".to_string());
                }
                "java" => {
                    langs.insert("java".to_string());
                }
                "rb" => {
                    langs.insert("ruby".to_string());
                }
                "sh" | "bash" => {
                    langs.insert("shell".to_string());
                }
                _ => {}
            }
        }
    }

    let mut result: Vec<String> = langs.into_iter().collect();
    result.sort();
    result
}

fn compute_file_hash(path: &Path) -> Result<String> {
    let bytes = std::fs::read(path).map_err(AgentError::Io)?;
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    Ok(hex::encode(hasher.finalize()))
}

fn normalize_cache_path(path: &Path, repo_root: &Path) -> Result<String> {
    let relative = path
        .strip_prefix(repo_root)
        .unwrap_or(path)
        .to_string_lossy()
        .to_string();
    cache_helpers::validate_and_normalize_path(&relative, repo_root)
}

fn is_tool_cacheable(tool: &str) -> bool {
    match tool {
        "ruff" => command_exists("ruff"),
        other => command_exists(other),
    }
}

fn file_level_tool_applicable(tool: &str, path: &Path) -> bool {
    let ext = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    match tool {
        "eslint" => matches!(
            ext.as_str(),
            "ts" | "tsx" | "mts" | "cts" | "js" | "jsx" | "mjs" | "cjs"
        ),
        "ruff" => matches!(ext.as_str(), "py" | "pyi"),
        "shellcheck" => matches!(ext.as_str(), "sh" | "bash"),
        "semgrep" => !ext.is_empty(),
        _ => false,
    }
}

fn run_file_level_tool(tool: &str, files: &[PathBuf]) -> Result<Vec<VerifyFinding>> {
    match tool {
        "eslint" => run_eslint(files),
        "ruff" => run_ruff_or_flake8(files),
        "shellcheck" => run_shellcheck(files),
        "semgrep" => run_semgrep(files),
        other => Err(AgentError::Validation(format!(
            "unsupported file-level tool: {other}"
        ))),
    }
}

fn parse_cached_verify_findings(json: &str) -> Result<Vec<VerifyFinding>> {
    serde_json::from_str(json).map_err(AgentError::Json)
}

fn verify_status_label(findings: &[VerifyFinding]) -> &'static str {
    if findings.iter().any(|finding| finding.severity == "error") {
        "failed"
    } else if findings.is_empty() {
        "passed"
    } else {
        "warning"
    }
}

fn verify_status_allows_progress(status: &VerifyStatus) -> bool {
    matches!(status, VerifyStatus::Passed | VerifyStatus::Skipped)
}

fn verify_step_failure(tool: &str, message: impl Into<String>) -> VerifyFinding {
    VerifyFinding {
        tool: tool.to_string(),
        severity: "error".to_string(),
        message: message.into(),
        file: None,
        line: None,
        rule: None,
    }
}

fn require_node_runner(tool: &str) -> Result<String> {
    require_node_runner_from(tool, resolve_node_runner())
}

fn require_node_runner_from(tool: &str, runner: Option<String>) -> Result<String> {
    runner.ok_or_else(|| AgentError::Command(format!("No Node runner found; cannot run {tool}")))
}

fn require_command_available(command: &str, purpose: &str) -> Result<()> {
    if command_exists(command) {
        Ok(())
    } else {
        Err(AgentError::Command(format!(
            "{command} not found; cannot run {purpose}"
        )))
    }
}

fn finalize_structured_tool_findings(
    tool: &str,
    output_format: &str,
    status_success: bool,
    findings: Vec<VerifyFinding>,
    output_excerpt: &str,
) -> Result<Vec<VerifyFinding>> {
    if status_success || !findings.is_empty() {
        Ok(findings)
    } else {
        Err(AgentError::Command(format!(
            "{tool} failed without parseable {output_format} findings: {output_excerpt}"
        )))
    }
}

fn map_parse_error(
    tool: &str,
    output_format: &str,
    error: AgentError,
    output_excerpt: &str,
) -> AgentError {
    AgentError::Command(format!(
        "{tool} emitted invalid {output_format}: {error}; {output_excerpt}"
    ))
}

fn group_findings_by_file(
    findings: &[VerifyFinding],
    repo_root: &Path,
) -> std::collections::HashMap<String, Vec<VerifyFinding>> {
    let mut grouped = std::collections::HashMap::new();

    for finding in findings {
        let Some(file) = &finding.file else {
            continue;
        };

        let normalized = cache_helpers::validate_and_normalize_path(file, repo_root)
            .unwrap_or_else(|_| file.replace('\\', "/"));
        grouped
            .entry(normalized)
            .or_insert_with(Vec::new)
            .push(finding.clone());
    }

    grouped
}

fn run_cached_file_level_tools(
    changed: &[PathBuf],
    repo_root: &Path,
    cache: &mut CacheManager,
) -> (Vec<VerifyFinding>, std::collections::HashSet<&'static str>) {
    let mut findings = Vec::new();
    let mut handled_tools = std::collections::HashSet::new();
    let mut file_hashes = std::collections::HashMap::new();

    for file in changed {
        if let Ok(normalized) = normalize_cache_path(file, repo_root) {
            if let Ok(hash) = compute_file_hash(file) {
                file_hashes.insert(normalized, hash);
            }
        }
    }

    for &tool in FILE_LEVEL_TOOLS {
        if !is_tool_cacheable(tool) {
            continue;
        }

        let mut pending: Vec<(PathBuf, String, String)> = Vec::new();
        let config_hash = cache_helpers::compute_config_hash(tool, repo_root);
        let tool_version = cache_helpers::get_tool_version(tool);

        for file in changed
            .iter()
            .filter(|file| file_level_tool_applicable(tool, file))
        {
            let Ok(normalized) = normalize_cache_path(file, repo_root) else {
                continue;
            };
            let Some(file_hash) = file_hashes.get(&normalized).cloned() else {
                continue;
            };

            match cache.check_verify(&normalized, &file_hash, tool, &config_hash, &tool_version) {
                Some(hit) => match parse_cached_verify_findings(&hit.findings) {
                    Ok(hit_findings) => findings.extend(hit_findings),
                    Err(e) => {
                        tracing::warn!(
                            tool,
                            file = %normalized,
                            error = %e,
                            "cached verify findings were invalid; treating as miss"
                        );
                        pending.push((file.clone(), normalized, file_hash));
                    }
                },
                None => {
                    if cache
                        .check_file_index(&normalized)
                        .map(|entry| entry.content_hash != file_hash)
                        .unwrap_or(false)
                    {
                        let _ = cache.invalidate_review_on_verify_miss();
                    }
                    pending.push((file.clone(), normalized, file_hash));
                }
            }
        }

        if pending.is_empty() {
            handled_tools.insert(tool);
            continue;
        }

        let pending_paths: Vec<PathBuf> = pending.iter().map(|(path, _, _)| path.clone()).collect();
        match run_file_level_tool(tool, &pending_paths) {
            Ok(tool_findings) => {
                let grouped = group_findings_by_file(&tool_findings, repo_root);
                for (_path, normalized, file_hash) in pending {
                    let file_findings = grouped.get(&normalized).cloned().unwrap_or_default();
                    let findings_json = match serde_json::to_string(&file_findings) {
                        Ok(value) => value,
                        Err(e) => {
                            tracing::warn!(
                                tool,
                                file = %normalized,
                                error = %e,
                                "failed to serialize verify findings for cache"
                            );
                            continue;
                        }
                    };

                    if let Err(e) = cache.store_verify(
                        &normalized,
                        &file_hash,
                        tool,
                        &config_hash,
                        &tool_version,
                        verify_status_label(&file_findings),
                        &findings_json,
                    ) {
                        tracing::warn!(
                            tool,
                            file = %normalized,
                            error = %e,
                            "failed to store verify cache entry"
                        );
                    }
                }

                findings.extend(tool_findings);
                handled_tools.insert(tool);
            }
            Err(e) => {
                tracing::warn!(tool, error = %e, "file-level tool cache path failed");
            }
        }
    }

    (findings, handled_tools)
}

/// Resolve the Node.js package runner.  Prefers `pnpm`, falls back to `npm`.
pub fn resolve_node_runner() -> Option<String> {
    if command_exists("pnpm") {
        Some("pnpm".to_string())
    } else if command_exists("npm") {
        Some("npm".to_string())
    } else {
        None
    }
}

/// Return `true` if `pytest` is available on `$PATH`.
pub fn has_pytest() -> bool {
    command_exists("pytest")
}

/// Run lint checks for the detected languages.
pub fn run_lint(
    languages: &[String],
    files: &[PathBuf],
    handled_tools: &std::collections::HashSet<&'static str>,
) -> Result<Vec<VerifyFinding>> {
    let mut findings = Vec::new();

    for lang in languages {
        match lang.as_str() {
            "typescript" | "javascript" => {
                if !handled_tools.contains("eslint") {
                    findings.extend(run_eslint(files)?);
                }
            }
            "rust" => {
                findings.extend(run_clippy()?);
            }
            "python" => {
                if !handled_tools.contains("ruff") {
                    findings.extend(run_ruff_or_flake8(files)?);
                }
            }
            "go" => {
                findings.extend(run_golint()?);
            }
            "shell" => {
                if !handled_tools.contains("shellcheck") {
                    findings.extend(run_shellcheck(files)?);
                }
            }
            _ => {
                tracing::info!("No linter configured for language: {lang}");
            }
        }
    }

    Ok(findings)
}

/// Run type checking for the detected languages.
pub fn run_typecheck(languages: &[String]) -> Result<Vec<VerifyFinding>> {
    let mut findings = Vec::new();

    for lang in languages {
        match lang.as_str() {
            "typescript" => {
                findings.extend(run_tsc()?);
            }
            "rust" => {
                findings.extend(run_cargo_check()?);
            }
            "python" => {
                findings.extend(run_mypy_or_pyright()?);
            }
            _ => {}
        }
    }

    Ok(findings)
}

/// Run tests for the detected languages, restricted to `test_files` when
/// possible.
pub fn run_tests(languages: &[String], test_files: &[PathBuf]) -> Result<Vec<VerifyFinding>> {
    let mut findings = Vec::new();

    for lang in languages {
        match lang.as_str() {
            "typescript" | "javascript" => {
                findings.extend(run_node_tests(test_files)?);
            }
            "rust" => {
                findings.extend(run_cargo_test()?);
            }
            "python" => {
                findings.extend(run_pytest(test_files)?);
            }
            "go" => {
                findings.extend(run_go_test()?);
            }
            _ => {}
        }
    }

    Ok(findings)
}

/// Run SAST analysis (Semgrep or CodeQL) if available.
pub fn run_sast(
    files: &[PathBuf],
    handled_tools: &std::collections::HashSet<&'static str>,
) -> Result<Vec<VerifyFinding>> {
    if handled_tools.contains("semgrep") {
        return Ok(Vec::new());
    }
    if command_exists("semgrep") {
        return run_semgrep(files);
    }
    if command_exists("codeql") {
        Err(AgentError::Command(
            "CodeQL detected but not yet integrated; SAST verification cannot proceed".to_string(),
        ))
    } else {
        Err(AgentError::Command(
            "No SAST tool found (semgrep/codeql); cannot verify changed files".to_string(),
        ))
    }
}

/// Normalize a gate-level string into the [`GateLevel`] enum.
pub fn normalize_gate_level(level: &str) -> Result<GateLevel> {
    match level.to_lowercase().replace('-', "_").as_str() {
        "a" | "level_a" | "levela" => Ok(GateLevel::A),
        "b" | "level_b" | "levelb" => Ok(GateLevel::B),
        "c" | "level_c" | "levelc" => Ok(GateLevel::C),
        other => Err(AgentError::Validation(format!(
            "unknown gate level: {other} (allowed: level_a / level_b / level_c)"
        ))),
    }
}

/// Main shadow-verify entry point.
///
/// 1. Determines changed files.
/// 2. Detects languages.
/// 3. Runs checks according to the gate level.
/// 4. Evaluates deletion guards.
/// 5. Writes the JSON report to `output`.
pub fn shadow_verify_run(
    phase: &str,
    plan: &Path,
    output: &Path,
    gate_level_str: &str,
    cache: Option<&mut CacheManager>,
) -> Result<VerifyResult> {
    let start = Instant::now();
    let run_id = uuid::Uuid::new_v4().to_string();
    let gate = normalize_gate_level(gate_level_str)?;
    let repo_root = shared::git::git_repo_root()?;

    tracing::info!(
        "shadow_verify_run: phase={phase}, plan={}, gate={gate_level_str}, run_id={run_id}",
        plan.display()
    );

    // 1. Determine changed files
    let changed = determine_changed_files()?;
    if changed.is_empty() {
        tracing::info!("No changed files detected; verification skipped");
        let result = VerifyResult {
            status: VerifyStatus::Skipped,
            gate_level: gate_level_str.to_string(),
            findings: Vec::new(),
            run_id,
            duration_secs: start.elapsed().as_secs(),
            languages_detected: Vec::new(),
            deletion_impacts: Vec::new(),
        };
        write_report(output, &result)?;
        return Ok(result);
    }

    // 2. Detect languages
    let languages = detect_project_languages(&changed);
    tracing::info!("Detected languages: {languages:?}");

    // 3. Deletion guard
    let deleted = detect_deleted_files();
    let deletion_impacts = analyze_non_code_deletions(&deleted);

    // 4. Run checks per gate level
    let mut findings = Vec::new();
    let mut handled_tools = std::collections::HashSet::new();

    if let Some(cache) = cache {
        let (cached_findings, cached_tools) =
            run_cached_file_level_tools(&changed, &repo_root, cache);
        findings.extend(cached_findings);
        handled_tools = cached_tools;
    }

    // Gate A: lint only
    match run_lint(&languages, &changed, &handled_tools) {
        Ok(f) => findings.extend(f),
        Err(e) => findings.push(verify_step_failure(
            "lint",
            format!("Lint step failed: {e}"),
        )),
    }

    if matches!(gate, GateLevel::B | GateLevel::C) {
        // Gate B: + typecheck + test + SAST
        match run_typecheck(&languages) {
            Ok(f) => findings.extend(f),
            Err(e) => findings.push(verify_step_failure(
                "typecheck",
                format!("Typecheck step failed: {e}"),
            )),
        }

        let test_files = match select_affected_tests(&changed) {
            Ok(files) => files,
            Err(e) => {
                findings.push(verify_step_failure(
                    "test_selection",
                    format!("Failed to select affected tests: {e}"),
                ));
                Vec::new()
            }
        };
        match run_tests(&languages, &test_files) {
            Ok(f) => findings.extend(f),
            Err(e) => findings.push(verify_step_failure(
                "test",
                format!("Test step failed: {e}"),
            )),
        }

        match run_sast(&changed, &handled_tools) {
            Ok(f) => findings.extend(f),
            Err(e) => findings.push(verify_step_failure(
                "sast",
                format!("SAST step failed: {e}"),
            )),
        }
    }

    if gate == GateLevel::C {
        // Gate C: + benchmarks
        match run_benchmarks(&languages) {
            Ok(f) => findings.extend(f),
            Err(e) => findings.push(verify_step_failure(
                "benchmark",
                format!("Benchmark step failed: {e}"),
            )),
        }
    }

    // 5. Determine status
    let has_errors = findings.iter().any(|f| f.severity == "error");
    let has_blockers = deletion_impacts.iter().any(|d| d.verdict == "BLOCK");
    let status = if has_errors || has_blockers {
        VerifyStatus::Failed
    } else {
        VerifyStatus::Passed
    };

    let result = VerifyResult {
        status,
        gate_level: gate_level_str.to_string(),
        findings,
        run_id,
        duration_secs: start.elapsed().as_secs(),
        languages_detected: languages,
        deletion_impacts,
    };

    write_report(output, &result)?;

    tracing::info!(
        "shadow_verify_run complete: status={:?}, findings={}, duration={}s",
        result.status,
        result.findings.len(),
        result.duration_secs,
    );

    Ok(result)
}

/// Verification loop with retry and escalation.
///
/// Runs [`shadow_verify_run`] up to `max_retries` times.  On persistent
/// failure the status is set to [`VerifyStatus::Error`] to signal
/// escalation.
pub fn shadow_verify_loop(
    phase: &str,
    plan: &Path,
    output: &Path,
    max_retries: u32,
    mut cache: Option<&mut CacheManager>,
) -> Result<VerifyResult> {
    let mut last_result: Option<VerifyResult> = None;

    for attempt in 1..=max_retries {
        tracing::info!("shadow_verify_loop: attempt {attempt}/{max_retries}");

        match shadow_verify_run(phase, plan, output, "level_b", cache.as_deref_mut()) {
            Ok(result) if verify_status_allows_progress(&result.status) => {
                tracing::info!(status = ?result.status, "Verification completed on attempt {attempt}");
                return Ok(result);
            }
            Ok(result) => {
                tracing::warn!(
                    status = ?result.status,
                    "Verification did not pass on attempt {attempt}: {} finding(s)",
                    result.findings.len()
                );
                last_result = Some(result);
            }
            Err(e) => {
                tracing::error!("Verification error on attempt {attempt}: {e}");
                last_result = Some(VerifyResult {
                    status: VerifyStatus::Error,
                    gate_level: "level_b".to_string(),
                    findings: vec![VerifyFinding {
                        tool: "shadow_verify".to_string(),
                        severity: "error".to_string(),
                        message: e.to_string(),
                        file: None,
                        line: None,
                        rule: None,
                    }],
                    run_id: uuid::Uuid::new_v4().to_string(),
                    duration_secs: 0,
                    languages_detected: Vec::new(),
                    deletion_impacts: Vec::new(),
                });
            }
        }
    }

    // Exhausted retries — escalate
    let mut result = last_result.unwrap_or(VerifyResult {
        status: VerifyStatus::Error,
        gate_level: "level_b".to_string(),
        findings: Vec::new(),
        run_id: uuid::Uuid::new_v4().to_string(),
        duration_secs: 0,
        languages_detected: Vec::new(),
        deletion_impacts: Vec::new(),
    });
    result.status = VerifyStatus::Error;
    tracing::error!("shadow_verify_loop: exhausted {max_retries} retries — escalating");
    write_report(output, &result)?;

    Ok(result)
}

/// Analyze non-code file deletions for potential impact.
pub fn analyze_non_code_deletions(deleted_files: &[String]) -> Vec<DeletionImpact> {
    let mut impacts = Vec::new();

    for file in deleted_files {
        // Check CI entry-points first (BLOCK)
        if CI_ENTRYPOINT_PATTERNS.iter().any(|pat| file.contains(pat)) {
            impacts.push(DeletionImpact {
                file: file.clone(),
                category: DeletionCategory::CiEntrypoint,
                verdict: "BLOCK".to_string(),
            });
            continue;
        }

        // Check config/lock patterns (WARN)
        if CONFIG_LOCK_PATTERNS.iter().any(|pat| file.contains(pat)) {
            impacts.push(DeletionImpact {
                file: file.clone(),
                category: DeletionCategory::ConfigLock,
                verdict: "WARN".to_string(),
            });
            continue;
        }

        // Check for supported-but-non-primary language files (WARN)
        let unsupported_exts = [".go", ".rs", ".java", ".rb", ".cs", ".swift"];
        if unsupported_exts.iter().any(|ext| file.ends_with(ext)) {
            impacts.push(DeletionImpact {
                file: file.clone(),
                category: DeletionCategory::UnsupportedLang,
                verdict: "WARN".to_string(),
            });
        }
    }

    impacts
}

// ---------------------------------------------------------------------------
// Internal: tool runners
// ---------------------------------------------------------------------------

/// Run ESLint on JS/TS files.
fn run_eslint(files: &[PathBuf]) -> Result<Vec<VerifyFinding>> {
    let runner = require_node_runner("ESLint")?;

    let ts_js_files: Vec<String> = files
        .iter()
        .filter(|f| {
            matches!(
                f.extension().and_then(|e| e.to_str()),
                Some("ts" | "tsx" | "js" | "jsx" | "mts" | "cts" | "mjs" | "cjs")
            )
        })
        .filter_map(|f| f.to_str().map(String::from))
        .collect();

    if ts_js_files.is_empty() {
        return Ok(Vec::new());
    }

    let mut args = vec!["eslint", "--format", "json"];
    let file_refs: Vec<&str> = ts_js_files.iter().map(|s| s.as_str()).collect();
    args.extend(file_refs);

    let output = Command::new(&runner)
        .args(["exec", "--"])
        .args(&args)
        .output()
        .map_err(|e| AgentError::Command(format!("ESLint failed to execute: {e}")))?;

    let findings = parse_eslint_output(&output.stdout)
        .map_err(|e| map_parse_error("ESLint", "JSON", e, &command_output_excerpt(&output)))?;

    finalize_structured_tool_findings(
        "ESLint",
        "JSON",
        output.status.success(),
        findings,
        &command_output_excerpt(&output),
    )
}

/// Parse ESLint JSON output into findings.
fn parse_eslint_output(stdout: &[u8]) -> Result<Vec<VerifyFinding>> {
    let text = String::from_utf8_lossy(stdout);
    let entries: Vec<serde_json::Value> = serde_json::from_str(&text).map_err(AgentError::Json)?;

    let mut findings = Vec::new();
    for entry in &entries {
        let file = entry["filePath"].as_str().map(String::from);
        if let Some(messages) = entry["messages"].as_array() {
            for msg in messages {
                let severity_num = msg["severity"].as_u64().unwrap_or(0);
                let severity = match severity_num {
                    2 => "error",
                    1 => "warning",
                    _ => "info",
                };
                findings.push(VerifyFinding {
                    tool: "eslint".to_string(),
                    severity: severity.to_string(),
                    message: msg["message"].as_str().unwrap_or("unknown").to_string(),
                    file: file.clone(),
                    line: msg["line"].as_u64().map(|n| n as u32),
                    rule: msg["ruleId"].as_str().map(String::from),
                });
            }
        }
    }
    Ok(findings)
}

/// Run `cargo clippy`.
fn run_clippy() -> Result<Vec<VerifyFinding>> {
    if !command_exists("cargo") {
        return Err(AgentError::Command(
            "cargo not found; cannot run cargo clippy".to_string(),
        ));
    }

    let workspace_root = resolve_rust_workspace_root()?;
    let output = Command::new("cargo")
        .current_dir(&workspace_root)
        .args(["clippy", "--message-format=json", "--", "-D", "warnings"])
        .output()
        .map_err(|e| AgentError::Command(format!("cargo clippy failed to execute: {e}")))?;

    let findings = parse_cargo_diagnostics(&output.stdout, "clippy")?;
    if output.status.success() || !findings.is_empty() {
        Ok(findings)
    } else {
        Err(AgentError::Command(format!(
            "cargo clippy failed: {}",
            command_output_excerpt(&output)
        )))
    }
}

/// Run `cargo check`.
fn run_cargo_check() -> Result<Vec<VerifyFinding>> {
    if !command_exists("cargo") {
        return Err(AgentError::Command(
            "cargo not found; cannot run cargo check".to_string(),
        ));
    }

    let workspace_root = resolve_rust_workspace_root()?;
    let output = Command::new("cargo")
        .current_dir(&workspace_root)
        .args(["check", "--message-format=json"])
        .output()
        .map_err(|e| AgentError::Command(format!("cargo check failed to execute: {e}")))?;

    let findings = parse_cargo_diagnostics(&output.stdout, "cargo_check")?;
    if output.status.success() || !findings.is_empty() {
        Ok(findings)
    } else {
        Err(AgentError::Command(format!(
            "cargo check failed: {}",
            command_output_excerpt(&output)
        )))
    }
}

/// Run `cargo test`.
fn run_cargo_test() -> Result<Vec<VerifyFinding>> {
    if !command_exists("cargo") {
        return Err(AgentError::Command(
            "cargo not found; cannot run cargo test".to_string(),
        ));
    }

    let workspace_root = resolve_rust_workspace_root()?;
    let output = Command::new("cargo")
        .current_dir(&workspace_root)
        .args(["test", "--quiet"])
        .output()
        .map_err(|e| AgentError::Command(format!("cargo test failed to execute: {e}")))?;

    if output.status.success() {
        Ok(Vec::new())
    } else {
        Ok(vec![VerifyFinding {
            tool: "cargo_test".to_string(),
            severity: "error".to_string(),
            message: format!("cargo test failed: {}", command_output_excerpt(&output)),
            file: None,
            line: None,
            rule: None,
        }])
    }
}

/// Parse cargo JSON diagnostics (shared by clippy and cargo check).
fn parse_cargo_diagnostics(stdout: &[u8], tool_name: &str) -> Result<Vec<VerifyFinding>> {
    let text = String::from_utf8_lossy(stdout);
    let mut findings = Vec::new();

    for line in text.lines() {
        let parsed: std::result::Result<serde_json::Value, _> = serde_json::from_str(line);
        let val = match parsed {
            Ok(v) => v,
            Err(_) => continue,
        };

        if val["reason"].as_str() != Some("compiler-message") {
            continue;
        }

        let msg = &val["message"];
        let level = msg["level"].as_str().unwrap_or("info");
        let severity = match level {
            "error" => "error",
            "warning" => "warning",
            _ => "info",
        };

        // Extract primary span
        let mut file = None;
        let mut line_num = None;
        if let Some(spans) = msg["spans"].as_array() {
            if let Some(primary) = spans
                .iter()
                .find(|s| s["is_primary"].as_bool() == Some(true))
            {
                file = primary["file_name"].as_str().map(String::from);
                line_num = primary["line_start"].as_u64().map(|n| n as u32);
            }
        }

        findings.push(VerifyFinding {
            tool: tool_name.to_string(),
            severity: severity.to_string(),
            message: msg["message"].as_str().unwrap_or("unknown").to_string(),
            file,
            line: line_num,
            rule: msg["code"]["code"].as_str().map(String::from),
        });
    }

    Ok(findings)
}

/// Run ruff (preferred) or flake8 for Python.
fn run_ruff_or_flake8(files: &[PathBuf]) -> Result<Vec<VerifyFinding>> {
    let py_files: Vec<String> = files
        .iter()
        .filter(|f| matches!(f.extension().and_then(|e| e.to_str()), Some("py" | "pyi")))
        .filter_map(|f| f.to_str().map(String::from))
        .collect();

    if py_files.is_empty() {
        return Ok(Vec::new());
    }

    if command_exists("ruff") {
        let mut args = vec!["check", "--output-format", "json"];
        let refs: Vec<&str> = py_files.iter().map(|s| s.as_str()).collect();
        args.extend(refs);

        let output = Command::new("ruff")
            .args(&args)
            .output()
            .map_err(|e| AgentError::Command(format!("ruff failed to execute: {e}")))?;
        let findings = parse_ruff_output(&output.stdout)
            .map_err(|e| map_parse_error("ruff", "JSON", e, &command_output_excerpt(&output)))?;
        return finalize_structured_tool_findings(
            "ruff",
            "JSON",
            output.status.success(),
            findings,
            &command_output_excerpt(&output),
        );
    }

    if command_exists("flake8") {
        let mut args = vec!["--format=json"];
        let refs: Vec<&str> = py_files.iter().map(|s| s.as_str()).collect();
        args.extend(refs);

        let output = Command::new("flake8")
            .args(&args)
            .output()
            .map_err(|e| AgentError::Command(format!("flake8 failed to execute: {e}")))?;
        if output.status.success() {
            return Ok(Vec::new());
        }

        return Ok(vec![VerifyFinding {
            tool: "flake8".to_string(),
            severity: "warning".to_string(),
            message: format!(
                "flake8 reported issues: {}",
                command_output_excerpt(&output)
            ),
            file: None,
            line: None,
            rule: None,
        }]);
    }

    Err(AgentError::Command(
        "No Python linter found (ruff/flake8); cannot lint Python files".to_string(),
    ))
}

/// Parse ruff JSON output.
fn parse_ruff_output(stdout: &[u8]) -> Result<Vec<VerifyFinding>> {
    let text = String::from_utf8_lossy(stdout);
    let entries: Vec<serde_json::Value> = serde_json::from_str(&text).map_err(AgentError::Json)?;

    let findings = entries
        .iter()
        .map(|e| {
            let severity = match e["fix"]["applicability"].as_str() {
                Some("Unsafe") => "error",
                _ => "warning",
            };
            VerifyFinding {
                tool: "ruff".to_string(),
                severity: severity.to_string(),
                message: e["message"].as_str().unwrap_or("unknown").to_string(),
                file: e["filename"].as_str().map(String::from),
                line: e["location"]["row"].as_u64().map(|n| n as u32),
                rule: e["code"].as_str().map(String::from),
            }
        })
        .collect();

    Ok(findings)
}

/// Run `tsc --noEmit`.
fn run_tsc() -> Result<Vec<VerifyFinding>> {
    let runner = require_node_runner("tsc")?;

    let output = Command::new(&runner)
        .args(["exec", "--", "tsc", "--noEmit"])
        .output()
        .map_err(|e| AgentError::Command(format!("tsc failed to execute: {e}")))?;

    if output.status.success() {
        return Ok(Vec::new());
    }

    let diagnostics = if output.stdout.is_empty() {
        String::from_utf8_lossy(&output.stderr).into_owned()
    } else {
        String::from_utf8_lossy(&output.stdout).into_owned()
    };
    let findings = parse_tsc_text_output(&diagnostics);
    finalize_structured_tool_findings(
        "tsc",
        "text",
        output.status.success(),
        findings,
        &command_output_excerpt(&output),
    )
}

/// Parse tsc plain-text errors like `src/foo.ts(10,5): error TS2345: ...`.
fn parse_tsc_text_output(text: &str) -> Vec<VerifyFinding> {
    let re = regex::Regex::new(r"^(.+)\((\d+),\d+\):\s+(error|warning)\s+(TS\d+):\s+(.+)$");
    let re = match re {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };

    text.lines()
        .filter_map(|line| {
            let caps = re.captures(line)?;
            Some(VerifyFinding {
                tool: "tsc".to_string(),
                severity: caps.get(3)?.as_str().to_string(),
                message: caps.get(5)?.as_str().to_string(),
                file: Some(caps.get(1)?.as_str().to_string()),
                line: caps.get(2)?.as_str().parse().ok(),
                rule: Some(caps.get(4)?.as_str().to_string()),
            })
        })
        .collect()
}

/// Run mypy or pyright for Python type checking.
fn run_mypy_or_pyright() -> Result<Vec<VerifyFinding>> {
    if command_exists("mypy") {
        let output = Command::new("mypy")
            .args([".", "--no-error-summary"])
            .output()
            .map_err(|e| AgentError::Command(format!("mypy failed to execute: {e}")))?;
        return if output.status.success() {
            Ok(Vec::new())
        } else {
            Ok(vec![VerifyFinding {
                tool: "mypy".to_string(),
                severity: "error".to_string(),
                message: command_output_excerpt(&output),
                file: None,
                line: None,
                rule: None,
            }])
        };
    }

    if command_exists("pyright") {
        let output = Command::new("pyright")
            .args(["--outputjson"])
            .output()
            .map_err(|e| AgentError::Command(format!("pyright failed to execute: {e}")))?;
        return if output.status.success() {
            Ok(Vec::new())
        } else {
            Ok(vec![VerifyFinding {
                tool: "pyright".to_string(),
                severity: "error".to_string(),
                message: command_output_excerpt(&output),
                file: None,
                line: None,
                rule: None,
            }])
        };
    }

    Err(AgentError::Command(
        "No Python type checker found (mypy/pyright); cannot type-check Python files".to_string(),
    ))
}

/// Run Node.js tests via the detected runner.
fn run_node_tests(test_files: &[PathBuf]) -> Result<Vec<VerifyFinding>> {
    let runner = require_node_runner("JS/TS tests")?;

    // Try `pnpm test` / `npm test`
    let output = Command::new(&runner)
        .arg("test")
        .output()
        .map_err(|e| AgentError::Command(format!("{runner} test failed to execute: {e}")))?;

    if output.status.success() {
        Ok(Vec::new())
    } else {
        let _ = test_files; // test_files used for future granular filtering
        Ok(vec![VerifyFinding {
            tool: "node_test".to_string(),
            severity: "error".to_string(),
            message: format!("{runner} test failed: {}", command_output_excerpt(&output)),
            file: None,
            line: None,
            rule: None,
        }])
    }
}

/// Run pytest for Python.
fn run_pytest(test_files: &[PathBuf]) -> Result<Vec<VerifyFinding>> {
    if !has_pytest() {
        return Err(AgentError::Command(
            "pytest not found; cannot run Python tests".to_string(),
        ));
    }

    let mut args: Vec<String> = vec!["-v".to_string(), "--tb=short".to_string()];
    if !test_files.is_empty() {
        for f in test_files {
            if let Some(s) = f.to_str() {
                args.push(s.to_string());
            }
        }
    }

    let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    let output = Command::new("pytest")
        .args(&arg_refs)
        .output()
        .map_err(|e| AgentError::Command(format!("pytest failed to execute: {e}")))?;

    if output.status.success() {
        Ok(Vec::new())
    } else {
        Ok(vec![VerifyFinding {
            tool: "pytest".to_string(),
            severity: "error".to_string(),
            message: command_output_excerpt(&output),
            file: None,
            line: None,
            rule: None,
        }])
    }
}

/// Run `go vet`.
fn run_golint() -> Result<Vec<VerifyFinding>> {
    require_command_available("go", "go vet")?;

    let output = Command::new("go")
        .args(["vet", "./..."])
        .output()
        .map_err(|e| AgentError::Command(format!("go vet failed to execute: {e}")))?;

    if output.status.success() {
        return Ok(Vec::new());
    }

    let diagnostics = String::from_utf8_lossy(&output.stderr);
    let findings: Vec<VerifyFinding> = diagnostics
        .lines()
        .filter(|line| !line.is_empty())
        .map(|line| VerifyFinding {
            tool: "go_vet".to_string(),
            severity: "warning".to_string(),
            message: line.to_string(),
            file: None,
            line: None,
            rule: None,
        })
        .collect();

    finalize_structured_tool_findings(
        "go vet",
        "text",
        output.status.success(),
        findings,
        &command_output_excerpt(&output),
    )
}

/// Run `go test ./...`.
fn run_go_test() -> Result<Vec<VerifyFinding>> {
    require_command_available("go", "go test")?;

    let output = Command::new("go")
        .args(["test", "./..."])
        .output()
        .map_err(|e| AgentError::Command(format!("go test failed to execute: {e}")))?;

    if output.status.success() {
        Ok(Vec::new())
    } else {
        Ok(vec![VerifyFinding {
            tool: "go_test".to_string(),
            severity: "error".to_string(),
            message: format!("go test failed: {}", command_output_excerpt(&output)),
            file: None,
            line: None,
            rule: None,
        }])
    }
}

/// Run shellcheck on shell scripts.
fn run_shellcheck(files: &[PathBuf]) -> Result<Vec<VerifyFinding>> {
    require_command_available("shellcheck", "shellcheck")?;

    let sh_files: Vec<String> = files
        .iter()
        .filter(|f| matches!(f.extension().and_then(|e| e.to_str()), Some("sh" | "bash")))
        .filter_map(|f| f.to_str().map(String::from))
        .collect();

    if sh_files.is_empty() {
        return Ok(Vec::new());
    }

    let mut args = vec!["--format=json".to_string()];
    args.extend(sh_files);
    let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();

    let output = Command::new("shellcheck")
        .args(&arg_refs)
        .output()
        .map_err(|e| AgentError::Command(format!("shellcheck failed to execute: {e}")))?;
    let findings = parse_shellcheck_output(&output.stdout)
        .map_err(|e| map_parse_error("shellcheck", "JSON", e, &command_output_excerpt(&output)))?;

    finalize_structured_tool_findings(
        "shellcheck",
        "JSON",
        output.status.success(),
        findings,
        &command_output_excerpt(&output),
    )
}

fn parse_shellcheck_output(stdout: &[u8]) -> Result<Vec<VerifyFinding>> {
    let text = String::from_utf8_lossy(stdout);
    let entries: Vec<serde_json::Value> = serde_json::from_str(&text).map_err(AgentError::Json)?;

    Ok(entries
        .iter()
        .map(|entry| {
            let level = entry["level"].as_str().unwrap_or("info");
            let severity = match level {
                "error" => "error",
                "warning" => "warning",
                _ => "info",
            };
            VerifyFinding {
                tool: "shellcheck".to_string(),
                severity: severity.to_string(),
                message: entry["message"].as_str().unwrap_or("unknown").to_string(),
                file: entry["file"].as_str().map(String::from),
                line: entry["line"].as_u64().map(|n| n as u32),
                rule: entry["code"].as_u64().map(|c| format!("SC{c}")),
            }
        })
        .collect())
}

/// Run Semgrep SAST.
fn run_semgrep(files: &[PathBuf]) -> Result<Vec<VerifyFinding>> {
    let file_args: Vec<String> = files
        .iter()
        .filter_map(|f| f.to_str().map(String::from))
        .collect();

    if file_args.is_empty() {
        return Ok(Vec::new());
    }

    let output = Command::new("semgrep")
        .args(["scan", "--json", "--config", "auto"])
        .args(&file_args)
        .output()
        .map_err(|e| AgentError::Command(format!("semgrep failed to execute: {e}")))?;
    let findings = parse_semgrep_output(&output.stdout)
        .map_err(|e| map_parse_error("semgrep", "JSON", e, &command_output_excerpt(&output)))?;

    finalize_structured_tool_findings(
        "semgrep",
        "JSON",
        output.status.success(),
        findings,
        &command_output_excerpt(&output),
    )
}

fn parse_semgrep_output(stdout: &[u8]) -> Result<Vec<VerifyFinding>> {
    let text = String::from_utf8_lossy(stdout);
    let parsed: serde_json::Value = serde_json::from_str(&text).map_err(AgentError::Json)?;
    let results = parsed["results"].as_array().ok_or_else(|| {
        AgentError::Command("semgrep JSON output did not contain a results array".to_string())
    })?;

    Ok(results
        .iter()
        .map(|result| {
            let severity = result["extra"]["severity"].as_str().unwrap_or("warning");
            VerifyFinding {
                tool: "semgrep".to_string(),
                severity: severity.to_string(),
                message: result["extra"]["message"]
                    .as_str()
                    .unwrap_or("unknown")
                    .to_string(),
                file: result["path"].as_str().map(String::from),
                line: result["start"]["line"].as_u64().map(|n| n as u32),
                rule: result["check_id"].as_str().map(String::from),
            }
        })
        .collect())
}

/// Run benchmarks (Gate C only).
fn run_benchmarks(languages: &[String]) -> Result<Vec<VerifyFinding>> {
    let mut findings = Vec::new();

    for lang in languages {
        if lang != "rust" {
            continue;
        }

        if !command_exists("cargo") {
            return Err(AgentError::Command(
                "cargo not found; cannot run cargo bench".to_string(),
            ));
        }

        let workspace_root = resolve_rust_workspace_root()?;
        let output = Command::new("cargo")
            .current_dir(&workspace_root)
            .args(["bench", "--no-run"])
            .output()
            .map_err(|e| AgentError::Command(format!("cargo bench failed to execute: {e}")))?;

        if !output.status.success() {
            findings.push(VerifyFinding {
                tool: "cargo_bench".to_string(),
                severity: "error".to_string(),
                message: format!(
                    "cargo bench --no-run failed: {}",
                    command_output_excerpt(&output)
                ),
                file: None,
                line: None,
                rule: None,
            });
        }
    }

    Ok(findings)
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
    // Walking current_dir.ancestors() as a fallback is explicitly prohibited
    // because it can land on a third candidate or repo-external Cargo.toml.
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

fn command_output_excerpt(output: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);

    let excerpt = stderr
        .lines()
        .take(10)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();

    if !excerpt.is_empty() {
        excerpt
    } else {
        stdout.lines().take(10).collect::<Vec<_>>().join("\n")
    }
}

/// Detect deleted files via `git diff --diff-filter=D`.
fn detect_deleted_files() -> Vec<String> {
    let output = Command::new("git")
        .args(["diff", "--name-only", "--diff-filter=D", "HEAD"])
        .output();

    match output {
        Ok(o) => String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter(|l| !l.is_empty())
            .map(String::from)
            .collect(),
        Err(_) => Vec::new(),
    }
}

/// Check if a filename looks like a test file.
fn is_test_file(name: &str) -> bool {
    name.contains(".test.")
        || name.contains(".spec.")
        || name.contains("_test.")
        || name.starts_with("test_")
        || name.ends_with("_test.rs")
        || name.ends_with("_test.go")
        || name.ends_with("_test.py")
}

/// Try to replace a path prefix (e.g. `src/` → `test/`).
fn replace_prefix(path: &Path, from: &str, to: &str) -> Option<PathBuf> {
    let s = path.to_str()?;
    if s.starts_with(from) {
        Some(PathBuf::from(s.replacen(from, to, 1)))
    } else if s.contains(&format!("/{from}/")) {
        Some(PathBuf::from(s.replacen(
            &format!("/{from}/"),
            &format!("/{to}/"),
            1,
        )))
    } else {
        None
    }
}

/// Write the verification report as JSON atomically (tempfile + rename).
fn write_report(output: &Path, result: &VerifyResult) -> Result<()> {
    let dir = match output.parent() {
        Some(parent) => {
            std::fs::create_dir_all(parent).map_err(AgentError::Io)?;
            parent
        }
        None => Path::new("."),
    };
    let json = serde_json::to_string_pretty(result).map_err(AgentError::Json)?;
    let mut tmp = tempfile::NamedTempFile::new_in(dir).map_err(AgentError::Io)?;
    use std::io::Write;
    tmp.write_all(json.as_bytes()).map_err(AgentError::Io)?;
    tmp.persist(output).map_err(|e| AgentError::Io(e.error))?;
    tracing::info!("Verification report written to {}", output.display());
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cmd::test_support::{lock_process_state, CurrentDirGuard};
    use std::{path::PathBuf, process::Command};

    #[test]
    fn test_normalize_gate_level() {
        assert_eq!(
            normalize_gate_level("level_a").unwrap() as u8,
            GateLevel::A as u8
        );
        assert_eq!(
            normalize_gate_level("level_b").unwrap() as u8,
            GateLevel::B as u8
        );
        assert_eq!(
            normalize_gate_level("level_c").unwrap() as u8,
            GateLevel::C as u8
        );
        assert_eq!(normalize_gate_level("a").unwrap() as u8, GateLevel::A as u8);
        assert_eq!(normalize_gate_level("B").unwrap() as u8, GateLevel::B as u8);
        assert!(normalize_gate_level("invalid").is_err());
    }

    #[test]
    fn test_detect_project_languages() {
        let files = vec![
            PathBuf::from("src/main.rs"),
            PathBuf::from("src/app.ts"),
            PathBuf::from("lib/utils.py"),
            PathBuf::from("scripts/deploy.sh"),
        ];
        let langs = detect_project_languages(&files);
        assert!(langs.contains(&"rust".to_string()));
        assert!(langs.contains(&"typescript".to_string()));
        assert!(langs.contains(&"python".to_string()));
        assert!(langs.contains(&"shell".to_string()));
    }

    #[test]
    fn test_detect_project_languages_empty() {
        let langs = detect_project_languages(&[]);
        assert!(langs.is_empty());
    }

    #[test]
    fn test_is_test_file() {
        assert!(is_test_file("foo.test.ts"));
        assert!(is_test_file("bar.spec.js"));
        assert!(is_test_file("baz_test.rs"));
        assert!(is_test_file("test_qux.py"));
        assert!(!is_test_file("main.rs"));
        assert!(!is_test_file("app.ts"));
    }

    #[test]
    fn test_analyze_non_code_deletions_ci() {
        let deleted = vec![".github/workflows/ci.yml".to_string()];
        let impacts = analyze_non_code_deletions(&deleted);
        assert_eq!(impacts.len(), 1);
        assert_eq!(impacts[0].verdict, "BLOCK");
        assert_eq!(impacts[0].category, DeletionCategory::CiEntrypoint);
    }

    #[test]
    fn test_analyze_non_code_deletions_config() {
        let deleted = vec!["package.json".to_string()];
        let impacts = analyze_non_code_deletions(&deleted);
        assert_eq!(impacts.len(), 1);
        assert_eq!(impacts[0].verdict, "WARN");
        assert_eq!(impacts[0].category, DeletionCategory::ConfigLock);
    }

    #[test]
    fn test_analyze_non_code_deletions_empty() {
        let impacts = analyze_non_code_deletions(&[]);
        assert!(impacts.is_empty());
    }

    #[test]
    fn test_analyze_non_code_deletions_unsupported_lang() {
        let deleted = vec!["src/main.go".to_string()];
        let impacts = analyze_non_code_deletions(&deleted);
        assert_eq!(impacts.len(), 1);
        assert_eq!(impacts[0].category, DeletionCategory::UnsupportedLang);
    }

    #[test]
    fn test_replace_prefix() {
        let p = PathBuf::from("src/foo/bar.ts");
        let replaced = replace_prefix(&p, "src", "test");
        assert_eq!(replaced, Some(PathBuf::from("test/foo/bar.ts")));
    }

    #[test]
    fn test_replace_prefix_none() {
        let p = PathBuf::from("lib/foo.ts");
        let replaced = replace_prefix(&p, "src", "test");
        assert!(replaced.is_none());
    }

    #[test]
    fn test_parse_eslint_output_empty() {
        let findings = parse_eslint_output(b"[]").unwrap();
        assert!(findings.is_empty());
    }

    #[test]
    fn test_parse_eslint_output_invalid() {
        let error = parse_eslint_output(b"not json").unwrap_err();
        assert!(matches!(error, AgentError::Json(_)));
    }

    #[test]
    fn test_parse_cargo_diagnostics_empty() {
        let findings = parse_cargo_diagnostics(b"", "clippy").unwrap();
        assert!(findings.is_empty());
    }

    #[test]
    fn test_parse_tsc_text_output() {
        let input = "src/foo.ts(10,5): error TS2345: Argument of type 'string' is not assignable.";
        let findings = parse_tsc_text_output(input);
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].tool, "tsc");
        assert_eq!(findings[0].severity, "error");
        assert_eq!(findings[0].file, Some("src/foo.ts".to_string()));
        assert_eq!(findings[0].line, Some(10));
        assert_eq!(findings[0].rule, Some("TS2345".to_string()));
    }

    #[test]
    fn test_parse_ruff_output_invalid() {
        let error = parse_ruff_output(b"not json").unwrap_err();
        assert!(matches!(error, AgentError::Json(_)));
    }

    #[test]
    fn test_parse_shellcheck_output_invalid() {
        let error = parse_shellcheck_output(b"not json").unwrap_err();
        assert!(matches!(error, AgentError::Json(_)));
    }

    #[test]
    fn test_parse_semgrep_output_invalid() {
        let error = parse_semgrep_output(b"not json").unwrap_err();
        assert!(matches!(error, AgentError::Json(_)));
    }

    #[test]
    fn test_parse_semgrep_output_missing_results() {
        let error = parse_semgrep_output(br#"{"errors":[]}"#).unwrap_err();
        assert!(matches!(error, AgentError::Command(_)));
    }

    #[test]
    fn test_require_node_runner_from_none_is_err() {
        let error = require_node_runner_from("ESLint", None).unwrap_err();
        assert!(matches!(error, AgentError::Command(_)));
        assert!(error.to_string().contains("No Node runner found"));
    }

    #[test]
    fn test_finalize_structured_tool_findings_non_success_without_findings_is_err() {
        let error = finalize_structured_tool_findings("ESLint", "JSON", false, Vec::new(), "boom")
            .unwrap_err();
        assert!(matches!(error, AgentError::Command(_)));
        assert!(error
            .to_string()
            .contains("without parseable JSON findings"));
    }

    #[test]
    fn test_verify_step_failure_is_error_finding() {
        let finding = verify_step_failure("lint", "missing verifier");
        assert_eq!(finding.tool, "lint");
        assert_eq!(finding.severity, "error");
        assert_eq!(finding.message, "missing verifier");
    }

    #[test]
    fn test_verify_status_allows_progress_for_passed_and_skipped() {
        assert!(verify_status_allows_progress(&VerifyStatus::Passed));
        assert!(verify_status_allows_progress(&VerifyStatus::Skipped));
        assert!(!verify_status_allows_progress(&VerifyStatus::Failed));
        assert!(!verify_status_allows_progress(&VerifyStatus::Error));
    }

    #[test]
    fn test_shadow_verify_loop_returns_skipped_without_escalation() {
        let _process_state = lock_process_state();
        let temp = tempfile::tempdir().unwrap();
        let plan = temp.path().join("plan.md");
        let output = temp.path().join("verify-report.json");

        let init_status = Command::new("git")
            .args(["init", "--quiet"])
            .current_dir(temp.path())
            .status()
            .unwrap();
        assert!(init_status.success());

        let _dir_guard = CurrentDirGuard::set(temp.path());

        let result = shadow_verify_loop("impl", &plan, &output, 3, None).unwrap();

        assert_eq!(result.status, VerifyStatus::Skipped);
        let persisted: VerifyResult =
            serde_json::from_slice(&std::fs::read(&output).unwrap()).unwrap();
        assert_eq!(persisted.status, VerifyStatus::Skipped);
    }

    #[test]
    fn test_command_exists_true() {
        // `true` should be available on any Unix system
        assert!(command_exists("true"));
    }

    #[test]
    fn test_command_exists_false() {
        assert!(!command_exists("nonexistent_command_xyz_12345"));
    }

    #[test]
    fn test_verify_result_json_roundtrip() {
        let result = VerifyResult {
            status: VerifyStatus::Passed,
            gate_level: "level_b".to_string(),
            findings: vec![VerifyFinding {
                tool: "clippy".to_string(),
                severity: "warning".to_string(),
                message: "unused variable".to_string(),
                file: Some("src/main.rs".to_string()),
                line: Some(42),
                rule: Some("unused_variables".to_string()),
            }],
            run_id: "test-run".to_string(),
            duration_secs: 5,
            languages_detected: vec!["rust".to_string()],
            deletion_impacts: Vec::new(),
        };

        let json = serde_json::to_string(&result).unwrap();
        let deserialized: VerifyResult = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.status, VerifyStatus::Passed);
        assert_eq!(deserialized.findings.len(), 1);
    }
}
