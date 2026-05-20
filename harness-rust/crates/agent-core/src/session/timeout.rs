//! Timeout manager — handles process execution with timeouts and heartbeats.
//!
//! Replaces: `.claude/commands/lib/timeout.sh` (288 LOC)
//!
//! # Design
//!
//! - Commands are spawned in their own process group via `setsid` (Unix).
//! - On timeout, the process group receives `SIGTERM` followed by `SIGKILL`.
//! - Progress is logged every 10 minutes.
//! - Heartbeat mode periodically updates `updated_at` in state.json
//!   **without locking** (intentional design decision — see inline docs).

use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use shared::error::{AgentError, Result};

#[cfg(unix)]
use std::os::unix::process::CommandExt;

/// Default timeout (30 minutes), matching `TIMEOUT_DEFAULT` in timeout.sh.
#[allow(dead_code)]
pub const DEFAULT_TIMEOUT: u64 = 1800;

/// Default heartbeat interval (60 seconds).
#[allow(dead_code)]
pub const DEFAULT_HEARTBEAT_INTERVAL: u64 = 60;

/// Progress log interval (10 minutes in seconds).
#[cfg_attr(not(test), allow(dead_code))]
const PROGRESS_LOG_INTERVAL: u64 = 600;

/// Timeout exit code (matching coreutils `timeout`).
#[cfg_attr(not(test), allow(dead_code))]
pub const TIMEOUT_EXIT_CODE: i32 = 124;

// ---------------------------------------------------------------------------
// Process group termination
// ---------------------------------------------------------------------------

/// Kill a process group with a two-phase approach: `SIGTERM`, then `SIGKILL`.
///
/// 1. Sends `SIGTERM` to the entire process group (`-pgid`).
/// 2. Waits `grace_secs` for graceful shutdown.
/// 3. If processes remain, sends `SIGKILL`.
#[cfg(unix)]
#[cfg_attr(not(test), allow(dead_code))]
pub fn timeout_kill_group(pgid: u32, grace_secs: u64) -> Result<()> {
    use nix::sys::signal::{kill, Signal};
    use nix::unistd::Pid;

    let neg_pgid = Pid::from_raw(-(pgid as i32));

    // Phase 1: SIGTERM
    let _ = kill(neg_pgid, Signal::SIGTERM);

    // Wait for graceful shutdown
    std::thread::sleep(Duration::from_secs(grace_secs));

    // Phase 2: SIGKILL if still alive
    if kill(neg_pgid, None).is_ok() {
        tracing::debug!("Process group {pgid} still alive, sending SIGKILL");
        let _ = kill(neg_pgid, Signal::SIGKILL);
    }

    Ok(())
}

#[cfg(not(unix))]
#[cfg_attr(not(test), allow(dead_code))]
pub fn timeout_kill_group(_pgid: u32, _grace_secs: u64) -> Result<()> {
    Err(AgentError::Command(
        "process group kill is only supported on Unix".into(),
    ))
}

// ---------------------------------------------------------------------------
// Process group creation
// ---------------------------------------------------------------------------

/// Spawn a command in a new process group.
///
/// On Unix, calls `setsid` via `pre_exec` so the child becomes its own
/// process-group leader (PID == PGID).
///
/// Returns `(Child, pgid)`.
#[cfg(unix)]
#[cfg_attr(not(test), allow(dead_code))]
pub fn create_process_group(cmd: &str, args: &[&str]) -> Result<(Child, u32)> {
    // SAFETY: pre_exec runs in the child process after fork().
    // setsid() is async-signal-safe per POSIX (IEEE Std 1003.1-2017).
    // No heap allocations, no Rust std calls, only the POSIX setsid() syscall.
    let child = unsafe {
        Command::new(cmd)
            .args(args)
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .pre_exec(|| {
                nix::unistd::setsid().map_err(|e| std::io::Error::other(format!("setsid: {e}")))?;
                Ok(())
            })
            .spawn()
            .map_err(|e| AgentError::Command(format!("failed to spawn {cmd}: {e}")))?
    };

    let pgid = child.id();
    Ok((child, pgid))
}

#[cfg(not(unix))]
#[cfg_attr(not(test), allow(dead_code))]
pub fn create_process_group(cmd: &str, args: &[&str]) -> Result<(Child, u32)> {
    let child = Command::new(cmd)
        .args(args)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| AgentError::Command(format!("failed to spawn {cmd}: {e}")))?;

    let pgid = child.id();
    Ok((child, pgid))
}

