//! Core domain types for the agent_base system.
//!
//! Every struct and enum here is shared across all crates.  The [`State`]
//! struct mirrors the shell `state.json` schema (v2.0.0).

use std::fmt;

use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{AgentError, Result};

// ---------------------------------------------------------------------------
// TaskStatus
// ---------------------------------------------------------------------------

/// Overall task lifecycle status.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    /// Task has been created but not yet started.
    Pending,
    /// Task is actively being processed.
    Running,
    /// Task finished successfully.
    Completed,
    /// Task terminated due to an error.
    Error,
    /// Task was interrupted (e.g. timeout or signal).
    Interrupted,
    /// Task was recovered from a stale or interrupted state.
    Recovered,
}

impl fmt::Display for TaskStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pending => write!(f, "pending"),
            Self::Running => write!(f, "running"),
            Self::Completed => write!(f, "completed"),
            Self::Error => write!(f, "error"),
            Self::Interrupted => write!(f, "interrupted"),
            Self::Recovered => write!(f, "recovered"),
        }
    }
}

// ---------------------------------------------------------------------------
// PhaseStatus
// ---------------------------------------------------------------------------

/// Per-phase lifecycle status.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PhaseStatus {
    /// Phase has not started.
    Pending,
    /// Phase is running (coder is active).
    Running,
    /// Phase is under review.
    Review,
    /// Phase is being fixed after review feedback.
    Fixing,
    /// Phase completed successfully.
    Completed,
    /// Phase failed and cannot proceed.
    Failed,
    /// Phase exceeded its time budget.
    Timeout,
    /// Phase was escalated for human intervention.
    Escalated,
}

impl fmt::Display for PhaseStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pending => write!(f, "pending"),
            Self::Running => write!(f, "running"),
            Self::Review => write!(f, "review"),
            Self::Fixing => write!(f, "fixing"),
            Self::Completed => write!(f, "completed"),
            Self::Failed => write!(f, "failed"),
            Self::Timeout => write!(f, "timeout"),
            Self::Escalated => write!(f, "escalated"),
        }
    }
}

impl std::str::FromStr for PhaseStatus {
    type Err = String;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s {
            "pending" => Ok(Self::Pending),
            "running" => Ok(Self::Running),
            "review" => Ok(Self::Review),
            "fixing" => Ok(Self::Fixing),
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            "timeout" => Ok(Self::Timeout),
            "escalated" => Ok(Self::Escalated),
            other => Err(format!("unknown phase status: {other}")),
        }
    }
}

// ---------------------------------------------------------------------------
// CoderEngine
// ---------------------------------------------------------------------------

/// Which engine executes the coder role.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoderEngine {
    /// OpenAI Codex.
    Codex,
    /// Anthropic Claude.
    Claude,
}

impl fmt::Display for CoderEngine {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Codex => write!(f, "codex"),
            Self::Claude => write!(f, "claude"),
        }
    }
}

impl std::str::FromStr for CoderEngine {
    type Err = String;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s {
            "codex" => Ok(Self::Codex),
            "claude" => Ok(Self::Claude),
            other => Err(format!(
                "unsupported coder engine: {other} (allowed: codex|claude)"
            )),
        }
    }
}

// ---------------------------------------------------------------------------
// QualityGateLevel
// ---------------------------------------------------------------------------

/// Quality gate strictness level.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum QualityGateLevel {
    /// Strictest — all checks must pass.
    #[serde(rename = "level_a")]
    LevelA,
    /// Standard — major checks must pass.
    #[serde(rename = "level_b")]
    LevelB,
    /// Lenient — only critical checks.
    #[serde(rename = "level_c")]
    LevelC,
}

impl fmt::Display for QualityGateLevel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::LevelA => write!(f, "level_a"),
            Self::LevelB => write!(f, "level_b"),
            Self::LevelC => write!(f, "level_c"),
        }
    }
}

// ---------------------------------------------------------------------------
// QualityGateStatus
// ---------------------------------------------------------------------------

/// Quality gate pass/fail verdict.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QualityGateStatus {
    /// Not yet evaluated.
    Pending,
    /// All required checks passed.
    Passed,
    /// One or more required checks failed.
    Failed,
}

