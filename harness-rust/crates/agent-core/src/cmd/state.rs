//! State management — complete replacement for `state.sh` (906 LOC, 37 jq calls -> 0).
//!
//! All JSON manipulation is handled by `serde_json`. File writes are atomic
//! (temp file + rename). Locking uses the RAII `LockGuard` from `shared::lock`.

use chrono::Utc;
use clap::Subcommand;
use serde_json::Value;
use std::path::{Path, PathBuf};
use uuid::Uuid;

use shared::error::{AgentError, Result};
use shared::lock::FileLock;
use shared::types::*;
use shared::validation::validate_jq_path;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Schema version this module produces and expects.
const STATE_SCHEMA_VERSION: &str = "2.0.0";

/// Default lock timeout in seconds.
const LOCK_TIMEOUT_SECS: u64 = 30;

// ---------------------------------------------------------------------------
// Ephemeral field names scrubbed from live state (mirrors _state_live_scrub_filter)
// ---------------------------------------------------------------------------

/// Keys removed from every object during scrub (walk phase).
const SCRUB_KEYS: &[&str] = &[
    "reviews",
    "fixes",
    "review",
    "reviewers",
    "reviewer",
    "review_file",
    "review_files",
    "review_output",
    "review_outputs",
    "reviewer_output",
    "reviewer_outputs",
    "review_session",
    "review_sessions",
    "reviewer_session",
    "reviewer_sessions",
    "review_trace",
    "reviewer_trace",
    "review_payload",
    "reviewer_payload",
    "session_id",
    "session_ids",
    "parent_session_id",
    "last_session_id",
    "last_reviewer_session_id",
];

// ---------------------------------------------------------------------------
// CLI subcommands
// ---------------------------------------------------------------------------

#[derive(Subcommand)]
pub enum StateAction {
    /// Initialize new state.json.
    Init {
        /// Path to the plan file.
        #[arg(long)]
        plan: String,
        /// Task name (identifier).
        #[arg(long)]
        task: String,
        /// Output directory (default: .claude/tmp/<task>).
        #[arg(long)]
        output_dir: Option<String>,
    },
    /// Get a value from state.json at the given JSON path.
    Get {
        /// Path to state.json.
        #[arg(long)]
        file: String,
        /// JSON path (e.g. `.status`, `.phases[0].name`).
        path: String,
    },
    /// Set a value in state.json at the given JSON path.
    Set {
        /// Path to state.json.
        #[arg(long)]
        file: String,
        /// JSON path.
        path: String,
        /// JSON value (string, number, object, etc.).
        value: String,
    },
    /// Append a JSON object to an array in state.json.
    Append {
        /// Path to state.json.
        #[arg(long)]
        file: String,
        /// JSON path to the array.
        path: String,
        /// JSON object to append.
        value: String,
    },
    /// Show human-readable state summary.
    Summary {
        /// Path to state.json.
        #[arg(long)]
        file: String,
    },
    /// Upsert a phase.
    UpsertPhase {
        /// Path to state.json.
        #[arg(long)]
        file: String,
        /// Phase name.
        #[arg(long)]
        name: String,
        /// Maximum iterations (default 5).
        #[arg(long, default_value_t = 5)]
        max_iterations: u32,
    },
    /// Set phase status.
    SetPhaseStatus {
        /// Path to state.json.
        #[arg(long)]
        file: String,
        /// Phase name.
        #[arg(long)]
        name: String,
        /// New status.
        #[arg(long)]
        status: String,
    },
    /// Record a coder session.
    RecordSession {
        /// Path to state.json.
        #[arg(long)]
        file: String,
        /// Session ID.
        #[arg(long)]
        session_id: String,
        /// Phase name.
        #[arg(long)]
        phase: String,
        /// Iteration number.
        #[arg(long)]
        iteration: u32,
        /// Coder engine (claude|codex).
        #[arg(long)]
        engine: Option<String>,
        /// Parent session ID (for forks).
        #[arg(long)]
        parent_id: Option<String>,
    },
    /// Get last session ID.
    GetLastSession {
        /// Path to state.json.
        #[arg(long)]
        file: String,
        /// Filter by phase.
        #[arg(long)]
        phase: Option<String>,
        /// Filter by engine.
        #[arg(long)]
        engine: Option<String>,
    },
    /// Set error info.
    SetError {
        /// Path to state.json.
        #[arg(long)]
        file: String,
        /// Error code.
        #[arg(long)]
        code: String,
        /// Error message.
        #[arg(long)]
        message: String,
        /// Phase where the error occurred.
        #[arg(long)]
        phase: Option<String>,
    },
    /// Clear error info.
    ClearError {
        /// Path to state.json.
        #[arg(long)]
        file: String,
    },
    /// Set coder engine.
    SetEngine {
        /// Path to state.json.
        #[arg(long)]
        file: String,
        /// Engine (claude|codex).
        #[arg(long)]
        engine: String,
    },
    /// Set task contract.
    SetContract {
        /// Path to state.json.
        #[arg(long)]
        file: String,
        /// Contract ID.
        #[arg(long)]
        id: String,
        /// Contract path.
        #[arg(long)]
        path: String,
    },
    /// Resolve plan path to absolute.
    ResolvePlan {
        /// Path to state.json.
        #[arg(long)]
        file: String,
        /// Repo root override.
        #[arg(long)]
        repo_root: Option<String>,
    },
    /// Run scrub on state.json.
    Scrub {
        /// Path to state.json.
        #[arg(long)]
        file: String,
    },
}

