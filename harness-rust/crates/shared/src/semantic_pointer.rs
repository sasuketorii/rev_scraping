//! Project-local pointer file for the externally-placed semantic database.
//!
//! The semantic database lives outside the project tree (platform data dir).
//! To make that external location human-discoverable from inside the project
//! and to let dispose-together tooling (uninstall / orphan-GC) resolve the
//! exact on-disk directory, the server lazily drops a small JSON pointer at
//! `<project_root>/.rev_harness/semantic-db.json` on open.
//!
//! The pointer is intentionally minimal: it records only the `project_id`,
//! the absolute `db_path`, and a `created_at` timestamp. It MUST NOT contain
//! anything sensitive. It is gitignored so it is never committed.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Directory (relative to the project root) that holds the pointer file.
pub const POINTER_DIR: &str = ".rev_harness";
/// File name of the semantic-db pointer.
pub const POINTER_FILE: &str = "semantic-db.json";

/// On-disk shape of the pointer file.
///
/// Field order is fixed so the serialized JSON is stable; the set of fields is
/// deliberately closed — only `project_id`, `db_path`, `created_at`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SemanticDbPointer {
    pub project_id: String,
    pub db_path: String,
    pub created_at: String,
}

/// Return `<project_root>/.rev_harness/semantic-db.json`.
pub fn pointer_path(project_root: &Path) -> PathBuf {
    project_root.join(POINTER_DIR).join(POINTER_FILE)
}

/// Lazily write the pointer file if it does not already exist.
///
/// - If a pointer already exists at the target path, it is left untouched
///   (never overwritten), so a stable `created_at` is preserved.
/// - Failures are non-fatal to the caller's main flow: this returns a
///   `Result` so the caller can log, but the server must treat a write error
///   as advisory (the pointer is a convenience, not a correctness anchor).
pub fn write_pointer_if_absent(
    project_root: &Path,
    project_id: &str,
    db_path: &Path,
) -> Result<bool, String> {
    let target = pointer_path(project_root);
    if target.exists() {
        return Ok(false);
    }

    let dir = target
        .parent()
        .ok_or_else(|| format!("pointer path has no parent: {}", target.display()))?;
    fs::create_dir_all(dir)
        .map_err(|e| format!("failed to create pointer dir {}: {e}", dir.display()))?;

    let pointer = SemanticDbPointer {
        project_id: project_id.to_string(),
        db_path: db_path.display().to_string(),
        created_at: chrono::Utc::now().to_rfc3339(),
    };
    let body = serde_json::to_string_pretty(&pointer)
        .map_err(|e| format!("failed to serialize pointer: {e}"))?;

    // Atomic publish via temp + rename so a concurrent reader never sees a
    // partial file, and a lost race simply leaves the first writer's pointer.
    let tmp = dir.join(format!("{POINTER_FILE}.{}.tmp", std::process::id()));
    fs::write(&tmp, body.as_bytes())
        .map_err(|e| format!("failed to write pointer tmp {}: {e}", tmp.display()))?;
    match fs::rename(&tmp, &target) {
        Ok(()) => Ok(true),
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            // If another process won the race, the file now exists: not an error.
            if target.exists() {
                Ok(false)
            } else {
                Err(format!(
                    "failed to publish pointer {}: {e}",
                    target.display()
                ))
            }
        }
    }
}

/// Read and parse the pointer file at `<project_root>/.rev_harness/semantic-db.json`.
pub fn read_pointer(project_root: &Path) -> Option<SemanticDbPointer> {
    let target = pointer_path(project_root);
    let body = fs::read_to_string(target).ok()?;
    serde_json::from_str(&body).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_pointer_when_absent_with_exact_fields() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path();
        let db_path = Path::new("/some/external/v1/proj-abc/semantic.db");

        let wrote = write_pointer_if_absent(root, "proj-abc", db_path).expect("write pointer");
        assert!(wrote, "first write should create the pointer");

        let target = pointer_path(root);
        assert!(target.exists());

        // Parse as a generic JSON object to assert NO extra fields exist.
        let raw = fs::read_to_string(&target).expect("read pointer");
        let value: serde_json::Value = serde_json::from_str(&raw).expect("parse json");
        let obj = value.as_object().expect("pointer is an object");
        let mut keys: Vec<&String> = obj.keys().collect();
        keys.sort();
        assert_eq!(
            keys,
            vec![
                &"created_at".to_string(),
                &"db_path".to_string(),
                &"project_id".to_string()
            ],
            "pointer must contain exactly project_id, db_path, created_at"
        );
        assert_eq!(obj["project_id"], "proj-abc");
        assert_eq!(obj["db_path"], db_path.display().to_string());
        assert!(obj["created_at"].as_str().is_some());
    }

    #[test]
    fn does_not_overwrite_existing_pointer() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path();
        let db_path = Path::new("/some/external/v1/proj-abc/semantic.db");

        assert!(write_pointer_if_absent(root, "proj-abc", db_path).expect("first write"));
        let first = read_pointer(root).expect("first pointer");

        // Second call with a DIFFERENT db_path must be a no-op.
        let other = Path::new("/some/external/v1/proj-abc/MOVED.db");
        let wrote = write_pointer_if_absent(root, "proj-abc", other).expect("second write");
        assert!(!wrote, "existing pointer must not be overwritten");

        let second = read_pointer(root).expect("second pointer");
        assert_eq!(first, second, "pointer content must be unchanged");
        assert_eq!(second.db_path, db_path.display().to_string());
    }
}