impl fmt::Display for QualityGateStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pending => write!(f, "pending"),
            Self::Passed => write!(f, "passed"),
            Self::Failed => write!(f, "failed"),
        }
    }
}

// ---------------------------------------------------------------------------
// EffortLevel
// ---------------------------------------------------------------------------

/// Model reasoning effort level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EffortLevel {
    /// Minimal reasoning.
    Low,
    /// Default reasoning effort.
    #[default]
    Medium,
    /// Elevated reasoning.
    High,
    /// Maximum reasoning budget.
    Max,
}

impl fmt::Display for EffortLevel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Low => write!(f, "low"),
            Self::Medium => write!(f, "medium"),
            Self::High => write!(f, "high"),
            Self::Max => write!(f, "max"),
        }
    }
}

impl std::str::FromStr for EffortLevel {
    type Err = String;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s {
            "low" => Ok(Self::Low),
            "medium" => Ok(Self::Medium),
            "high" => Ok(Self::High),
            "max" => Ok(Self::Max),
            other => Err(format!(
                "unknown effort level: {other} (allowed: low|medium|high|max)"
            )),
        }
    }
}

// ---------------------------------------------------------------------------
// CodexRole
// ---------------------------------------------------------------------------

/// Codex wrapper role.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexRole {
    /// Default / lightweight tasks.
    Standard,
    /// External research tasks.
    Research,
    /// Implementation tasks.
    Coder,
    /// Review tasks (highest effort).
    Reviewer,
}

impl fmt::Display for CodexRole {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Standard => write!(f, "standard"),
            Self::Research => write!(f, "research"),
            Self::Coder => write!(f, "coder"),
            Self::Reviewer => write!(f, "reviewer"),
        }
    }
}

impl std::str::FromStr for CodexRole {
    type Err = String;
    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        match s {
            "standard" => Ok(Self::Standard),
            "research" => Ok(Self::Research),
            "coder" => Ok(Self::Coder),
            "reviewer" => Ok(Self::Reviewer),
            other => Err(format!(
                "unknown codex role: {other} (allowed: standard|research|coder|reviewer)"
            )),
        }
    }
}

// ---------------------------------------------------------------------------
// ReviewVerdict
// ---------------------------------------------------------------------------

/// Reviewer verdict on a code submission.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewVerdict {
    /// Code passes review and is ready to merge.
    Lgtm,
    /// Fail-closed: provenance, gate, or budget validity is broken.
    Block,
    /// Code changes are required before merge.
    RequestChanges,
    /// Required verification evidence is missing.
    NeedsVerification,
    /// Acceptance boundary or ownership needs discussion.
    NeedsDiscussion,
}

impl ReviewVerdict {
    /// Parse the reviewer-contract label from a selected verdict checkbox.
    pub fn from_report_label(label: &str) -> Option<Self> {
        match label.trim() {
            "LGTM" => Some(Self::Lgtm),
            "BLOCK" => Some(Self::Block),
            "Request Changes" => Some(Self::RequestChanges),
            "Needs verification" => Some(Self::NeedsVerification),
            "Needs Discussion" => Some(Self::NeedsDiscussion),
            _ => None,
        }
    }

    /// Whether this verdict is an unconditional review success.
    pub fn is_lgtm(&self) -> bool {
        matches!(self, Self::Lgtm)
    }

    /// Whether this verdict should trigger a coder fix loop when available.
    pub fn requires_fix_loop(&self) -> bool {
        matches!(self, Self::RequestChanges)
    }

    /// Whether this verdict prevents the review surface from being completed.
    pub fn prevents_completion(&self) -> bool {
        !self.is_lgtm()
    }

    /// Whether this verdict blocks acceptance without a code-fix loop.
    pub fn blocks_acceptance(&self) -> bool {
        matches!(
            self,
            Self::Block | Self::NeedsVerification | Self::NeedsDiscussion
        )
    }
}

