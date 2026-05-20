//! Orchestration engine — replaces `auto_orchestrate.sh` (3,853 LOC).
//!
//! Manages the full orchestration lifecycle:
//! 1. Init state or resume from existing state file
//! 2. Acquire orchestration lock
//! 3. Run coder (if `--run-coder`)
//! 4. Run shadow verification
//! 5. Run reviewers in parallel
//! 6. Check for issues at the configured severity threshold
//! 7. If issues exist and iteration < max: run fix iteration, go to step 4
//! 8. If max iterations reached: generate escalation report
//! 9. Release lock, save state

use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use chrono::Utc;
use clap::Subcommand;
use harness_cache::CacheManager;
use serde::{Deserialize, Serialize};
use shared::error::{AgentError, Result};
use shared::lock::FileLock;
use shared::types::*;

use super::state::StateManager;

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/// Subcommands for the `orchestrate` family.
#[derive(Subcommand)]
pub enum OrchestrateAction {
    /// Start new orchestration.
    Run {
        /// Path to the execution plan.
        #[arg(long)]
        plan: String,
        /// Orchestration phase name (e.g. `"impl"`, `"test"`).
        #[arg(long)]
        phase: String,
        /// Run coder automatically.
        #[arg(long)]
        run_coder: bool,
        /// Fix issues at or above this severity (high/medium/low/all).
        #[arg(long, default_value = "high")]
        fix_until: String,
        /// Maximum review/fix iterations.
        #[arg(long, default_value = "5")]
        max_iterations: u32,
        /// Comma-separated reviewer names.
        #[arg(long, default_value = "safety,perf,consistency")]
        reviewers: String,
        /// Quality gate level (A/B/C).
        #[arg(long)]
        gate: Option<String>,
        /// Codex timeout in seconds.
        #[arg(long, default_value = "7200")]
        codex_timeout: u64,
        /// Claude timeout in seconds.
        #[arg(long, default_value = "1800")]
        claude_timeout: u64,
    },
    /// Resume from state file.
    Resume {
        /// Path to state.json.
        #[arg(long)]
        state_file: String,
        /// Recover from stale state.
        #[arg(long)]
        recover: bool,
    },
    /// Show orchestration status.
    Status {
        /// Path to state.json.
        #[arg(long)]
        state_file: String,
    },
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Configuration for an orchestration run.
#[derive(Debug, Clone)]
pub struct OrchestrateConfig {
    /// Path to the execution plan.
    pub plan: PathBuf,
    /// Orchestration phase name.
    pub phase: String,
    /// Whether to run the coder automatically.
    pub run_coder: bool,
    /// Severity threshold for fixing issues.
    pub fix_until: String,
    /// Maximum review/fix iterations.
    pub max_iterations: u32,
    /// List of reviewer names.
    pub reviewers: Vec<String>,
    /// Quality gate level.
    pub gate: Option<String>,
    /// Codex timeout in seconds.
    pub codex_timeout: u64,
    /// Claude timeout in seconds.
    pub claude_timeout: u64,
    /// Path to existing state file (for resume).
    pub state_file: Option<PathBuf>,
}

/// Result of a shadow verification step.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerifyResult {
    /// Whether verification passed.
    pub passed: bool,
    /// Number of findings.
    pub finding_count: usize,
    /// Path to the report file.
    pub report_path: PathBuf,
}

/// Default stale state threshold in seconds (1 hour).
const STALE_THRESHOLD_SECS: u64 = 3600;

/// Lock timeout for orchestration lock.
const ORCH_LOCK_TIMEOUT_SECS: u64 = 30;

