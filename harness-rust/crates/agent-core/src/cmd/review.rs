//! Review orchestration module — replaces `reviewer.sh` (2,371 LOC).
//!
//! Manages reviewer lifecycle: selecting reviewers (static or dynamic),
//! running them in parallel via Codex wrapper, aggregating results, and
//! validating output format.

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::thread;

use harness_cache::{helpers as cache_helpers, CacheManager};
use clap::Subcommand;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use shared::error::{AgentError, Result};
use shared::types::ReviewVerdict;

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/// Subcommands for the `review` family.
#[derive(Subcommand)]
pub enum ReviewAction {
    /// Run all specified reviewers.
    RunAll {
        /// Comma-separated reviewer names (e.g. `"safety,perf,consistency"`).
        #[arg(long)]
        reviewers: String,
        /// Path to the coder output to review.
        #[arg(long)]
        coder_output: String,
        /// Directory for individual review output files.
        #[arg(long)]
        output_dir: String,
        /// Current orchestration phase.
        #[arg(long)]
        phase: String,
    },
    /// Run a single reviewer.
    RunSingle {
        /// Reviewer name (e.g. `"safety"`).
        #[arg(long)]
        reviewer: String,
        /// Path to the coder output to review.
        #[arg(long)]
        coder_output: String,
        /// Output file for the review report.
        #[arg(long)]
        output: String,
        /// Current orchestration phase.
        #[arg(long)]
        phase: String,
    },
    /// Select reviewers dynamically based on change analysis.
    SelectDynamic {
        /// Path to the coder output to analyze.
        #[arg(long)]
        coder_output: String,
    },
    /// List all available reviewers.
    ListAvailable,
    /// Validate a review output file format.
    ValidateOutput {
        /// Path to the review file to validate.
        #[arg(long)]
        file: String,
    },
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Output from a single reviewer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewOutput {
    /// Reviewer name.
    pub reviewer: String,
    /// Extracted verdict, if parseable.
    pub verdict: Option<ReviewVerdict>,
    /// Raw review content.
    pub content: String,
    /// Path to the output file.
    pub output_file: PathBuf,
}

/// Aggregated results from all reviewers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AggregatedReview {
    /// Individual review outputs.
    pub outputs: Vec<ReviewOutput>,
    /// Combined content from all reviews.
    pub aggregated_content: String,
    /// Whether every reviewer returned `LGTM`.
    pub all_lgtm: bool,
    /// Whether any reviewer requested code changes.
    pub has_fixable_verdicts: bool,
    /// Whether any reviewer returned a non-fixable blocking verdict.
    pub has_blocking_verdicts: bool,
    /// Whether any reviewer found blocking issues.
    pub has_blockers: bool,
    /// Issue counts by severity.
    pub issue_counts: IssueCounts,
}

/// Issue counts by severity level.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct IssueCounts {
    /// Number of high-severity (blocking) issues.
    pub high: usize,
    /// Number of medium-severity issues.
    pub medium: usize,
    /// Number of low-severity issues.
    pub low: usize,
}

/// Validation result for a review output file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewOutputValidation {
    /// Overall validity.
    pub valid: bool,
    /// Whether a `# Code Review Report` header was found.
    pub has_report: bool,
    /// Whether a `## Summary` section was found.
    pub has_summary: bool,
    /// Whether a `## Findings` section was found.
    pub has_findings: bool,
    /// Whether a `## Tests` section was found.
    pub has_tests: bool,
    /// Whether a `## Review Scope` section was found.
    pub has_review_scope: bool,
    /// Whether a `## Required Verification` section was found.
    pub has_required_verification: bool,
    /// Whether a `## Evidence Reviewed` section was found.
    pub has_evidence_reviewed: bool,
    /// Whether a `## Unverified Areas` section was found.
    pub has_unverified_areas: bool,
    /// Whether a `## Open Questions` section was found.
    pub has_open_questions: bool,
    /// Whether a `## Verdict` section was found.
    pub has_verdict: bool,
    /// Validation errors, if any.
    pub errors: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CachedReviewPayload {
    content: String,
}

#[derive(Debug, Clone)]
struct PreparedReviewPacket {
    content: String,
    cache_key: String,
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// All available reviewer roles.
pub const AVAILABLE_REVIEWERS: &[&str] = &[
    "safety",
    "perf",
    "consistency",
    "sql_injection",
    "auth_security",
    "accessibility",
];

/// Default maximum parallel reviewer count.
const DEFAULT_MAX_PARALLEL: usize = 3;

/// Codex wrapper path relative to repo root.
const CODEX_WRAPPER_REL: &str = "scripts/codex-wrapper.sh";
const REVIEW_CONTRACT_PATHS: &[&str] = &[
    "docs/roles/reviewer.md",
    "docs/manual/verification-truth-matrix.md",
];

const REPORT_HEADER: &str = "# Code Review Report";
const FINDINGS_SECTION: &str = "## Findings";
const SUMMARY_SECTION: &str = "## Summary";
const TESTS_SECTION: &str = "## Tests";
const REVIEW_SCOPE_SECTION: &str = "## Review Scope";
const REQUIRED_VERIFICATION_SECTION: &str = "## Required Verification";
const EVIDENCE_REVIEWED_SECTION: &str = "## Evidence Reviewed";
const UNVERIFIED_AREAS_SECTION: &str = "## Unverified Areas";
const OPEN_QUESTIONS_SECTION: &str = "## Open Questions";
const VERDICT_SECTION: &str = "## Verdict";

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Execute a `review` subcommand.
pub fn run(action: ReviewAction) -> Result<()> {
    match action {
        ReviewAction::RunAll {
            reviewers,
            coder_output,
            output_dir,
            phase,
        } => {
            let repo_root = shared::git::git_repo_root()?;
            let result = run_all(
                &reviewers,
                Path::new(&coder_output),
                Path::new(&output_dir),
                &phase,
                &repo_root,
                None,
                0,
            )?;
            let json = serde_json::to_string_pretty(&result).map_err(AgentError::Json)?;
            println!("{json}");
            Ok(())
        }
        ReviewAction::RunSingle {
            reviewer,
            coder_output,
            output,
            phase,
        } => {
            let repo_root = shared::git::git_repo_root()?;
            let result = run_single(
                &reviewer,
                Path::new(&coder_output),
                Path::new(&output),
                &phase,
                &repo_root,
            )?;
            let json = serde_json::to_string_pretty(&result).map_err(AgentError::Json)?;
            println!("{json}");
            Ok(())
        }
        ReviewAction::SelectDynamic { coder_output } => {
            let selected = select_dynamic(Path::new(&coder_output))?;
            for r in &selected {
                println!("{r}");
            }
            Ok(())
        }
        ReviewAction::ListAvailable => {
            for r in list_available() {
                println!("{r}");
            }
            Ok(())
        }
        ReviewAction::ValidateOutput { file } => {
            let content = fs::read_to_string(&file).map_err(AgentError::Io)?;
            let validation = validate_output_format(&content)?;
            let json = serde_json::to_string_pretty(&validation).map_err(AgentError::Json)?;
            println!("{json}");
            Ok(())
        }
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Return the list of all available reviewer names.
pub fn list_available() -> Vec<String> {
    AVAILABLE_REVIEWERS.iter().map(|s| s.to_string()).collect()
}

/// Select reviewers dynamically based on the coder output content.
///
/// Heuristics:
/// - Always include `safety` and `consistency`.
/// - Include `perf` if output mentions performance-related keywords.
/// - Include `sql_injection` if SQL-related content is detected.
/// - Include `auth_security` if auth-related content is detected.
/// - Include `accessibility` if UI-related content is detected.
pub fn select_dynamic(coder_output: &Path) -> Result<Vec<String>> {
    let content = fs::read_to_string(coder_output).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to read coder output: {e}"),
        ))
    })?;

    let lower = content.to_lowercase();
    let mut reviewers = vec!["safety".to_string(), "consistency".to_string()];

    if contains_any(
        &lower,
        &[
            "performance",
            "latency",
            "throughput",
            "benchmark",
            "cache",
            "optimize",
            "O(n",
        ],
    ) {
        reviewers.push("perf".to_string());
    }

    if contains_any(
        &lower,
        &[
            "sql",
            "query",
            "database",
            "select ",
            "insert ",
            "update ",
            "delete ",
            "postgresql",
            "mysql",
            "sqlite",
        ],
    ) {
        reviewers.push("sql_injection".to_string());
    }

    if contains_any(
        &lower,
        &[
            "auth",
            "login",
            "password",
            "token",
            "jwt",
            "oauth",
            "session",
            "cookie",
            "credential",
        ],
    ) {
        reviewers.push("auth_security".to_string());
    }

    if contains_any(
        &lower,
        &[
            "aria-",
            "role=",
            "tabindex",
            "alt=",
            "screen reader",
            "accessibility",
            "a11y",
            "<button",
            "<input",
            "<form",
        ],
    ) {
        reviewers.push("accessibility".to_string());
    }

    // Deduplicate
    reviewers.sort();
    reviewers.dedup();

    Ok(reviewers)
}

