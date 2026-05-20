//! Session manager — handles Claude/Codex CLI session lifecycle.
//!
//! Replaces: `.claude/commands/lib/session.sh` (409 LOC)
//!
//! # Design
//!
//! - New sessions are always started via the canonical wrapper scripts.
//! - `session_resume` and `session_fork` are **fail-closed** in orchestrated
//!   mode — they always return an error.
//! - All session IDs are validated before use.
//! - Temp files are cleaned up via RAII (`TempDir` / `NamedTempFile`).

pub mod timeout;

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use shared::error::{AgentError, Result};
use shared::types::EffortLevel;
use shared::validation;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default session timeout (30 minutes), matching SESSION_TIMEOUT in session.sh.
pub const DEFAULT_SESSION_TIMEOUT: u64 = 1800;

/// Default effort level fallback.
const EFFORT_LEVEL_FALLBACK: EffortLevel = EffortLevel::Medium;

/// Claude wrapper script name (relative to repo `scripts/`).
const CLAUDE_WRAPPER_NAME: &str = "claude-wrapper.sh";

/// Codex wrapper script name (relative to repo `scripts/`).
const CODEX_WRAPPER_NAME: &str = "codex-wrapper.sh";

/// Environment variable for explicit effort level.
const ENV_EFFORT_LEVEL: &str = "CLAUDE_CODE_EFFORT_LEVEL";

/// Environment variable for the deprecated thinking budget.
const ENV_THINKING_BUDGET: &str = "CLAUDE_THINKING_BUDGET";

/// Environment variable for default effort level override.
const ENV_EFFORT_LEVEL_DEFAULT: &str = "CLAUDE_CODE_EFFORT_LEVEL_DEFAULT";

// ---------------------------------------------------------------------------
// Effort-level resolution
// ---------------------------------------------------------------------------

/// Resolve the effective effort level from environment variables.
///
/// Resolution order (matching `_resolve_claude_effort_level` in session.sh):
///
/// 1. `CLAUDE_CODE_EFFORT_LEVEL` — if set and valid, used directly.
/// 2. `CLAUDE_THINKING_BUDGET` (deprecated) — mapped to effort:
///    - >= 10000 → Max
///    - >= 4000  → High
///    - >= 1000  → Medium
///    - < 1000   → Low
/// 3. `CLAUDE_CODE_EFFORT_LEVEL_DEFAULT` — if set and valid.
/// 4. Fallback: `Medium`.
pub fn resolve_effort_level() -> EffortLevel {
    // 1. Explicit effort level
    if let Ok(val) = std::env::var(ENV_EFFORT_LEVEL) {
        if let Ok(level) = val.parse::<EffortLevel>() {
            return level;
        }
        let default = resolve_default_effort_level();
        tracing::warn!(
            "Invalid {}: {} (must be low|medium|high|max). Using default: {}",
            ENV_EFFORT_LEVEL,
            val,
            default
        );
        return default;
    }

    // 2. Deprecated thinking budget
    if let Ok(val) = std::env::var(ENV_THINKING_BUDGET) {
        tracing::warn!(
            "{} is deprecated. Use {} instead.",
            ENV_THINKING_BUDGET,
            ENV_EFFORT_LEVEL
        );
        if let Ok(budget) = val.parse::<u64>() {
            return if budget >= 10000 {
                EffortLevel::Max
            } else if budget >= 4000 {
                EffortLevel::High
            } else if budget >= 1000 {
                EffortLevel::Medium
            } else {
                EffortLevel::Low
            };
        }
        let default = resolve_default_effort_level();
        tracing::warn!(
            "Invalid {}: {}. Using default effort: {}",
            ENV_THINKING_BUDGET,
            val,
            default
        );
        return default;
    }

    // 3/4. Default
    resolve_default_effort_level()
}

