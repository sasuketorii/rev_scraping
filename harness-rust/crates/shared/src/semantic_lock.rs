//! Cross-binary file lock for managed semantic.db.
//!
//! The semantic MCP server holds this lock while it serves a managed database.
//! GC probes the same lock before deleting a database unit.

use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};

use fs2::FileExt;

use crate::error::AgentError;

pub struct SemanticDbLock {
    _file: File,
    path: PathBuf,
}

impl SemanticDbLock {
    /// Return the lock file path for a managed semantic database.
    pub fn lock_path(db_path: &Path) -> PathBuf {
        let mut path = db_path.to_path_buf();
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("semantic.db");
        path.set_file_name(format!("{name}.harness-lock"));
        path
    }

    /// Try to acquire the advisory lock for `db_path`.
    pub fn try_acquire(db_path: &Path) -> Result<Self, AgentError> {
        let lock_path = Self::lock_path(db_path);
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .open(&lock_path)
            .map_err(|e| AgentError::Lock(format!("open lock {}: {e}", lock_path.display())))?;
        file.try_lock_exclusive()
            .map_err(|e| AgentError::Lock(format!("lock {}: {e}", lock_path.display())))?;
        Ok(Self {
            _file: file,
            path: lock_path,
        })
    }

    /// Return true when a fresh lock probe cannot acquire `db_path`.
    pub fn is_active(db_path: &Path) -> bool {
        Self::try_acquire(db_path).is_err()
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for SemanticDbLock {
    fn drop(&mut self) {
        // Closing the file releases the OS advisory lock. Keep the lock file
        // for the next acquisition attempt.
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lock_path_appends_harness_lock_suffix() {
        let db_path = Path::new("/tmp/project/semantic.db");
        assert_eq!(
            SemanticDbLock::lock_path(db_path),
            PathBuf::from("/tmp/project/semantic.db.harness-lock")
        );
    }

    #[test]
    fn try_acquire_succeeds_when_unlocked() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let db_path = tmp.path().join("semantic.db");
        let lock = SemanticDbLock::try_acquire(&db_path).expect("acquire lock");
        assert_eq!(lock.path(), SemanticDbLock::lock_path(&db_path));
    }

    #[test]
    fn try_acquire_fails_when_held_by_other_handle() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let db_path = tmp.path().join("semantic.db");
        let _held = SemanticDbLock::try_acquire(&db_path).expect("acquire first lock");
        assert!(SemanticDbLock::try_acquire(&db_path).is_err());
    }

    #[test]
    fn is_active_returns_false_when_unlocked() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let db_path = tmp.path().join("semantic.db");
        assert!(!SemanticDbLock::is_active(&db_path));
    }

    #[test]
    fn is_active_returns_true_when_held() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let db_path = tmp.path().join("semantic.db");
        let _held = SemanticDbLock::try_acquire(&db_path).expect("acquire first lock");
        assert!(SemanticDbLock::is_active(&db_path));
    }

    #[test]
    fn release_on_drop_allows_reacquire() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let db_path = tmp.path().join("semantic.db");
        {
            let _held = SemanticDbLock::try_acquire(&db_path).expect("acquire first lock");
        }
        assert!(SemanticDbLock::try_acquire(&db_path).is_ok());
    }
}
