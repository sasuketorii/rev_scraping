//! Shared path resolution for semantic MCP data.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use crate::error::{AgentError, Result};

/// Return the semantic MCP data root.
///
/// `SEMANTIC_MCP_HOME` is honored only for explicit test harness runs. Normal
/// debug and release builds use platform data directories.
pub fn semantic_mcp_data_root() -> Result<PathBuf> {
    if is_test_mode() {
        if let Ok(path) = std::env::var("SEMANTIC_MCP_HOME") {
            return Ok(PathBuf::from(path));
        }
    }

    #[cfg(test)]
    if let Ok(path) = std::env::var("SEMANTIC_MCP_HOME") {
        return Ok(PathBuf::from(path));
    }

    if !is_test_mode() {
        if let Ok(path) = std::env::var("REV_HARNESS_RUST_DB_HOME") {
            return Ok(PathBuf::from(path));
        }
    }

    platform_data_root().map(|root| root.join("Revharness").join("semantic-mcp"))
}

/// Return the v2 semantic MCP database path for `project_id`.
pub fn semantic_mcp_db_path(project_id: &str) -> Result<PathBuf> {
    validate_project_id_segment(project_id)?;
    Ok(semantic_mcp_data_root()?
        .join("v1")
        .join(project_id)
        .join("semantic.db"))
}

/// Return the legacy semantic MCP database path, if a home directory is known.
pub fn legacy_db_path(project_id: &str) -> Option<PathBuf> {
    validate_project_id_segment(project_id).ok()?;
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .ok()?;
    Some(
        PathBuf::from(home)
            .join([".semantic", "-mcp"].concat())
            .join(project_id)
            .join("semantic.db"),
    )
}

/// True only when the explicit integration-test harness override is enabled.
pub fn is_test_mode() -> bool {
    std::env::var("REVHARNESS_TEST_HARNESS").as_deref() == Ok("1")
        && std::env::var("SEMANTIC_MCP_HOME").is_ok()
}

pub fn try_lock_exclusive_with_timeout(
    f: &std::fs::File,
    timeout: Duration,
) -> std::io::Result<()> {
    use fs2::FileExt;
    let start = Instant::now();
    let backoff = Duration::from_millis(100);
    loop {
        match f.try_lock_exclusive() {
            Ok(()) => return Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if start.elapsed() >= timeout {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::WouldBlock,
                        format!("try_lock_exclusive timed out after {timeout:?}"),
                    ));
                }
                std::thread::sleep(backoff);
            }
            Err(e) => return Err(e),
        }
    }
}

fn validate_project_id_segment(project_id: &str) -> Result<()> {
    if project_id.is_empty() {
        return Err(AgentError::Validation(
            "project_id must not be empty".to_string(),
        ));
    }
    if !project_id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(AgentError::Validation(
            "project_id must contain only letters, numbers, '_' or '-'".to_string(),
        ));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn platform_data_root() -> Result<PathBuf> {
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
        return Ok(PathBuf::from(xdg));
    }
    let home = std::env::var("HOME")
        .map_err(|_| AgentError::Config("HOME environment variable not set".to_string()))?;
    Ok(PathBuf::from(home).join(".local").join("share"))
}

#[cfg(target_os = "macos")]
fn platform_data_root() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .map_err(|_| AgentError::Config("HOME environment variable not set".to_string()))?;
    Ok(PathBuf::from(home)
        .join("Library")
        .join("Application Support"))
}

#[cfg(target_os = "windows")]
fn platform_data_root() -> Result<PathBuf> {
    let local = std::env::var("LOCALAPPDATA")
        .map_err(|_| AgentError::Config("LOCALAPPDATA environment variable not set".to_string()))?;
    Ok(PathBuf::from(local))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_path_like_project_ids() {
        assert!(semantic_mcp_db_path("../x").is_err());
        assert!(semantic_mcp_db_path("x/y").is_err());
    }

    #[test]
    fn honors_rust_db_home_override_outside_test_mode() {
        // Hold the crate-wide env lock for the whole test so this env mutation
        // can never race a concurrent `semantic_gc` test (which would otherwise
        // resolve a real platform path, panic, and poison its mutex). The guard
        // also snapshots and restores all managed vars on drop.
        let _guard = crate::test_env::EnvGuard::acquire();

        std::env::set_var("REV_HARNESS_RUST_DB_HOME", "/tmp/revharness-rust-db-home");
        std::env::remove_var("REVHARNESS_TEST_HARNESS");
        std::env::remove_var("SEMANTIC_MCP_HOME");

        assert_eq!(
            semantic_mcp_data_root().unwrap(),
            PathBuf::from("/tmp/revharness-rust-db-home")
        );
    }
}