/// Resolve the configured default effort level.
fn resolve_default_effort_level() -> EffortLevel {
    if let Ok(val) = std::env::var(ENV_EFFORT_LEVEL_DEFAULT) {
        if let Ok(level) = val.parse::<EffortLevel>() {
            return level;
        }
        tracing::warn!(
            "Invalid {}: {} (must be low|medium|high|max). Using fallback: {}",
            ENV_EFFORT_LEVEL_DEFAULT,
            val,
            EFFORT_LEVEL_FALLBACK
        );
    }
    EFFORT_LEVEL_FALLBACK
}

// ---------------------------------------------------------------------------
// Session ID utilities
// ---------------------------------------------------------------------------

/// Validate a session ID.
///
/// Delegates to [`shared::validation::validate_session_id`].
#[cfg_attr(not(test), allow(dead_code))]
pub fn validate_session_id(id: &str) -> Result<()> {
    validation::validate_session_id(id)
}

/// Generate a new UUID v4 session identifier.
pub fn generate_session_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

// ---------------------------------------------------------------------------
// Wrapper path resolution (fail-closed security)
// ---------------------------------------------------------------------------

/// Resolve and validate a wrapper script path.
///
/// The canonical path is always `{repo_root}/scripts/{wrapper_name}`.
/// If `candidate` is provided, it must resolve to the same canonical path
/// (symlinks are followed). A mismatch causes a fail-closed error.
pub fn resolve_canonical_wrapper_path(
    candidate: Option<&str>,
    wrapper_name: &str,
    env_name: &str,
    repo_root: &Path,
) -> Result<PathBuf> {
    let canonical = repo_root.join("scripts").join(wrapper_name);

    let Some(candidate_str) = candidate else {
        return Ok(canonical);
    };

    let candidate_path = Path::new(candidate_str);
    let resolved = candidate_path.canonicalize().map_err(|e| {
        AgentError::Validation(format!(
            "{env_name} cannot be resolved: {candidate_str}: {e}"
        ))
    })?;

    let canonical_resolved = canonical
        .canonicalize()
        .unwrap_or_else(|_| canonical.clone());

    if resolved != canonical_resolved {
        return Err(AgentError::Validation(format!(
            "{env_name} must resolve to canonical repo path: {}",
            canonical.display()
        )));
    }

    Ok(canonical)
}

/// Ensure the Claude wrapper script exists and is executable.
///
/// Returns the canonical path to `scripts/claude-wrapper.sh`.
pub fn ensure_claude_wrapper(repo_root: &Path) -> Result<PathBuf> {
    let candidate = std::env::var("CLAUDE_WRAPPER").ok();
    let path = resolve_canonical_wrapper_path(
        candidate.as_deref(),
        CLAUDE_WRAPPER_NAME,
        "CLAUDE_WRAPPER",
        repo_root,
    )?;

    check_executable(&path, "claude-wrapper.sh")?;
    Ok(path)
}

/// Ensure the Codex wrapper script (for coder role) exists and is executable.
///
/// Returns the canonical path to `scripts/codex-wrapper.sh`.
pub fn ensure_codex_wrapper(repo_root: &Path) -> Result<PathBuf> {
    let candidate = std::env::var("CODEX_WRAPPER_CODER_CANONICAL")
        .or_else(|_| std::env::var("CODEX_WRAPPER_HIGH"))
        .ok();
    let path = resolve_canonical_wrapper_path(
        candidate.as_deref(),
        CODEX_WRAPPER_NAME,
        "CODEX_WRAPPER_CODER_CANONICAL",
        repo_root,
    )?;

    check_executable(&path, "codex-wrapper.sh")?;
    Ok(path)
}