// ---------------------------------------------------------------------------
// timeout_run
// ---------------------------------------------------------------------------

/// Run a command with a timeout.
///
/// - Spawns the command in a new process group.
/// - Polls every second for completion.
/// - Logs progress every 10 minutes.
/// - On timeout, kills the process group and returns exit code 124.
#[cfg_attr(not(test), allow(dead_code))]
pub fn timeout_run(timeout_secs: u64, cmd: &str, args: &[&str]) -> Result<ExitStatus> {
    if cmd.is_empty() {
        return Err(AgentError::Validation(
            "timeout_run: no command specified".into(),
        ));
    }

    let (mut child, pgid) = create_process_group(cmd, args)?;

    let start = Instant::now();
    let timeout = Duration::from_secs(timeout_secs);

    loop {
        // Check if child has exited
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => { /* still running */ }
            Err(e) => return Err(AgentError::Io(e)),
        }

        // Check timeout
        let elapsed = start.elapsed();
        if elapsed >= timeout {
            tracing::warn!(
                "Timeout after {}s, killing process group {pgid}",
                timeout_secs
            );
            timeout_kill_group(pgid, 2)?;
            let _ = child.wait();
            return Err(AgentError::Timeout(format!(
                "command timed out after {timeout_secs}s (exit code {TIMEOUT_EXIT_CODE})"
            )));
        }

        // Progress logging every 10 minutes
        let elapsed_secs = elapsed.as_secs();
        if elapsed_secs > 0 && elapsed_secs.is_multiple_of(PROGRESS_LOG_INTERVAL) {
            tracing::info!("Still running... {elapsed_secs}s / {timeout_secs}s");
        }

        std::thread::sleep(Duration::from_secs(1));
    }
}

// ---------------------------------------------------------------------------
// timeout_run_with_heartbeat
// ---------------------------------------------------------------------------

/// Run a command with timeout and periodic heartbeat updates.
///
/// Same as [`timeout_run`], but additionally updates the `updated_at` field
/// in `state_file` at every `heartbeat_interval` seconds.
///
/// # Heartbeat design (intentionally lock-free)
///
/// The heartbeat update writes `updated_at` only, without acquiring a lock.
/// This is intentional: blocking on a lock could cause the heartbeat to stall,
/// which defeats its purpose. In the worst case a concurrent `state_save`
/// overwrites the heartbeat timestamp — this is acceptable since only
/// `updated_at` is affected and data integrity is maintained.
#[cfg_attr(not(test), allow(dead_code))]
pub fn timeout_run_with_heartbeat(
    timeout_secs: u64,
    heartbeat_interval: u64,
    state_file: Option<&Path>,
    cmd: &str,
    args: &[&str],
) -> Result<ExitStatus> {
    if cmd.is_empty() {
        return Err(AgentError::Validation(
            "timeout_run_with_heartbeat: no command specified".into(),
        ));
    }

    let (mut child, pgid) = create_process_group(cmd, args)?;

    let start = Instant::now();
    let timeout = Duration::from_secs(timeout_secs);
    let heartbeat_dur = Duration::from_secs(heartbeat_interval);
    let mut last_heartbeat = Instant::now();

    loop {
        // Check if child has exited
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => { /* still running */ }
            Err(e) => return Err(AgentError::Io(e)),
        }

        let elapsed = start.elapsed();

        // Check timeout
        if elapsed >= timeout {
            tracing::warn!(
                "Timeout after {}s (with heartbeat), killing process group {pgid}",
                timeout_secs
            );
            timeout_kill_group(pgid, 2)?;
            let _ = child.wait();
            return Err(AgentError::Timeout(format!(
                "command timed out after {timeout_secs}s (exit code {TIMEOUT_EXIT_CODE})"
            )));
        }

        // Heartbeat update
        if let Some(sf) = state_file {
            if last_heartbeat.elapsed() >= heartbeat_dur {
                heartbeat_update(sf);
                last_heartbeat = Instant::now();
            }
        }

        // Progress logging every 10 minutes
        let elapsed_secs = elapsed.as_secs();
        if elapsed_secs > 0 && elapsed_secs.is_multiple_of(PROGRESS_LOG_INTERVAL) {
            tracing::info!("Still running (heartbeat mode)... {elapsed_secs}s / {timeout_secs}s");
        }

        std::thread::sleep(Duration::from_secs(1));
    }
}

