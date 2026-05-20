//! Coder orchestration module — replaces `coder.sh` (1,123 LOC).
//!
//! Manages the coder lifecycle: complexity analysis, engine selection,
//! prompt construction, execution (via Claude or Codex), and fix iterations.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use clap::Subcommand;
use serde::{Deserialize, Serialize};

use shared::error::{AgentError, Result};
use shared::types::{CoderEngine, CodexRole};

#[cfg(test)]
use shared::types::{CoderInfo, CoderSession, State};

use crate::session;

// ---------------------------------------------------------------------------
// Static regex
// ---------------------------------------------------------------------------

/// Regex for matching file references (paths with extensions) in plan content.
static FILE_REF_RE: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
    regex::Regex::new(r"(?:^|\s)([a-zA-Z0-9_./-]+\.[a-zA-Z]{1,6})(?:\s|$|[,;:)])")
        .expect("file reference regex")
});

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/// Subcommands for the `coder` family.
#[derive(Subcommand)]
pub enum CoderAction {
    /// Run coder (new session).
    Run {
        /// Path to the execution plan.
        #[arg(long)]
        plan: String,
        /// Orchestration phase name.
        #[arg(long)]
        phase: String,
        /// Path for the coder output file.
        #[arg(long)]
        output: String,
        /// Engine override: `"codex"` or `"claude"`.
        #[arg(long)]
        engine: Option<String>,
    },
    /// Run fix iteration after review feedback.
    Fix {
        /// Path to the execution plan.
        #[arg(long)]
        plan: String,
        /// Orchestration phase name.
        #[arg(long)]
        phase: String,
        /// Path to the review output / feedback.
        #[arg(long)]
        review_output: String,
        /// Current fix iteration number.
        #[arg(long)]
        iteration: u32,
        /// Path for the coder output file.
        #[arg(long)]
        output: String,
    },
    /// Analyze task complexity from a plan.
    AnalyzeComplexity {
        /// Path to the execution plan.
        #[arg(long)]
        plan: String,
    },
    /// Select the recommended engine for a task.
    SelectEngine {
        /// Path to the execution plan.
        #[arg(long)]
        plan: String,
    },
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Task complexity assessment derived from plan analysis.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskComplexity {
    /// Complexity score (1 - 10).
    pub score: u32,
    /// Whether the task involves security-sensitive changes.
    pub security_sensitive: bool,
    /// Estimated number of files affected.
    pub file_count: usize,
    /// Whether the task requires test creation/modification.
    pub test_required: bool,
    /// Recommended coder engine.
    pub recommended_engine: CoderEngine,
    /// Recommended Codex role.
    pub recommended_role: CodexRole,
}

/// Result from a coder execution.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoderResult {
    /// Session identifier (if retrievable).
    pub session_id: Option<String>,
    /// Path to the output file.
    pub output_file: PathBuf,
    /// Engine that was used.
    pub engine: CoderEngine,
    /// Process exit code.
    pub exit_code: i32,
}

// ---------------------------------------------------------------------------
// Constants — security keywords
// ---------------------------------------------------------------------------

/// Keywords that indicate security-sensitive changes.
const SECURITY_KEYWORDS: &[&str] = &[
    "password",
    "secret",
    "credential",
    "token",
    "auth",
    "jwt",
    "oauth",
    "encryption",
    "decrypt",
    "private_key",
    "api_key",
    "apikey",
    "access_control",
    "permission",
    "privilege",
    "rbac",
    "csrf",
    "xss",
    "injection",
    "sanitize",
    "certificate",
    "tls",
    "ssl",
    "hmac",
    "hash",
    "bcrypt",
    "argon2",
    "scrypt",
];

/// Default coder timeout in seconds (30 minutes for Claude).
const DEFAULT_CLAUDE_TIMEOUT: u64 = 1800;

