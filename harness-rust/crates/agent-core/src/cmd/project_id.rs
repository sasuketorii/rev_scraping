//! Project ID helpers.
//!
//! Authoritative project_id bootstrap/read/validation lives here.
//! Semantic MCP launch remains on the shell adapter surface.

use std::env;
use std::fs;
use std::io::Write;
use std::path::{Component, Path, PathBuf};

use clap::Subcommand;
use tempfile::NamedTempFile;
use uuid::Uuid;

use shared::error::{AgentError, Result};

const PROJECT_ID_MAX_LENGTH: usize = 64;
const PROJECT_ID_FORBIDDEN_LITERAL: &str = "agent_base";
const PROJECT_ID_ARTIFACT_RELATIVE_PATH: &str = ".shared/project_id";

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

#[derive(Subcommand, Debug)]
pub enum ProjectIdAction {
    /// Read project ID from artifact.
    Read {
        #[arg(long, hide = true)]
        repo_root: Option<PathBuf>,
    },
    /// Show artifact path.
    ArtifactPath {
        #[arg(long, hide = true)]
        repo_root: Option<PathBuf>,
    },
    /// Bootstrap new project ID.
    Bootstrap {
        /// Seed value for the project ID (default: derive from repo name).
        #[arg(long)]
        seed: Option<String>,
        #[arg(long, hide = true)]
        repo_root: Option<PathBuf>,
    },
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(action: ProjectIdAction) -> Result<()> {
    match action {
        ProjectIdAction::Read { repo_root } => {
            let repo_root = resolve_cli_repo_root(repo_root.as_deref())?;
            println!("{}", read_project_id(&repo_root)?);
            Ok(())
        }
        ProjectIdAction::ArtifactPath { repo_root } => {
            let repo_root = resolve_cli_repo_root(repo_root.as_deref())?;
            println!("{}", project_id_artifact_path(&repo_root)?.display());
            Ok(())
        }
        ProjectIdAction::Bootstrap { seed, repo_root } => {
            let repo_root = resolve_cli_repo_root(repo_root.as_deref())?;
            println!("{}", bootstrap_project_id(&repo_root, seed.as_deref())?);
            Ok(())
        }
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Return the nominal artifact path beneath the provided root.
pub fn artifact_path(repo_root: &Path) -> PathBuf {
    repo_root.join(PROJECT_ID_ARTIFACT_RELATIVE_PATH)
}

/// Read the authoritative project_id from the repo-local artifact.
pub fn read_project_id(repo_root: &Path) -> Result<String> {
    let artifact_path = project_id_artifact_path(repo_root)?;
    if artifact_path.is_file() {
        return read_project_id_from_path(repo_root, &artifact_path);
    }

    Err(AgentError::NotFound(format!(
        "missing project_id artifact: {}",
        artifact_path.display()
    )))
}

/// Validate a project ID string using the shell-compatible contract.
pub fn validate_project_id(id: &str) -> Result<()> {
    validate_project_id_bytes(id.as_bytes())
}

/// Bootstrap the project_id artifact if missing, otherwise return the existing id.
pub fn bootstrap_project_id(repo_root: &Path, seed: Option<&str>) -> Result<String> {
    let artifact_path = project_id_artifact_path(repo_root)?;
    if artifact_path.is_file() {
        return read_project_id_from_path(repo_root, &artifact_path);
    }

    let project_name = seed.unwrap_or_else(|| {
        repo_root
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("repo")
    });
    let project_id = generate_project_id(project_name)?;
    write_project_id_artifact(repo_root, &artifact_path, &project_id)?;
    Ok(project_id)
}

/// Shell-compatible normalization for bootstrap seeds / repo names.
pub fn sanitize_project_name(raw_name: &str) -> String {
    let mut normalized = String::new();
    let mut previous_was_replaced = false;

    for ch in raw_name.chars().flat_map(|ch| ch.to_lowercase()) {
        if ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_' || ch == '-' {
            normalized.push(ch);
            previous_was_replaced = false;
        } else if !previous_was_replaced {
            normalized.push('-');
            previous_was_replaced = true;
        }
    }

    let trimmed = normalized.trim_matches('-').to_string();
    if trimmed.is_empty() {
        "repo".to_string()
    } else {
        trimmed
    }
}

// ---------------------------------------------------------------------------
// Core helpers
// ---------------------------------------------------------------------------

fn resolve_cli_repo_root(repo_root: Option<&Path>) -> Result<PathBuf> {
    if let Some(root) = repo_root {
        return canonicalize_dir(root);
    }

    discover_repo_root_from_current_dir()
}

fn discover_repo_root_from_current_dir() -> Result<PathBuf> {
    let current_dir = canonicalize_dir(&env::current_dir().map_err(AgentError::Io)?)?;
    let mut candidate = current_dir.clone();

    loop {
        if resolve_git_dir(&candidate)?.is_some() {
            return Ok(candidate);
        }

        if !candidate.pop() {
            break;
        }
    }

    Ok(current_dir)
}

fn canonicalize_dir(dir_path: &Path) -> Result<PathBuf> {
    if !dir_path.exists() {
        return Err(AgentError::Validation(format!(
            "directory does not exist: {}",
            dir_path.display()
        )));
    }
    if !dir_path.is_dir() {
        return Err(AgentError::Validation(format!(
            "directory path is required: {}",
            dir_path.display()
        )));
    }
    fs::canonicalize(dir_path).map_err(AgentError::Io)
}

fn resolve_existing_path(path: &Path) -> Result<PathBuf> {
    let parent_dir = path
        .parent()
        .ok_or_else(|| AgentError::Validation(format!("path is required: {}", path.display())))?;
    let base_name = path
        .file_name()
        .ok_or_else(|| AgentError::Validation(format!("path is required: {}", path.display())))?;
    let canonical_parent = canonicalize_dir(parent_dir)?;
    let resolved = canonical_parent.join(base_name);

    if !resolved.exists() {
        return Err(AgentError::Validation(format!(
            "path does not exist: {}",
            path.display()
        )));
    }

    Ok(resolved)
}

fn resolve_path_from_base(base_dir: &Path, candidate_path: &Path) -> PathBuf {
    if candidate_path.is_absolute() {
        return candidate_path.to_path_buf();
    }

    base_dir.join(candidate_path)
}

fn reject_symlink_path(path: &Path, label: &str) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(AgentError::Validation(format!(
            "{label} must not be a symlink: {}",
            path.display()
        ))),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(AgentError::Io(error)),
    }
}