// ---------------------------------------------------------------------------
// timeout_check / timeout_remaining
// ---------------------------------------------------------------------------

/// Check whether a timeout has elapsed.
///
/// Returns `true` if `elapsed >= timeout_secs` since `start_ts` (ISO-8601).
#[cfg_attr(not(test), allow(dead_code))]
pub fn timeout_check(start_ts: &str, timeout_secs: u64) -> bool {
    match elapsed_since(start_ts) {
        Some(elapsed) => elapsed >= timeout_secs,
        None => false,
    }
}

/// Return the remaining seconds until timeout, or `None` if parsing fails.
///
/// Returns `0` if already timed out.
#[cfg_attr(not(test), allow(dead_code))]
pub fn timeout_remaining(start_ts: &str, timeout_secs: u64) -> Option<u64> {
    let elapsed = elapsed_since(start_ts)?;
    Some(timeout_secs.saturating_sub(elapsed))
}

// ---------------------------------------------------------------------------
// Child wait helper (used by session module for codex)
// ---------------------------------------------------------------------------

/// Wait for a child process with a timeout, polling every second.
///
/// Does **not** use process groups — just waits on the child PID.
pub fn wait_child_with_timeout(child: &mut Child, timeout_secs: u64) -> Result<ExitStatus> {
    let start = Instant::now();
    let timeout = Duration::from_secs(timeout_secs);

    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => { /* still running */ }
            Err(e) => return Err(AgentError::Io(e)),
        }

        if start.elapsed() >= timeout {
            // Try to kill the child
            let _ = child.kill();
            let _ = child.wait();
            return Err(AgentError::Timeout(format!(
                "child process timed out after {timeout_secs}s"
            )));
        }

        std::thread::sleep(Duration::from_secs(1));
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Compute seconds elapsed since an ISO-8601 timestamp.
#[cfg_attr(not(test), allow(dead_code))]
fn elapsed_since(start_ts: &str) -> Option<u64> {
    let start = chrono::DateTime::parse_from_rfc3339(start_ts).ok()?;
    let now = chrono::Utc::now();
    let diff = now.signed_duration_since(start);
    if diff.num_seconds() < 0 {
        return Some(0);
    }
    Some(diff.num_seconds() as u64)
}