/// Run a single reviewer via Codex wrapper.
///
/// 1. Builds a review prompt/packet.
/// 2. Writes the packet to a temp file.
/// 3. Invokes `codex-wrapper.sh --role reviewer --stdin`.
/// 4. Reads and parses the output.
pub fn run_single(
    reviewer: &str,
    coder_output: &Path,
    output: &Path,
    phase: &str,
    repo_root: &Path,
) -> Result<ReviewOutput> {
    // Validate reviewer name
    if !AVAILABLE_REVIEWERS.contains(&reviewer) {
        return Err(AgentError::Validation(format!(
            "unknown reviewer: {reviewer} (available: {})",
            AVAILABLE_REVIEWERS.join(", ")
        )));
    }

    tracing::info!("Running reviewer: {reviewer} (phase={phase})");

    let packet = prepare_review_packet(reviewer, coder_output, phase, repo_root)?;
    run_single_with_packet(reviewer, &packet.content, output, repo_root)
}

fn compute_file_hash(path: &Path) -> Result<String> {
    let bytes = fs::read(path).map_err(AgentError::Io)?;
    Ok(compute_bytes_hash(&bytes))
}

fn compute_bytes_hash(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

fn normalize_cache_path(path: &Path, repo_root: &Path) -> Result<String> {
    let relative = path
        .strip_prefix(repo_root)
        .unwrap_or(path)
        .to_string_lossy()
        .to_string();
    cache_helpers::validate_and_normalize_path(&relative, repo_root)
}

fn encode_cached_review_payload(output: &ReviewOutput) -> Result<String> {
    serde_json::to_string(&CachedReviewPayload {
        content: output.content.clone(),
    })
    .map_err(AgentError::Json)
}

fn decode_cached_review_payload(json: &str) -> Result<CachedReviewPayload> {
    serde_json::from_str(json).map_err(AgentError::Json)
}

fn compute_review_cache_key(packet_content: &str, repo_root: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"packet:");
    hasher.update(packet_content.as_bytes());

    for relative_path in REVIEW_CONTRACT_PATHS {
        let path = repo_root.join(relative_path);
        if let Ok(bytes) = fs::read(&path) {
            hasher.update(b"\0contract:");
            hasher.update(relative_path.as_bytes());
            hasher.update(b"\0");
            hasher.update(&bytes);
        }
    }

    hex::encode(hasher.finalize())
}

fn prepare_review_packet(
    reviewer: &str,
    coder_output: &Path,
    phase: &str,
    repo_root: &Path,
) -> Result<PreparedReviewPacket> {
    let content = build_review_packet(reviewer, coder_output, phase)?;
    let cache_key = compute_review_cache_key(&content, repo_root);
    Ok(PreparedReviewPacket { content, cache_key })
}

fn run_single_with_packet(
    reviewer: &str,
    packet: &str,
    output: &Path,
    repo_root: &Path,
) -> Result<ReviewOutput> {
    let mut prompt_file = tempfile::Builder::new()
        .prefix(&format!("review_{reviewer}_"))
        .suffix(".md")
        .tempfile()
        .map_err(AgentError::Io)?;
    prompt_file
        .write_all(packet.as_bytes())
        .map_err(AgentError::Io)?;
    prompt_file.flush().map_err(AgentError::Io)?;

    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(AgentError::Io)?;
    }

    let wrapper = repo_root.join(CODEX_WRAPPER_REL);
    if !wrapper.exists() {
        return Err(AgentError::NotFound(format!(
            "Codex wrapper not found: {}",
            wrapper.display()
        )));
    }

    let prompt_content = fs::read(prompt_file.path()).map_err(AgentError::Io)?;

    let mut cmd = Command::new(&wrapper);
    cmd.args(["--role", "reviewer", "--stdin"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());

    let mut child = cmd.spawn().map_err(|e| {
        AgentError::Command(format!("Failed to start Codex wrapper for {reviewer}: {e}"))
    })?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(&prompt_content).map_err(AgentError::Io)?;
    }

    let command_output = child
        .wait_with_output()
        .map_err(|e| AgentError::Command(format!("Codex wrapper for {reviewer} failed: {e}")))?;

    fs::write(output, &command_output.stdout).map_err(AgentError::Io)?;

    if !command_output.status.success() {
        return Err(AgentError::Command(format!(
            "Reviewer {reviewer} returned exit code {:?}: {}",
            command_output.status.code(),
            command_output_excerpt(&command_output)
        )));
    }

    let content = String::from_utf8_lossy(&command_output.stdout).to_string();
    let verdict = validate_review_output(&content, reviewer)?;

    tracing::info!("Reviewer {reviewer} complete: verdict={:?}", verdict);

    Ok(ReviewOutput {
        reviewer: reviewer.to_string(),
        verdict: Some(verdict),
        content,
        output_file: output.to_path_buf(),
    })
}