impl fmt::Display for ReviewVerdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Lgtm => write!(f, "LGTM"),
            Self::Block => write!(f, "BLOCK"),
            Self::RequestChanges => write!(f, "Request Changes"),
            Self::NeedsVerification => write!(f, "Needs verification"),
            Self::NeedsDiscussion => write!(f, "Needs Discussion"),
        }
    }
}

// ---------------------------------------------------------------------------
// IssueSeverity
// ---------------------------------------------------------------------------

/// Severity of a review issue.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IssueSeverity {
    /// Must fix before merge.
    High,
    /// Should fix, but not a blocker.
    Medium,
    /// Nice to fix; informational.
    Low,
}

impl fmt::Display for IssueSeverity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::High => write!(f, "high"),
            Self::Medium => write!(f, "medium"),
            Self::Low => write!(f, "low"),
        }
    }
}

// ---------------------------------------------------------------------------
// Top-level State
// ---------------------------------------------------------------------------

/// Top-level orchestration state (mirrors `state.json` v2.0.0).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct State {
    /// Schema version string.
    pub version: String,
    /// Task metadata.
    pub task: Task,
    /// Overall task status.
    pub status: TaskStatus,
    /// Name of the phase currently being executed.
    pub current_phase: Option<String>,
    /// Engine assignments.
    pub assignments: Assignments,
    /// Ordered list of phases.
    pub phases: Vec<Phase>,
    /// Quality gate configuration and result.
    pub quality_gate: QualityGate,
    /// Recorded sessions.
    pub sessions: Sessions,
    /// Timeout configuration.
    pub timeouts: Timeouts,
    /// ISO 8601 creation timestamp.
    pub created_at: String,
    /// ISO 8601 last-update timestamp.
    pub updated_at: String,
    /// Last error, if any.
    pub error: Option<StateError>,
}

impl Default for State {
    fn default() -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            version: "2.0.0".to_string(),
            task: Task::default(),
            status: TaskStatus::Pending,
            current_phase: None,
            assignments: Assignments::default(),
            phases: Vec::new(),
            quality_gate: QualityGate::default(),
            sessions: Sessions::default(),
            timeouts: Timeouts::default(),
            created_at: now.clone(),
            updated_at: now,
            error: None,
        }
    }
}

impl State {
    /// Create a new pending state for a given plan and task name.
    pub fn new(plan_path: &str, task_name: &str) -> Self {
        let now = Utc::now().to_rfc3339();
        Self {
            version: "2.0.0".to_string(),
            task: Task {
                id: Uuid::new_v4().to_string(),
                name: task_name.to_string(),
                plan_path: plan_path.to_string(),
                contract_id: None,
                contract_path: None,
            },
            status: TaskStatus::Pending,
            current_phase: None,
            assignments: Assignments::default(),
            phases: Vec::new(),
            quality_gate: QualityGate::default(),
            sessions: Sessions::default(),
            timeouts: Timeouts::default(),
            created_at: now.clone(),
            updated_at: now,
            error: None,
        }
    }

    /// Return the index of the phase with the given name, if it exists.
    pub fn find_phase(&self, name: &str) -> Option<usize> {
        self.phases.iter().position(|p| p.name == name)
    }

    /// Insert a new phase or no-op if it already exists (matching shell behavior).
    pub fn upsert_phase(&mut self, name: &str, max_iterations: u32) {
        if self.find_phase(name).is_some() {
            // Shell version logs "already exists" and returns — no update.
            return;
        }
        self.phases.push(Phase {
            name: name.to_string(),
            status: PhaseStatus::Pending,
            iteration: 0,
            max_iterations,
            coder: None,
            started_at: None,
            completed_at: None,
        });
        self.touch();
    }

    /// Set the status of an existing phase.
    ///
    /// Returns an error if the phase does not exist.
    pub fn set_phase_status(&mut self, name: &str, status: PhaseStatus) -> Result<()> {
        let idx = self
            .find_phase(name)
            .ok_or_else(|| AgentError::State(format!("phase not found: {name}")))?;
        self.phases[idx].status = status;
        self.touch();
        Ok(())
    }

    /// Append a coder session record.
    pub fn record_session(&mut self, session: CoderSession) {
        self.sessions.coder_sessions.push(session);
        self.touch();
    }