/// Default coder timeout in seconds (2 hours for Codex).
const DEFAULT_CODEX_TIMEOUT: u64 = 7200;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Execute a `coder` subcommand.
pub fn run(action: CoderAction) -> Result<()> {
    match action {
        CoderAction::Run {
            plan,
            phase,
            output,
            engine,
        } => {
            let repo_root = shared::git::git_repo_root()?;
            let plan_path = Path::new(&plan);
            let engine = resolve_engine(
                engine
                    .as_deref()
                    .map(|s| s.parse::<CoderEngine>().map_err(AgentError::Validation))
                    .transpose()?,
                plan_path,
            );
            let result = coder_run(plan_path, &phase, Path::new(&output), engine, &repo_root)?;
            let json = serde_json::to_string_pretty(&result).map_err(AgentError::Json)?;
            println!("{json}");
            Ok(())
        }
        CoderAction::Fix {
            plan,
            phase,
            review_output,
            iteration,
            output,
        } => {
            let repo_root = shared::git::git_repo_root()?;
            let result = coder_run_fix(
                Path::new(&plan),
                &phase,
                Path::new(&review_output),
                iteration,
                Path::new(&output),
                &repo_root,
            )?;
            let json = serde_json::to_string_pretty(&result).map_err(AgentError::Json)?;
            println!("{json}");
            Ok(())
        }
        CoderAction::AnalyzeComplexity { plan } => {
            let complexity = analyze_task_complexity(Path::new(&plan))?;
            let json = serde_json::to_string_pretty(&complexity).map_err(AgentError::Json)?;
            println!("{json}");
            Ok(())
        }
        CoderAction::SelectEngine { plan } => {
            let plan_path = Path::new(&plan);
            let engine = resolve_engine(None, plan_path);
            println!("{}", engine_label(engine));
            Ok(())
        }
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Analyze task complexity from a plan file.
///
/// Scoring heuristics (ported from shell):
/// - Base score: 3
/// - Plan length > 100 lines: +2
/// - Multiple file references: +1 per 5 files
/// - Security keywords detected: +3 (also sets `security_sensitive`)
/// - Test-related phase / content: sets `test_required`
pub fn analyze_task_complexity(plan_path: &Path) -> Result<TaskComplexity> {
    let content = fs::read_to_string(plan_path).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to read plan: {e}"),
        ))
    })?;

    let lower = content.to_lowercase();
    let lines: Vec<&str> = content.lines().collect();
    let line_count = lines.len();

    let mut score: u32 = 3;

    // Plan length
    if line_count > 100 {
        score = score.saturating_add(2);
    } else if line_count > 50 {
        score = score.saturating_add(1);
    }

    // Count file references (lines containing path-like patterns)
    let file_count = count_file_references(&content);
    score = score.saturating_add((file_count / 5) as u32);

    // Security sensitivity
    let security_sensitive = is_security_sensitive_content(&lower);
    if security_sensitive {
        score = score.saturating_add(3);
    }

    // Test requirement
    let test_required = lower.contains("test")
        || lower.contains("spec")
        || lower.contains("__test__")
        || lower.contains("pytest")
        || lower.contains("jest")
        || lower.contains("vitest");

    // Clamp to 1-10
    score = score.clamp(1, 10);

    // Determine recommended engine and role
    let mut complexity = TaskComplexity {
        score,
        security_sensitive,
        file_count,
        test_required,
        recommended_engine: CoderEngine::Codex,
        recommended_role: CodexRole::Standard,
    };
    complexity.recommended_role = select_codex_role(&complexity);

    Ok(complexity)
}

#[cfg(test)]
/// Get recommended parallel coder count based on complexity.
///
/// - Score 1-4: 1 coder
/// - Score 5-7: 1-2 coders
/// - Score 8+: 1 (security-sensitive tasks should not be parallelized)
pub fn get_recommended_count(complexity: &TaskComplexity) -> u32 {
    if complexity.security_sensitive {
        return 1;
    }
    match complexity.score {
        1..=4 => 1,
        5..=7 => 2,
        _ => 1,
    }
}

#[cfg(test)]
/// Check if a plan involves security-sensitive changes.
pub fn is_security_sensitive_plan(plan_path: &Path) -> Result<bool> {
    let content = fs::read_to_string(plan_path).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to read plan: {e}"),
        ))
    })?;
    Ok(is_security_sensitive_content(&content.to_lowercase()))
}

/// Select the appropriate Codex role based on complexity.
pub fn select_codex_role(complexity: &TaskComplexity) -> CodexRole {
    select_codex_role_from_score(complexity.score, complexity.security_sensitive)
}

/// Resolve coder engine. Currently always returns Codex.
/// Claude engine selection is reserved for future implementation.
pub fn resolve_engine(explicit: Option<CoderEngine>, _plan_path: &Path) -> CoderEngine {
    explicit.unwrap_or(CoderEngine::Codex)
}