/// Run multiple reviewers in parallel.
///
/// Uses `std::thread` (not tokio) for simplicity.  At most `max_parallel`
/// threads run concurrently.
pub fn run_parallel(
    reviewers: &[String],
    coder_output: &Path,
    output_dir: &Path,
    phase: &str,
    repo_root: &Path,
    mut cache: Option<&mut CacheManager>,
    iteration: u32,
) -> Result<Vec<ReviewOutput>> {
    fs::create_dir_all(output_dir).map_err(AgentError::Io)?;

    let force_full_review = tree_sitter_index::should_force_full_review(iteration, 5);
    let results: Arc<Mutex<Vec<ReviewOutput>>> = Arc::new(Mutex::new(Vec::new()));
    let errors: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let mut reviewers_to_run: Vec<(String, String)> = Vec::new();
    let mut review_cache_keys: HashMap<String, String> = HashMap::new();
    let mut cached_outputs = Vec::new();

    if !force_full_review {
        if let Some(cache) = cache.as_deref_mut() {
            let coder_hash = compute_file_hash(coder_output)?;
            let coder_key = normalize_cache_path(coder_output, repo_root)?;
            let head_commit =
                shared::git::git_current_head().unwrap_or_else(|_| "unknown".to_string());
            let mut pending = Vec::new();

            for reviewer in reviewers {
                let packet = prepare_review_packet(reviewer, coder_output, phase, repo_root)?;
                review_cache_keys.insert(reviewer.clone(), packet.cache_key.clone());
                match cache.check_review(
                    &coder_key,
                    &coder_hash,
                    reviewer,
                    &packet.cache_key,
                    &head_commit,
                ) {
                    Some(hit) => match decode_cached_review_payload(&hit.findings) {
                        Ok(payload) => match validate_review_output(&payload.content, reviewer) {
                            Ok(verdict) => {
                                let output_file =
                                    output_dir.join(review_output_filename(phase, reviewer));
                                fs::write(&output_file, &payload.content)
                                    .map_err(AgentError::Io)?;
                                cached_outputs.push(ReviewOutput {
                                    reviewer: reviewer.clone(),
                                    verdict: Some(verdict),
                                    content: payload.content,
                                    output_file,
                                });
                            }
                            Err(e) => {
                                tracing::warn!(
                                    reviewer,
                                    error = %e,
                                    "cached review output invalid; running reviewer again"
                                );
                                pending.push((reviewer.clone(), packet.content.clone()));
                            }
                        },
                        Err(e) => {
                            tracing::warn!(
                                reviewer,
                                error = %e,
                                "cached review payload invalid; running reviewer again"
                            );
                            pending.push((reviewer.clone(), packet.content.clone()));
                        }
                    },
                    None => pending.push((reviewer.clone(), packet.content)),
                }
            }

            reviewers_to_run = pending;
        }
    }

    if reviewers_to_run.is_empty() && cached_outputs.len() != reviewers.len() {
        reviewers_to_run = reviewers
            .iter()
            .map(|reviewer| {
                let packet = prepare_review_packet(reviewer, coder_output, phase, repo_root)?;
                review_cache_keys.insert(reviewer.clone(), packet.cache_key.clone());
                Ok((reviewer.clone(), packet.content))
            })
            .collect::<Result<Vec<_>>>()?;
    }

    // Process reviewers in batches of max_parallel
    for chunk in reviewers_to_run.chunks(DEFAULT_MAX_PARALLEL) {
        let mut handles = Vec::new();

        for (reviewer, packet) in chunk {
            let reviewer = reviewer.clone();
            let packet = packet.clone();
            let output_file = output_dir.join(review_output_filename(phase, &reviewer));
            let repo_root = repo_root.to_path_buf();
            let results = Arc::clone(&results);
            let errors = Arc::clone(&errors);

            let handle = thread::spawn(move || {
                match run_single_with_packet(&reviewer, &packet, &output_file, &repo_root) {
                    Ok(output) => {
                        let mut r = results.lock().unwrap_or_else(|e| e.into_inner());
                        r.push(output);
                    }
                    Err(e) => {
                        tracing::error!("Reviewer {reviewer} failed: {e}");
                        let mut errs = errors.lock().unwrap_or_else(|e| e.into_inner());
                        errs.push(format!("{reviewer}: {e}"));
                    }
                }
            });
            handles.push(handle);
        }

        for handle in handles {
            if let Err(e) = handle.join() {
                tracing::error!("Reviewer thread panicked: {e:?}");
                let mut errs = errors.lock().unwrap_or_else(|pe| pe.into_inner());
                errs.push(format!("reviewer thread panicked: {e:?}"));
            }
        }
    }

    let results = match Arc::try_unwrap(results) {
        Ok(mutex) => mutex.into_inner().unwrap_or_default(),
        Err(arc) => {
            let guard = arc.lock().unwrap_or_else(|e| e.into_inner());
            guard.clone()
        }
    };

    let errors = match Arc::try_unwrap(errors) {
        Ok(mutex) => mutex.into_inner().unwrap_or_default(),
        Err(arc) => {
            let guard = arc.lock().unwrap_or_else(|e| e.into_inner());
            guard.clone()
        }
    };

    if !errors.is_empty() {
        return Err(AgentError::Command(format!(
            "review cycle blocked because reviewer execution failed: {}",
            errors.join("; ")
        )));
    }

    let mut outputs = cached_outputs;
    outputs.extend(results);
    outputs.sort_by(|a, b| a.reviewer.cmp(&b.reviewer));

    if outputs.len() != reviewers.len() {
        return Err(AgentError::Command(format!(
            "review cycle blocked because {} of {} reviewer outputs were produced",
            outputs.len(),
            reviewers.len()
        )));
    }

    if !force_full_review {
        if let Some(cache) = cache {
            let coder_hash = compute_file_hash(coder_output)?;
            let coder_key = normalize_cache_path(coder_output, repo_root)?;
            let head_commit =
                shared::git::git_current_head().unwrap_or_else(|_| "unknown".to_string());

            for output in &outputs {
                let Some(cache_key) = review_cache_keys.get(&output.reviewer) else {
                    tracing::warn!(
                        reviewer = %output.reviewer,
                        "review cache key missing; skipping cache store"
                    );
                    continue;
                };
                let payload = match encode_cached_review_payload(output) {
                    Ok(value) => value,
                    Err(e) => {
                        tracing::warn!(
                            reviewer = %output.reviewer,
                            error = %e,
                            "failed to encode review payload for cache"
                        );
                        continue;
                    }
                };

                let verdict = output
                    .verdict
                    .as_ref()
                    .map(std::string::ToString::to_string)
                    .unwrap_or_else(|| "error".to_string());

                if let Err(e) = cache.store_review(
                    &coder_key,
                    &coder_hash,
                    &output.reviewer,
                    cache_key,
                    &head_commit,
                    &verdict,
                    &payload,
                ) {
                    tracing::warn!(
                        reviewer = %output.reviewer,
                        error = %e,
                        "failed to store review cache entry"
                    );
                }
            }
        }
    }

    Ok(outputs)
}

/// Aggregate individual review outputs into the shell-compatible batch surface.
pub fn aggregate(outputs: &[ReviewOutput]) -> String {
    let mut report = String::new();

    for output in outputs {
        let section_name = output
            .output_file
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("review_output.md");
        report.push_str(&format!("## {section_name}\n"));
        report.push_str(&output.content);
        if !output.content.ends_with('\n') {
            report.push('\n');
        }
        report.push('\n');
    }

    report
}

/// Run all reviewers (orchestration function).
///
/// 1. Parses the comma-separated reviewer list.
/// 2. Runs them in parallel.
/// 3. Aggregates results.
pub fn run_all(
    reviewers: &str,
    coder_output: &Path,
    output_dir: &Path,
    phase: &str,
    repo_root: &Path,
    cache: Option<&mut CacheManager>,
    iteration: u32,
) -> Result<AggregatedReview> {
    let reviewer_list: Vec<String> = reviewers
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    if reviewer_list.is_empty() {
        return Err(AgentError::Validation("no reviewers specified".to_string()));
    }

    tracing::info!(
        "Running {} reviewer(s): {}",
        reviewer_list.len(),
        reviewer_list.join(", ")
    );

    let outputs = run_parallel(
        &reviewer_list,
        coder_output,
        output_dir,
        phase,
        repo_root,
        cache,
        iteration,
    )?;

    let aggregated_content = aggregate(&outputs);
    let aggregated_validation = validate_output_format(&aggregated_content)?;
    if !aggregated_validation.valid {
        return Err(AgentError::Validation(format!(
            "aggregated review output is invalid: {}",
            aggregated_validation.errors.join("; ")
        )));
    }

    // Write aggregated report atomically
    let agg_path = output_dir.join("review_aggregated.md");
    {
        use tempfile::NamedTempFile;
        let dir = agg_path.parent().unwrap_or(Path::new("."));
        let mut tmp = NamedTempFile::new_in(dir).map_err(AgentError::Io)?;
        tmp.write_all(aggregated_content.as_bytes())
            .map_err(AgentError::Io)?;
        tmp.persist(&agg_path)
            .map_err(|e| AgentError::Io(e.error))?;
    }

    Ok(summarize_outputs(outputs, aggregated_content))
}