    /// Record an error on the state.
    pub fn set_error(&mut self, code: &str, message: &str, phase: Option<&str>) {
        self.error = Some(StateError {
            code: code.to_string(),
            message: message.to_string(),
            phase: phase.map(String::from),
            timestamp: Some(Utc::now().to_rfc3339()),
        });
        self.status = TaskStatus::Error;
        self.touch();
    }

    /// Clear any recorded error and reset status to [`TaskStatus::Running`].
    pub fn clear_error(&mut self) {
        self.error = None;
        self.status = TaskStatus::Running;
        self.touch();
    }

    /// Bump the `updated_at` timestamp to now.
    fn touch(&mut self) {
        self.updated_at = Utc::now().to_rfc3339();
    }
}

// ---------------------------------------------------------------------------
// Task
// ---------------------------------------------------------------------------

/// Task identification metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    /// Unique task identifier (UUID v4).
    pub id: String,
    /// Human-readable task name.
    pub name: String,
    /// Path to the execution plan file.
    pub plan_path: String,
    /// Optional contract identifier.
    pub contract_id: Option<String>,
    /// Optional path to the contract file.
    pub contract_path: Option<String>,
}

impl Default for Task {
    fn default() -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            name: String::new(),
            plan_path: String::new(),
            contract_id: None,
            contract_path: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Assignments
// ---------------------------------------------------------------------------

/// Engine assignment configuration.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Assignments {
    /// Which engine is assigned to the coder role.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub coder_engine: Option<CoderEngine>,
}

// ---------------------------------------------------------------------------
// Phase
// ---------------------------------------------------------------------------

/// A single phase in the orchestration pipeline.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Phase {
    /// Phase name (e.g. `"test"`, `"impl"`).
    pub name: String,
    /// Current status of this phase.
    pub status: PhaseStatus,
    /// Current iteration count (starts at 0).
    pub iteration: u32,
    /// Maximum allowed iterations before escalation.
    pub max_iterations: u32,
    /// Coder session info, if a coder has run.
    pub coder: Option<CoderInfo>,
    /// ISO 8601 timestamp when the phase started.
    pub started_at: Option<String>,
    /// ISO 8601 timestamp when the phase completed.
    pub completed_at: Option<String>,
}

// ---------------------------------------------------------------------------
// CoderInfo
// ---------------------------------------------------------------------------

/// Coder session reference within a phase.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoderInfo {
    /// Session identifier from the coder engine.
    pub session_id: Option<String>,
    /// Path to the coder's output file.
    pub output_file: Option<String>,
}

// ---------------------------------------------------------------------------
// QualityGate
// ---------------------------------------------------------------------------

/// Quality gate configuration and evaluation result.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QualityGate {
    /// Configured strictness level.
    pub level: Option<QualityGateLevel>,
    /// Evaluation result.
    pub status: QualityGateStatus,
}

impl Default for QualityGate {
    fn default() -> Self {
        Self {
            level: None,
            status: QualityGateStatus::Pending,
        }
    }
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/// Container for all recorded sessions.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Sessions {
    /// Coder sessions executed during this task.
    pub coder_sessions: Vec<CoderSession>,
}

// ---------------------------------------------------------------------------
// CoderSession
// ---------------------------------------------------------------------------

/// Record of a single coder session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoderSession {
    /// Unique session identifier.
    pub session_id: String,
    /// Phase this session belongs to.
    pub phase: Option<String>,
    /// Iteration number within the phase.
    pub iteration: Option<u32>,
    /// Engine that ran this session.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub engine: Option<CoderEngine>,
    /// Parent session for forked sessions.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_session_id: Option<String>,
    /// ISO 8601 creation timestamp.
    pub created_at: Option<String>,
}

// ---------------------------------------------------------------------------
// Timeouts
// ---------------------------------------------------------------------------

/// Timeout configuration for external engines.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Timeouts {
    /// Codex timeout in seconds (default: 7200).
    pub codex_secs: u64,
    /// Claude timeout in seconds (default: 1800).
    pub claude_secs: u64,
}

