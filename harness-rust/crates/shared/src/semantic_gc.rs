//! Garbage collection for managed semantic MCP databases.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Connection;
use serde::Serialize;
use tracing::warn;

use crate::semantic_lock::SemanticDbLock;

#[derive(Debug, Clone, Serialize)]
pub struct GcCandidate {
    pub path: String,
    pub size_bytes: u64,
    pub last_accessed_unix_ms: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct GcOutput {
    pub schema_version: u32,
    pub scanned: usize,
    pub candidates: Vec<GcCandidate>,
    pub deleted: Vec<String>,
    pub skipped_active: Vec<GcCandidate>,
    pub tool_errors: Vec<String>,
    pub freed_bytes: u64,
    pub dry_run: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct GcOptions {
    pub older_than_days: u64,
    pub dry_run: bool,
    pub force: bool,
    pub ignore_active_lock: bool,
}

impl Default for GcOptions {
    fn default() -> Self {
        Self {
            older_than_days: 30,
            dry_run: true,
            force: false,
            ignore_active_lock: false,
        }
    }
}

pub fn run_gc(options: GcOptions) -> Result<GcOutput, String> {
    if options.older_than_days == 0 {
        return Err("sem.admin.gc failed: older_than_days must be >= 1".to_string());
    }

    let root = crate::paths::semantic_mcp_data_root()
        .map_err(|e| format!("sem.admin.gc failed: data root unavailable: {e}"))?;
    let version_root = root.join("v1");
    let now_ms = now_unix_ms()?;
    let ttl_ms = options
        .older_than_days
        .checked_mul(24)
        .and_then(|v| v.checked_mul(60))
        .and_then(|v| v.checked_mul(60))
        .and_then(|v| v.checked_mul(1000))
        .ok_or_else(|| "sem.admin.gc failed: older_than_days overflow".to_string())?
        as i64;

    let mut scanned = 0usize;
    let mut candidates = Vec::new();
    let mut deleted = Vec::new();
    let mut skipped_active = Vec::new();
    let mut tool_errors = Vec::new();
    let mut freed_bytes = 0u64;

    if !version_root.exists() {
        return Ok(GcOutput {
            schema_version: 1,
            scanned,
            candidates,
            deleted,
            skipped_active,
            tool_errors,
            freed_bytes,
            dry_run: options.dry_run,
        });
    }

    for entry in fs::read_dir(&version_root)
        .map_err(|e| format!("sem.admin.gc failed: scan {}: {e}", version_root.display()))?
    {
        let entry = entry.map_err(|e| format!("sem.admin.gc failed: read_dir entry: {e}"))?;
        let project_dir = entry.path();
        if !project_dir.is_dir() {
            continue;
        }
        let db_path = project_dir.join("semantic.db");
        if !db_path.exists() {
            continue;
        }
        scanned += 1;

        let last_accessed_unix_ms = read_last_accessed_unix_ms(&db_path)
            .unwrap_or_else(|| mtime_unix_ms(&project_dir).unwrap_or(0));
        let size_bytes = managed_db_size(&db_path);
        let candidate = GcCandidate {
            path: db_path.display().to_string(),
            size_bytes,
            last_accessed_unix_ms,
        };

        if SemanticDbLock::is_active(&db_path) {
            if !options.ignore_active_lock {
                skipped_active.push(candidate);
                continue;
            }
            warn!(
                path = %db_path.display(),
                "sem.admin.gc ignoring active semantic db lock"
            );
        }

        if now_ms - last_accessed_unix_ms < ttl_ms {
            continue;
        }

        if !options.dry_run && options.force {
            delete_managed_db_files(&db_path)?;
            freed_bytes = freed_bytes.saturating_add(size_bytes);
            deleted.push(candidate.path.clone());
            if let Err(e) = fs::remove_dir(&project_dir) {
                if e.kind() != std::io::ErrorKind::NotFound
                    && e.kind() != std::io::ErrorKind::DirectoryNotEmpty
                {
                    tool_errors.push(format!(
                        "sem.admin.gc warning: remove dir {}: {e}",
                        project_dir.display()
                    ));
                }
            }
        }

        candidates.push(candidate);
    }

    Ok(GcOutput {
        schema_version: 1,
        scanned,
        candidates,
        deleted,
        skipped_active,
        tool_errors,
        freed_bytes,
        dry_run: options.dry_run,
    })
}

pub fn delete_managed_db_files(db_path: &Path) -> Result<(), String> {
    for path in managed_db_file_paths(db_path) {
        if path.exists() {
            fs::remove_file(&path)
                .map_err(|e| format!("sem.admin.gc failed: delete {}: {e}", path.display()))?;
        }
    }
    Ok(())
}

pub fn managed_db_size(db_path: &Path) -> u64 {
    managed_db_file_paths(db_path)
        .into_iter()
        .filter_map(|path| fs::metadata(path).ok())
        .map(|meta| meta.len())
        .sum()
}

pub fn read_last_accessed_unix_ms(db_path: &Path) -> Option<i64> {
    let conn = Connection::open(db_path).ok()?;
    let seconds = conn
        .query_row(
            "SELECT value FROM _ts_meta WHERE key = 'last_accessed'",
            [],
            |row| row.get::<_, String>(0),
        )
        .ok()?
        .parse::<i64>()
        .ok()?;
    seconds.checked_mul(1000)
}

pub fn mtime_unix_ms(path: &Path) -> Option<i64> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_millis() as i64)
}