/// Validate the format of a review output.
pub fn validate_output_format(content: &str) -> Result<ReviewOutputValidation> {
    if content
        .lines()
        .map(|line| line.trim_end_matches('\r').trim())
        .any(|line| aggregated_section_name(line).is_some())
    {
        return validate_aggregated_output_format(content);
    }

    Ok(validate_single_review_report(content))
}

/// Extract the verdict from a review report.
pub fn extract_verdict(content: &str) -> Option<ReviewVerdict> {
    let mut verdicts = extract_all_verdicts(content);
    if verdicts.len() == 1 {
        verdicts.pop()
    } else {
        None
    }
}

fn validate_review_output(content: &str, reviewer: &str) -> Result<ReviewVerdict> {
    let validation = validate_output_format(content)?;
    if !validation.valid {
        return Err(AgentError::Validation(format!(
            "reviewer {reviewer} produced invalid output: {}",
            validation.errors.join("; ")
        )));
    }

    let verdict = extract_verdict(content).ok_or_else(|| {
        AgentError::Validation(format!(
            "reviewer {reviewer} did not produce a valid verdict selection"
        ))
    })?;

    Ok(verdict)
}

fn summarize_outputs(outputs: Vec<ReviewOutput>, aggregated_content: String) -> AggregatedReview {
    let combined_content: String = outputs
        .iter()
        .map(|output| output.content.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let all_lgtm = outputs
        .iter()
        .all(|output| output.verdict.as_ref().is_some_and(ReviewVerdict::is_lgtm));
    let has_fixable_verdicts = outputs.iter().any(|output| {
        output
            .verdict
            .as_ref()
            .is_some_and(ReviewVerdict::requires_fix_loop)
    });
    let has_blocking_verdicts = outputs.iter().any(|output| {
        output
            .verdict
            .as_ref()
            .is_some_and(ReviewVerdict::blocks_acceptance)
    });
    let blocker = has_blockers(&combined_content) || has_blocking_verdicts;
    let counts = count_issues(&combined_content);

    AggregatedReview {
        outputs,
        aggregated_content,
        all_lgtm,
        has_fixable_verdicts,
        has_blocking_verdicts,
        has_blockers: blocker,
        issue_counts: counts,
    }
}

/// Check if review content contains blocking (High-severity) issues.
pub fn has_blockers(content: &str) -> bool {
    if has_blocking_verdicts(content) {
        return true;
    }

    let lower = content.to_lowercase();
    lower.contains("[high]")
        || lower.contains("severity: high")
        || lower.contains("**high**")
        || lower.contains("blocker")
}

/// Check if review content contains issues at or above a given severity.
///
/// `fix_until` can be `"high"`, `"medium"`, `"low"`, or `"all"`.
pub fn has_issues(content: &str, fix_until: &str) -> bool {
    if has_non_lgtm_verdicts(content) {
        return true;
    }

    let lower = content.to_lowercase();
    match fix_until.to_lowercase().as_str() {
        "high" => {
            lower.contains("[high]")
                || lower.contains("severity: high")
                || lower.contains("**high**")
        }
        "medium" => {
            has_issues(content, "high")
                || lower.contains("[medium]")
                || lower.contains("severity: medium")
                || lower.contains("**medium**")
        }
        "low" | "all" => {
            has_issues(content, "medium")
                || lower.contains("[low]")
                || lower.contains("severity: low")
                || lower.contains("**low**")
        }
        _ => false,
    }
}

/// Count issues by severity in the review content.
pub fn count_issues(content: &str) -> IssueCounts {
    let lower = content.to_lowercase();

    let high = count_pattern(&lower, "[high]")
        + count_pattern(&lower, "severity: high")
        + count_pattern(&lower, "**high**");

    let medium = count_pattern(&lower, "[medium]")
        + count_pattern(&lower, "severity: medium")
        + count_pattern(&lower, "**medium**");

    let low = count_pattern(&lower, "[low]")
        + count_pattern(&lower, "severity: low")
        + count_pattern(&lower, "**low**");

    IssueCounts { high, medium, low }
}

/// Build a review prompt/packet for a given reviewer.
///
/// Reads the coder output and wraps it with role-specific instructions.
pub fn build_review_packet(reviewer: &str, coder_output: &Path, phase: &str) -> Result<String> {
    let coder_content = fs::read_to_string(coder_output).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to read coder output for review: {e}"),
        ))
    })?;

    let role_instructions = match reviewer {
        "safety" => "Focus on security vulnerabilities, injection risks, unsafe operations, secret exposure, and access control issues.",
        "perf" => "Focus on performance bottlenecks, unnecessary allocations, O(n^2) patterns, missing caching opportunities, and scalability concerns.",
        "consistency" => "Focus on code style consistency, naming conventions, architecture patterns, documentation completeness, and adherence to project standards.",
        "sql_injection" => "Focus exclusively on SQL injection vulnerabilities, parameterized query usage, ORM security, and database access patterns.",
        "auth_security" => "Focus on authentication and authorization: password handling, token management, session security, CSRF protection, and privilege escalation.",
        "accessibility" => "Focus on web accessibility (WCAG 2.1): ARIA attributes, keyboard navigation, color contrast, screen reader compatibility, and semantic HTML.",
        _ => "Perform a general code review covering correctness, readability, and maintainability.",
    };

    let token_estimate = estimate_tokens(&coder_content);

    let packet = format!(
        r#"# Code Review Request

## Reviewer Role: {reviewer}
## Phase: {phase}
## Content Size: ~{token_estimate} tokens

## Review Focus
{role_instructions}

## Output Contract
Return one markdown report that follows the reviewer contract in `docs/roles/reviewer.md`.

```markdown
# Code Review Report

## Review Request
- incoming request status:
- task id:
- task lineage ledger entry:
- prior task id:
- slice id:
- prior slice id:
- review request target:
- discovery owner:
- bug class candidate:
- worker outcome:
- request objective:

## Review Outcome
- review verdict:
- outgoing next status:
- next action:

## Slice Contract
- change surface:
- in-scope:
- out-of-scope:
- required checks:
- evidence destination:
- completion boundary:

## Loop Budget Ledger
- fix-review loops used:
- closure resets used:
- reviewer-found same-class finding count:
- re-slice count for task:
- cumulative reviewer requests for task:
- cumulative late same-class findings for task:
- cumulative closure resets for task:
- task-level stall-or-wall-time budget:
- task-level stall-or-wall-time budget status:

## Summary
[1-3 short lines with the overall assessment]

## Findings
- None.

## Tests
- **実施:** YES / NO
- **結果:** PASS / FAIL / NOT RUN
- **未実施の理由:**

## Review Scope
- change surface:
- in-scope:
- out-of-scope:
- 対象 hunk / ownership:
- evidence destination:
- completion boundary:

## Class Closure Sheet
- bug class:
- task id:
- task lineage ledger entry:
- prior task id:
- slice id:
- change surface:
- owned sink universe:
- closed universe basis:
- closed universe status:
- search method / exact commands:
- sheet status:
- last reset trigger:
- remaining issues:
- basis:
- timestamp:
- target scope:

## Adversarial Pre-Closure Pass
- executed at:
- reviewer request target:
- search commands:
- opposite hypothesis checked:
- untouched owned surfaces checked:
- boundary / fallback / alias paths checked:
- new same-class sinks found:
- result:

## Required Verification
- command:
- result:
- covered scope:
- artifact pointer:
- no-artifact reason:
- artifact integrity:

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract

## Evidence Reviewed
- diff:
- change surface declaration:
- scope declaration:
- verification result:
- evidence destination:
- artifact:

## Unverified Areas
- None.

## Open Questions
- None.

## Verdict
- [ ] LGTM - pending acceptance
- [ ] BLOCK - blocked
- [ ] Request Changes - pending review
- [ ] Needs verification - pending verification
- [ ] Needs Discussion - blocked
```

If no issues are found:
- In `## Findings`, write `- None.`
- Keep the canonical sections explicit
- Select exactly one verdict
- Use `BLOCK` for fail-closed missing provenance / budget / gate conditions
- Use `Needs verification` only for non-blocking verification gaps

---

## Code Under Review

{coder_content}
"#
    );

    Ok(packet)
}