// ---------------------------------------------------------------------------
// CLI dispatch
// ---------------------------------------------------------------------------

pub fn run(action: StateAction) -> Result<()> {
    match action {
        StateAction::Init {
            plan,
            task,
            output_dir,
        } => {
            shared::validation::validate_identifier(&task, "task")?;
            let mgr = StateManager::init(&plan, &task, output_dir.as_deref())?;
            println!("{}", mgr.file_path().display());
            Ok(())
        }
        StateAction::Get { file, path } => {
            let mgr = StateManager::load(&file)?;
            let val = mgr.get(&path)?;
            // Print the value: strings without quotes, others as JSON.
            match &val {
                Value::String(s) => println!("{s}"),
                Value::Null => {} // match jq `// empty` — print nothing
                _ => println!("{val}"),
            }
            Ok(())
        }
        StateAction::Set { file, path, value } => {
            let mut mgr = StateManager::load(&file)?;
            let json_val = parse_json_value(&value);
            mgr.set(&path, json_val)?;
            Ok(())
        }
        StateAction::Append { file, path, value } => {
            let mut mgr = StateManager::load(&file)?;
            let json_val: Value = serde_json::from_str(&value)
                .map_err(|e| AgentError::Validation(format!("invalid JSON: {e}")))?;
            mgr.append(&path, json_val)?;
            Ok(())
        }
        StateAction::Summary { file } => {
            let mgr = StateManager::load(&file)?;
            mgr.show_summary();
            Ok(())
        }
        StateAction::UpsertPhase {
            file,
            name,
            max_iterations,
        } => {
            let mut mgr = StateManager::load(&file)?;
            mgr.upsert_phase(&name, max_iterations)?;
            Ok(())
        }
        StateAction::SetPhaseStatus { file, name, status } => {
            let mut mgr = StateManager::load(&file)?;
            let ps: PhaseStatus = status.parse().map_err(AgentError::Validation)?;
            mgr.set_phase_status(&name, ps)?;
            Ok(())
        }
        StateAction::RecordSession {
            file,
            session_id,
            phase,
            iteration,
            engine,
            parent_id,
        } => {
            let mut mgr = StateManager::load(&file)?;
            shared::validation::validate_session_id(&session_id)?;
            let eng = match &engine {
                Some(e) => Some(e.parse::<CoderEngine>().map_err(AgentError::Validation)?),
                None => None,
            };
            let session = CoderSession {
                session_id,
                phase: Some(phase),
                iteration: Some(iteration),
                engine: eng,
                parent_session_id: parent_id,
                created_at: Some(now_iso()),
            };
            mgr.record_session(session)?;
            Ok(())
        }
        StateAction::GetLastSession {
            file,
            phase,
            engine,
        } => {
            let mgr = StateManager::load(&file)?;
            let eng = match &engine {
                Some(e) => Some(e.parse::<CoderEngine>().map_err(AgentError::Validation)?),
                None => None,
            };
            if let Some(sid) = mgr.get_last_session(phase.as_deref(), eng) {
                println!("{sid}");
            }
            Ok(())
        }
        StateAction::SetError {
            file,
            code,
            message,
            phase,
        } => {
            let mut mgr = StateManager::load(&file)?;
            mgr.set_error(&code, &message, phase.as_deref())?;
            Ok(())
        }
        StateAction::ClearError { file } => {
            let mut mgr = StateManager::load(&file)?;
            mgr.clear_error()?;
            Ok(())
        }
        StateAction::SetEngine { file, engine } => {
            let mut mgr = StateManager::load(&file)?;
            let eng: CoderEngine = engine
                .parse()
                .map_err(|e: String| AgentError::Validation(e))?;
            mgr.set_coder_engine(eng)?;
            Ok(())
        }
        StateAction::SetContract { file, id, path } => {
            let mut mgr = StateManager::load(&file)?;
            mgr.set_contract(&id, &path)?;
            Ok(())
        }
        StateAction::ResolvePlan { file, repo_root } => {
            let mgr = StateManager::load(&file)?;
            let resolved = mgr.resolve_plan_path(repo_root.as_deref())?;
            println!("{}", resolved.display());
            Ok(())
        }
        StateAction::Scrub { file } => {
            let mut mgr = StateManager::load(&file)?;
            mgr.scrub_live_state();
            mgr.atomic_write()?;
            Ok(())
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Parse a string as JSON if possible, otherwise wrap it as a JSON string.
fn parse_json_value(s: &str) -> Value {
    serde_json::from_str(s).unwrap_or_else(|_| Value::String(s.to_string()))
}

/// Current UTC time in ISO-8601 format.
fn now_iso() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

// ---------------------------------------------------------------------------
// StateManager
// ---------------------------------------------------------------------------

/// State manager — handles all state.json CRUD operations.
///
/// Replaces: `.claude/commands/lib/state.sh` (906 LOC, 37 jq calls -> 0).
pub struct StateManager {
    /// Deserialized state.
    state: State,
    /// Absolute path to state.json.
    file_path: PathBuf,
    /// Lock directory path (sibling of state.json).
    lock_path: PathBuf,
    /// Parent directory of state.json.
    dir: PathBuf,
}

impl StateManager {
    // -----------------------------------------------------------------------
    // Public accessors
    // -----------------------------------------------------------------------

    /// Return a reference to the directory containing the state file.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Return a reference to the state file path.
    pub fn file_path(&self) -> &Path {
        &self.file_path
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// Initialize a new state.json.
    ///
    /// Creates the output directory, generates a UUID task ID, and writes
    /// the initial state file. Equivalent to `state_init` in state.sh.
    pub fn init(plan_path: &str, task_name: &str, output_dir: Option<&str>) -> Result<Self> {
        let normalized = Self::normalize_plan_path(plan_path)?;

        // Determine output directory.
        let dir = match output_dir {
            Some(d) => PathBuf::from(d),
            None => {
                // Default: .claude/tmp/<task_name> relative to repo root.
                shared::git::git_repo_root()
                    .unwrap_or_else(|_| PathBuf::from("."))
                    .join(".claude")
                    .join("tmp")
                    .join(task_name)
            }
        };
        std::fs::create_dir_all(&dir)?;

        let file_path = dir.join("state.json");
        let lock_path = dir.join(".state.lock");
        let now = now_iso();

        let state = State {
            version: STATE_SCHEMA_VERSION.to_string(),
            task: Task {
                id: Uuid::new_v4().to_string(),
                name: task_name.to_string(),
                plan_path: normalized,
                contract_id: None,
                contract_path: None,
            },
            status: TaskStatus::Pending,
            current_phase: None,
            assignments: Assignments::default(),
            phases: Vec::new(),
            quality_gate: QualityGate {
                level: None,
                status: QualityGateStatus::Pending,
            },
            sessions: Sessions::default(),
            timeouts: Timeouts::default(),
            created_at: now.clone(),
            updated_at: now,
            error: None,
        };

        let mut mgr = Self {
            state,
            file_path,
            lock_path,
            dir,
        };

        mgr.scrub_live_state();
        mgr.atomic_write()?;
        tracing::info!("State initialized: {}", mgr.file_path.display());
        Ok(mgr)
    }

    /// Load an existing state.json.
    ///
    /// Validates schema version and runs scrub on load.
    /// Equivalent to `state_load` in state.sh.
    pub fn load(state_file: &str) -> Result<Self> {
        let file_path = PathBuf::from(state_file);
        if !file_path.exists() {
            return Err(AgentError::NotFound(format!(
                "state file not found: {state_file}"
            )));
        }

        let dir = file_path
            .parent()
            .ok_or_else(|| AgentError::State("cannot determine state directory".into()))?
            .to_path_buf();
        let lock_path = dir.join(".state.lock");

        let data = std::fs::read_to_string(&file_path)?;
        let state: State = serde_json::from_str(&data)?;

        if state.version != STATE_SCHEMA_VERSION {
            tracing::warn!(
                "State schema version mismatch: {} (expected: {STATE_SCHEMA_VERSION})",
                state.version
            );
        }

        let mut mgr = Self {
            state,
            file_path,
            lock_path,
            dir,
        };

        mgr.scrub_live_state();
        // Persist scrubbed version on load.
        mgr.atomic_write()?;
        tracing::debug!("State loaded: {}", mgr.file_path.display());
        Ok(mgr)
    }

    /// Save the current state, updating `updated_at` and running scrub.
    ///
    /// Acquires lock, writes atomically, runs scrub, releases lock.
    /// Equivalent to `state_save` in state.sh.
    pub fn save(&mut self) -> Result<()> {
        self.state.updated_at = now_iso();
        self.scrub_live_state();
        self.atomic_write()?;
        tracing::debug!("State saved: {}", self.file_path.display());
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Generic JSON-path accessors (jq-path compatible)
    // -----------------------------------------------------------------------

    /// Get a value at the given JSON path.
    ///
    /// Validates the path against the jq-path pattern.
    /// Returns `Value::Null` if the path doesn't exist.
    pub fn get(&self, path: &str) -> Result<Value> {
        validate_jq_path(path)?;
        let root = serde_json::to_value(&self.state)?;
        Ok(resolve_path(&root, path))
    }

    /// Set a value at the given JSON path, then persist atomically.
    pub fn set(&mut self, path: &str, value: Value) -> Result<()> {
        validate_jq_path(path)?;
        let mut root = serde_json::to_value(&self.state)?;
        set_at_path(&mut root, path, value)?;
        self.state = serde_json::from_value(root)?;
        self.scrub_live_state();
        self.atomic_write()?;
        Ok(())
    }

    /// Append a value to an array at the given JSON path, then persist.
    pub fn append(&mut self, path: &str, value: Value) -> Result<()> {
        validate_jq_path(path)?;
        if !value.is_object() && !value.is_array() && !value.is_string() && !value.is_number() {
            // Accept any JSON value, but validate it's parseable.
        }
        let mut root = serde_json::to_value(&self.state)?;
        append_at_path(&mut root, path, value)?;
        self.state = serde_json::from_value(root)?;
        self.scrub_live_state();
        self.atomic_write()?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Phase management
    // -----------------------------------------------------------------------

    /// Find the index of a phase by name, or `None` if not found.
    pub fn find_phase(&self, name: &str) -> Option<usize> {
        self.state.phases.iter().position(|p| p.name == name)
    }

    /// Add a new phase or no-op if it already exists.
    pub fn upsert_phase(&mut self, name: &str, max_iterations: u32) -> Result<()> {
        if self.find_phase(name).is_some() {
            tracing::debug!("Phase already exists: {name}");
            return Ok(());
        }

        let phase = Phase {
            name: name.to_string(),
            status: PhaseStatus::Pending,
            iteration: 0,
            max_iterations,
            coder: None,
            started_at: None,
            completed_at: None,
        };
        self.state.phases.push(phase);
        self.save()?;
        tracing::info!("Phase added: {name}");
        Ok(())
    }

    /// Set the status of a named phase. Automatically sets timestamps.
    pub fn set_phase_status(&mut self, name: &str, status: PhaseStatus) -> Result<()> {
        let idx = self
            .find_phase(name)
            .ok_or_else(|| AgentError::NotFound(format!("phase not found: {name}")))?;

        self.state.current_phase = Some(name.to_string());
        self.state.phases[idx].status = status.clone();

        let now = now_iso();
        match status {
            PhaseStatus::Running | PhaseStatus::Review | PhaseStatus::Fixing => {
                if self.state.phases[idx].started_at.is_none() {
                    self.state.phases[idx].started_at = Some(now);
                }
            }
            PhaseStatus::Completed
            | PhaseStatus::Failed
            | PhaseStatus::Timeout
            | PhaseStatus::Escalated => {
                self.state.phases[idx].completed_at = Some(now);
            }
            PhaseStatus::Pending => {}
        }

        self.save()?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Session management
    // -----------------------------------------------------------------------

    /// Record a coder session.
    pub fn record_session(&mut self, session: CoderSession) -> Result<()> {
        tracing::debug!("Session recorded: {}", session.session_id);
        self.state.sessions.coder_sessions.push(session);
        self.save()?;
        Ok(())
    }

    /// Get the last session ID, optionally filtered by phase and/or engine.
    pub fn get_last_session(
        &self,
        phase: Option<&str>,
        engine: Option<CoderEngine>,
    ) -> Option<String> {
        self.state
            .sessions
            .coder_sessions
            .iter()
            .rev()
            .find(|s| {
                let phase_ok = match phase {
                    Some(p) => s.phase.as_deref() == Some(p),
                    None => true,
                };
                let engine_ok = match engine {
                    Some(e) => s.engine == Some(e),
                    None => true,
                };
                phase_ok && engine_ok
            })
            .map(|s| s.session_id.clone())
    }

    /// Record an error.
    pub fn set_error(&mut self, code: &str, message: &str, phase: Option<&str>) -> Result<()> {
        let now = now_iso();
        self.state.error = Some(StateError {
            code: code.to_string(),
            message: message.to_string(),
            phase: phase.map(|s| s.to_string()),
            timestamp: Some(now),
        });
        tracing::error!("Error recorded: [{code}] {message}");
        self.save()?;
        Ok(())
    }

    /// Clear the current error.
    pub fn clear_error(&mut self) -> Result<()> {
        self.state.error = None;
        self.save()?;
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Engine / contract / plan
    // -----------------------------------------------------------------------

    /// Set the coder engine assignment.
    pub fn set_coder_engine(&mut self, engine: CoderEngine) -> Result<()> {
        self.state.assignments.coder_engine = Some(engine);
        self.save()?;
        Ok(())
    }

    /// Set task contract ID and path.
    pub fn set_contract(&mut self, id: &str, path: &str) -> Result<()> {
        self.state.task.contract_id = Some(id.to_string());
        self.state.task.contract_path = Some(path.to_string());
        self.save()?;
        Ok(())
    }

    /// Resolve the plan path to an absolute path.
    ///
    /// If the stored plan_path is relative, it is resolved relative to
    /// the given `repo_root` (or the git repo root of the current directory).
    pub fn resolve_plan_path(&self, repo_root: Option<&str>) -> Result<PathBuf> {
        let plan_path = &self.state.task.plan_path;

        if plan_path.starts_with('/') {
            return Ok(PathBuf::from(plan_path));
        }

        let root = match repo_root {
            Some(r) => std::fs::canonicalize(r)
                .map_err(|e| AgentError::State(format!("cannot canonicalize repo root: {e}")))?,
            None => shared::git::git_repo_root()?,
        };

        let candidate = root.join(plan_path);
        // Canonicalize the parent directory, keep the filename.
        let parent = candidate
            .parent()
            .ok_or_else(|| AgentError::State("cannot determine plan parent dir".into()))?;
        let abs_parent = std::fs::canonicalize(parent)
            .map_err(|e| AgentError::State(format!("cannot resolve plan directory: {e}")))?;
        Ok(abs_parent.join(candidate.file_name().unwrap_or_default()))
    }

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------

    /// Print a human-readable summary to stdout.
    pub fn show_summary(&self) {
        let s = &self.state;
        println!("=== State Summary ===");
        println!("File: {}", self.file_path.display());
        println!();
        println!("Task: {} ({})", s.task.name, s.task.id);
        println!("Status: {}", s.status);
        println!(
            "Current Phase: {}",
            s.current_phase.as_deref().unwrap_or("none")
        );
        println!(
            "Coder Engine: {}",
            s.assignments
                .coder_engine
                .map(|e| e.to_string())
                .unwrap_or_else(|| "not set".into())
        );
        println!("Created: {}", s.created_at);
        println!("Updated: {}", s.updated_at);
        println!();
        println!("Phases:");
        for p in &s.phases {
            println!(
                "  - {}: {} (iteration: {}/{})",
                p.name, p.status, p.iteration, p.max_iterations
            );
        }
        println!();
        println!(
            "Quality Gate: {} (level: {})",
            s.quality_gate.status,
            s.quality_gate
                .level
                .as_ref()
                .map(|l| l.to_string())
                .unwrap_or_else(|| "not set".into())
        );
        if let Some(ref err) = s.error {
            println!();
            println!("Error: [{}] {}", err.code, err.message);
        }
    }

    // -----------------------------------------------------------------------
    // Private: scrub
    // -----------------------------------------------------------------------

    /// Remove ephemeral review/fix/session data from the in-memory state.
    ///
    /// This is the Rust equivalent of `_state_live_scrub_filter` in state.sh.
    /// It:
    /// 1. Walks all objects and removes ephemeral keys (reviews, fixes, etc.).
    /// 2. Contracts `coder_sessions` to keep only core fields.
    /// 3. Filters out invalid phase entries.
    fn scrub_live_state(&mut self) {
        // Contract coder sessions — keep only core fields, strip extras.
        self.state
            .sessions
            .coder_sessions
            .retain(|s| !s.session_id.is_empty());

        // The typed model already prevents stray keys on the Phase struct.
        // However, if the state was loaded from JSON with extra fields, the
        // serde deserialization would have dropped them. For extra safety we
        // re-serialize and scrub the raw JSON, then deserialize back.
        if let Ok(mut root) = serde_json::to_value(&self.state) {
            scrub_value(&mut root);

            // Rebuild sessions.coder_sessions from the original (pre-scrub)
            // data, since scrub_value removes session_id/parent_session_id
            // from all objects. We re-insert the contracted sessions.
            let contracted: Vec<Value> = self
                .state
                .sessions
                .coder_sessions
                .iter()
                .filter(|s| !s.session_id.is_empty())
                .map(|s| {
                    let mut obj = serde_json::json!({
                        "session_id": s.session_id,
                        "phase": s.phase,
                        "iteration": s.iteration,
                        "created_at": s.created_at,
                    });
                    if let Some(engine) = &s.engine {
                        obj["engine"] = serde_json::json!(engine);
                    }
                    if let Some(pid) = &s.parent_session_id {
                        obj["parent_session_id"] = serde_json::json!(pid);
                    }
                    obj
                })
                .collect();

            root["sessions"] = serde_json::json!({
                "coder_sessions": contracted,
            });

            // Filter out non-object entries from phases.
            if let Some(phases) = root.get_mut("phases").and_then(|v| v.as_array_mut()) {
                phases.retain(|p| p.is_object());
            }

            // Deserialize back. If this fails (shouldn't), keep the existing state.
            if let Ok(scrubbed) = serde_json::from_value::<State>(root) {
                self.state = scrubbed;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Private: plan path normalization
    // -----------------------------------------------------------------------

    /// Convert a plan path to a repo-relative path (if inside a git repo).
    fn normalize_plan_path(plan_path: &str) -> Result<String> {
        let abs_path = std::fs::canonicalize(plan_path).map_err(|e| {
            AgentError::State(format!("failed to normalize plan_path '{plan_path}': {e}"))
        })?;

        // Try to find the git repo root for the plan's directory.
        if let Some(_parent) = abs_path.parent() {
            if let Ok(repo_root) = shared::git::git_repo_root() {
                let repo_root = std::fs::canonicalize(&repo_root).unwrap_or(repo_root);
                if let Ok(relative) = abs_path.strip_prefix(&repo_root) {
                    return Ok(relative.to_string_lossy().to_string());
                }
            }
        }

        // Not in a git repo or not under repo root — use absolute.
        Ok(abs_path.to_string_lossy().to_string())
    }

    // -----------------------------------------------------------------------
    // Private: atomic write
    // -----------------------------------------------------------------------

    /// Write state.json atomically using temp-file + rename.
    ///
    /// Acquires the lock, writes to a temp file in the same directory,
    /// then renames over the target.
    fn atomic_write(&self) -> Result<()> {
        let _guard = FileLock::acquire(&self.lock_path, LOCK_TIMEOUT_SECS)?;

        let tmp = tempfile::NamedTempFile::new_in(&self.dir)
            .map_err(|e| AgentError::State(format!("failed to create temp file: {e}")))?;

        let data = serde_json::to_string_pretty(&self.state)?;
        std::fs::write(tmp.path(), data.as_bytes())?;

        // Persist (rename) the temp file to the target path.
        tmp.persist(&self.file_path).map_err(|e| {
            AgentError::State(format!(
                "failed to persist state file to {}: {e}",
                self.file_path.display()
            ))
        })?;

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// JSON-path traversal helpers
// ---------------------------------------------------------------------------

/// Segments of a parsed jq-style path.
#[derive(Debug)]
enum PathSegment {
    Key(String),
    Index(usize),
}

/// Parse a jq-style path into segments.
///
/// Example: `.phases[0].name` -> [Key("phases"), Index(0), Key("name")]
fn parse_path(path: &str) -> Vec<PathSegment> {
    let mut segments = Vec::new();
    let mut chars = path.chars().peekable();

    while let Some(&c) = chars.peek() {
        match c {
            '.' => {
                chars.next();
                let mut key = String::new();
                while let Some(&c2) = chars.peek() {
                    if c2 == '.' || c2 == '[' {
                        break;
                    }
                    key.push(c2);
                    chars.next();
                }
                if !key.is_empty() {
                    segments.push(PathSegment::Key(key));
                }
            }
            '[' => {
                chars.next();
                let mut num = String::new();
                while let Some(&c2) = chars.peek() {
                    if c2 == ']' {
                        chars.next();
                        break;
                    }
                    num.push(c2);
                    chars.next();
                }
                if let Ok(idx) = num.parse::<usize>() {
                    segments.push(PathSegment::Index(idx));
                }
            }
            _ => {
                chars.next();
            }
        }
    }

    segments
}

/// Resolve a jq-style path against a JSON value, returning the value or Null.
fn resolve_path(root: &Value, path: &str) -> Value {
    let segments = parse_path(path);
    let mut current = root;

    for seg in &segments {
        match seg {
            PathSegment::Key(k) => {
                current = current.get(k.as_str()).unwrap_or(&Value::Null);
            }
            PathSegment::Index(i) => {
                current = current.get(*i).unwrap_or(&Value::Null);
            }
        }
        if current.is_null() {
            return Value::Null;
        }
    }

    current.clone()
}

/// Set a value at a jq-style path in a mutable JSON value.
fn set_at_path(root: &mut Value, path: &str, value: Value) -> Result<()> {
    let segments = parse_path(path);
    if segments.is_empty() {
        return Err(AgentError::Validation("empty path".into()));
    }

    let mut current = root;

    // Navigate to the parent of the target.
    for seg in &segments[..segments.len() - 1] {
        current =
            match seg {
                PathSegment::Key(k) => {
                    if !current.is_object() {
                        *current = serde_json::json!({});
                    }
                    current
                        .as_object_mut()
                        .unwrap()
                        .entry(k.clone())
                        .or_insert(Value::Null)
                }
                PathSegment::Index(i) => {
                    if !current.is_array() {
                        return Err(AgentError::State(format!(
                            "expected array at index {i}, found {}",
                            current
                        )));
                    }
                    current.as_array_mut().unwrap().get_mut(*i).ok_or_else(|| {
                        AgentError::State(format!("array index {i} out of bounds"))
                    })?
                }
            };
    }

    // Set the final segment.
    match &segments[segments.len() - 1] {
        PathSegment::Key(k) => {
            if !current.is_object() {
                *current = serde_json::json!({});
            }
            current.as_object_mut().unwrap().insert(k.clone(), value);
        }
        PathSegment::Index(i) => {
            if !current.is_array() {
                return Err(AgentError::State(format!("expected array for index {i}")));
            }
            let arr = current.as_array_mut().unwrap();
            if *i < arr.len() {
                arr[*i] = value;
            } else {
                return Err(AgentError::State(format!(
                    "array index {i} out of bounds (len={})",
                    arr.len()
                )));
            }
        }
    }

    Ok(())
}

/// Append a value to an array at a jq-style path.
fn append_at_path(root: &mut Value, path: &str, value: Value) -> Result<()> {
    let segments = parse_path(path);
    if segments.is_empty() {
        return Err(AgentError::Validation("empty path".into()));
    }

    let mut current = root;

    for seg in &segments {
        current = match seg {
            PathSegment::Key(k) => {
                if !current.is_object() {
                    *current = serde_json::json!({});
                }
                current
                    .as_object_mut()
                    .unwrap()
                    .entry(k.clone())
                    .or_insert(Value::Array(Vec::new()))
            }
            PathSegment::Index(i) => current
                .as_array_mut()
                .and_then(|a| a.get_mut(*i))
                .ok_or_else(|| AgentError::State(format!("index {i} out of bounds")))?,
        };
    }

    if !current.is_array() {
        return Err(AgentError::State(format!(
            "expected array at path {path}, found {}",
            current
        )));
    }

    current.as_array_mut().unwrap().push(value);
    Ok(())
}

/// Recursively remove ephemeral keys from all objects in a JSON tree.
///
/// This mirrors the `walk(f)` + `del(...)` portion of `_state_live_scrub_filter`.
fn scrub_value(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for key in SCRUB_KEYS {
                map.remove(*key);
            }
            for v in map.values_mut() {
                scrub_value(v);
            }
        }
        Value::Array(arr) => {
            for v in arr.iter_mut() {
                scrub_value(v);
            }
        }
        _ => {}
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_path_basic() {
        let segs = parse_path(".status");
        assert_eq!(segs.len(), 1);
        assert!(matches!(&segs[0], PathSegment::Key(k) if k == "status"));
    }

    #[test]
    fn parse_path_nested() {
        let segs = parse_path(".phases[0].name");
        assert_eq!(segs.len(), 3);
        assert!(matches!(&segs[0], PathSegment::Key(k) if k == "phases"));
        assert!(matches!(&segs[1], PathSegment::Index(0)));
        assert!(matches!(&segs[2], PathSegment::Key(k) if k == "name"));
    }

    #[test]
    fn resolve_path_works() {
        let root = serde_json::json!({
            "a": { "b": [10, 20, 30] }
        });
        assert_eq!(resolve_path(&root, ".a.b[1]"), serde_json::json!(20));
        assert_eq!(resolve_path(&root, ".missing"), Value::Null);
    }

    #[test]
    fn set_at_path_works() {
        let mut root = serde_json::json!({
            "a": { "b": "old" }
        });
        set_at_path(&mut root, ".a.b", Value::String("new".into())).unwrap();
        assert_eq!(root["a"]["b"], "new");
    }

    #[test]
    fn append_at_path_works() {
        let mut root = serde_json::json!({
            "items": [1, 2]
        });
        append_at_path(&mut root, ".items", serde_json::json!(3)).unwrap();
        assert_eq!(root["items"], serde_json::json!([1, 2, 3]));
    }

    #[test]
    fn validate_jq_path_accepts_valid() {
        assert!(validate_jq_path(".status").is_ok());
        assert!(validate_jq_path(".phases[0].name").is_ok());
        assert!(validate_jq_path(".a.b_c.d").is_ok());
        assert!(validate_jq_path(".sessions.coder_sessions").is_ok());
    }

    #[test]
    fn validate_jq_path_rejects_invalid() {
        assert!(validate_jq_path("").is_err());
        assert!(validate_jq_path("status").is_err());
        assert!(validate_jq_path("; rm -rf /").is_err());
        assert!(validate_jq_path(".a | .b").is_err());
    }

    #[test]
    fn scrub_removes_ephemeral_keys() {
        let mut val = serde_json::json!({
            "name": "test",
            "reviews": [1,2,3],
            "fixes": [4,5],
            "session_id": "abc",
            "nested": {
                "reviewer_sessions": ["x"],
                "keep": true
            }
        });
        scrub_value(&mut val);
        assert!(val.get("reviews").is_none());
        assert!(val.get("fixes").is_none());
        assert!(val.get("session_id").is_none());
        assert!(val["nested"].get("reviewer_sessions").is_none());
        assert_eq!(val["nested"]["keep"], true);
        assert_eq!(val["name"], "test");
    }
}