/// Lock-free heartbeat update of `updated_at` in state.json.
///
/// WARNING: This function intentionally does NOT acquire a lock.
/// See the module-level docs for rationale.
#[cfg_attr(not(test), allow(dead_code))]
fn heartbeat_update(state_file: &Path) {
    let content = match fs::read_to_string(state_file) {
        Ok(c) => c,
        Err(_) => return,
    };

    let mut value: serde_json::Value = match serde_json::from_str(&content) {
        Ok(v) => v,
        Err(_) => return,
    };

    let now = chrono::Utc::now().to_rfc3339();
    if let Some(obj) = value.as_object_mut() {
        obj.insert(
            "updated_at".to_string(),
            serde_json::Value::String(now.clone()),
        );
    }

    // Write to temp file then rename (atomic on same filesystem)
    let dir = match state_file.parent() {
        Some(d) => d,
        None => return,
    };

    let tmp = match tempfile::Builder::new()
        .prefix("heartbeat")
        .tempfile_in(dir)
    {
        Ok(t) => t,
        Err(_) => return,
    };

    let (mut file, tmp_path) = match tmp.keep() {
        Ok(pair) => pair,
        Err(_) => return,
    };

    if file
        .write_all(
            serde_json::to_string_pretty(&value)
                .unwrap_or_default()
                .as_bytes(),
        )
        .is_ok()
    {
        if fs::rename(&tmp_path, state_file).is_ok() {
            tracing::debug!("Heartbeat: state updated at {now}");
        } else {
            let _ = fs::remove_file(&tmp_path);
        }
    } else {
        let _ = fs::remove_file(&tmp_path);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_timeout_check_not_elapsed() {
        let now = chrono::Utc::now().to_rfc3339();
        assert!(!timeout_check(&now, 3600));
    }

    #[test]
    fn test_timeout_check_elapsed() {
        // 1 hour ago
        let past = (chrono::Utc::now() - chrono::Duration::hours(1)).to_rfc3339();
        assert!(timeout_check(&past, 1800)); // 30 min timeout
    }

    #[test]
    fn test_timeout_check_invalid_timestamp() {
        assert!(!timeout_check("not-a-timestamp", 60));
    }

    #[test]
    fn test_timeout_remaining_full() {
        let now = chrono::Utc::now().to_rfc3339();
        let remaining = timeout_remaining(&now, 3600);
        assert!(remaining.is_some());
        // Should be close to 3600 (within a few seconds of test execution)
        let r = remaining.unwrap();
        assert!((3598..=3600).contains(&r));
    }

    #[test]
    fn test_timeout_remaining_expired() {
        let past = (chrono::Utc::now() - chrono::Duration::hours(2)).to_rfc3339();
        let remaining = timeout_remaining(&past, 3600);
        assert_eq!(remaining, Some(0));
    }

    #[test]
    fn test_timeout_remaining_invalid() {
        assert!(timeout_remaining("garbage", 60).is_none());
    }

    #[test]
    fn test_timeout_run_no_command() {
        let result = timeout_run(10, "", &[]);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("no command specified"));
    }

    #[test]
    fn test_timeout_run_fast_command() {
        let result = timeout_run(10, "true", &[]);
        assert!(result.is_ok());
        assert!(result.unwrap().success());
    }

    #[test]
    fn test_timeout_run_failing_command() {
        let result = timeout_run(10, "false", &[]);
        assert!(result.is_ok());
        assert!(!result.unwrap().success());
    }

    #[test]
    fn test_timeout_run_with_heartbeat_no_command() {
        let result = timeout_run_with_heartbeat(10, 5, None, "", &[]);
        assert!(result.is_err());
    }

    #[test]
    fn test_timeout_run_with_heartbeat_fast() {
        let result = timeout_run_with_heartbeat(10, 2, None, "true", &[]);
        assert!(result.is_ok());
        assert!(result.unwrap().success());
    }

    #[test]
    fn test_heartbeat_update_nonexistent_file() {
        // Should not panic
        heartbeat_update(Path::new("/nonexistent/state.json"));
    }

    #[test]
    fn test_heartbeat_update_valid_file() {
        let dir = tempfile::tempdir().unwrap();
        let state_path = dir.path().join("state.json");
        let initial = serde_json::json!({
            "version": "2.0.0",
            "updated_at": "2024-01-01T00:00:00Z"
        });
        fs::write(&state_path, serde_json::to_string_pretty(&initial).unwrap()).unwrap();

        heartbeat_update(&state_path);

        let content = fs::read_to_string(&state_path).unwrap();
        let value: serde_json::Value = serde_json::from_str(&content).unwrap();
        let updated = value["updated_at"].as_str().unwrap();
        // Should have been updated to something more recent
        assert_ne!(updated, "2024-01-01T00:00:00Z");
    }

    #[test]
    fn test_wait_child_with_timeout_fast() {
        let mut child = Command::new("true").spawn().unwrap();
        let result = wait_child_with_timeout(&mut child, 10);
        assert!(result.is_ok());
        assert!(result.unwrap().success());
    }

    #[cfg(unix)]
    #[test]
    fn test_create_process_group() {
        let result = create_process_group("echo", &["hello"]);
        assert!(result.is_ok());
        let (mut child, pgid) = result.unwrap();
        assert!(pgid > 0);
        let status = child.wait().unwrap();
        assert!(status.success());
    }

    #[cfg(unix)]
    #[test]
    fn test_timeout_kill_group_nonexistent() {
        // Killing a non-existent process group should not panic
        let result = timeout_kill_group(99999, 0);
        assert!(result.is_ok());
    }

    #[test]
    fn test_elapsed_since_valid() {
        let ts = chrono::Utc::now().to_rfc3339();
        let elapsed = elapsed_since(&ts);
        assert!(elapsed.is_some());
        assert!(elapsed.unwrap() <= 1);
    }

    #[test]
    fn test_elapsed_since_future() {
        let future = (chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339();
        let elapsed = elapsed_since(&future);
        assert_eq!(elapsed, Some(0));
    }

    #[test]
    fn test_elapsed_since_invalid() {
        assert!(elapsed_since("not-valid").is_none());
    }
}