impl Default for Timeouts {
    fn default() -> Self {
        Self {
            codex_secs: 7200,
            claude_secs: 1800,
        }
    }
}

// ---------------------------------------------------------------------------
// StateError
// ---------------------------------------------------------------------------

/// Error information stored in the state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StateError {
    /// Machine-readable error code.
    pub code: String,
    /// Human-readable error message.
    pub message: String,
    /// Phase in which the error occurred.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phase: Option<String>,
    /// ISO 8601 timestamp of the error.
    pub timestamp: Option<String>,
}

// ---------------------------------------------------------------------------
// LockMetadata
// ---------------------------------------------------------------------------

/// Metadata written alongside a lock file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LockMetadata {
    /// Unique lock token (UUID v4).
    pub token: String,
    /// PID of the process that acquired the lock.
    pub pid: u32,
    /// ISO 8601 timestamp when the lock was acquired.
    pub created_at: String,
    /// ISO 8601 timestamp of the last heartbeat.
    pub updated_at: String,
    /// Owner identifier (e.g. "orchestrator").
    pub owner: String,
    /// Hostname of the machine holding the lock.
    pub host: String,
    /// Optional path to the state file guarded by this lock.
    pub state_file: Option<String>,
}

// ---------------------------------------------------------------------------
// ReviewResult
// ---------------------------------------------------------------------------

/// Result of a single reviewer's evaluation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewResult {
    /// Name of the reviewer (e.g. "safety", "perf").
    pub reviewer: String,
    /// Overall verdict.
    pub verdict: ReviewVerdict,
    /// Individual issues found.
    pub issues: Vec<ReviewIssue>,
    /// Path to the reviewer's raw output file.
    pub output_file: String,
}

// ---------------------------------------------------------------------------
// ReviewIssue
// ---------------------------------------------------------------------------

/// A single issue raised by a reviewer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewIssue {
    /// How severe this issue is.
    pub severity: IssueSeverity,
    /// Description of the issue.
    pub message: String,
    /// Source file where the issue was found.
    pub file: Option<String>,
    /// Line number in the source file.
    pub line: Option<u32>,
}

// ---------------------------------------------------------------------------
// WorktreeInfo
// ---------------------------------------------------------------------------

/// Git worktree entry returned by [`crate::git::git_worktree_list`].
#[derive(Debug, Clone)]
pub struct WorktreeInfo {
    /// Filesystem path to the worktree.
    pub path: String,
    /// Commit SHA the worktree is checked out at.
    pub head: String,
    /// Branch name, if any.
    pub branch: Option<String>,
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_new_creates_pending() {
        let s = State::new("/tmp/plan.md", "test-task");
        assert_eq!(s.status, TaskStatus::Pending);
        assert_eq!(s.task.plan_path, "/tmp/plan.md");
        assert_eq!(s.task.name, "test-task");
        assert_eq!(s.version, "2.0.0");
    }

    #[test]
    fn upsert_phase_creates_and_noop_on_existing() {
        let mut s = State::default();
        s.upsert_phase("impl", 5);
        assert_eq!(s.phases.len(), 1);
        assert_eq!(s.phases[0].max_iterations, 5);

        // Second call with different max_iterations is a no-op (matching shell behavior).
        s.upsert_phase("impl", 10);
        assert_eq!(s.phases.len(), 1);
        assert_eq!(s.phases[0].max_iterations, 5); // unchanged
    }

    #[test]
    fn set_phase_status_works() {
        let mut s = State::default();
        s.upsert_phase("test", 3);
        assert!(s.set_phase_status("test", PhaseStatus::Running).is_ok());
        assert_eq!(s.phases[0].status, PhaseStatus::Running);
    }

    #[test]
    fn set_phase_status_errors_on_missing() {
        let mut s = State::default();
        assert!(s
            .set_phase_status("nonexistent", PhaseStatus::Running)
            .is_err());
    }

    #[test]
    fn set_and_clear_error() {
        let mut s = State::default();
        s.set_error("E001", "something broke", Some("impl"));
        assert_eq!(s.status, TaskStatus::Error);
        assert!(s.error.is_some());

        s.clear_error();
        assert_eq!(s.status, TaskStatus::Running);
        assert!(s.error.is_none());
    }

