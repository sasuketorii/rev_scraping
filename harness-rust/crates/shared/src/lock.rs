//! File-based locking with metadata persistence.
//!
//! Provides an RAII [`FileLock`] guard that uses `mkdir` semantics for
//! atomic lock acquisition (matching the shell implementation in
//! `lib/utils.sh`), plus JSON metadata written alongside the lock
//! directory for observability and stale-lock detection.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use chrono::Utc;
use uuid::Uuid;

use crate::error::{AgentError, Result};
use crate::types::LockMetadata;

/// An RAII lock guard that releases the lock on drop.
///
/// The lock is represented as a directory on the filesystem.
/// A `metadata.json` file inside the directory stores diagnostic
/// information about the holder.
#[derive(Debug)]
pub struct FileLock {
    /// Path to the lock directory.
    path: PathBuf,
}

impl FileLock {
    /// Attempt to acquire a lock at `lock_path` within `timeout_secs`.
    ///
    /// On success a `metadata.json` file is written inside the lock
    /// directory.  Returns [`AgentError::Lock`] on timeout.
    pub fn acquire(lock_path: &Path, timeout_secs: u64) -> Result<Self> {
        let deadline = Instant::now() + Duration::from_secs(timeout_secs);
        loop {
            match std::fs::create_dir(lock_path) {
                Ok(()) => {
                    let guard = Self {
                        path: lock_path.to_path_buf(),
                    };
                    // Best-effort metadata write — lock is already held.
                    let now = Utc::now().to_rfc3339();
                    let meta = LockMetadata {
                        token: Uuid::new_v4().to_string(),
                        pid: std::process::id(),
                        created_at: now.clone(),
                        updated_at: now,
                        owner: std::env::var("USER")
                            .or_else(|_| std::env::var("LOGNAME"))
                            .unwrap_or_else(|_| "unknown".to_string()),
                        host: hostname(),
                        state_file: None,
                    };
                    let _ = Self::write_metadata_inner(lock_path, &meta);
                    return Ok(guard);
                }
                Err(e)
                    if e.kind() == std::io::ErrorKind::AlreadyExists
                        && Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(100));
                }
                Err(e) => {
                    return Err(AgentError::Lock(format!(
                        "failed to acquire lock at {}: {e}",
                        lock_path.display()
                    )));
                }
            }
        }
    }

    /// Release the lock explicitly.  Also called automatically on drop.
    pub fn release(self) -> Result<()> {
        // Drop impl handles cleanup; consume self to trigger it.
        Ok(())
    }

    /// Check whether a lock at `lock_path` is stale (older than
    /// `threshold_secs` seconds based on filesystem mtime).
    pub fn is_stale(lock_path: &Path, threshold_secs: u64) -> bool {
        let Ok(meta) = std::fs::metadata(lock_path) else {
            return false;
        };
        let Ok(modified) = meta.modified() else {
            return false;
        };
        let elapsed = SystemTime::now()
            .duration_since(modified)
            .unwrap_or(Duration::ZERO);
        elapsed.as_secs() > threshold_secs
    }

    /// Write lock metadata to `<lock_path>/metadata.json`.
    pub fn write_metadata(lock_path: &Path, metadata: &LockMetadata) -> Result<()> {
        Self::write_metadata_inner(lock_path, metadata)
    }

    /// Read lock metadata from `<lock_path>/metadata.json`.
    pub fn read_metadata(lock_path: &Path) -> Result<LockMetadata> {
        let meta_path = lock_path.join("metadata.json");
        let data = std::fs::read_to_string(&meta_path).map_err(|e| {
            AgentError::Lock(format!(
                "cannot read lock metadata at {}: {e}",
                meta_path.display()
            ))
        })?;
        serde_json::from_str(&data).map_err(|e| {
            AgentError::Lock(format!(
                "invalid lock metadata at {}: {e}",
                meta_path.display()
            ))
        })
    }

    // -- internal helpers --

    fn write_metadata_inner(lock_path: &Path, metadata: &LockMetadata) -> Result<()> {
        let meta_path = lock_path.join("metadata.json");
        let json = serde_json::to_string_pretty(metadata)?;
        std::fs::write(&meta_path, json).map_err(|e| {
            AgentError::Lock(format!(
                "cannot write lock metadata at {}: {e}",
                meta_path.display()
            ))
        })
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        // Remove metadata file first, then the directory.
        let meta_path = self.path.join("metadata.json");
        if let Err(e) = std::fs::remove_file(&meta_path) {
            if e.kind() != std::io::ErrorKind::NotFound {
                tracing::warn!(
                    "Failed to remove lock metadata at {}: {e}",
                    meta_path.display()
                );
            }
        }
        if let Err(e) = std::fs::remove_dir(&self.path) {
            if e.kind() != std::io::ErrorKind::NotFound {
                tracing::warn!(
                    "Failed to remove lock directory at {}: {e}",
                    self.path.display()
                );
            }
        }
    }
}

/// Best-effort hostname retrieval.
fn hostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("HOST"))
        .unwrap_or_else(|_| "unknown".to_string())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn acquire_and_release() {
        let tmp = TempDir::new().expect("tempdir");
        let lock_path = tmp.path().join("test.lock");
        let guard = FileLock::acquire(&lock_path, 5).expect("acquire");
        assert!(lock_path.exists());
        guard.release().expect("release");
        assert!(!lock_path.exists());
    }

    #[test]
    fn metadata_roundtrip() {
        let tmp = TempDir::new().expect("tempdir");
        let lock_path = tmp.path().join("meta.lock");
        let guard = FileLock::acquire(&lock_path, 5).expect("acquire");
        let meta = FileLock::read_metadata(&lock_path).expect("read");
        assert_eq!(meta.pid, std::process::id());
        drop(guard);
    }

    #[test]
    fn is_stale_returns_false_for_fresh() {
        let tmp = TempDir::new().expect("tempdir");
        let lock_path = tmp.path().join("fresh.lock");
        let _guard = FileLock::acquire(&lock_path, 5).expect("acquire");
        assert!(!FileLock::is_stale(&lock_path, 3600));
    }

    #[test]
    fn is_stale_returns_false_for_nonexistent() {
        let tmp = TempDir::new().expect("tempdir");
        let lock_path = tmp.path().join("nonexistent.lock");
        assert!(!FileLock::is_stale(&lock_path, 60));
    }
}