/// Verify that a file exists and has the executable bit set.
fn check_executable(path: &Path, name: &str) -> Result<()> {
    let meta = fs::metadata(path).map_err(|_| {
        AgentError::NotFound(format!(
            "{name} not found or not accessible: {}",
            path.display()
        ))
    })?;

    let mode = meta.permissions().mode();
    if mode & 0o111 == 0 {
        return Err(AgentError::Validation(format!(
            "{name} is not executable: {}",
            path.display()
        )));
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Claude session management
// ---------------------------------------------------------------------------

/// Start a new Claude CLI session.
///
/// - Generates a fresh session ID.
/// - Writes the prompt to a temp file.
/// - Calls `claude-wrapper.sh` with `--mode orchestrator-full`.
/// - Returns the session ID on success.
///
/// Temp files are cleaned up even on error (via [`tempfile`] RAII).
pub fn session_start(
    prompt: &str,
    output_file: Option<&Path>,
    timeout_secs: u64,
    repo_root: &Path,
) -> Result<String> {
    if prompt.is_empty() {
        return Err(AgentError::Validation(
            "session_start: prompt is required".into(),
        ));
    }

    let wrapper = ensure_claude_wrapper(repo_root)?;
    let session_id = generate_session_id();
    let effort = resolve_effort_level();

    // Write prompt to temp file
    let prompt_file = write_temp_file("claude_prompt", prompt)?;
    let prompt_path = prompt_file.path();

    // Output handling
    let temp_output = if output_file.is_none() {
        Some(
            tempfile::Builder::new()
                .prefix("claude_output")
                .tempfile()
                .map_err(AgentError::Io)?,
        )
    } else {
        None
    };

    let target_output = match output_file {
        Some(p) => p.to_path_buf(),
        None => temp_output
            .as_ref()
            .map(|f| f.path().to_path_buf())
            .unwrap_or_default(),
    };

    let timeout_str = timeout_secs.to_string();
    let mut cmd = Command::new(&wrapper);
    cmd.args([
        "--mode",
        "orchestrator-full",
        "--input",
        &prompt_path.to_string_lossy(),
        "--output",
        &target_output.to_string_lossy(),
        "--effort",
        &effort.to_string(),
        "--timeout",
        &timeout_str,
        "--session-id",
        &session_id,
    ]);

    let status = cmd
        .status()
        .map_err(|e| AgentError::Command(format!("Claude wrapper failed to start: {e}")))?;

    if !status.success() {
        return Err(AgentError::Command(
            "Claude wrapper failed while starting session".into(),
        ));
    }

    // If no output file was specified, read and print temp output
    if output_file.is_none() {
        if let Some(ref tf) = temp_output {
            let content = fs::read_to_string(tf.path()).unwrap_or_default();
            print!("{content}");
        }
    }

    tracing::info!("Session started: {session_id}");
    Ok(session_id)
}

/// Resume an existing session.
///
/// **Always returns an error** — session continuation is disabled in
/// orchestrated/automatic flows (fail-closed).
#[cfg_attr(not(test), allow(dead_code))]
pub fn session_resume(session_id: &str, _prompt: &str) -> Result<()> {
    if session_id.is_empty() {
        return Err(AgentError::Validation(
            "session_resume: session_id is required".into(),
        ));
    }
    validation::validate_session_id(session_id)?;

    deny_interactive_session_continuation("session_resume")
}

/// Fork from an existing session.
///
/// **Always returns an error** — session continuation is disabled in
/// orchestrated/automatic flows (fail-closed).
#[cfg_attr(not(test), allow(dead_code))]
pub fn session_fork(parent_id: &str, _prompt: &str) -> Result<()> {
    if parent_id.is_empty() {
        return Err(AgentError::Validation(
            "session_fork: parent_session_id is required".into(),
        ));
    }
    validation::validate_session_id(parent_id)?;

    deny_interactive_session_continuation("session_fork")
}

/// Run a session with timeout.
///
/// - If `session_id` is `None` or `"new"`: generates a fresh session.
/// - If `session_id` is an existing ID: **fail-closed** (denies continuation).
#[cfg_attr(not(test), allow(dead_code))]
pub fn session_run_with_timeout(
    timeout_secs: u64,
    session_id: Option<&str>,
    prompt: &str,
    output_file: Option<&Path>,
    repo_root: &Path,
) -> Result<()> {
    // Validate session_id if provided and not "new"
    let is_new = match session_id {
        None => true,
        Some("new") => true,
        Some("") => true,
        Some(id) => {
            validation::validate_session_id(id)?;
            false
        }
    };

    if !is_new {
        return deny_interactive_session_continuation("session_run_with_timeout");
    }

    // Start a fresh session
    let wrapper = ensure_claude_wrapper(repo_root)?;
    let new_id = generate_session_id();
    let effort = resolve_effort_level();

    let prompt_file = write_temp_file("session_prompt", prompt)?;
    let prompt_path = prompt_file.path();

    let temp_output = if output_file.is_none() {
        Some(
            tempfile::Builder::new()
                .prefix("session_output")
                .tempfile()
                .map_err(AgentError::Io)?,
        )
    } else {
        None
    };

    let target_output = match output_file {
        Some(p) => p.to_path_buf(),
        None => temp_output
            .as_ref()
            .map(|f| f.path().to_path_buf())
            .unwrap_or_default(),
    };

    let timeout_str = timeout_secs.to_string();
    let mut cmd = Command::new(&wrapper);
    cmd.args([
        "--mode",
        "orchestrator-full",
        "--input",
        &prompt_path.to_string_lossy(),
        "--output",
        &target_output.to_string_lossy(),
        "--effort",
        &effort.to_string(),
        "--timeout",
        &timeout_str,
        "--session-id",
        &new_id,
    ]);

    let status = cmd
        .status()
        .map_err(|e| AgentError::Command(format!("Claude wrapper failed to start: {e}")))?;

    if !status.success() {
        return Err(AgentError::Command(
            "Claude wrapper failed while running session".into(),
        ));
    }

    // Print temp output if no explicit output file
    if output_file.is_none() {
        if let Some(ref tf) = temp_output {
            let content = fs::read_to_string(tf.path()).unwrap_or_default();
            print!("{content}");
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Codex session management
// ---------------------------------------------------------------------------

/// Start a new Codex CLI session (coder role).
///
/// - Records the start epoch before execution.
/// - Calls `codex-wrapper.sh --role coder --stdin < prompt_file > output_file`.
/// - After execution, finds the latest Codex session ID from `~/.codex/sessions/`.
/// - Returns the session ID if found.
pub fn codex_session_start(
    prompt_file: &Path,
    output_file: &Path,
    timeout_secs: u64,
    repo_root: &Path,
) -> Result<Option<String>> {
    if !prompt_file.is_file() {
        return Err(AgentError::NotFound(format!(
            "codex_session_start: prompt_file not found: {}",
            prompt_file.display()
        )));
    }

    let wrapper = ensure_codex_wrapper(repo_root)?;
    tracing::info!("Starting Codex session...");

    // Record start epoch for session ID matching
    let start_epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| AgentError::Command(format!("system time error: {e}")))?
        .as_secs();

    // Read prompt from file for stdin
    let prompt_content = fs::read(prompt_file).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to read prompt file: {e}"),
        ))
    })?;

    // Build command: codex-wrapper.sh --role coder --stdin
    let output_fs = fs::File::create(output_file).map_err(AgentError::Io)?;

    let mut cmd = Command::new(&wrapper);
    cmd.args(["--role", "coder", "--stdin"])
        .stdin(std::process::Stdio::piped())
        .stdout(output_fs)
        .stderr(std::process::Stdio::piped());

    let mut child = cmd
        .spawn()
        .map_err(|e| AgentError::Command(format!("Codex wrapper failed to start: {e}")))?;

    // Write prompt to stdin
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(&prompt_content).map_err(AgentError::Io)?;
        // stdin is dropped here, closing the pipe
    }

    // Wait with timeout
    let status = timeout::wait_child_with_timeout(&mut child, timeout_secs)?;

    if !status.success() {
        tracing::warn!("Codex execution returned: {:?}", status.code());
    } else {
        tracing::info!("Codex execution completed");
    }

    // Find the latest codex session ID
    let session_id = get_latest_codex_session(start_epoch);

    match &session_id {
        Some(id) => tracing::info!("Codex session: {id}"),
        None => tracing::warn!("Could not retrieve Codex session ID"),
    }

    Ok(session_id)
}