fn read_git_metadata_path_line(path: &Path, label: &str) -> Result<String> {
    reject_symlink_path(path, label)?;
    let raw = fs::read(path).map_err(AgentError::Io)?;
    let line = if raw.last() == Some(&b'\n') {
        &raw[..raw.len() - 1]
    } else {
        raw.as_slice()
    };
    if line.is_empty() {
        return Err(AgentError::Validation(format!(
            "{label} is invalid: {}",
            path.display()
        )));
    }
    if line.contains(&b'\n') || line.contains(&b'\r') {
        return Err(AgentError::Validation(format!(
            "{label} is invalid: {}",
            path.display()
        )));
    }

    String::from_utf8(line.to_vec())
        .map_err(|_| AgentError::Validation(format!("{label} is invalid: {}", path.display())))
}

fn resolve_git_dir(repo_root: &Path) -> Result<Option<PathBuf>> {
    let git_metadata_path = repo_root.join(".git");
    let git_metadata = match fs::symlink_metadata(&git_metadata_path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(AgentError::Io(error)),
    };

    if git_metadata.file_type().is_symlink() {
        return Err(AgentError::Validation(format!(
            ".git metadata path must not be a symlink: {}",
            git_metadata_path.display()
        )));
    }

    if git_metadata.is_dir() {
        return canonicalize_dir(&git_metadata_path).map(Some);
    }

    if git_metadata.is_file() {
        let git_dir_raw = read_git_metadata_path_line(&git_metadata_path, "git metadata file")?;
        let git_dir = git_dir_raw.strip_prefix("gitdir: ").ok_or_else(|| {
            AgentError::Validation(format!(
                "git metadata file is invalid: {}",
                git_metadata_path.display()
            ))
        })?;
        if git_dir.is_empty() {
            return Err(AgentError::Validation(format!(
                "git metadata file is invalid: {}",
                git_metadata_path.display()
            )));
        }

        return canonicalize_dir(&resolve_path_from_base(repo_root, Path::new(git_dir))).map(Some);
    }

    Err(AgentError::Validation(format!(
        ".git metadata path must be a file or directory: {}",
        git_metadata_path.display()
    )))
}