/// Build a coder prompt from the plan, phase, and optional extra context.
pub fn build_prompt(plan_path: &Path, phase: &str, context: Option<&str>) -> Result<String> {
    let plan_content = fs::read_to_string(plan_path).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to read plan: {e}"),
        ))
    })?;

    let mut prompt = String::new();

    prompt.push_str(&format!("# Coder Task — Phase: {phase}\n\n"));
    prompt.push_str("## Execution Plan\n\n");
    prompt.push_str(&plan_content);
    prompt.push_str("\n\n");

    if let Some(ctx) = context {
        if !ctx.is_empty() {
            prompt.push_str("## Additional Context\n\n");
            prompt.push_str(ctx);
            prompt.push_str("\n\n");
        }
    }

    prompt.push_str("## Instructions\n\n");
    prompt.push_str(&format!(
        "Execute the **{phase}** phase of the plan above.\n"
    ));
    prompt.push_str("Follow the project coding standards and ensure all changes are correct.\n");
    prompt.push_str("If tests are required, include them.\n");

    Ok(prompt)
}

/// Run the coder (main execution — new session).
///
/// Dispatches to either Claude or Codex based on the resolved engine.
pub fn coder_run(
    plan: &Path,
    phase: &str,
    output: &Path,
    engine: CoderEngine,
    repo_root: &Path,
) -> Result<CoderResult> {
    tracing::info!(
        "coder_run: engine={}, phase={phase}, plan={}",
        engine,
        plan.display()
    );

    let prompt = build_prompt(plan, phase, None)?;

    // Ensure output directory exists
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(AgentError::Io)?;
    }

    match engine {
        CoderEngine::Claude => run_via_claude(&prompt, output, repo_root),
        CoderEngine::Codex => run_via_codex(&prompt, output, repo_root),
    }
}

/// Run a fix iteration after review feedback.
///
/// Reads the review output and builds a fix prompt that includes both the
/// original plan context and the review findings.
pub fn coder_run_fix(
    plan: &Path,
    phase: &str,
    review_output: &Path,
    iteration: u32,
    output: &Path,
    repo_root: &Path,
) -> Result<CoderResult> {
    tracing::info!(
        "coder_run_fix: phase={phase}, iteration={iteration}, review={}",
        review_output.display()
    );

    let review_content = fs::read_to_string(review_output).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to read review output: {e}"),
        ))
    })?;

    let fix_context = format!(
        r#"## Review Feedback (Iteration {iteration})

The following review findings must be addressed:

{review_content}

## Fix Instructions

- Address ALL [High] severity issues (blockers).
- Address [Medium] severity issues where feasible.
- Do NOT introduce new issues while fixing existing ones.
- Iteration: {iteration}
"#
    );

    let prompt = build_prompt(plan, phase, Some(&fix_context))?;

    // Ensure output directory exists
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(AgentError::Io)?;
    }

    // Fix iterations always use Codex (coder role)
    run_via_codex(&prompt, output, repo_root)
}

#[cfg(test)]
/// Record a coder result into the orchestration state.
pub fn record_to_state(state: &mut State, result: &CoderResult, phase: &str) {
    // Update phase coder info
    if let Some(idx) = state.find_phase(phase) {
        state.phases[idx].coder = Some(CoderInfo {
            session_id: result.session_id.clone(),
            output_file: Some(result.output_file.to_string_lossy().to_string()),
        });
    }

    // Record session
    if let Some(ref sid) = result.session_id {
        state.record_session(CoderSession {
            session_id: sid.clone(),
            phase: Some(phase.to_string()),
            iteration: Some(0),
            engine: Some(result.engine),
            parent_session_id: None,
            created_at: Some(chrono::Utc::now().to_rfc3339()),
        });
    }
}

/// Return a human-readable label for a coder engine.
pub fn engine_label(engine: CoderEngine) -> &'static str {
    match engine {
        CoderEngine::Codex => "codex",
        CoderEngine::Claude => "claude",
    }
}

// ---------------------------------------------------------------------------
// Internal: engine dispatch
// ---------------------------------------------------------------------------

