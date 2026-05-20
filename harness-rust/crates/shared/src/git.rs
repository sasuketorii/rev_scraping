//! Git CLI utilities.
//!
//! All functions shell out to the `git` binary via [`std::process::Command`].
//! They return [`AgentError::Git`] on failure.

use std::path::PathBuf;
use std::process::Command;

use crate::error::{AgentError, Result};
use crate::types::WorktreeInfo;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Run a git command and return trimmed stdout on success.
fn git_output(args: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .args(args)
        .output()
        .map_err(|e| AgentError::Git(format!("failed to run git: {e}")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AgentError::Git(format!(
            "git {} failed: {}",
            args.join(" "),
            stderr.trim()
        )));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Split trimmed git output into non-empty lines.
fn git_lines(args: &[&str]) -> Result<Vec<String>> {
    let raw = git_output(args)?;
    Ok(raw
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect())
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Return the repository root directory.
pub fn git_repo_root() -> Result<PathBuf> {
    let root = git_output(&["rev-parse", "--show-toplevel"])?;
    Ok(PathBuf::from(root))
}

/// Return the repository root for the given path.
///
/// Backward-compatible alias used by `agent-core`.
pub fn repo_root(path: &std::path::Path) -> Result<String> {
    let output = Command::new("git")
        .args([
            "-C",
            &path.to_string_lossy(),
            "rev-parse",
            "--show-toplevel",
        ])
        .output()
        .map_err(|e| AgentError::Git(format!("failed to run git: {e}")))?;

    if !output.status.success() {
        return Err(AgentError::Git("not inside a git repository".into()));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Return the current HEAD commit SHA.
pub fn git_current_head() -> Result<String> {
    git_output(&["rev-parse", "HEAD"])
}

/// Return the list of files changed between `base` and HEAD.
pub fn git_diff_files(base: &str) -> Result<Vec<String>> {
    git_lines(&["diff", "--name-only", base, "HEAD"])
}

/// Return the list of files with uncommitted changes (staged + unstaged).
pub fn git_changed_files() -> Result<Vec<String>> {
    git_lines(&["diff", "--name-only", "HEAD"])
}

/// Return the list of untracked files.
pub fn git_ls_files_untracked() -> Result<Vec<String>> {
    git_lines(&["ls-files", "--others", "--exclude-standard"])
}

/// List all git worktrees and parse their metadata.
pub fn git_worktree_list() -> Result<Vec<WorktreeInfo>> {
    let raw = git_output(&["worktree", "list", "--porcelain"])?;
    let mut result = Vec::new();
    let mut path: Option<String> = None;
    let mut head: Option<String> = None;
    let mut branch: Option<String> = None;

    for line in raw.lines() {
        if let Some(p) = line.strip_prefix("worktree ") {
            // Flush previous entry
            if let (Some(p_val), Some(h_val)) = (path.take(), head.take()) {
                result.push(WorktreeInfo {
                    path: p_val,
                    head: h_val,
                    branch: branch.take(),
                });
            }
            path = Some(p.to_string());
            head = None;
            branch = None;
        } else if let Some(h) = line.strip_prefix("HEAD ") {
            head = Some(h.to_string());
        } else if let Some(b) = line.strip_prefix("branch ") {
            branch = Some(b.to_string());
        }
    }
    // Flush last entry
    if let (Some(p_val), Some(h_val)) = (path, head) {
        result.push(WorktreeInfo {
            path: p_val,
            head: h_val,
            branch,
        });
    }

    Ok(result)
}

/// Return the list of git-tracked files at a specific root directory.
pub fn git_ls_files_at(root: &std::path::Path) -> Result<Vec<String>> {
    let output = std::process::Command::new("git")
        .args(["-C", &root.to_string_lossy(), "ls-files", "--cached"])
        .output()
        .map_err(|e| AgentError::Git(format!("failed to run git ls-files: {e}")))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AgentError::Git(format!(
            "git ls-files failed: {}",
            stderr.trim()
        )));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| l.to_string())
        .collect())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repo_root_returns_path() {
        // This test only passes when run inside a git repository.
        if let Ok(root) = git_repo_root() {
            assert!(root.exists());
        }
    }

    #[test]
    fn current_head_returns_sha() {
        if let Ok(sha) = git_current_head() {
            // A full SHA is 40 hex characters.
            assert!(sha.len() >= 7);
        }
    }
}