pub fn now_unix_ms() -> Result<i64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("system clock before UNIX_EPOCH: {e}"))
        .map(|duration| duration.as_millis() as i64)
}

fn managed_db_file_paths(db_path: &Path) -> Vec<PathBuf> {
    vec![
        db_path.to_path_buf(),
        PathBuf::from(format!("{}-wal", db_path.as_os_str().to_string_lossy())),
        PathBuf::from(format!("{}-shm", db_path.as_os_str().to_string_lossy())),
        SemanticDbLock::lock_path(db_path),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;
    use std::sync::{Mutex, OnceLock};

    fn env_mutex() -> &'static Mutex<()> {
        static ENV_MUTEX: OnceLock<Mutex<()>> = OnceLock::new();
        ENV_MUTEX.get_or_init(|| Mutex::new(()))
    }

    fn with_temp_semantic_home<T>(test: impl FnOnce(&Path) -> T) -> T {
        let _guard = env_mutex().lock().expect("env mutex");
        let tmp = tempfile::tempdir().expect("tempdir");
        std::env::set_var("REVHARNESS_TEST_HARNESS", "1");
        std::env::set_var("SEMANTIC_MCP_HOME", tmp.path());
        let result = test(tmp.path());
        std::env::remove_var("REVHARNESS_TEST_HARNESS");
        std::env::remove_var("SEMANTIC_MCP_HOME");
        result
    }

    fn seed_db(project_id: &str, last_accessed_seconds: i64) -> PathBuf {
        let db_path = crate::paths::semantic_mcp_db_path(project_id).expect("db path");
        fs::create_dir_all(db_path.parent().expect("db parent")).expect("create db parent");
        let conn = Connection::open(&db_path).expect("open sqlite db");
        conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS _ts_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            ",
        )
        .expect("create metadata table");
        conn.execute(
            "INSERT OR REPLACE INTO _ts_meta(key, value) VALUES('last_accessed', ?1)",
            params![last_accessed_seconds.to_string()],
        )
        .expect("seed last_accessed");
        db_path
    }

    fn old_access_seconds() -> i64 {
        (now_unix_ms().expect("now") / 1000) - (40 * 24 * 60 * 60)
    }

    #[test]
    fn run_gc_rejects_older_than_days_zero() {
        let err = run_gc(GcOptions {
            older_than_days: 0,
            ..GcOptions::default()
        })
        .expect_err("older_than_days=0 must fail");
        assert!(err.contains("older_than_days must be >= 1"));
    }

    #[test]
    fn run_gc_dry_run_does_not_delete() {
        with_temp_semantic_home(|_| {
            let db_path = seed_db("dry_run_project", old_access_seconds());
            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: true,
                force: false,
                ignore_active_lock: false,
            })
            .expect("run gc");
            assert_eq!(output.candidates.len(), 1);
            assert!(output.deleted.is_empty());
            assert!(db_path.exists());
        });
    }

    #[test]
    fn run_gc_force_deletes_db_wal_shm_lock_unit() {
        with_temp_semantic_home(|_| {
            let db_path = seed_db("force_project", old_access_seconds());
            let wal_path = PathBuf::from(format!("{}-wal", db_path.as_os_str().to_string_lossy()));
            let shm_path = PathBuf::from(format!("{}-shm", db_path.as_os_str().to_string_lossy()));
            let lock_path = SemanticDbLock::lock_path(&db_path);
            fs::write(&wal_path, b"wal").expect("write wal");
            fs::write(&shm_path, b"shm").expect("write shm");
            fs::write(&lock_path, b"lock").expect("write lock");

            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: false,
                force: true,
                ignore_active_lock: false,
            })
            .expect("run gc");

            assert_eq!(output.deleted.len(), 1);
            assert!(!db_path.exists());
            assert!(!wal_path.exists());
            assert!(!shm_path.exists());
            assert!(!lock_path.exists());
        });
    }

    #[test]
    fn run_gc_skips_active_locked_db_by_default() {
        with_temp_semantic_home(|_| {
            let db_path = seed_db("locked_project", old_access_seconds());
            let _lock = SemanticDbLock::try_acquire(&db_path).expect("acquire active lock");

            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: false,
                force: true,
                ignore_active_lock: false,
            })
            .expect("run gc");

            assert_eq!(output.skipped_active.len(), 1);
            assert!(output.candidates.is_empty());
            assert!(output.deleted.is_empty());
            assert!(db_path.exists());
        });
    }

    #[test]
    fn run_gc_includes_active_with_ignore_active_lock_flag() {
        with_temp_semantic_home(|_| {
            let db_path = seed_db("ignored_lock_project", old_access_seconds());
            let _lock = SemanticDbLock::try_acquire(&db_path).expect("acquire active lock");

            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: true,
                force: false,
                ignore_active_lock: true,
            })
            .expect("run gc");

            assert_eq!(output.candidates.len(), 1);
            assert!(output.skipped_active.is_empty());
            assert_eq!(output.candidates[0].path, db_path.display().to_string());
        });
    }

    #[test]
    fn run_gc_output_has_schema_version_1() {
        with_temp_semantic_home(|_| {
            let output = run_gc(GcOptions::default()).expect("run gc");
            assert_eq!(output.schema_version, 1);
        });
    }
}