fn resolve_common_git_dir(repo_root: &Path) -> Result<Option<PathBuf>> {
    let Some(git_dir) = resolve_git_dir(repo_root)? else {
        return Ok(None);
    };
    let commondir_path = git_dir.join("commondir");

    let commondir_metadata = match fs::symlink_metadata(&commondir_path) {
        Ok(metadata) => Some(metadata),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => return Err(AgentError::Io(error)),
    };

    if let Some(metadata) = commondir_metadata {
        if metadata.file_type().is_symlink() {
            return Err(AgentError::Validation(format!(
                "git commondir file must not be a symlink: {}",
                commondir_path.display()
            )));
        }
        if !metadata.is_file() {
            return Err(AgentError::Validation(format!(
                "git commondir path must be a regular file: {}",
                commondir_path.display()
            )));
        }

        let commondir = read_git_metadata_path_line(&commondir_path, "git commondir file")?;
        return canonicalize_dir(&resolve_path_from_base(&git_dir, Path::new(&commondir)))
            .map(Some);
    }

    Ok(Some(git_dir))
}

fn path_within_root(candidate: &Path, root: &Path) -> bool {
    candidate == root || candidate.starts_with(root)
}

fn resolve_linked_worktree_identity_root(
    repo_root: &Path,
    git_dir: &Path,
    common_git_dir: &Path,
) -> Result<PathBuf> {
    if common_git_dir.file_name().and_then(|name| name.to_str()) != Some(".git") {
        return Err(AgentError::Validation(format!(
            "git common dir must resolve to a .git directory: {}",
            common_git_dir.display()
        )));
    }

    let git_metadata_path = repo_root.join(".git");
    reject_symlink_path(
        &git_metadata_path,
        "linked worktree proof requires a regular .git file",
    )?;
    let git_metadata = fs::symlink_metadata(&git_metadata_path).map_err(AgentError::Io)?;
    if !git_metadata.is_file() {
        return Err(AgentError::Validation(format!(
            "linked worktree proof requires .git file metadata: {}",
            git_metadata_path.display()
        )));
    }

    let worktrees_dir = common_git_dir.join("worktrees");
    let git_dir_parent = git_dir.parent().ok_or_else(|| {
        AgentError::Validation(format!(
            "linked worktree gitdir must be a direct child of {}: {}",
            worktrees_dir.display(),
            git_dir.display()
        ))
    })?;
    if git_dir_parent != worktrees_dir {
        return Err(AgentError::Validation(format!(
            "linked worktree gitdir must be a direct child of {}: {}",
            worktrees_dir.display(),
            git_dir.display()
        )));
    }

    let backref_path = git_dir.join("gitdir");
    let backref_raw =
        read_git_metadata_path_line(&backref_path, "linked worktree gitdir back-reference")?;
    let resolved_backref =
        resolve_existing_path(&resolve_path_from_base(git_dir, Path::new(&backref_raw)))?;
    let expected_git_file = resolve_existing_path(&git_metadata_path)?;
    if resolved_backref != expected_git_file {
        return Err(AgentError::Validation(format!(
            "linked worktree gitdir back-reference mismatch: expected {} got {}",
            expected_git_file.display(),
            resolved_backref.display()
        )));
    }

    let identity_root = common_git_dir.parent().ok_or_else(|| {
        AgentError::Validation(format!(
            "git common dir must resolve to a .git directory: {}",
            common_git_dir.display()
        ))
    })?;
    canonicalize_dir(identity_root)
}