/// Scan `~/.codex/sessions/` for the most recent session created after `after_epoch`.
///
/// Codex session files follow the pattern: `rollout-YYYY-MM-DDTHH-mm-ss-UUID.jsonl`.
/// The UUID is extracted from the filename.
pub fn get_latest_codex_session(after_epoch: u64) -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let sessions_dir = PathBuf::from(home).join(".codex").join("sessions");

    if !sessions_dir.is_dir() {
        return None;
    }

    let entries = fs::read_dir(&sessions_dir).ok()?;

    // UUID regex for extraction from filenames like rollout-2024-01-01T00-00-00-UUID.jsonl
    let uuid_re = regex::Regex::new(
        r"rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$"
    ).ok()?;

    let mut best: Option<(std::time::SystemTime, String)> = None;

    for entry in entries.flatten() {
        let path = entry.path();
        let fname = match path.file_name() {
            Some(f) => f.to_string_lossy().to_string(),
            None => continue,
        };

        // Check modification time — skip entries that fail metadata retrieval
        let meta = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        let mtime = match meta.modified() {
            Ok(t) => t,
            Err(_) => continue,
        };
        let mtime_epoch = match mtime.duration_since(std::time::UNIX_EPOCH) {
            Ok(d) => d.as_secs(),
            Err(_) => continue,
        };

        if mtime_epoch < after_epoch {
            continue;
        }

        // Extract UUID from filename
        if let Some(caps) = uuid_re.captures(&fname) {
            if let Some(uuid_match) = caps.get(1) {
                let uuid = uuid_match.as_str().to_string();
                match &best {
                    None => best = Some((mtime, uuid)),
                    Some((prev_time, _)) if mtime > *prev_time => {
                        best = Some((mtime, uuid));
                    }
                    _ => {}
                }
            }
        }
    }

    best.map(|(_, id)| id)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Deny interactive session continuation (fail-closed).