/// Run the coder via Claude CLI.
fn run_via_claude(prompt: &str, output: &Path, repo_root: &Path) -> Result<CoderResult> {
    tracing::info!("Dispatching to Claude CLI...");

    let session_id =
        session::session_start(prompt, Some(output), DEFAULT_CLAUDE_TIMEOUT, repo_root)?;

    let exit_code = if output.exists() { 0 } else { 1 };

    Ok(CoderResult {
        session_id: Some(session_id),
        output_file: output.to_path_buf(),
        engine: CoderEngine::Claude,
        exit_code,
    })
}

/// Run the coder via Codex CLI.
fn run_via_codex(prompt: &str, output: &Path, repo_root: &Path) -> Result<CoderResult> {
    tracing::info!("Dispatching to Codex CLI...");

    // Write prompt to temp file for Codex stdin
    let mut prompt_file = tempfile::Builder::new()
        .prefix("coder_prompt_")
        .suffix(".md")
        .tempfile()
        .map_err(AgentError::Io)?;
    prompt_file
        .write_all(prompt.as_bytes())
        .map_err(AgentError::Io)?;
    prompt_file.flush().map_err(AgentError::Io)?;

    let session_id =
        session::codex_session_start(prompt_file.path(), output, DEFAULT_CODEX_TIMEOUT, repo_root)?;

    let exit_code = if output.exists() { 0 } else { 1 };

    Ok(CoderResult {
        session_id,
        output_file: output.to_path_buf(),
        engine: CoderEngine::Codex,
        exit_code,
    })
}

// ---------------------------------------------------------------------------
// Internal: complexity helpers
// ---------------------------------------------------------------------------

/// Check if content contains security-sensitive keywords.
fn is_security_sensitive_content(lower_content: &str) -> bool {
    SECURITY_KEYWORDS
        .iter()
        .any(|kw| lower_content.contains(kw))
}

/// Select Codex role based on score and security flag.
fn select_codex_role_from_score(score: u32, security_sensitive: bool) -> CodexRole {
    if security_sensitive || score >= 5 {
        CodexRole::Coder
    } else {
        CodexRole::Standard
    }
}