fn project_identity_root(repo_root: &Path) -> Result<PathBuf> {
    let canonical_root = canonicalize_dir(repo_root)?;
    let Some(git_dir) = resolve_git_dir(&canonical_root)? else {
        return Ok(canonical_root);
    };
    let common_git_dir = resolve_common_git_dir(&canonical_root)?.ok_or_else(|| {
        AgentError::Validation(format!(
            "git metadata path is unavailable for repo root: {}",
            canonical_root.display()
        ))
    })?;

    let local_git_dir = canonical_root.join(".git");
    if git_dir == local_git_dir && common_git_dir == local_git_dir {
        return Ok(canonical_root);
    }

    resolve_linked_worktree_identity_root(&canonical_root, &git_dir, &common_git_dir)
}

fn assert_no_symlink_components(root: &Path, path: &Path) -> Result<()> {
    let normalized_root = canonicalize_dir(root)?;
    if !path_within_root(path, &normalized_root) {
        return Err(AgentError::Validation(format!(
            "project_id path escapes repo-local identity root: {}",
            path.display()
        )));
    }

    let relative = path.strip_prefix(&normalized_root).map_err(|_| {
        AgentError::Validation(format!(
            "project_id path escapes repo-local identity root: {}",
            path.display()
        ))
    })?;

    let mut current = normalized_root;
    for component in relative.components() {
        match component {
            Component::CurDir | Component::ParentDir => {
                return Err(AgentError::Validation(format!(
                    "project_id path must not contain traversal components: {}",
                    path.display()
                )))
            }
            Component::Normal(part) => {
                current.push(part);
                if fs::symlink_metadata(&current)
                    .map(|metadata| metadata.file_type().is_symlink())
                    .unwrap_or(false)
                {
                    return Err(AgentError::Validation(format!(
                        "project_id path contains symlink component: {}",
                        current.display()
                    )));
                }
            }
            _ => {}
        }
    }

    Ok(())
}

fn assert_repo_local_artifact_path(repo_root: &Path, artifact_path: &Path) -> Result<()> {
    let identity_root = project_identity_root(repo_root)?;
    assert_no_symlink_components(&identity_root, artifact_path)?;

    if let Some(parent_dir) = artifact_path.parent() {
        if parent_dir.exists() {
            let resolved_parent = canonicalize_dir(parent_dir)?;
            if !path_within_root(&resolved_parent, &identity_root) {
                return Err(AgentError::Validation(format!(
                    "project_id artifact directory escapes repo-local identity root: {}",
                    resolved_parent.display()
                )));
            }
        }
    }

    if artifact_path.exists() {
        let metadata = fs::symlink_metadata(artifact_path).map_err(AgentError::Io)?;
        if metadata.file_type().is_symlink() {
            return Err(AgentError::Validation(format!(
                "project_id artifact path must not be a symlink: {}",
                artifact_path.display()
            )));
        }
        if !metadata.file_type().is_file() {
            return Err(AgentError::Validation(format!(
                "project_id artifact path must be a regular file: {}",
                artifact_path.display()
            )));
        }

        let resolved_artifact = resolve_existing_path(artifact_path)?;
        if !path_within_root(&resolved_artifact, &identity_root) {
            return Err(AgentError::Validation(format!(
                "project_id artifact path escapes repo-local identity root: {}",
                resolved_artifact.display()
            )));
        }
    }

    Ok(())
}

fn project_id_artifact_path(repo_root: &Path) -> Result<PathBuf> {
    let identity_root = project_identity_root(repo_root)?;
    let artifact_path = artifact_path(&identity_root);
    assert_repo_local_artifact_path(repo_root, &artifact_path)?;
    Ok(artifact_path)
}

fn is_project_id_byte(byte: u8) -> bool {
    matches!(byte, b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'_' | b'-')
}