    #[test]
    fn state_roundtrip_json() {
        let s = State::new("/tmp/plan.md", "roundtrip");
        let json = serde_json::to_string_pretty(&s).expect("serialize");
        let s2: State = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(s2.task.name, "roundtrip");
        assert_eq!(s2.version, "2.0.0");
    }

    #[test]
    fn enum_display_roundtrip() {
        assert_eq!(TaskStatus::Pending.to_string(), "pending");
        assert_eq!(TaskStatus::Interrupted.to_string(), "interrupted");
        assert_eq!(TaskStatus::Recovered.to_string(), "recovered");
        assert_eq!(PhaseStatus::Escalated.to_string(), "escalated");
        assert_eq!(CoderEngine::Codex.to_string(), "codex");
        assert_eq!(QualityGateLevel::LevelB.to_string(), "level_b");
        assert_eq!(QualityGateStatus::Pending.to_string(), "pending");
        assert_eq!(ReviewVerdict::Lgtm.to_string(), "LGTM");
        assert_eq!(ReviewVerdict::Block.to_string(), "BLOCK");
        assert_eq!(IssueSeverity::High.to_string(), "high");
        assert_eq!(EffortLevel::Medium.to_string(), "medium");
        assert_eq!(CodexRole::Reviewer.to_string(), "reviewer");
    }

    #[test]
    fn review_verdict_contract_helpers() {
        assert_eq!(
            ReviewVerdict::from_report_label("LGTM"),
            Some(ReviewVerdict::Lgtm)
        );
        assert_eq!(
            ReviewVerdict::from_report_label("BLOCK"),
            Some(ReviewVerdict::Block)
        );
        assert_eq!(
            ReviewVerdict::from_report_label("Needs verification"),
            Some(ReviewVerdict::NeedsVerification)
        );
        assert!(ReviewVerdict::Lgtm.is_lgtm());
        assert!(ReviewVerdict::Block.prevents_completion());
        assert!(ReviewVerdict::Block.blocks_acceptance());
        assert!(!ReviewVerdict::Block.requires_fix_loop());
        assert!(ReviewVerdict::RequestChanges.requires_fix_loop());
        assert!(ReviewVerdict::RequestChanges.prevents_completion());
        assert!(ReviewVerdict::NeedsVerification.prevents_completion());
        assert!(ReviewVerdict::NeedsVerification.blocks_acceptance());
        assert!(!ReviewVerdict::NeedsVerification.requires_fix_loop());
        assert!(ReviewVerdict::NeedsDiscussion.blocks_acceptance());
        assert!(!ReviewVerdict::NeedsDiscussion.requires_fix_loop());
        assert!(!ReviewVerdict::RequestChanges.blocks_acceptance());
    }

    #[test]
    fn record_session_appends() {
        let mut s = State::default();
        s.record_session(CoderSession {
            session_id: "abc-123".to_string(),
            phase: Some("impl".to_string()),
            iteration: Some(1),
            engine: Some(CoderEngine::Codex),
            parent_session_id: None,
            created_at: None,
        });
        assert_eq!(s.sessions.coder_sessions.len(), 1);
        assert_eq!(s.sessions.coder_sessions[0].session_id, "abc-123");
    }

    #[test]
    fn enum_from_str() {
        assert_eq!("running".parse::<PhaseStatus>(), Ok(PhaseStatus::Running));
        assert!("invalid".parse::<PhaseStatus>().is_err());

        assert_eq!("codex".parse::<CoderEngine>(), Ok(CoderEngine::Codex));
        assert!("invalid".parse::<CoderEngine>().is_err());

        assert_eq!("high".parse::<EffortLevel>(), Ok(EffortLevel::High));
        assert!("invalid".parse::<EffortLevel>().is_err());

        assert_eq!("reviewer".parse::<CodexRole>(), Ok(CodexRole::Reviewer));
        assert!("invalid".parse::<CodexRole>().is_err());
    }
}