/// Count file references in plan content (paths with `/` or file extensions).
fn count_file_references(content: &str) -> usize {
    let mut files = std::collections::HashSet::new();
    for cap in FILE_REF_RE.captures_iter(content) {
        if let Some(m) = cap.get(1) {
            files.insert(m.as_str().to_string());
        }
    }
    files.len()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_analyze_task_complexity_simple() {
        let dir = tempfile::tempdir().unwrap();
        let plan = dir.path().join("plan.md");
        fs::write(&plan, "# Simple Plan\n\nFix a typo in README.md\n").unwrap();

        let complexity = analyze_task_complexity(&plan).unwrap();
        assert!(complexity.score >= 1 && complexity.score <= 10);
        assert!(!complexity.security_sensitive);
        assert_eq!(complexity.file_count, 1); // README.md
    }

    #[test]
    fn test_analyze_task_complexity_security() {
        let dir = tempfile::tempdir().unwrap();
        let plan = dir.path().join("plan.md");
        fs::write(
            &plan,
            "# Auth Plan\n\nImplement password hashing with bcrypt for user authentication.\nUpdate jwt token validation.\n",
        )
        .unwrap();

        let complexity = analyze_task_complexity(&plan).unwrap();
        assert!(complexity.security_sensitive);
        assert!(complexity.score >= 6); // base 3 + security 3
    }

    #[test]
    fn test_analyze_task_complexity_large() {
        let dir = tempfile::tempdir().unwrap();
        let plan = dir.path().join("plan.md");
        let mut content = String::new();
        for i in 0..120 {
            content.push_str(&format!("Line {i}: implement feature\n"));
        }
        fs::write(&plan, content).unwrap();

        let complexity = analyze_task_complexity(&plan).unwrap();
        assert!(complexity.score >= 5); // base 3 + length 2
    }

    #[test]
    fn test_analyze_task_complexity_missing_file() {
        let result = analyze_task_complexity(Path::new("/nonexistent/plan.md"));
        assert!(result.is_err());
    }

    #[test]
    fn test_get_recommended_count() {
        let low = TaskComplexity {
            score: 3,
            security_sensitive: false,
            file_count: 2,
            test_required: false,
            recommended_engine: CoderEngine::Codex,
            recommended_role: CodexRole::Standard,
        };
        assert_eq!(get_recommended_count(&low), 1);

        let medium = TaskComplexity {
            score: 6,
            security_sensitive: false,
            file_count: 10,
            test_required: true,
            recommended_engine: CoderEngine::Codex,
            recommended_role: CodexRole::Coder,
        };
        assert_eq!(get_recommended_count(&medium), 2);

        let security = TaskComplexity {
            score: 9,
            security_sensitive: true,
            file_count: 5,
            test_required: true,
            recommended_engine: CoderEngine::Codex,
            recommended_role: CodexRole::Coder,
        };
        assert_eq!(get_recommended_count(&security), 1);
    }

    #[test]
    fn test_is_security_sensitive_plan() {
        let dir = tempfile::tempdir().unwrap();
        let plan = dir.path().join("plan.md");
        fs::write(&plan, "Implement JWT authentication flow").unwrap();
        assert!(is_security_sensitive_plan(&plan).unwrap());

        let plan2 = dir.path().join("plan2.md");
        fs::write(&plan2, "Update button color in UI").unwrap();
        assert!(!is_security_sensitive_plan(&plan2).unwrap());
    }

    #[test]
    fn test_select_codex_role() {
        let standard = TaskComplexity {
            score: 3,
            security_sensitive: false,
            file_count: 1,
            test_required: false,
            recommended_engine: CoderEngine::Codex,
            recommended_role: CodexRole::Standard,
        };
        assert_eq!(select_codex_role(&standard), CodexRole::Standard);

        let complex = TaskComplexity {
            score: 8,
            security_sensitive: false,
            file_count: 20,
            test_required: true,
            recommended_engine: CoderEngine::Codex,
            recommended_role: CodexRole::Coder,
        };
        assert_eq!(select_codex_role(&complex), CodexRole::Coder);

        let secure = TaskComplexity {
            score: 6,
            security_sensitive: true,
            file_count: 5,
            test_required: true,
            recommended_engine: CoderEngine::Codex,
            recommended_role: CodexRole::Coder,
        };
        assert_eq!(select_codex_role(&secure), CodexRole::Coder);
    }

    #[test]
    fn test_resolve_engine_explicit() {
        let dir = tempfile::tempdir().unwrap();
        let plan = dir.path().join("plan.md");
        fs::write(&plan, "Some plan").unwrap();

        assert_eq!(
            resolve_engine(Some(CoderEngine::Claude), &plan),
            CoderEngine::Claude
        );
        assert_eq!(
            resolve_engine(Some(CoderEngine::Codex), &plan),
            CoderEngine::Codex
        );
    }

    #[test]
    fn test_resolve_engine_auto() {
        let dir = tempfile::tempdir().unwrap();
        let plan = dir.path().join("plan.md");
        fs::write(&plan, "Simple change to config file").unwrap();

        let engine = resolve_engine(None, &plan);
        // Should resolve to something valid
        assert!(matches!(engine, CoderEngine::Codex | CoderEngine::Claude));
    }

    #[test]
    fn test_resolve_engine_missing_plan() {
        let engine = resolve_engine(None, Path::new("/nonexistent/plan.md"));
        // Falls back to Codex
        assert_eq!(engine, CoderEngine::Codex);
    }

    #[test]
    fn test_build_prompt() {
        let dir = tempfile::tempdir().unwrap();
        let plan = dir.path().join("plan.md");
        fs::write(&plan, "# My Plan\n\nDo stuff.\n").unwrap();

        let prompt = build_prompt(&plan, "impl", None).unwrap();
        assert!(prompt.contains("Phase: impl"));
        assert!(prompt.contains("# My Plan"));
        assert!(prompt.contains("Do stuff"));
    }

    #[test]
    fn test_build_prompt_with_context() {
        let dir = tempfile::tempdir().unwrap();
        let plan = dir.path().join("plan.md");
        fs::write(&plan, "# Plan").unwrap();

        let prompt = build_prompt(&plan, "test", Some("Extra context here")).unwrap();
        assert!(prompt.contains("Additional Context"));
        assert!(prompt.contains("Extra context here"));
    }

    #[test]
    fn test_build_prompt_missing_plan() {
        let result = build_prompt(Path::new("/nonexistent/plan.md"), "impl", None);
        assert!(result.is_err());
    }

    #[test]
    fn test_engine_label() {
        assert_eq!(engine_label(CoderEngine::Codex), "codex");
        assert_eq!(engine_label(CoderEngine::Claude), "claude");
    }

    #[test]
    fn test_record_to_state() {
        let mut state = State::new("/tmp/plan.md", "test-task");
        state.upsert_phase("impl", 5);

        let result = CoderResult {
            session_id: Some("test-session-12345678".to_string()),
            output_file: PathBuf::from("/tmp/output.md"),
            engine: CoderEngine::Codex,
            exit_code: 0,
        };

        record_to_state(&mut state, &result, "impl");

        // Check phase coder info was set
        let phase = &state.phases[0];
        assert!(phase.coder.is_some());
        let coder = phase.coder.as_ref().unwrap();
        assert_eq!(coder.session_id, Some("test-session-12345678".to_string()));
        assert_eq!(coder.output_file, Some("/tmp/output.md".to_string()));

        // Check session was recorded
        assert_eq!(state.sessions.coder_sessions.len(), 1);
        assert_eq!(
            state.sessions.coder_sessions[0].session_id,
            "test-session-12345678"
        );
    }

    #[test]
    fn test_record_to_state_no_session_id() {
        let mut state = State::new("/tmp/plan.md", "test-task");
        state.upsert_phase("impl", 5);

        let result = CoderResult {
            session_id: None,
            output_file: PathBuf::from("/tmp/output.md"),
            engine: CoderEngine::Claude,
            exit_code: 1,
        };

        record_to_state(&mut state, &result, "impl");

        // Phase coder info should still be set
        let phase = &state.phases[0];
        assert!(phase.coder.is_some());

        // No session should be recorded (session_id was None)
        assert_eq!(state.sessions.coder_sessions.len(), 0);
    }

    #[test]
    fn test_record_to_state_missing_phase() {
        let mut state = State::new("/tmp/plan.md", "test-task");
        // Don't add a phase

        let result = CoderResult {
            session_id: Some("test-session-12345678".to_string()),
            output_file: PathBuf::from("/tmp/output.md"),
            engine: CoderEngine::Codex,
            exit_code: 0,
        };

        // Should not panic, just not update the phase
        record_to_state(&mut state, &result, "nonexistent");

        // Session should still be recorded
        assert_eq!(state.sessions.coder_sessions.len(), 1);
    }

    #[test]
    fn test_is_security_sensitive_content() {
        assert!(is_security_sensitive_content("implement password hashing"));
        assert!(is_security_sensitive_content("update jwt validation"));
        assert!(is_security_sensitive_content("fix csrf protection"));
        assert!(!is_security_sensitive_content("update button color"));
        assert!(!is_security_sensitive_content("refactor string utilities"));
    }

    #[test]
    fn test_select_codex_role_from_score() {
        assert_eq!(select_codex_role_from_score(3, false), CodexRole::Standard);
        assert_eq!(select_codex_role_from_score(5, false), CodexRole::Coder);
        assert_eq!(select_codex_role_from_score(8, false), CodexRole::Coder);
        // Security always gets Coder
        assert_eq!(select_codex_role_from_score(3, true), CodexRole::Coder);
    }

    #[test]
    fn test_count_file_references() {
        let content = "Edit src/main.rs and tests/test_foo.py to implement the feature.";
        let count = count_file_references(content);
        assert!(count >= 2);
    }

    #[test]
    fn test_count_file_references_none() {
        let content = "Just a description with no file paths.";
        let count = count_file_references(content);
        assert_eq!(count, 0);
    }

    #[test]
    fn test_task_complexity_json_roundtrip() {
        let complexity = TaskComplexity {
            score: 5,
            security_sensitive: false,
            file_count: 3,
            test_required: true,
            recommended_engine: CoderEngine::Codex,
            recommended_role: CodexRole::Coder,
        };
        let json = serde_json::to_string(&complexity).unwrap();
        let deserialized: TaskComplexity = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.score, 5);
        assert_eq!(deserialized.recommended_engine, CoderEngine::Codex);
    }

    #[test]
    fn test_coder_result_json_roundtrip() {
        let result = CoderResult {
            session_id: Some("abc-12345678".to_string()),
            output_file: PathBuf::from("/tmp/output.md"),
            engine: CoderEngine::Claude,
            exit_code: 0,
        };
        let json = serde_json::to_string(&result).unwrap();
        let deserialized: CoderResult = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.engine, CoderEngine::Claude);
        assert_eq!(deserialized.exit_code, 0);
    }
}