/// Re-export `estimate_tokens` from the capsule module to avoid duplication.
use crate::cmd::capsule::estimate_tokens;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Check if a string contains any of the given patterns.
fn contains_any(haystack: &str, patterns: &[&str]) -> bool {
    patterns.iter().any(|p| haystack.contains(p))
}

/// Count non-overlapping occurrences of a pattern in a string.
fn count_pattern(text: &str, pattern: &str) -> usize {
    text.matches(pattern).count()
}

fn review_output_filename(phase: &str, reviewer: &str) -> String {
    format!("{phase}_review_{reviewer}.md")
}

fn empty_validation() -> ReviewOutputValidation {
    ReviewOutputValidation {
        valid: false,
        has_report: false,
        has_summary: false,
        has_findings: false,
        has_tests: false,
        has_review_scope: false,
        has_required_verification: false,
        has_evidence_reviewed: false,
        has_unverified_areas: false,
        has_open_questions: false,
        has_verdict: false,
        errors: Vec::new(),
    }
}

fn validate_single_review_report(content: &str) -> ReviewOutputValidation {
    let mut validation = empty_validation();
    let mut current_section: Option<&str> = None;
    let mut summary_has_content = false;
    let mut findings_has_valid_content = false;
    let mut tests_has_content = false;
    let mut review_scope_has_content = false;
    let mut required_verification_has_content = false;
    let mut evidence_reviewed_has_content = false;
    let mut unverified_areas_has_content = false;
    let mut open_questions_has_content = false;
    let mut verdict_selection_count = 0;

    for raw_line in content.lines() {
        let trimmed = raw_line.trim_end_matches('\r').trim();

        match trimmed {
            REPORT_HEADER => {
                validation.has_report = true;
                current_section = None;
                continue;
            }
            SUMMARY_SECTION => {
                validation.has_summary = true;
                current_section = Some("summary");
                continue;
            }
            FINDINGS_SECTION => {
                validation.has_findings = true;
                current_section = Some("findings");
                continue;
            }
            TESTS_SECTION => {
                validation.has_tests = true;
                current_section = Some("tests");
                continue;
            }
            REVIEW_SCOPE_SECTION => {
                validation.has_review_scope = true;
                current_section = Some("review_scope");
                continue;
            }
            REQUIRED_VERIFICATION_SECTION => {
                validation.has_required_verification = true;
                current_section = Some("required_verification");
                continue;
            }
            EVIDENCE_REVIEWED_SECTION => {
                validation.has_evidence_reviewed = true;
                current_section = Some("evidence_reviewed");
                continue;
            }
            UNVERIFIED_AREAS_SECTION => {
                validation.has_unverified_areas = true;
                current_section = Some("unverified_areas");
                continue;
            }
            OPEN_QUESTIONS_SECTION => {
                validation.has_open_questions = true;
                current_section = Some("open_questions");
                continue;
            }
            VERDICT_SECTION => {
                validation.has_verdict = true;
                current_section = Some("verdict");
                continue;
            }
            _ if trimmed.starts_with("## ") => {
                current_section = None;
                continue;
            }
            _ => {}
        }

        match current_section {
            Some("summary") if !trimmed.is_empty() => summary_has_content = true,
            Some("findings") if is_findings_entry(trimmed) => findings_has_valid_content = true,
            Some("tests") if !trimmed.is_empty() => tests_has_content = true,
            Some("review_scope") if !trimmed.is_empty() => review_scope_has_content = true,
            Some("required_verification") if !trimmed.is_empty() => {
                required_verification_has_content = true;
            }
            Some("evidence_reviewed") if !trimmed.is_empty() => {
                evidence_reviewed_has_content = true
            }
            Some("unverified_areas") if !trimmed.is_empty() => unverified_areas_has_content = true,
            Some("open_questions") if !trimmed.is_empty() => open_questions_has_content = true,
            Some("verdict") if selected_verdict_from_line(trimmed).is_some() => {
                verdict_selection_count += 1;
            }
            _ => {}
        }
    }

    let mut errors = Vec::new();

    if !validation.has_report {
        errors.push(format!("Missing required header: {REPORT_HEADER}"));
    }
    if !validation.has_summary {
        errors.push(format!("Missing required section: {SUMMARY_SECTION}"));
    }
    if !validation.has_findings {
        errors.push(format!("Missing required section: {FINDINGS_SECTION}"));
    }
    if !validation.has_tests {
        errors.push(format!("Missing required section: {TESTS_SECTION}"));
    }
    if !validation.has_review_scope {
        errors.push(format!("Missing required section: {REVIEW_SCOPE_SECTION}"));
    }
    if !validation.has_required_verification {
        errors.push(format!(
            "Missing required section: {REQUIRED_VERIFICATION_SECTION}"
        ));
    }
    if !validation.has_evidence_reviewed {
        errors.push(format!(
            "Missing required section: {EVIDENCE_REVIEWED_SECTION}"
        ));
    }
    if !validation.has_unverified_areas {
        errors.push(format!(
            "Missing required section: {UNVERIFIED_AREAS_SECTION}"
        ));
    }
    if !validation.has_open_questions {
        errors.push(format!(
            "Missing required section: {OPEN_QUESTIONS_SECTION}"
        ));
    }
    if !validation.has_verdict {
        errors.push(format!("Missing required section: {VERDICT_SECTION}"));
    }
    if validation.has_summary && !summary_has_content {
        errors.push("Summary section must not be empty".to_string());
    }
    if validation.has_findings && !findings_has_valid_content {
        errors.push(
            "Findings section must contain '- None.' or severity-tagged findings".to_string(),
        );
    }
    if validation.has_tests && !tests_has_content {
        errors.push("Tests section must not be empty".to_string());
    }
    if validation.has_review_scope && !review_scope_has_content {
        errors.push("Review Scope section must not be empty".to_string());
    }
    if validation.has_required_verification && !required_verification_has_content {
        errors.push("Required Verification section must not be empty".to_string());
    }
    if validation.has_evidence_reviewed && !evidence_reviewed_has_content {
        errors.push("Evidence Reviewed section must not be empty".to_string());
    }
    if validation.has_unverified_areas && !unverified_areas_has_content {
        errors.push("Unverified Areas section must not be empty".to_string());
    }
    if validation.has_open_questions && !open_questions_has_content {
        errors.push("Open Questions section must not be empty".to_string());
    }
    if validation.has_verdict && verdict_selection_count != 1 {
        errors.push("Verdict section must contain exactly one selected checkbox".to_string());
    }

    validation.valid = errors.is_empty();
    validation.errors = errors;
    validation
}

