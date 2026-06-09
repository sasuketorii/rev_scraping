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

/// Run a git command rooted at `repo` (via `-C`) and return trimmed-line output.
///
/// Used by the path-aware variants so that callers (and tests) can target a
/// specific working tree without mutating the process-wide current directory.
fn git_lines_at(repo: &std::path::Path, args: &[&str]) -> Result<Vec<String>> {
    let mut full: Vec<&str> = vec!["-C"];
    let repo_str = repo.to_string_lossy();
    full.push(&repo_str);
    full.extend_from_slice(args);
    git_lines(&full)
}

/// Run a git command rooted at `repo` (via `-C`) and return trimmed stdout.
fn git_output_at(repo: &std::path::Path, args: &[&str]) -> Result<String> {
    let mut full: Vec<&str> = vec!["-C"];
    let repo_str = repo.to_string_lossy();
    full.push(&repo_str);
    full.extend_from_slice(args);
    git_output(&full)
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

/// Return the list of files changed by a single commit (default: `HEAD`),
/// for incremental post-commit reindexing.
///
/// This returns the files touched **by the commit itself** — not the working
/// tree — so a post-commit hook can reindex exactly the symbols a commit
/// introduced (the case where edit-driven indexing leaves the cache stale).
/// Paths are repo-relative (as emitted by git) and include renames and
/// deletions; the caller is expected to tolerate paths that no longer exist on
/// disk (e.g. the old name of a rename, or a deletion) by skipping them.
///
/// `base` selects the comparison point for an ordinary commit (default
/// `HEAD^`). The two non-ordinary cases are resolved automatically:
///
/// - **Initial commit** (no parent): `base` (`HEAD^`) does not resolve, so we
///   fall back to `git diff-tree --no-commit-id --name-only -r HEAD`, which
///   diffs the commit against the empty tree and lists every file it added.
/// - **Merge commit** (>=2 parents) with the default base: a plain
///   `git diff HEAD^ HEAD` would resolve `HEAD^` to the *first parent* and
///   therefore report the entire set of files the merged branch brought onto
///   the mainline — usually far more than the merge commit "changed". We make
///   that choice explicit and deterministic by pinning the base to `HEAD^1`
///   (first parent). Rationale: a post-commit reindex wants the symbols that
///   are now present on the line we just committed to; first-parent diff is the
///   conventional "what landed on this branch" view and is bounded. An explicit
///   `base` override is always honoured verbatim, so callers that want a
///   different merge semantics can pass one.
pub fn git_commit_changed_files(base: Option<&str>) -> Result<Vec<String>> {
    let repo = git_repo_root()?;
    git_commit_changed_files_at(&repo, base)
}

/// Return the number of parents of `HEAD` in the repo at `repo`.
///
/// `0` = initial (root) commit, `1` = ordinary commit, `>=2` = merge commit.
/// Implemented via `git rev-list --parents -n 1 HEAD`, which prints the commit
/// SHA followed by each parent SHA on one line; parents = tokens - 1.
pub fn git_commit_parent_count(repo: &std::path::Path) -> Result<usize> {
    git_commit_parent_count_for_ref(repo, "HEAD")
}

/// Return the number of parents of `commitish` in the repo at `repo`.
pub fn git_commit_parent_count_for_ref(repo: &std::path::Path, commitish: &str) -> Result<usize> {
    let parents_line = git_output_at(repo, &["rev-list", "--parents", "-n", "1", commitish])?;
    Ok(parents_line.split_whitespace().count().saturating_sub(1))
}

/// Path-aware variant of [`git_commit_changed_files`] rooted at `repo`.
///
/// Identical semantics to [`git_commit_changed_files`]; exposed so callers and
/// tests can target a specific working tree without changing the process cwd.
pub fn git_commit_changed_files_at(
    repo: &std::path::Path,
    base: Option<&str>,
) -> Result<Vec<String>> {
    git_commit_changed_files_at_head(repo, base, None)
}

/// Path-aware commit changed-file collector for an immutable head ref.
///
/// When `head` is `None`, this is equivalent to [`git_commit_changed_files_at`].
/// Passing a concrete commit SHA lets async post-commit work index the commit
/// that triggered the hook even if `HEAD` advances before the detached process
/// runs.
pub fn git_commit_changed_files_at_head(
    repo: &std::path::Path,
    base: Option<&str>,
    head: Option<&str>,
) -> Result<Vec<String>> {
    let head_ref = head.unwrap_or("HEAD");
    let parent_count = git_commit_parent_count_for_ref(repo, head_ref)?;

    // Initial commit: no parent to diff against. Diff the commit tree against
    // the empty tree (`--root`) to list everything it introduced. Without
    // `--root`, diff-tree on a parentless commit emits nothing.
    if parent_count == 0 && base.is_none() {
        return git_lines_at(
            repo,
            &[
                "diff-tree",
                "--root",
                "--no-commit-id",
                "--name-only",
                "-r",
                head_ref,
            ],
        );
    }

    // For an ordinary or merge commit, decide the base. An explicit override is
    // honoured as-is; otherwise the default is HEAD^, pinned to the first parent
    // (HEAD^1) for merges so the diff stays bounded and deterministic.
    let resolved_base = match base {
        Some(b) => b.to_string(),
        None if parent_count >= 2 => format!("{head_ref}^1"),
        None => format!("{head_ref}^"),
    };

    // `--no-renames`: a rename is reported as a delete of the old path plus an
    // add of the new path. This is deliberate for incremental reindex — the new
    // path must be (re)indexed, and the old path is a deletion the indexer skips
    // (no file on disk). It also makes the output independent of git's
    // similarity heuristic, which would otherwise vary the result.
    git_lines_at(
        repo,
        &[
            "diff",
            "--name-only",
            "--no-renames",
            &resolved_base,
            head_ref,
        ],
    )
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

    // -----------------------------------------------------------------------
    // git_commit_changed_files_at — test helpers
    //
    // These build throw-away git repositories under a tempdir so the commit
    // collector can be exercised deterministically (normal / initial / rename /
    // delete / merge) without touching the host repo or the process cwd.
    // -----------------------------------------------------------------------

    use std::path::Path;
    use std::process::Command;

    /// Run a git command in `repo`, panicking on failure (test-only).
    fn git(repo: &Path, args: &[&str]) {
        let status = Command::new("git")
            .arg("-C")
            .arg(repo)
            .args(args)
            .output()
            .expect("failed to spawn git");
        assert!(
            status.status.success(),
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&status.stderr)
        );
    }

    /// Initialise a deterministic repo (fixed identity, no signing, `main`).
    fn init_repo(repo: &Path) {
        git(repo, &["init", "-q", "-b", "main"]);
        git(repo, &["config", "user.email", "test@example.com"]);
        git(repo, &["config", "user.name", "Test"]);
        git(repo, &["config", "commit.gpgsign", "false"]);
    }

    fn write(repo: &Path, rel: &str, contents: &str) {
        let path = repo.join(rel);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(path, contents).unwrap();
    }

    #[test]
    fn commit_changed_files_initial_commit_lists_all_added() {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path();
        init_repo(repo);
        write(repo, "a.rs", "fn a() {}\n");
        write(repo, "dir/b.rs", "fn b() {}\n");
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "initial"]);

        // No parent: default base (HEAD^) cannot resolve, must fall back to
        // diff-tree against the empty tree.
        let mut files = git_commit_changed_files_at(repo, None).unwrap();
        files.sort();
        assert_eq!(files, vec!["a.rs".to_string(), "dir/b.rs".to_string()]);
    }

    #[test]
    fn commit_changed_files_normal_commit_lists_only_that_commit() {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path();
        init_repo(repo);
        write(repo, "a.rs", "fn a() {}\n");
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "c1"]);

        // Second commit changes only b.rs; a.rs is untouched.
        write(repo, "b.rs", "fn b() {}\n");
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "c2"]);

        let files = git_commit_changed_files_at(repo, None).unwrap();
        assert_eq!(files, vec!["b.rs".to_string()]);
    }

    #[test]
    fn commit_changed_files_with_explicit_head_ignores_later_head_advance() {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path();
        init_repo(repo);
        write(repo, "a.rs", "fn a() {}\n");
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "c1"]);

        write(repo, "b.rs", "fn b() {}\n");
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "c2"]);
        let head_c2 = git_output_at(repo, &["rev-parse", "HEAD"]).unwrap();
        let base_c2 = git_output_at(repo, &["rev-parse", "HEAD^1"]).unwrap();

        write(repo, "c.rs", "fn c() {}\n");
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "c3"]);

        let pinned =
            git_commit_changed_files_at_head(repo, Some(&base_c2), Some(&head_c2)).unwrap();
        assert_eq!(pinned, vec!["b.rs".to_string()]);

        let current = git_commit_changed_files_at(repo, None).unwrap();
        assert_eq!(current, vec!["c.rs".to_string()]);
    }

    #[test]
    fn commit_changed_files_includes_renames_and_deletes() {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path();
        init_repo(repo);
        write(repo, "old.rs", "fn x() {}\n");
        write(repo, "doomed.rs", "fn y() {}\n");
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "c1"]);

        // Rename old.rs -> new.rs and delete doomed.rs in one commit.
        std::fs::rename(repo.join("old.rs"), repo.join("new.rs")).unwrap();
        std::fs::remove_file(repo.join("doomed.rs")).unwrap();
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "c2"]);

        // `diff --name-only` reports both sides of a rename plus the deletion.
        // The collector returns them all; the indexer is expected to skip paths
        // that no longer exist on disk (old.rs, doomed.rs).
        let mut files = git_commit_changed_files_at(repo, None).unwrap();
        files.sort();
        assert_eq!(
            files,
            vec![
                "doomed.rs".to_string(),
                "new.rs".to_string(),
                "old.rs".to_string()
            ]
        );
    }

    #[test]
    fn commit_changed_files_merge_uses_first_parent() {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path();
        init_repo(repo);
        write(repo, "base.rs", "fn base() {}\n");
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "base"]);

        // Branch off and add feature.rs on a side branch.
        git(repo, &["checkout", "-q", "-b", "feature"]);
        write(repo, "feature.rs", "fn feat() {}\n");
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "feature"]);

        // Advance main with its own file so the merge is a real (non-ff) merge.
        git(repo, &["checkout", "-q", "main"]);
        write(repo, "main_only.rs", "fn m() {}\n");
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "main work"]);

        // Merge feature into main: creates a 2-parent merge commit.
        git(
            repo,
            &["merge", "-q", "--no-ff", "-m", "merge feature", "feature"],
        );

        // With the default base, a merge pins to HEAD^1 (first parent = the
        // "main work" commit). The first-parent diff therefore surfaces the
        // file the merged branch brought in (feature.rs), not main_only.rs which
        // already existed on the first parent.
        let files = git_commit_changed_files_at(repo, None).unwrap();
        assert_eq!(files, vec!["feature.rs".to_string()]);
    }
}