fn block_phase<T>(
    state_mgr: &mut StateManager,
    phase: &str,
    code: &str,
    message: impl Into<String>,
) -> Result<T> {
    let message = message.into();
    state_mgr.set_error(code, &message, Some(phase))?;
    Err(AgentError::Command(message))
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Execute an `orchestrate` subcommand.
pub fn run(action: OrchestrateAction) -> Result<()> {
    match action {
        OrchestrateAction::Run {
            plan,
            phase,
            run_coder,
            fix_until,
            max_iterations,
            reviewers,
            gate,
            codex_timeout,
            claude_timeout,
        } => {
            let reviewer_list: Vec<String> = reviewers
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();

            let config = OrchestrateConfig {
                plan: PathBuf::from(&plan),
                phase,
                run_coder,
                fix_until,
                max_iterations,
                reviewers: reviewer_list,
                gate,
                codex_timeout,
                claude_timeout,
                state_file: None,
            };

            orchestrate_run(config)
        }
        OrchestrateAction::Resume {
            state_file,
            recover,
        } => {
            if recover {
                recover_stale_state(Path::new(&state_file))?;
            }

            // Read state file directly for config extraction
            let state_content = fs::read_to_string(&state_file).map_err(AgentError::Io)?;
            let state_json: serde_json::Value = serde_json::from_str(&state_content)?;

            // Extract config from state
            let plan_path = state_json["task"]["plan_path"]
                .as_str()
                .unwrap_or("")
                .to_string();
            let phase = state_json["current_phase"]
                .as_str()
                .unwrap_or("impl")
                .to_string();

            let config = OrchestrateConfig {
                plan: PathBuf::from(&plan_path),
                phase,
                run_coder: false,
                fix_until: "high".to_string(),
                max_iterations: 5,
                reviewers: vec![
                    "safety".to_string(),
                    "perf".to_string(),
                    "consistency".to_string(),
                ],
                gate: None,
                codex_timeout: 7200,
                claude_timeout: 1800,
                state_file: Some(PathBuf::from(&state_file)),
            };

            orchestrate_run(config)
        }
        OrchestrateAction::Status { state_file } => {
            let mgr = StateManager::load(&state_file)?;
            mgr.show_summary();

            let stale = is_state_stale(Path::new(&state_file), STALE_THRESHOLD_SECS);
            if stale {
                println!();
                println!(
                    "WARNING: State appears stale (last update > {} seconds ago)",
                    STALE_THRESHOLD_SECS
                );
                println!("Run with --recover to reset stale state.");
            }

            Ok(())
        }
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Main orchestration entry point.
///
/// Implements the full orchestration loop:
/// 1. Initialize or load state
/// 2. Acquire lock
/// 3. Run coder (optional)
/// 4. Shadow verify
/// 5. Run reviewers
/// 6. Check issues / fix loop
/// 7. Quality gate
/// 8. Finalize
pub fn orchestrate_run(config: OrchestrateConfig) -> Result<()> {
    tracing::info!(
        "orchestrate_run: phase={}, plan={}, run_coder={}, codex_timeout={}, claude_timeout={}",
        config.phase,
        config.plan.display(),
        config.run_coder,
        config.codex_timeout,
        config.claude_timeout,
    );
    let repo_root = shared::git::git_repo_root()?;
    let project_id = match super::project_id::read_project_id(&repo_root) {
        Ok(value) => Some(value),
        Err(e) => {
            tracing::warn!("project ID unavailable; cache disabled: {e}");
            None
        }
    };
    let semantic_db_path = project_id
        .as_deref()
        .and_then(|value| resolve_semantic_db_path(value).ok());
    let mut cache = match project_id.as_deref() {
        Some(value) => match CacheManager::new(value) {
            Ok(cache) => Some(cache),
            Err(e) => {
                tracing::warn!("cache initialization failed; continuing without cache: {e}");
                None
            }
        },
        None => None,
    };

    // 1. Initialize or load state
    let task_name = config
        .plan
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("task")
        .to_string();

    let mut state_mgr = match &config.state_file {
        Some(sf) => StateManager::load(&sf.to_string_lossy())?,
        None => StateManager::init(&config.plan.to_string_lossy(), &task_name, None)?,
    };

    // Set up phase
    state_mgr.upsert_phase(&config.phase, config.max_iterations)?;
    state_mgr.set_phase_status(&config.phase, PhaseStatus::Running)?;

    // Determine state directory for lock
    let state_dir = state_mgr.dir().to_path_buf();

    // 2. Acquire orchestration lock
    let lock_path = state_dir.join(".orchestrate.lock");
    let _lock = acquire_orchestration_lock(&lock_path)?;
    tracing::info!("Orchestration lock acquired");

    // Set up task output directory
    let task_dir = state_dir.clone();
    fs::create_dir_all(&task_dir).map_err(AgentError::Io)?;

    // 3. Run coder (if requested)
    if config.run_coder {
        tracing::info!("Running coder phase...");
        match run_coder_phase(&config, &mut state_mgr) {
            Ok(()) => tracing::info!("Coder phase completed"),
            Err(e) => {
                state_mgr.set_error("CODER_FAILED", &e.to_string(), Some(&config.phase))?;
                return Err(e);
            }
        }
    }

    // 4-7. Review/fix loop
    let coder_output = task_dir.join(format!("coder_output_{}.md", config.phase));
    for iteration in 1..=config.max_iterations {
        tracing::info!("Review iteration {}/{}", iteration, config.max_iterations);

        // 4. Shadow verify
        let verify_output = task_dir.join(format!("verify_{}_{}.json", config.phase, iteration));
        if let Err(e) = prepare_iteration_context(
            &config,
            &task_dir,
            iteration,
            project_id.as_deref(),
            semantic_db_path.as_deref(),
            cache.as_mut(),
        ) {
            return block_phase(
                &mut state_mgr,
                &config.phase,
                "CONTEXT_FAILED",
                format!("context preparation failed: {e}"),
            );
        }

        match run_shadow_verify(&config.phase, &config.plan, &verify_output, cache.as_mut()) {
            Ok(vr) => {
                if !vr.passed {
                    return block_phase(
                        &mut state_mgr,
                        &config.phase,
                        "VERIFY_FAILED",
                        format!(
                            "shadow verify did not pass (findings={}, report={})",
                            vr.finding_count,
                            vr.report_path.display()
                        ),
                    );
                }
            }
            Err(e) => {
                return block_phase(
                    &mut state_mgr,
                    &config.phase,
                    "VERIFY_FAILED",
                    format!("shadow verify failed: {e}"),
                );
            }
        }

        // 5. Run reviewers
        let review_output = task_dir.join(format!("review_{}_{}.md", config.phase, iteration));
        let aggregated_review = match run_review_cycle(
            &config,
            &coder_output,
            &review_output,
            cache.as_mut(),
            iteration,
        ) {
            Ok(review) => {
                tracing::info!(
                    "Review cycle {iteration} completed (all_lgtm={}, has_fixable_verdicts={}, has_blocking_verdicts={})",
                    review.all_lgtm,
                    review.has_fixable_verdicts,
                    review.has_blocking_verdicts,
                );
                review
            }
            Err(e) => {
                return block_phase(
                    &mut state_mgr,
                    &config.phase,
                    "REVIEW_FAILED",
                    format!("review cycle failed: {e}"),
                );
            }
        };

        // 6. Check for issues
        let review_content = aggregated_review.aggregated_content;

        if aggregated_review.all_lgtm && !has_issues(&review_content, &config.fix_until) {
            tracing::info!(
                "All reviewers returned LGTM and no issues remain at severity '{}' or above",
                config.fix_until
            );
            state_mgr.set_phase_status(&config.phase, PhaseStatus::Completed)?;
            break;
        }

        if aggregated_review.has_blocking_verdicts {
            return block_phase(
                &mut state_mgr,
                &config.phase,
                "REVIEW_BLOCKED",
                "review cycle returned a blocking reviewer verdict; manual intervention required",
            );
        }

        if aggregated_review.has_blockers || has_blockers(&review_content) {
            tracing::warn!("Blockers found in review iteration {iteration}");
        }

        // 7. Check if we've exhausted iterations
        if iteration >= config.max_iterations {
            tracing::error!(
                "Max iterations ({}) reached — escalating",
                config.max_iterations
            );
            state_mgr.set_phase_status(&config.phase, PhaseStatus::Escalated)?;

            let report = generate_escalation_report(&state_mgr, &config.phase, &review_content)?;
            let escalation_path = task_dir.join(format!("escalation_report_{}.md", config.phase));
            fs::write(&escalation_path, &report).map_err(AgentError::Io)?;

            return block_phase(
                &mut state_mgr,
                &config.phase,
                "MAX_ITERATIONS_REACHED",
                format!(
                    "max iterations ({}) reached; escalation report written to {}",
                    config.max_iterations,
                    escalation_path.display()
                ),
            );
        }

        if !config.run_coder {
            state_mgr.set_phase_status(&config.phase, PhaseStatus::Failed)?;
            return block_phase(
                &mut state_mgr,
                &config.phase,
                "MANUAL_FIX_REQUIRED",
                format!(
                    "review cycle requested changes but run_coder=false; manual fix required (review output: {})",
                    review_output.display()
                ),
            );
        }

        // Run fix iteration
        tracing::info!("Running fix iteration {iteration}...");
        state_mgr.set_phase_status(&config.phase, PhaseStatus::Fixing)?;
        match run_fix_iteration(&config, &mut state_mgr, iteration, &review_output) {
            Ok(()) => tracing::info!("Fix iteration {iteration} completed"),
            Err(e) => {
                return block_phase(
                    &mut state_mgr,
                    &config.phase,
                    "FIX_FAILED",
                    format!("fix iteration {iteration} failed: {e}"),
                );
            }
        }

        state_mgr.set_phase_status(&config.phase, PhaseStatus::Review)?;
    }

    // 8. Run quality gate (if configured)
    if let Some(ref gate_level) = config.gate {
        tracing::info!("Running quality gate: level {gate_level}");
        match super::gate::run_gate(gate_level) {
            Ok(result) => {
                if result.passed {
                    tracing::info!("Quality gate passed");
                } else {
                    return block_phase(
                        &mut state_mgr,
                        &config.phase,
                        "GATE_FAILED",
                        format!("quality gate level {} failed", gate_level),
                    );
                }
            }
            Err(e) => {
                return block_phase(
                    &mut state_mgr,
                    &config.phase,
                    "GATE_FAILED",
                    format!("quality gate failed: {e}"),
                );
            }
        }
    }

    // 9. Save final state
    state_mgr.save()?;
    if let Some(cache) = cache.as_ref() {
        let stats = cache.get_cache_stats();
        tracing::info!(
            file_index = stats.file_index_count,
            verify = stats.verify_cache_count,
            review = stats.review_cache_count,
            capsule = stats.capsule_cache_count,
            bytes = stats.total_size_bytes,
            "cache stats"
        );
    }
    tracing::info!("Orchestration completed for phase: {}", config.phase);

    // Lock is released via RAII drop
    Ok(())
}

/// Run the coder phase.
///
/// Invokes the coder module to execute the plan for the given phase.
pub fn run_coder_phase(config: &OrchestrateConfig, state: &mut StateManager) -> Result<()> {
    let repo_root = shared::git::git_repo_root()?;
    let task_dir = state.dir().to_path_buf();
    let output = task_dir.join(format!("coder_output_{}.md", config.phase));

    let result = super::coder::coder_run(
        &config.plan,
        &config.phase,
        &output,
        super::coder::resolve_engine(None, &config.plan),
        &repo_root,
    )?;

    // Record to state
    if let Some(ref sid) = result.session_id {
        let session = CoderSession {
            session_id: sid.clone(),
            phase: Some(config.phase.clone()),
            iteration: Some(0),
            engine: Some(result.engine),
            parent_session_id: None,
            created_at: Some(Utc::now().to_rfc3339()),
        };
        state.record_session(session)?;
    }

    if result.exit_code != 0 {
        return Err(AgentError::Command(format!(
            "coder exited with code {}",
            result.exit_code
        )));
    }

    Ok(())
}

/// Run shadow verification.
///
/// Delegates to the verify module to run lint/typecheck/test/SAST checks.
pub fn run_shadow_verify(
    phase: &str,
    plan: &Path,
    output: &Path,
    cache: Option<&mut CacheManager>,
) -> Result<VerifyResult> {
    tracing::info!(
        "Running shadow verify: phase={phase}, output={}",
        output.display()
    );

    match super::verify::shadow_verify_run(phase, plan, output, "level_b", cache) {
        Ok(result) => {
            let passed = verify_status_allows_progress(&result.status);
            Ok(VerifyResult {
                passed,
                finding_count: result.findings.len(),
                report_path: output.to_path_buf(),
            })
        }
        Err(e) => {
            tracing::warn!("Shadow verify error: {e}");
            // Write error report
            if let Some(parent) = output.parent() {
                let _ = fs::create_dir_all(parent);
            }
            let _ = fs::write(
                output,
                format!("{{\"status\": \"error\", \"message\": \"{e}\"}}"),
            );
            Err(e)
        }
    }
}

fn verify_status_allows_progress(status: &super::verify::VerifyStatus) -> bool {
    matches!(
        status,
        super::verify::VerifyStatus::Passed | super::verify::VerifyStatus::Skipped
    )
}

/// Run the review cycle for a single iteration.
///
/// Invokes reviewers via the review module and writes aggregated output.
pub fn run_review_cycle(
    config: &OrchestrateConfig,
    coder_output: &Path,
    review_output: &Path,
    cache: Option<&mut CacheManager>,
    iteration: u32,
) -> Result<super::review::AggregatedReview> {
    let repo_root = shared::git::git_repo_root()?;

    if !coder_output.exists() {
        return Err(AgentError::NotFound(format!(
            "coder output missing; review cycle is blocked: {}",
            coder_output.display()
        )));
    }

    let coder_content = fs::read_to_string(coder_output).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to read coder output: {e}"),
        ))
    })?;
    if coder_content.trim().is_empty() {
        return Err(AgentError::Validation(format!(
            "coder output is empty; review cycle is blocked: {}",
            coder_output.display()
        )));
    }

    let review_dir = review_output
        .parent()
        .unwrap_or(Path::new("."))
        .join("reviews");

    let reviewer_str = config.reviewers.join(",");

    let result = super::review::run_all(
        &reviewer_str,
        coder_output,
        &review_dir,
        &config.phase,
        &repo_root,
        cache,
        iteration,
    )?;

    // Write aggregated review to the output path
    if let Some(parent) = review_output.parent() {
        fs::create_dir_all(parent).map_err(AgentError::Io)?;
    }
    fs::write(review_output, &result.aggregated_content).map_err(AgentError::Io)?;

    Ok(result)
}