fn validate_project_id_bytes(project_id: &[u8]) -> Result<()> {
    if project_id.is_empty() {
        return Err(AgentError::Validation(
            "project_id must not be empty".to_string(),
        ));
    }
    if project_id.len() > PROJECT_ID_MAX_LENGTH {
        return Err(AgentError::Validation(format!(
            "project_id must be <= {} characters",
            PROJECT_ID_MAX_LENGTH
        )));
    }
    if project_id.iter().any(|byte| byte.is_ascii_control()) {
        return Err(AgentError::Validation(
            "project_id must not contain control bytes".to_string(),
        ));
    }
    if !project_id.iter().all(|byte| is_project_id_byte(*byte)) {
        return Err(AgentError::Validation(
            "project_id must contain only letters, numbers, '_' or '-'".to_string(),
        ));
    }
    if project_id == PROJECT_ID_FORBIDDEN_LITERAL.as_bytes() {
        return Err(AgentError::Validation(format!(
            "project_id literal '{}' is forbidden; bootstrap a repo-local immutable id",
            PROJECT_ID_FORBIDDEN_LITERAL
        )));
    }

    Ok(())
}

fn read_project_id_from_path(repo_root: &Path, artifact_path: &Path) -> Result<String> {
    assert_repo_local_artifact_path(repo_root, artifact_path)?;
    let raw = fs::read(artifact_path).map_err(AgentError::Io)?;
    if raw.is_empty() {
        return Err(AgentError::Validation(format!(
            "project_id artifact must not be empty: {}",
            artifact_path.display()
        )));
    }

    let project_id_bytes = if raw.last() == Some(&b'\n') {
        &raw[..raw.len() - 1]
    } else {
        raw.as_slice()
    };
    if project_id_bytes.is_empty() {
        return Err(AgentError::Validation(format!(
            "project_id artifact must not be empty: {}",
            artifact_path.display()
        )));
    }
    if project_id_bytes.contains(&b'\n') {
        return Err(AgentError::Validation(format!(
            "project_id artifact must contain exactly one logical line: {}",
            artifact_path.display()
        )));
    }
    validate_project_id_bytes(project_id_bytes)?;
    String::from_utf8(project_id_bytes.to_vec()).map_err(|_| {
        AgentError::Validation(
            "project_id must contain only letters, numbers, '_' or '-'".to_string(),
        )
    })
}

fn write_project_id_artifact(
    repo_root: &Path,
    artifact_path: &Path,
    project_id: &str,
) -> Result<()> {
    assert_repo_local_artifact_path(repo_root, artifact_path)?;

    let parent_dir = artifact_path.parent().ok_or_else(|| {
        AgentError::Validation(format!(
            "project_id artifact path has no parent: {}",
            artifact_path.display()
        ))
    })?;
    fs::create_dir_all(parent_dir).map_err(AgentError::Io)?;
    assert_repo_local_artifact_path(repo_root, artifact_path)?;

    let mut tmp_file = NamedTempFile::new_in(parent_dir).map_err(AgentError::Io)?;
    writeln!(tmp_file, "{project_id}").map_err(AgentError::Io)?;
    tmp_file.persist(artifact_path).map_err(|error| {
        AgentError::Io(std::io::Error::new(
            error.error.kind(),
            format!("failed to persist project_id artifact: {}", error.error),
        ))
    })?;

    assert_repo_local_artifact_path(repo_root, artifact_path)
}

fn random_suffix() -> String {
    Uuid::new_v4()
        .simple()
        .to_string()
        .chars()
        .take(12)
        .collect()
}