#[cfg_attr(not(test), allow(dead_code))]
fn deny_interactive_session_continuation(helper_name: &str) -> Result<()> {
    tracing::error!(
        "{helper_name}: interactive session continuation is disabled in orchestrated/automatic flow"
    );
    tracing::error!(
        "{helper_name}: start a fresh session and carry forward the required context in the prompt instead"
    );
    Err(AgentError::Command(format!(
        "{helper_name}: interactive session continuation is disabled in orchestrated/automatic flow"
    )))
}

/// Write content to a named temporary file. The file is cleaned up on drop.
fn write_temp_file(prefix: &str, content: &str) -> Result<tempfile::NamedTempFile> {
    let mut file = tempfile::Builder::new()
        .prefix(prefix)
        .suffix(".txt")
        .tempfile()
        .map_err(AgentError::Io)?;

    file.write_all(content.as_bytes()).map_err(AgentError::Io)?;
    file.flush().map_err(AgentError::Io)?;

    Ok(file)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;
    use std::sync::Mutex;

    static EFFORT_ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EffortEnvGuard {
        explicit: Option<OsString>,
        budget: Option<OsString>,
        default: Option<OsString>,
    }

    impl EffortEnvGuard {
        fn capture() -> Self {
            Self {
                explicit: std::env::var_os(ENV_EFFORT_LEVEL),
                budget: std::env::var_os(ENV_THINKING_BUDGET),
                default: std::env::var_os(ENV_EFFORT_LEVEL_DEFAULT),
            }
        }
    }

    impl Drop for EffortEnvGuard {
        fn drop(&mut self) {
            restore_effort_env(ENV_EFFORT_LEVEL, self.explicit.take());
            restore_effort_env(ENV_THINKING_BUDGET, self.budget.take());
            restore_effort_env(ENV_EFFORT_LEVEL_DEFAULT, self.default.take());
        }
    }

    fn restore_effort_env(key: &str, value: Option<OsString>) {
        match value {
            Some(value) => std::env::set_var(key, value),
            None => std::env::remove_var(key),
        }
    }

    fn clear_effort_env() {
        std::env::remove_var(ENV_EFFORT_LEVEL);
        std::env::remove_var(ENV_THINKING_BUDGET);
        std::env::remove_var(ENV_EFFORT_LEVEL_DEFAULT);
    }

    fn with_isolated_effort_env<T>(setup: impl FnOnce(), test: impl FnOnce() -> T) -> T {
        let _lock = EFFORT_ENV_LOCK
            .lock()
            .expect("effort env lock should not be poisoned");
        let _guard = EffortEnvGuard::capture();
        clear_effort_env();
        setup();
        test()
    }

    #[test]
    fn test_generate_session_id_format() {
        let id = generate_session_id();
        // UUID v4 format: 8-4-4-4-12 hex chars
        assert_eq!(id.len(), 36);
        assert!(id.contains('-'));
        // Must pass validation
        assert!(validate_session_id(&id).is_ok());
    }

    #[test]
    fn test_session_resume_always_fails() {
        let result = session_resume("abcd1234-test", "some prompt");
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("interactive session continuation is disabled"));
    }

    #[test]
    fn test_session_fork_always_fails() {
        let result = session_fork("abcd1234-test", "some prompt");
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("interactive session continuation is disabled"));
    }

    #[test]
    fn test_session_resume_validates_id() {
        let result = session_resume("bad", "prompt");
        assert!(result.is_err());
        // Should fail on validation before reaching denial
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("session ID"));
    }

    #[test]
    fn test_session_fork_validates_id() {
        let result = session_fork("bad", "prompt");
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("session ID"));
    }

    #[test]
    fn test_session_resume_rejects_empty() {
        let result = session_resume("", "prompt");
        assert!(result.is_err());
    }

    #[test]
    fn test_session_fork_rejects_empty() {
        let result = session_fork("", "prompt");
        assert!(result.is_err());
    }

    #[test]
    fn test_session_start_rejects_empty_prompt() {
        let result = session_start("", None, 60, Path::new("/tmp"));
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("prompt is required"));
    }

    #[test]
    fn test_resolve_effort_level_default() {
        with_isolated_effort_env(
            || {},
            || {
                let level = resolve_effort_level();
                assert_eq!(level, EffortLevel::Medium);
            },
        );
    }

    #[test]
    fn test_resolve_effort_level_explicit() {
        with_isolated_effort_env(
            || std::env::set_var(ENV_EFFORT_LEVEL, "high"),
            || {
                let level = resolve_effort_level();
                assert_eq!(level, EffortLevel::High);
            },
        );
    }

    #[test]
    fn test_resolve_canonical_wrapper_path_no_candidate() {
        let repo = Path::new("/tmp/fake-repo");
        let result =
            resolve_canonical_wrapper_path(None, "claude-wrapper.sh", "CLAUDE_WRAPPER", repo);
        assert!(result.is_ok());
        assert_eq!(
            result.unwrap(),
            PathBuf::from("/tmp/fake-repo/scripts/claude-wrapper.sh")
        );
    }

    #[test]
    fn test_resolve_canonical_wrapper_path_bad_candidate() {
        let repo = Path::new("/tmp/fake-repo");
        let result = resolve_canonical_wrapper_path(
            Some("/etc/passwd"),
            "claude-wrapper.sh",
            "CLAUDE_WRAPPER",
            repo,
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_session_run_with_timeout_new_session_denied() {
        // Existing session ID should be denied
        let result = session_run_with_timeout(
            60,
            Some("abcd1234-existing-session"),
            "prompt",
            None,
            Path::new("/tmp"),
        );
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("interactive session continuation is disabled"));
    }

    #[test]
    fn test_codex_session_start_rejects_missing_file() {
        let result = codex_session_start(
            Path::new("/nonexistent/prompt.md"),
            Path::new("/tmp/output.md"),
            60,
            Path::new("/tmp"),
        );
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("prompt_file not found"));
    }

    #[test]
    fn test_get_latest_codex_session_nonexistent_dir() {
        // With a future epoch, nothing should match
        let result = get_latest_codex_session(u64::MAX);
        assert!(result.is_none());
    }

    #[test]
    fn test_write_temp_file() {
        let tf = write_temp_file("test_prefix", "hello world");
        assert!(tf.is_ok());
        let tf = tf.unwrap();
        let content = fs::read_to_string(tf.path()).unwrap();
        assert_eq!(content, "hello world");
        // File is cleaned up when tf is dropped
    }
}