/// Refresh context, symbol index, maintenance, and capsule artifacts.
pub fn prepare_iteration_context(
    config: &OrchestrateConfig,
    task_dir: &Path,
    iteration: u32,
    project_id: Option<&str>,
    semantic_db_path: Option<&Path>,
    mut cache: Option<&mut CacheManager>,
) -> Result<()> {
    let snapshot_path = task_dir.join(format!("context_{}_{}.json", config.phase, iteration));
    super::context::context_update(&config.plan, &snapshot_path, false, cache.as_deref_mut())?;

    let snapshot_content = fs::read_to_string(&snapshot_path).map_err(AgentError::Io)?;
    let snapshot: super::context::ContextSnapshot =
        serde_json::from_str(&snapshot_content).map_err(AgentError::Json)?;
    let existing_files: Vec<String> = snapshot
        .files
        .iter()
        .map(|entry| entry.path.clone())
        .collect();

    if let Some(cache) = cache.as_deref_mut() {
        cache.maintenance(7, &existing_files)?;
    }

    if let (Some(project_id), Some(db_path)) = (project_id, semantic_db_path) {
        let index_result =
            super::context::index_symbols_from_snapshot(&snapshot_path, db_path, project_id)?;
        tracing::info!(
            parsed = index_result.files_parsed,
            skipped = index_result.files_skipped,
            failures = index_result.parse_failures,
            "symbol index refreshed"
        );

        let changed_files = super::verify::determine_changed_files()?
            .into_iter()
            .map(|path| path.to_string_lossy().to_string())
            .collect::<Vec<_>>();
        if !changed_files.is_empty() {
            let capsule = super::capsule::build_capsule_with_symbols(
                &config.plan,
                &changed_files,
                super::capsule::MAX_CAPSULE_TOKENS,
                db_path,
                project_id,
                cache,
            )?;
            let capsule_output =
                task_dir.join(format!("capsule_{}_{}.json", config.phase, iteration));
            let capsule_json = serde_json::to_string_pretty(&capsule).map_err(AgentError::Json)?;
            fs::write(capsule_output, capsule_json).map_err(AgentError::Io)?;
        }
    }

    Ok(())
}

