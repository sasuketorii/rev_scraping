//! Shared freshness calculation for cache-bound capsule/context invariants.

use std::path::{Component, Path, PathBuf};

use rusqlite::Connection;
use sha2::{Digest, Sha256};

/// Cache-bound freshness state for a set of changed files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FreshnessSnapshot {
    pub file_sha_rollup: String,
    pub index_version: u64,
}

/// Errors returned by shared freshness checks.
#[derive(thiserror::Error, Debug)]
pub enum FreshnessError {
    #[error("file_parse_cache miss for path: {0}")]
    MissingCacheEntry(String),
    #[error("_ts_meta.index_version invalid: {0}")]
    InvalidIndexVersion(String),
    #[error("path validation failed: {0}")]
    InvalidPath(String),
    #[error("freshness rollup changed: expected {expected}, actual {actual}")]
    Changed { expected: String, actual: String },
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

/// Return the current freshness snapshot for `changed_files_repo_relative`.
pub fn snapshot(
    conn: &Connection,
    project_id: &str,
    repo_root: &Path,
    changed_files_repo_relative: &[String],
) -> Result<FreshnessSnapshot, FreshnessError> {
    let repo_root = repo_root.canonicalize()?;
    let mut pairs = Vec::with_capacity(changed_files_repo_relative.len());
    for rel in changed_files_repo_relative {
        // Validate the path on disk (symlink / escape / traversal guards) using
        // the absolute join, but key file_parse_cache and the rollup by the
        // REPO-RELATIVE string — file_parse_cache.file_path is now stored
        // repo-relative (path flip). Storage + rollup input flip together, so
        // sem.capsule freshness-verify stays internally consistent (the
        // FILE_SHA_ROLLUP value changes intentionally; there is no golden).
        validate_repo_relative_path(&repo_root, rel)?;
        let relative_key = path_to_forward_slashes(Path::new(rel));
        let hash = lookup_file_hash(conn, project_id, &relative_key)?
            .ok_or_else(|| FreshnessError::MissingCacheEntry(rel.clone()))?;
        pairs.push((relative_key, hash));
    }
    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    let rollup_input = pairs
        .iter()
        .map(|(path, hash)| format!("{path}\t{hash}"))
        .collect::<Vec<_>>()
        .join("\n");

    Ok(FreshnessSnapshot {
        file_sha_rollup: sha256_hex(&rollup_input),
        index_version: read_index_version(conn)?,
    })
}

/// Verify that the current FILE_SHA_ROLLUP still matches `expected_rollup`.
pub fn verify_unchanged(
    conn: &Connection,
    project_id: &str,
    repo_root: &Path,
    changed_files_repo_relative: &[String],
    expected_rollup: &str,
) -> Result<(), FreshnessError> {
    let current = snapshot(conn, project_id, repo_root, changed_files_repo_relative)?;
    if current.file_sha_rollup != expected_rollup {
        return Err(FreshnessError::Changed {
            expected: expected_rollup.to_string(),
            actual: current.file_sha_rollup,
        });
    }
    Ok(())
}

/// Read the current tree-sitter index version.
pub fn read_index_version(conn: &Connection) -> Result<u64, FreshnessError> {
    let value: String = conn.query_row(
        "SELECT value FROM _ts_meta WHERE key = 'index_version'",
        [],
        |row| row.get(0),
    )?;
    value
        .parse::<u64>()
        .map_err(|_| FreshnessError::InvalidIndexVersion(value))
}

fn validate_repo_relative_path(
    canonical_repo_root: &Path,
    rel: &str,
) -> Result<PathBuf, FreshnessError> {
    if rel.trim().is_empty() {
        return Err(FreshnessError::InvalidPath(
            "repo-relative path must not be empty".to_string(),
        ));
    }
    let rel_path = Path::new(rel);
    if rel_path.is_absolute() {
        return Err(FreshnessError::InvalidPath(format!(
            "absolute path rejected: {rel}"
        )));
    }
    if rel_path
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
        return Err(FreshnessError::InvalidPath(format!(
            "parent traversal rejected: {rel}"
        )));
    }

    let joined = canonical_repo_root.join(rel_path);
    let mut current = canonical_repo_root.to_path_buf();
    for component in rel_path.components() {
        current.push(component.as_os_str());
        if current.symlink_metadata()?.file_type().is_symlink() {
            return Err(FreshnessError::InvalidPath(format!(
                "symlink path rejected: {rel}"
            )));
        }
    }
    let canonical = joined.canonicalize()?;
    if !canonical.starts_with(canonical_repo_root) {
        return Err(FreshnessError::InvalidPath(format!(
            "path escapes repo root: {rel}"
        )));
    }
    Ok(canonical)
}

fn lookup_file_hash(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
) -> Result<Option<String>, FreshnessError> {
    let mut stmt = conn.prepare(
        "SELECT file_hash FROM file_parse_cache WHERE project_id = ?1 AND file_path = ?2",
    )?;
    match stmt.query_row(rusqlite::params![project_id, file_path], |row| row.get(0)) {
        Ok(hash) => Ok(Some(hash)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(FreshnessError::Sqlite(e)),
    }
}

fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hex::encode(hasher.finalize())
}

fn path_to_forward_slashes(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}