fn generate_project_id(project_name: &str) -> Result<String> {
    let prefix = sanitize_project_name(project_name);
    let suffix = random_suffix();

    let max_prefix_length = PROJECT_ID_MAX_LENGTH
        .checked_sub(suffix.len() + 1)
        .ok_or_else(|| {
            AgentError::Validation("internal error: invalid project_id prefix budget".to_string())
        })?;
    if max_prefix_length < 1 {
        return Err(AgentError::Validation(
            "internal error: invalid project_id prefix budget".to_string(),
        ));
    }

    let truncated_prefix: String = prefix.chars().take(max_prefix_length).collect();
    let project_id = format!("{truncated_prefix}-{suffix}");
    validate_project_id(&project_id)?;
    Ok(project_id)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cmd::test_support::{lock_process_state, CurrentDirGuard, EnvGuard, PathGuard};

    fn write_linked_worktree_fixture(primary: &Path, linked: &Path) {
        let linked_git_dir = primary.join(".git/worktrees/linked");
        fs::create_dir_all(&linked_git_dir).unwrap();
        fs::create_dir_all(linked).unwrap();
        fs::write(
            linked.join(".git"),
            format!("gitdir: {}\n", linked_git_dir.display()),
        )
        .unwrap();
        fs::write(linked_git_dir.join("commondir"), "../..\n").unwrap();
        fs::write(
            linked_git_dir.join("gitdir"),
            format!("{}\n", linked.join(".git").display()),
        )
        .unwrap();
    }

    fn write_project_id_fixture(repo_root: &Path, project_id: &str) {
        fs::create_dir_all(repo_root.join(".git")).unwrap();
        fs::create_dir_all(repo_root.join(".shared")).unwrap();
        fs::write(
            repo_root.join(".shared/project_id"),
            format!("{project_id}\n"),
        )
        .unwrap();
    }

    fn assert_external_identity_redirect_is_rejected(attacker: &Path, victim: &Path) {
        let artifact_error = project_id_artifact_path(attacker).unwrap_err().to_string();
        assert!(artifact_error.contains("linked worktree"));

        let read_error = read_project_id(attacker).unwrap_err().to_string();
        assert!(read_error.contains("linked worktree"));

        let bootstrap_error = bootstrap_project_id(attacker, Some("attacker"))
            .unwrap_err()
            .to_string();
        assert!(bootstrap_error.contains("linked worktree"));

        assert_eq!(
            fs::read_to_string(victim.join(".shared/project_id")).unwrap(),
            "victim-id\n"
        );
        assert!(!attacker.join(".shared/project_id").exists());
    }

    #[test]
    fn test_sanitize_project_name_basic() {
        assert_eq!(sanitize_project_name("My Project"), "my-project");
        assert_eq!(sanitize_project_name("hello_world"), "hello_world");
        assert_eq!(sanitize_project_name("foo--bar"), "foo--bar");
    }

    #[test]
    fn test_sanitize_project_name_special() {
        assert_eq!(sanitize_project_name("a/b/c"), "a-b-c");
        assert_eq!(sanitize_project_name("---leading"), "leading");
        assert_eq!(sanitize_project_name("trailing---"), "trailing");
        assert_eq!(sanitize_project_name(""), "repo");
    }

    #[test]
    fn test_sanitize_project_name_truncation_happens_in_generate() {
        let long = "a".repeat(100);
        let result = sanitize_project_name(&long);
        assert_eq!(result.len(), 100);
    }

    #[test]
    fn test_artifact_path() {
        let root = Path::new("/repo");
        let path = artifact_path(root);
        assert_eq!(path, PathBuf::from("/repo/.shared/project_id"));
    }

    #[test]
    fn test_validate_project_id_valid() {
        assert!(validate_project_id("my-project").is_ok());
        assert!(validate_project_id("proj_123").is_ok());
    }

    #[test]
    fn test_validate_project_id_invalid() {
        assert!(validate_project_id("").is_err());
        assert!(validate_project_id("agent_base").is_err());
        assert!(validate_project_id("bad/id").is_err());
        assert!(validate_project_id("bad\rid").is_err());
        assert!(validate_project_id("bad\nid").is_err());
    }

    #[test]
    fn test_bootstrap_and_read() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();

        let id = bootstrap_project_id(root, Some("test-proj")).unwrap();
        assert!(id.starts_with("test-proj-"));

        let read_id = read_project_id(root).unwrap();
        assert_eq!(read_id, id);

        let id2 = bootstrap_project_id(root, Some("different")).unwrap();
        assert_eq!(id2, id);
    }

    #[test]
    fn test_bootstrap_from_dirname() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();

        let id = bootstrap_project_id(root, None).unwrap();
        assert!(!id.is_empty());
    }

    #[test]
    fn test_read_project_id_missing() {
        let dir = tempfile::tempdir().unwrap();
        let result = read_project_id(dir.path());
        assert!(result.is_err());
        let error = result.err().unwrap().to_string();
        assert!(error.contains("missing project_id artifact"));
    }

    #[test]
    fn test_read_project_id_rejects_multiline_artifact() {
        let dir = tempfile::tempdir().unwrap();
        let shared_dir = dir.path().join(".shared");
        fs::create_dir_all(&shared_dir).unwrap();
        fs::write(shared_dir.join("project_id"), "valid-id\nsecond-line\n").unwrap();

        let error = read_project_id(dir.path()).unwrap_err().to_string();
        assert!(error.contains("must contain exactly one logical line"));
    }

    #[test]
    fn test_read_project_id_rejects_embedded_carriage_return_artifact() {
        let dir = tempfile::tempdir().unwrap();
        let shared_dir = dir.path().join(".shared");
        fs::create_dir_all(&shared_dir).unwrap();
        fs::write(shared_dir.join("project_id"), b"abc\rdef\n").unwrap();

        let error = read_project_id(dir.path()).unwrap_err().to_string();
        assert!(error.contains("must not contain control bytes"));
    }

    #[test]
    fn test_read_project_id_rejects_terminal_crlf_artifact() {
        let dir = tempfile::tempdir().unwrap();
        let shared_dir = dir.path().join(".shared");
        fs::create_dir_all(&shared_dir).unwrap();
        fs::write(shared_dir.join("project_id"), b"valid-id\r\n").unwrap();

        let error = read_project_id(dir.path()).unwrap_err().to_string();
        assert!(error.contains("must not contain control bytes"));
    }

    #[test]
    fn test_project_id_artifact_path_rejects_symlink_parent() {
        let dir = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), dir.path().join(".shared")).unwrap();

        let error = project_id_artifact_path(dir.path())
            .unwrap_err()
            .to_string();
        assert!(error.contains("symlink component"));
    }

    #[test]
    fn test_project_id_artifact_path_prefers_identity_root() {
        let dir = tempfile::tempdir().unwrap();
        let primary = dir.path().join("primary");
        let linked = dir.path().join("linked");
        fs::create_dir_all(primary.join(".git")).unwrap();
        write_linked_worktree_fixture(&primary, &linked);

        let artifact = project_id_artifact_path(&linked).unwrap();
        let expected_root = canonicalize_dir(&primary).unwrap();
        assert_eq!(artifact, expected_root.join(".shared/project_id"));
    }

    #[test]
    fn test_project_id_surfaces_reject_forged_external_gitdir_redirect() {
        let dir = tempfile::tempdir().unwrap();
        let victim = dir.path().join("victim");
        let attacker = dir.path().join("attacker");

        write_project_id_fixture(&victim, "victim-id");
        fs::create_dir_all(&attacker).unwrap();
        fs::write(
            attacker.join(".git"),
            format!("gitdir: {}\n", victim.join(".git").display()),
        )
        .unwrap();

        assert_external_identity_redirect_is_rejected(&attacker, &victim);
    }

    #[test]
    fn test_project_id_surfaces_reject_forged_external_commondir_redirect() {
        let dir = tempfile::tempdir().unwrap();
        let victim = dir.path().join("victim");
        let attacker = dir.path().join("attacker");

        write_project_id_fixture(&victim, "victim-id");
        fs::create_dir_all(attacker.join(".git")).unwrap();
        fs::write(
            attacker.join(".git/commondir"),
            format!("{}\n", victim.join(".git").display()),
        )
        .unwrap();

        assert_external_identity_redirect_is_rejected(&attacker, &victim);
    }

    #[test]
    fn test_linked_worktree_bootstrap_and_read_use_common_identity_root() {
        let dir = tempfile::tempdir().unwrap();
        let primary = dir.path().join("primary");
        let linked = dir.path().join("linked");

        fs::create_dir_all(primary.join(".git")).unwrap();
        write_linked_worktree_fixture(&primary, &linked);

        let artifact = project_id_artifact_path(&linked).unwrap();
        let project_id = bootstrap_project_id(&linked, Some("linked-worktree")).unwrap();

        assert_eq!(
            artifact,
            canonicalize_dir(&primary)
                .unwrap()
                .join(".shared/project_id")
        );
        assert_eq!(read_project_id(&linked).unwrap(), project_id);
        assert_eq!(
            fs::read_to_string(primary.join(".shared/project_id")).unwrap(),
            format!("{project_id}\n")
        );
        assert!(!linked.join(".shared/project_id").exists());
    }

    #[test]
    fn test_identity_resolution_ignores_git_env_injection() {
        let _process_state = lock_process_state();
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("repo");
        let victim = dir.path().join("victim");

        write_project_id_fixture(&repo, "local-id");
        write_project_id_fixture(&victim, "victim-id");

        let _git_dir = EnvGuard::set("GIT_DIR", victim.join(".git"));
        let _git_common_dir = EnvGuard::set("GIT_COMMON_DIR", victim.join(".git"));
        let _git_work_tree = EnvGuard::set("GIT_WORK_TREE", &victim);

        assert_eq!(
            project_id_artifact_path(&repo).unwrap(),
            canonicalize_dir(&repo).unwrap().join(".shared/project_id")
        );
        assert_eq!(read_project_id(&repo).unwrap(), "local-id");
    }

    #[test]
    fn test_read_project_id_ignores_path_poisoned_git_for_common_root_resolution() {
        use std::os::unix::fs::PermissionsExt;

        let _process_state = lock_process_state();
        let dir = tempfile::tempdir().unwrap();
        let primary = dir.path().join("primary");
        let linked = dir.path().join("linked");
        let hostile_dir = dir.path().join("hostile-bin");
        let hostile_git = hostile_dir.join("git");
        let hostile_marker = hostile_dir.join("git.marker");

        fs::create_dir_all(primary.join(".git")).unwrap();
        fs::create_dir_all(primary.join(".shared")).unwrap();
        write_linked_worktree_fixture(&primary, &linked);
        fs::write(primary.join(".shared/project_id"), "common-root-id\n").unwrap();

        fs::create_dir_all(&hostile_dir).unwrap();
        fs::write(
            &hostile_git,
            format!("#!/bin/sh\n: > {}\nexit 99\n", hostile_marker.display()),
        )
        .unwrap();
        let mut permissions = fs::metadata(&hostile_git).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&hostile_git, permissions).unwrap();

        let _path_guard = PathGuard::prepend(&hostile_dir);
        let project_id = read_project_id(&linked).unwrap();

        assert_eq!(project_id, "common-root-id");
        assert!(!hostile_marker.exists());
    }

    #[test]
    fn test_resolve_cli_repo_root_ignores_path_poisoned_git_when_repo_root_is_omitted() {
        use std::os::unix::fs::PermissionsExt;

        let _process_state = lock_process_state();
        let dir = tempfile::tempdir().unwrap();
        let primary = dir.path().join("primary");
        let linked = dir.path().join("linked");
        let nested = linked.join("src");
        let hostile_dir = dir.path().join("hostile-bin");
        let hostile_git = hostile_dir.join("git");
        let hostile_marker = hostile_dir.join("git.marker");

        fs::create_dir_all(primary.join(".git")).unwrap();
        write_linked_worktree_fixture(&primary, &linked);
        fs::create_dir_all(&nested).unwrap();

        fs::create_dir_all(&hostile_dir).unwrap();
        fs::write(
            &hostile_git,
            format!("#!/bin/sh\n: > {}\nexit 99\n", hostile_marker.display()),
        )
        .unwrap();
        let mut permissions = fs::metadata(&hostile_git).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&hostile_git, permissions).unwrap();

        let _path_guard = PathGuard::prepend(&hostile_dir);
        let _dir_guard = CurrentDirGuard::set(&nested);
        let repo_root = resolve_cli_repo_root(None).unwrap();

        assert_eq!(repo_root, canonicalize_dir(&linked).unwrap());
        assert!(!hostile_marker.exists());
    }
}