/// Run a fix iteration after review feedback.
pub fn run_fix_iteration(
    config: &OrchestrateConfig,
    state: &mut StateManager,
    iteration: u32,
    review_output: &Path,
) -> Result<()> {
    let repo_root = shared::git::git_repo_root()?;
    let task_dir = state.dir().to_path_buf();
    let output = task_dir.join(format!("coder_fix_{}_{}.md", config.phase, iteration));

    let result = super::coder::coder_run_fix(
        &config.plan,
        &config.phase,
        review_output,
        iteration,
        &output,
        &repo_root,
    )?;

    // Record fix session
    if let Some(ref sid) = result.session_id {
        let session = CoderSession {
            session_id: sid.clone(),
            phase: Some(config.phase.clone()),
            iteration: Some(iteration),
            engine: Some(result.engine),
            parent_session_id: None,
            created_at: Some(Utc::now().to_rfc3339()),
        };
        state.record_session(session)?;
    }

    Ok(())
}

/// Check if review content contains blocking (High-severity) issues.
pub fn has_blockers(review_content: &str) -> bool {
    super::review::has_blockers(review_content)
}

/// Check if review content contains issues at or above the given severity.
pub fn has_issues(review_content: &str, fix_until: &str) -> bool {
    super::review::has_issues(review_content, fix_until)
}