fn validate_aggregated_output_format(content: &str) -> Result<ReviewOutputValidation> {
    let mut validation = ReviewOutputValidation {
        valid: false,
        has_report: true,
        has_summary: true,
        has_findings: true,
        has_tests: true,
        has_review_scope: true,
        has_required_verification: true,
        has_evidence_reviewed: true,
        has_unverified_areas: true,
        has_open_questions: true,
        has_verdict: true,
        errors: Vec::new(),
    };
    let mut current_section_name: Option<String> = None;
    let mut current_section_body: Vec<String> = Vec::new();
    let mut saw_section = false;

    for raw_line in content.lines() {
        let line = raw_line.trim_end_matches('\r');
        let trimmed = line.trim();

        if let Some(section_name) = aggregated_section_name(trimmed) {
            if let Some(previous_section_name) = current_section_name.take() {
                merge_aggregate_section_validation(
                    &mut validation,
                    &previous_section_name,
                    &current_section_body,
                );
            }

            current_section_name = Some(section_name.to_string());
            current_section_body.clear();
            saw_section = true;
            continue;
        }

        if saw_section {
            current_section_body.push(line.to_string());
        } else if !trimmed.is_empty() {
            validation.errors.push(
                "Aggregated review output must not contain content outside reviewer sections"
                    .to_string(),
            );
        }
    }

    if let Some(previous_section_name) = current_section_name.take() {
        merge_aggregate_section_validation(
            &mut validation,
            &previous_section_name,
            &current_section_body,
        );
    }

    if !saw_section {
        validation.has_report = false;
        validation.has_summary = false;
        validation.has_findings = false;
        validation.has_tests = false;
        validation.has_review_scope = false;
        validation.has_required_verification = false;
        validation.has_evidence_reviewed = false;
        validation.has_unverified_areas = false;
        validation.has_open_questions = false;
        validation.has_verdict = false;
        validation
            .errors
            .push("Aggregated review output is missing reviewer sections".to_string());
    }

    validation.valid = validation.errors.is_empty();
    Ok(validation)
}

fn merge_aggregate_section_validation(
    validation: &mut ReviewOutputValidation,
    section_name: &str,
    section_body: &[String],
) {
    let section_content = section_body.join("\n");
    let section_validation = validate_single_review_report(&section_content);
    validation.has_report &= section_validation.has_report;
    validation.has_summary &= section_validation.has_summary;
    validation.has_findings &= section_validation.has_findings;
    validation.has_tests &= section_validation.has_tests;
    validation.has_review_scope &= section_validation.has_review_scope;
    validation.has_required_verification &= section_validation.has_required_verification;
    validation.has_evidence_reviewed &= section_validation.has_evidence_reviewed;
    validation.has_unverified_areas &= section_validation.has_unverified_areas;
    validation.has_open_questions &= section_validation.has_open_questions;
    validation.has_verdict &= section_validation.has_verdict;

    if !section_validation.valid {
        validation.errors.extend(
            section_validation
                .errors
                .into_iter()
                .map(|error| format!("{section_name}: {error}")),
        );
    }
}

fn is_findings_entry(line: &str) -> bool {
    let trimmed = line.trim();
    let lower = trimmed.to_ascii_lowercase();
    lower == "- none"
        || lower == "- none."
        || lower == "- no findings"
        || lower == "- no findings."
        || trimmed.starts_with("### [High] ")
        || trimmed.starts_with("### [Medium] ")
        || trimmed.starts_with("### [Low] ")
}

fn aggregated_section_name(line: &str) -> Option<&str> {
    let section = line.strip_prefix("## ")?;
    let (prefix, suffix) = section.split_once("_review_")?;
    if prefix.is_empty() || suffix.is_empty() || !suffix.ends_with(".md") {
        return None;
    }
    Some(section)
}

fn selected_verdict_from_line(line: &str) -> Option<ReviewVerdict> {
    let candidate = line
        .trim()
        .strip_prefix("- [x] ")
        .or_else(|| line.trim().strip_prefix("- [X] "))?;
    let label = candidate.split(" - ").next().unwrap_or(candidate).trim();
    ReviewVerdict::from_report_label(label)
}

fn extract_all_verdicts(content: &str) -> Vec<ReviewVerdict> {
    let mut verdicts = Vec::new();
    let mut in_verdict = false;
    let mut selected = None;
    let mut invalid_section = false;

    for line in content.lines() {
        let trimmed = line.trim_end_matches('\r').trim();

        if trimmed == VERDICT_SECTION {
            finalize_verdict_section(&mut verdicts, &mut selected, &mut invalid_section);
            in_verdict = true;
            continue;
        }

        if in_verdict && trimmed.starts_with("## ") {
            finalize_verdict_section(&mut verdicts, &mut selected, &mut invalid_section);
            in_verdict = false;
            continue;
        }

        if !in_verdict {
            continue;
        }

        if let Some(verdict) = selected_verdict_from_line(trimmed) {
            if selected.is_some() {
                selected = None;
                invalid_section = true;
                continue;
            }
            selected = Some(verdict);
        }
    }

    if in_verdict {
        finalize_verdict_section(&mut verdicts, &mut selected, &mut invalid_section);
    }

    verdicts
}

fn finalize_verdict_section(
    verdicts: &mut Vec<ReviewVerdict>,
    selected: &mut Option<ReviewVerdict>,
    invalid_section: &mut bool,
) {
    if !*invalid_section {
        if let Some(verdict) = selected.take() {
            verdicts.push(verdict);
        }
    } else {
        *selected = None;
    }
    *invalid_section = false;
}

fn has_non_lgtm_verdicts(content: &str) -> bool {
    extract_all_verdicts(content)
        .iter()
        .any(ReviewVerdict::prevents_completion)
}