/// Generate an escalation report when max iterations are reached.
pub fn generate_escalation_report(
    _state: &StateManager,
    phase: &str,
    review_content: &str,
) -> Result<String> {
    let now = Utc::now().to_rfc3339();
    let issue_counts = super::review::count_issues(review_content);

    let report = format!(
        r#"# Escalation Report

## Metadata
- **Phase:** {phase}
- **Generated:** {now}
- **Status:** Max iterations reached — manual intervention required

## Issue Summary
- High: {}
- Medium: {}
- Low: {}

## Last Review Content

{review_content}

## Recommended Actions
1. Review the findings above manually
2. Determine which issues are false positives
3. Fix remaining issues and re-run orchestration
4. Consider adjusting the `--fix-until` threshold

## Notes
This escalation was generated automatically because the review/fix loop
exhausted its maximum iteration count without resolving all issues at the
configured severity threshold.
"#,
        issue_counts.high, issue_counts.medium, issue_counts.low
    );

    Ok(report)
}

fn resolve_semantic_db_path(project_id: &str) -> Result<PathBuf> {
    shared::paths::semantic_mcp_db_path(project_id)
}

/// Acquire the orchestration lock.
///
/// Returns a `FileLock` guard that is released on drop.
pub fn acquire_orchestration_lock(lock_path: &Path) -> Result<FileLock> {
    FileLock::acquire(lock_path, ORCH_LOCK_TIMEOUT_SECS)
}

/// Check whether a state file is stale.
///
/// A state file is considered stale if it hasn't been modified in
/// `max_age` seconds.
pub fn is_state_stale(state_file: &Path, max_age: u64) -> bool {
    let meta = match fs::metadata(state_file) {
        Ok(m) => m,
        Err(_) => return false,
    };

    let modified = match meta.modified() {
        Ok(t) => t,
        Err(_) => return false,
    };

    let elapsed = SystemTime::now()
        .duration_since(modified)
        .unwrap_or_default();

    elapsed.as_secs() > max_age
}

/// Recover a stale orchestration state.
///
/// Resets the status to `"recovered"` and clears any errors, allowing
/// the orchestration to be resumed.
pub fn recover_stale_state(state_file: &Path) -> Result<()> {
    if !state_file.exists() {
        return Err(AgentError::NotFound(format!(
            "state file not found: {}",
            state_file.display()
        )));
    }

    let mut mgr = StateManager::load(&state_file.to_string_lossy())?;

    tracing::info!("Recovering stale state: {}", state_file.display());

    mgr.clear_error()?;

    // Reset any running/fixing phases to pending
    // We need to read phase names first, then update
    let content = fs::read_to_string(state_file).map_err(AgentError::Io)?;
    let state: State = serde_json::from_str(&content)?;

    for phase in &state.phases {
        if matches!(
            phase.status,
            PhaseStatus::Running | PhaseStatus::Fixing | PhaseStatus::Review
        ) {
            let _ = mgr.set_phase_status(&phase.name, PhaseStatus::Pending);
        }
    }

    mgr.save()?;
    tracing::info!("State recovered successfully");
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_has_blockers() {
        assert!(has_blockers("[High] security issue"));
        assert!(has_blockers("severity: high"));
        assert!(has_blockers(
            "## Verdict\n- [ ] LGTM - ok\n- [ ] Request Changes - fix required\n- [x] Needs verification - missing evidence\n"
        ));
        assert!(!has_blockers("all good"));
    }

    #[test]
    fn test_has_issues_high() {
        assert!(has_issues("[High] problem", "high"));
        assert!(!has_issues("[Low] nit", "high"));
        assert!(has_issues(
            "## Verdict\n- [ ] LGTM - ok\n- [x] Request Changes - fix required\n",
            "high"
        ));
    }

    #[test]
    fn test_has_issues_medium() {
        assert!(has_issues("[High] problem", "medium"));
        assert!(has_issues("[Medium] concern", "medium"));
        assert!(!has_issues("[Low] nit", "medium"));
    }

    #[test]
    fn test_has_issues_all() {
        assert!(has_issues("[Low] nit", "all"));
        assert!(has_issues("[Low] nit", "low"));
    }

    #[test]
    fn test_review_verdict_routing_contract() {
        let blocking_verdict =
            "## Verdict\n- [ ] LGTM - ok\n- [ ] Request Changes - fix required\n- [ ] Needs verification - missing evidence\n- [x] Needs Discussion - waiting on boundary decision\n";
        let fixable_verdict =
            "## Verdict\n- [ ] LGTM - ok\n- [x] Request Changes - fix required\n- [ ] Needs verification - missing evidence\n- [ ] Needs Discussion - waiting on boundary decision\n";

        assert!(has_blockers(blocking_verdict));
        assert!(has_issues(blocking_verdict, "high"));
        assert!(!has_blockers(fixable_verdict));
        assert!(has_issues(fixable_verdict, "high"));
    }

    #[test]
    fn test_verify_status_allows_progress_for_skipped() {
        assert!(verify_status_allows_progress(
            &super::super::verify::VerifyStatus::Passed
        ));
        assert!(verify_status_allows_progress(
            &super::super::verify::VerifyStatus::Skipped
        ));
        assert!(!verify_status_allows_progress(
            &super::super::verify::VerifyStatus::Failed
        ));
        assert!(!verify_status_allows_progress(
            &super::super::verify::VerifyStatus::Error
        ));
    }

    #[test]
    fn test_generate_escalation_report() {
        let dir = tempfile::tempdir().unwrap();
        let state_path = dir.path().join("state.json");
        let state = State::new("plan.md", "test");
        let json = serde_json::to_string_pretty(&state).unwrap();
        fs::write(&state_path, &json).unwrap();

        let mgr = StateManager::load(&state_path.to_string_lossy()).unwrap();
        let report =
            generate_escalation_report(&mgr, "impl", "[High] SQL injection\n[Medium] missing docs")
                .unwrap();

        assert!(report.contains("# Escalation Report"));
        assert!(report.contains("impl"));
        assert!(report.contains("SQL injection"));
    }

    #[test]
    fn test_is_state_stale_fresh() {
        let dir = tempfile::tempdir().unwrap();
        let state_path = dir.path().join("state.json");
        fs::write(&state_path, "{}").unwrap();

        assert!(!is_state_stale(&state_path, 3600));
    }

    #[test]
    fn test_is_state_stale_nonexistent() {
        assert!(!is_state_stale(Path::new("/nonexistent/state.json"), 60));
    }

    #[test]
    fn test_orchestrate_config_defaults() {
        let config = OrchestrateConfig {
            plan: PathBuf::from("plan.md"),
            phase: "impl".to_string(),
            run_coder: false,
            fix_until: "high".to_string(),
            max_iterations: 5,
            reviewers: vec!["safety".to_string()],
            gate: None,
            codex_timeout: 7200,
            claude_timeout: 1800,
            state_file: None,
        };

        assert_eq!(config.max_iterations, 5);
        assert_eq!(config.fix_until, "high");
    }

    #[test]
    fn test_verify_result_json_roundtrip() {
        let result = VerifyResult {
            passed: true,
            finding_count: 0,
            report_path: PathBuf::from("/tmp/report.json"),
        };
        let json = serde_json::to_string(&result).unwrap();
        let deserialized: VerifyResult = serde_json::from_str(&json).unwrap();
        assert!(deserialized.passed);
        assert_eq!(deserialized.finding_count, 0);
    }

    #[test]
    fn test_acquire_and_release_lock() {
        let dir = tempfile::tempdir().unwrap();
        let lock_path = dir.path().join("test.lock");
        let lock = acquire_orchestration_lock(&lock_path).unwrap();
        assert!(lock_path.exists());
        drop(lock);
        assert!(!lock_path.exists());
    }

    #[test]
    fn test_run_review_cycle_blocks_when_coder_output_missing() {
        let dir = tempfile::tempdir().unwrap();
        let config = OrchestrateConfig {
            plan: PathBuf::from("plan.md"),
            phase: "impl".to_string(),
            run_coder: false,
            fix_until: "high".to_string(),
            max_iterations: 1,
            reviewers: vec!["safety".to_string()],
            gate: None,
            codex_timeout: 7200,
            claude_timeout: 1800,
            state_file: None,
        };

        let missing_coder_output = dir.path().join("missing_coder_output.md");
        let review_output = dir.path().join("review.md");
        let err =
            run_review_cycle(&config, &missing_coder_output, &review_output, None, 1).unwrap_err();

        assert!(err.to_string().contains("coder output missing"));
    }

    #[test]
    fn test_run_review_cycle_blocks_when_coder_output_empty() {
        let dir = tempfile::tempdir().unwrap();
        let config = OrchestrateConfig {
            plan: PathBuf::from("plan.md"),
            phase: "impl".to_string(),
            run_coder: false,
            fix_until: "high".to_string(),
            max_iterations: 1,
            reviewers: vec!["safety".to_string()],
            gate: None,
            codex_timeout: 7200,
            claude_timeout: 1800,
            state_file: None,
        };

        let empty_coder_output = dir.path().join("coder_output.md");
        fs::write(&empty_coder_output, "").unwrap();
        let review_output = dir.path().join("review.md");
        let err =
            run_review_cycle(&config, &empty_coder_output, &review_output, None, 1).unwrap_err();

        assert!(err.to_string().contains("coder output is empty"));
    }
}