fn has_blocking_verdicts(content: &str) -> bool {
    extract_all_verdicts(content)
        .iter()
        .any(ReviewVerdict::blocks_acceptance)
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn verdict_block(selected: &str) -> String {
        [
            ("LGTM", "問題なし、マージ可能"),
            ("BLOCK", "fail-closed。required deterministic check failure、provenance 欠落、ceiling 超過、または final gate 不成立"),
            ("Request Changes", "修正が必要"),
            ("Needs verification", "required checks の証跡不足"),
            ("Needs Discussion", "議論が必要"),
        ]
        .into_iter()
        .map(|(label, description)| {
            let checked = if label == selected { "x" } else { " " };
            format!("- [{checked}] {label} - {description}")
        })
        .collect::<Vec<_>>()
        .join("\n")
    }

    fn valid_review_report(selected_verdict: &str) -> String {
        format!(
            r#"# Code Review Report

## Summary
Reviewed the synthetic fixture and recorded the acceptance boundary.

## Findings
- None.

## Tests
- **実施:** NO
- **結果:** NOT RUN
- **未実施の理由:** Synthetic fixture only.

## Review Scope
- 対象 slice: native reviewer contract
- in-scope: review report contract validation
- out-of-scope: runtime queue behavior
- 対象 hunk / ownership: synthetic fixture only
- completion boundary: contract-compliant report validates

## Required Verification
- command: bash test/integration/native_reviewer_surface_smoke.sh
- result: NOT RUN
- artifact path:
- artifact 不在理由: synthetic fixture only
- covered slice / hunk: report-format validator

## Evidence Reviewed
- diff: synthetic diff fixture
- scope declaration: synthetic fixture scope
- verification result: synthetic fixture only
- artifact: none; synthetic fixture

## Unverified Areas
- None.

## Open Questions
- None.

## Verdict
{}
"#,
            verdict_block(selected_verdict)
        )
    }

    #[test]
    fn test_list_available() {
        let list = list_available();
        assert!(list.contains(&"safety".to_string()));
        assert!(list.contains(&"perf".to_string()));
        assert!(list.contains(&"consistency".to_string()));
        assert_eq!(list.len(), AVAILABLE_REVIEWERS.len());
    }

    #[test]
    fn test_extract_verdict_lgtm() {
        let content = format!("## Verdict\n{}\n", verdict_block("LGTM"));
        assert_eq!(extract_verdict(&content), Some(ReviewVerdict::Lgtm));
    }

    #[test]
    fn test_extract_verdict_request_changes() {
        let content = format!("## Verdict\n{}\n", verdict_block("Request Changes"));
        assert_eq!(
            extract_verdict(&content),
            Some(ReviewVerdict::RequestChanges)
        );
    }

    #[test]
    fn test_extract_verdict_block() {
        let content = format!("## Verdict\n{}\n", verdict_block("BLOCK"));
        assert_eq!(extract_verdict(&content), Some(ReviewVerdict::Block));
    }

    #[test]
    fn test_extract_verdict_needs_verification() {
        let content = format!("## Verdict\n{}\n", verdict_block("Needs verification"));
        assert_eq!(
            extract_verdict(&content),
            Some(ReviewVerdict::NeedsVerification)
        );
    }

    #[test]
    fn test_extract_verdict_needs_discussion() {
        let content = format!("## Verdict\n{}\n", verdict_block("Needs Discussion"));
        assert_eq!(
            extract_verdict(&content),
            Some(ReviewVerdict::NeedsDiscussion)
        );
    }

    #[test]
    fn test_extract_verdict_none() {
        let content = "## Summary\nSome review without a verdict section.";
        assert_eq!(extract_verdict(content), None);
    }

    #[test]
    fn test_extract_verdict_requires_checkbox_selection() {
        let content = "## Verdict\nThe code passes review.";
        assert_eq!(extract_verdict(content), None);
    }

    #[test]
    fn test_extract_verdict_multiple_selected_is_invalid() {
        let content =
            "## Verdict\n- [x] LGTM - 問題なし、マージ可能\n- [x] Request Changes - 修正が必要\n";
        assert_eq!(extract_verdict(content), None);
    }

    #[test]
    fn test_extract_all_verdicts_aggregated() {
        let content = format!(
            "## impl_review_safety.md\n{}\n## impl_review_perf.md\n{}\n",
            valid_review_report("LGTM"),
            valid_review_report("Request Changes")
        );
        assert_eq!(
            extract_all_verdicts(&content),
            vec![ReviewVerdict::Lgtm, ReviewVerdict::RequestChanges]
        );
    }

    #[test]
    fn test_has_blockers_true() {
        assert!(has_blockers("Found issue [High] in auth module"));
        assert!(has_blockers("severity: high — SQL injection"));
        assert!(has_blockers("This is a **high** severity issue"));
        assert!(has_blockers("This is a blocker issue"));
        assert!(has_blockers(&valid_review_report("BLOCK")));
        assert!(has_blockers(&valid_review_report("Needs verification")));
    }

    #[test]
    fn test_has_blockers_false() {
        assert!(!has_blockers("All looks good. No issues found."));
        assert!(!has_blockers("[Low] minor style issue"));
        assert!(!has_blockers(&valid_review_report("Request Changes")));
    }

    #[test]
    fn test_has_issues() {
        let content = "[High] security issue\n[Medium] perf concern\n[Low] style nit";
        assert!(has_issues(content, "high"));
        assert!(has_issues(content, "medium"));
        assert!(has_issues(content, "low"));
        assert!(has_issues(content, "all"));

        let low_only = "[Low] style nit";
        assert!(!has_issues(low_only, "high"));
        assert!(!has_issues(low_only, "medium"));
        assert!(has_issues(low_only, "low"));

        let request_changes = valid_review_report("Request Changes");
        assert!(has_issues(&request_changes, "high"));
        assert!(has_issues(&request_changes, "medium"));

        let needs_discussion = valid_review_report("Needs Discussion");
        assert!(has_issues(&needs_discussion, "high"));
    }

    #[test]
    fn test_count_issues() {
        let content = "[High] issue 1\n[High] issue 2\n[Medium] concern\n[Low] nit 1\n[Low] nit 2\n[Low] nit 3";
        let counts = count_issues(content);
        assert_eq!(counts.high, 2);
        assert_eq!(counts.medium, 1);
        assert_eq!(counts.low, 3);
    }

    #[test]
    fn test_count_issues_empty() {
        let counts = count_issues("No issues here.");
        assert_eq!(counts.high, 0);
        assert_eq!(counts.medium, 0);
        assert_eq!(counts.low, 0);
    }

    #[test]
    fn test_validate_output_format_valid() {
        let content = valid_review_report("LGTM");
        let validation = validate_output_format(&content).unwrap();
        assert!(validation.valid);
        assert!(validation.has_report);
        assert!(validation.has_summary);
        assert!(validation.has_findings);
        assert!(validation.has_tests);
        assert!(validation.has_review_scope);
        assert!(validation.has_required_verification);
        assert!(validation.has_evidence_reviewed);
        assert!(validation.has_unverified_areas);
        assert!(validation.has_open_questions);
        assert!(validation.has_verdict);
        assert!(validation.errors.is_empty());
    }

    #[test]
    fn test_validate_output_format_missing_sections() {
        let content =
            "# Code Review Report\n\n## Summary\nSome text but no findings or verdict sections.";
        let validation = validate_output_format(content).unwrap();
        assert!(!validation.valid);
        assert!(validation.has_report);
        assert!(validation.has_summary);
        assert!(!validation.has_findings);
        assert!(!validation.has_tests);
        assert!(!validation.has_verdict);
        assert!(validation
            .errors
            .iter()
            .any(|error| error.contains(FINDINGS_SECTION)));
        assert!(validation
            .errors
            .iter()
            .any(|error| error.contains(TESTS_SECTION)));
    }

    #[test]
    fn test_validate_output_format_empty() {
        let validation = validate_output_format("").unwrap();
        assert!(!validation.valid);
        assert_eq!(validation.errors.len(), 10);
    }

    #[test]
    fn test_validate_output_format_requires_findings_content() {
        let content = valid_review_report("LGTM").replace("- None.", "No structured findings here");
        let validation = validate_output_format(&content).unwrap();
        assert!(!validation.valid);
        assert!(validation
            .errors
            .iter()
            .any(|error| error.contains("Findings section must contain")));
    }

    #[test]
    fn test_validate_output_format_valid_aggregated() {
        let content = format!(
            "## impl_review_safety.md\n{}\n## impl_review_perf.md\n{}\n",
            valid_review_report("LGTM"),
            valid_review_report("Request Changes")
        );
        let validation = validate_output_format(&content).unwrap();
        assert!(validation.valid);
    }

    #[test]
    fn test_validate_output_format_rejects_aggregated_preamble() {
        let content = format!(
            "# Aggregated Review Report\n\n## impl_review_safety.md\n{}\n",
            valid_review_report("LGTM")
        );
        let validation = validate_output_format(&content).unwrap();
        assert!(!validation.valid);
        assert!(validation
            .errors
            .iter()
            .any(|error| error.contains("outside reviewer sections")));
    }

    #[test]
    fn test_validate_review_output_accepts_needs_verification_verdict() {
        let content = valid_review_report("Needs verification");
        assert_eq!(
            validate_review_output(&content, "safety").unwrap(),
            ReviewVerdict::NeedsVerification
        );
    }

    #[test]
    fn test_validate_review_output_accepts_needs_discussion_verdict() {
        let content = valid_review_report("Needs Discussion");
        assert_eq!(
            validate_review_output(&content, "safety").unwrap(),
            ReviewVerdict::NeedsDiscussion
        );
    }

    #[test]
    fn test_validate_review_output_accepts_request_changes_verdict() {
        let content = valid_review_report("Request Changes");
        assert_eq!(
            validate_review_output(&content, "safety").unwrap(),
            ReviewVerdict::RequestChanges
        );
    }

    #[test]
    fn test_validate_review_output_accepts_block_verdict() {
        let content = valid_review_report("BLOCK");
        assert_eq!(
            validate_review_output(&content, "safety").unwrap(),
            ReviewVerdict::Block
        );
    }

    #[test]
    fn test_estimate_tokens_ascii() {
        // 100 ASCII chars -> ~25 tokens
        let text = "a".repeat(100);
        let tokens = estimate_tokens(&text);
        assert_eq!(tokens, 25);
    }

    #[test]
    fn test_estimate_tokens_non_ascii() {
        // 30 non-ASCII chars -> ~20 tokens
        let text = "\u{3042}".repeat(30); // Japanese 'a'
        let tokens = estimate_tokens(&text);
        assert_eq!(tokens, 20);
    }

    #[test]
    fn test_estimate_tokens_mixed() {
        let text = "Hello World! \u{3053}\u{3093}\u{306b}\u{3061}\u{306f}";
        let tokens = estimate_tokens(text);
        assert!(tokens > 0);
    }

    #[test]
    fn test_estimate_tokens_empty() {
        assert_eq!(estimate_tokens(""), 0);
    }

    #[test]
    fn test_build_review_packet() {
        let dir = tempfile::tempdir().unwrap();
        let coder_output = dir.path().join("coder.md");
        fs::write(&coder_output, "fn main() { println!(\"hello\"); }").unwrap();

        let packet = build_review_packet("safety", &coder_output, "impl").unwrap();
        assert!(packet.contains("Reviewer Role: safety"));
        assert!(packet.contains("Phase: impl"));
        assert!(packet.contains("security vulnerabilities"));
        assert!(packet.contains("# Code Review Report"));
        assert!(packet.contains("## Review Scope"));
        assert!(packet.contains("Needs verification"));
        assert!(packet.contains("fn main()"));
    }

    #[test]
    fn test_build_review_packet_missing_file() {
        let result = build_review_packet("safety", Path::new("/nonexistent/file.md"), "impl");
        assert!(result.is_err());
    }

    #[test]
    fn test_prepare_review_packet_cache_key_tracks_inline_contract_changes() {
        let dir = tempfile::tempdir().unwrap();
        let coder_output = dir.path().join("coder.md");
        fs::write(&coder_output, "fn main() { println!(\"hello\"); }").unwrap();

        let prepared = prepare_review_packet("safety", &coder_output, "impl", dir.path()).unwrap();
        let changed_packet = prepared.content.replace(
            "Use `Needs verification`",
            "Use `Needs verification` or escalate when",
        );

        assert_ne!(
            compute_review_cache_key(&changed_packet, dir.path()),
            prepared.cache_key
        );
    }

    #[test]
    fn test_prepare_review_packet_cache_key_tracks_contract_docs() {
        let dir = tempfile::tempdir().unwrap();
        let coder_output = dir.path().join("coder.md");
        let reviewer_doc = dir.path().join("docs/roles/reviewer.md");
        let matrix_doc = dir.path().join("docs/manual/verification-truth-matrix.md");

        fs::create_dir_all(reviewer_doc.parent().unwrap()).unwrap();
        fs::create_dir_all(matrix_doc.parent().unwrap()).unwrap();
        fs::write(&coder_output, "fn main() { println!(\"hello\"); }").unwrap();
        fs::write(&reviewer_doc, "reviewer contract v1").unwrap();
        fs::write(&matrix_doc, "matrix contract v1").unwrap();

        let prepared_v1 =
            prepare_review_packet("safety", &coder_output, "impl", dir.path()).unwrap();

        fs::write(&reviewer_doc, "reviewer contract v2").unwrap();

        let prepared_v2 =
            prepare_review_packet("safety", &coder_output, "impl", dir.path()).unwrap();

        assert_ne!(prepared_v1.cache_key, prepared_v2.cache_key);
    }

    #[test]
    fn test_select_dynamic_basic() {
        let dir = tempfile::tempdir().unwrap();
        let output = dir.path().join("coder.md");
        fs::write(&output, "Added SQL query for user authentication with password hashing and performance optimization").unwrap();

        let reviewers = select_dynamic(&output).unwrap();
        assert!(reviewers.contains(&"safety".to_string()));
        assert!(reviewers.contains(&"consistency".to_string()));
        assert!(reviewers.contains(&"sql_injection".to_string()));
        assert!(reviewers.contains(&"auth_security".to_string()));
        assert!(reviewers.contains(&"perf".to_string()));
    }

    #[test]
    fn test_select_dynamic_minimal() {
        let dir = tempfile::tempdir().unwrap();
        let output = dir.path().join("coder.md");
        fs::write(&output, "Refactored utility function for string parsing").unwrap();

        let reviewers = select_dynamic(&output).unwrap();
        // Should always have safety + consistency
        assert!(reviewers.contains(&"safety".to_string()));
        assert!(reviewers.contains(&"consistency".to_string()));
        // Should not have domain-specific reviewers
        assert!(!reviewers.contains(&"sql_injection".to_string()));
    }

    #[test]
    fn test_aggregate() {
        let outputs = vec![
            ReviewOutput {
                reviewer: "safety".to_string(),
                verdict: Some(ReviewVerdict::Lgtm),
                content: valid_review_report("LGTM"),
                output_file: PathBuf::from("/tmp/impl_review_safety.md"),
            },
            ReviewOutput {
                reviewer: "perf".to_string(),
                verdict: Some(ReviewVerdict::RequestChanges),
                content: valid_review_report("Request Changes"),
                output_file: PathBuf::from("/tmp/impl_review_perf.md"),
            },
        ];

        let report = aggregate(&outputs);
        assert!(report.starts_with("## impl_review_safety.md"));
        assert!(report.contains("## impl_review_perf.md"));
        assert!(report.contains("# Code Review Report"));
        assert!(!report.contains("Aggregated Review Report"));
        assert!(validate_output_format(&report).unwrap().valid);
        assert!(has_issues(&report, "high"));
    }

    #[test]
    fn test_aggregate_empty() {
        let report = aggregate(&[]);
        assert!(report.is_empty());
    }

    #[test]
    fn test_summarize_outputs_tracks_fixable_and_blocking_verdicts() {
        let outputs = vec![
            ReviewOutput {
                reviewer: "perf".to_string(),
                verdict: Some(ReviewVerdict::RequestChanges),
                content: valid_review_report("Request Changes"),
                output_file: PathBuf::from("/tmp/impl_review_perf.md"),
            },
            ReviewOutput {
                reviewer: "safety".to_string(),
                verdict: Some(ReviewVerdict::NeedsVerification),
                content: valid_review_report("Needs verification"),
                output_file: PathBuf::from("/tmp/impl_review_safety.md"),
            },
        ];

        let aggregated_content = aggregate(&outputs);
        let review = summarize_outputs(outputs, aggregated_content);

        assert!(!review.all_lgtm);
        assert!(review.has_fixable_verdicts);
        assert!(review.has_blocking_verdicts);
        assert!(review.has_blockers);
    }

    #[test]
    fn test_contains_any() {
        assert!(contains_any("hello world", &["hello", "foo"]));
        assert!(!contains_any("hello world", &["foo", "bar"]));
        assert!(!contains_any("", &["foo"]));
    }

    #[test]
    fn test_count_pattern() {
        assert_eq!(count_pattern("aaa", "a"), 3);
        assert_eq!(count_pattern("hello world hello", "hello"), 2);
        assert_eq!(count_pattern("no match", "xyz"), 0);
    }

    #[test]
    fn test_review_output_json_roundtrip() {
        let output = ReviewOutput {
            reviewer: "safety".to_string(),
            verdict: Some(ReviewVerdict::Lgtm),
            content: valid_review_report("LGTM"),
            output_file: PathBuf::from("/tmp/review.md"),
        };
        let json = serde_json::to_string(&output).unwrap();
        let deserialized: ReviewOutput = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.reviewer, "safety");
        assert_eq!(deserialized.verdict, Some(ReviewVerdict::Lgtm));
    }

    #[test]
    fn test_issue_counts_json_roundtrip() {
        let counts = IssueCounts {
            high: 1,
            medium: 2,
            low: 3,
        };
        let json = serde_json::to_string(&counts).unwrap();
        let deserialized: IssueCounts = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.high, 1);
        assert_eq!(deserialized.medium, 2);
        assert_eq!(deserialized.low, 3);
    }
}
