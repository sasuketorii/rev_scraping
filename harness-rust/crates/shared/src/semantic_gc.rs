//! Garbage collection for managed semantic MCP databases.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Connection;
use serde::Serialize;
use tracing::warn;

use crate::semantic_lock::SemanticDbLock;

/// RevHarness SQLite `application_id` marker ("RSEM").
///
/// Mirrors `semantic_mcp::db::REVHARNESS_APP_ID`. Duplicated here (rather than
/// depended-on) because `shared` is the foundation crate and must not depend on
/// `semantic-mcp`. The destructive orphan-GC validates this marker FIRST and
/// refuses to touch any DB that is not RSEM-stamped, so a foreign SQLite file
/// that happens to live under the data root can never be deleted.
pub const REVHARNESS_APP_ID: i64 = 0x5253_454D;

/// GC selection strategy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GcMode {
    /// Default: delete managed DBs whose `last_accessed` is older than the TTL.
    Ttl,
    /// Destructive dispose-together: delete managed DBs whose recorded
    /// `projects.root_path` no longer exists on disk (the project was deleted).
    /// A DB with a blank/NULL/no-row `root_path` falls back to TTL semantics and
    /// is NEVER treated as an orphan, so an un-backfilled DB is never wrongly
    /// deleted.
    OrphansMissingRoot,
}

impl Default for GcMode {
    fn default() -> Self {
        GcMode::Ttl
    }
}

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

#[derive(Debug, Clone)]
pub struct GcOptions {
    pub older_than_days: u64,
    pub dry_run: bool,
    pub force: bool,
    pub ignore_active_lock: bool,
    pub mode: GcMode,
    /// When `Some(project_id)`, GC only ever *considers* the managed DB whose
    /// project directory name equals `project_id`. Every other managed DB under
    /// the data root is skipped entirely — it is never scanned, never reported,
    /// and (critically) never deleted. This scoping is applied BEFORE any
    /// mutation so the default (current-project-only) path can never delete a DB
    /// outside the current project. `None` means scan all projects.
    pub only_project_id: Option<String>,
}

impl Default for GcOptions {
    fn default() -> Self {
        Self {
            older_than_days: 30,
            dry_run: true,
            force: false,
            ignore_active_lock: false,
            mode: GcMode::Ttl,
            only_project_id: None,
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
        // Current-project scoping (applied BEFORE any deletion). When
        // `only_project_id` is set, every other project's directory is skipped
        // outright so a non-`--all-projects` run can never even consider, let
        // alone delete, a DB outside the current project.
        if let Some(ref only) = options.only_project_id {
            let dir_name = project_dir
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or_default();
            if dir_name != only.as_str() {
                continue;
            }
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

        // Decide eligibility BEFORE the active-lock check so that an active
        // lock can never be the thing that promotes a non-eligible DB.
        let eligible = match options.mode {
            GcMode::Ttl => now_ms - last_accessed_unix_ms >= ttl_ms,
            GcMode::OrphansMissingRoot => match classify_orphan(&db_path) {
                OrphanClass::Orphan => true,
                // Foreign (non-RSEM), root present, or root unknown/blank: never
                // an orphan. Fall back to TTL so a stale-but-rooted DB can still
                // be aged out, and a foreign/unknown DB is left strictly alone.
                OrphanClass::Foreign => false,
                OrphanClass::RootPresent => false,
                OrphanClass::RootUnknown => now_ms - last_accessed_unix_ms >= ttl_ms,
            },
        };

        if !eligible {
            continue;
        }

        // Positive-managed-proof guard (BLOCKER-2 fix). Before ANY deletion we
        // require POSITIVE proof that this is a RevHarness-managed DB — RSEM
        // application_id OR a legacy app_id-0 DB carrying the full RevHarness
        // schema. A DB that is merely "not nonzero-foreign" no longer qualifies:
        // a plain foreign SQLite (app_id 0, no RevHarness schema) is `is_foreign_db`
        // and is skipped here. In orphan mode `classify_orphan` already required
        // the same positive proof, so this guard also covers the TTL delete path.
        if !options.dry_run && options.force && is_foreign_db(&db_path) {
            tool_errors.push(format!(
                "sem.admin.gc warning: refusing to delete DB lacking positive RevHarness identification (foreign) {}",
                db_path.display()
            ));
            continue;
        }

        // Active-lock guard. An active advisory lock means a live server holds
        // this DB; it must NEVER be deleted. This skip is UNCONDITIONAL on the
        // destructive (delete) path: `ignore_active_lock` can never bypass it,
        // so a force + ignore_active_lock invocation can still not delete a
        // live, locked DB. `ignore_active_lock` only relaxes the *non*-
        // destructive (dry-run) preview so an operator can still SEE an
        // active-locked candidate when scanning.
        let active_locked = SemanticDbLock::is_active(&db_path);
        if active_locked {
            let destructive = !options.dry_run && options.force;
            if destructive || !options.ignore_active_lock {
                // Destructive run, or default preview: report as skipped and
                // never reach the delete path.
                skipped_active.push(candidate);
                continue;
            }
            // Non-destructive preview with ignore_active_lock: surface the
            // candidate but it is structurally impossible to delete here
            // because the delete path below requires `!dry_run && force`.
            warn!(
                path = %db_path.display(),
                "sem.admin.gc surfacing active-locked candidate in dry-run preview (ignore_active_lock)"
            );
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

/// Result of classifying a candidate DB for orphan (missing-root) GC.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OrphanClass {
    /// Positively-identified managed DB whose recorded root_path is non-empty
    /// and does NOT exist on disk → genuine orphan, safe to delete under opt-in.
    Orphan,
    /// Not a positively-identified managed DB (foreign SQLite, app_id-0 without
    /// the RevHarness schema, or unreadable) → never touch.
    Foreign,
    /// Managed DB whose recorded root_path exists on disk → live, keep.
    RootPresent,
    /// Managed DB with no usable root_path (NULL/blank/no row/no table) →
    /// unknown, fall back to TTL, never treat as orphan.
    RootUnknown,
}

/// Tables that positively identify a RevHarness-managed semantic DB.
///
/// This mirrors the required-table set in
/// `semantic_mcp::db::validate_revharness_schema`. Duplicated here (rather than
/// depended-on) because `shared` is the foundation crate and must not depend on
/// `semantic-mcp` — the same reason `REVHARNESS_APP_ID` is duplicated above. It
/// is the on-disk signature used to recognize a LEGACY managed DB that was
/// created before the RSEM `application_id` stamp was applied (app_id still 0).
///
/// A foreign SQLite file with `application_id == 0` will not carry this full set
/// of tables, so it is correctly classified as foreign and never deleted.
const REVHARNESS_MANAGED_TABLES: &[&str] = &[
    "projects",
    "components",
    "components_fts",
    "_ts_meta",
    "capsules",
    "symbols",
    "symbol_dependencies",
    "file_parse_cache",
];

/// Read the SQLite `application_id` of a DB file without mutating it.
///
/// Returns `None` if the file cannot be opened or the pragma cannot be read.
fn read_application_id(db_path: &Path) -> Option<i64> {
    // Open read-only so we never create or migrate a foreign file. A failure to
    // open read-only (e.g. file missing) yields None → treated as Foreign.
    let conn = Connection::open_with_flags(
        db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    conn.query_row("PRAGMA application_id", [], |row| row.get::<_, i64>(0))
        .ok()
}

/// Fail closed unless `db_path` is an existing RSEM-stamped RevHarness DB.
///
/// Use this before non-server mutation paths that open the managed
/// `semantic.db` directly. It intentionally does not adopt legacy app_id-0 DBs:
/// adoption/stamping is owned by semantic-mcp startup, while background hooks
/// and CLI maintenance paths must not mutate an unmarked or foreign database.
pub fn assert_rsem_managed_db(db_path: &Path, operation: &str) -> crate::error::Result<()> {
    if !db_path.exists() {
        return Err(crate::error::AgentError::Validation(format!(
            "refusing {operation}: semantic.db does not exist at managed path; start semantic-mcp or run a managed bootstrap first"
        )));
    }

    match read_application_id(db_path) {
        Some(REVHARNESS_APP_ID) => Ok(()),
        Some(app_id) => Err(crate::error::AgentError::Validation(format!(
            "refusing {operation}: semantic.db is not RevHarness-managed (application_id={app_id:#x}, expected {REVHARNESS_APP_ID:#x})"
        ))),
        None => Err(crate::error::AgentError::Validation(format!(
            "refusing {operation}: semantic.db application_id could not be read"
        ))),
    }
}

/// True only when `db_path` carries the full RevHarness managed-table set.
///
/// Used to positively recognize a legacy managed DB whose `application_id` is
/// still 0 (created before the RSEM stamp). A read-only failure or any missing
/// table yields `false`, so a foreign app_id-0 SQLite is never mistaken for a
/// managed DB.
fn has_revharness_schema(db_path: &Path) -> bool {
    let Ok(conn) = Connection::open_with_flags(
        db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) else {
        return false;
    };
    for table in REVHARNESS_MANAGED_TABLES {
        let exists: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('table','view') AND name=?1",
                rusqlite::params![table],
                |row| row.get(0),
            )
            .unwrap_or(0);
        if exists == 0 {
            return false;
        }
    }
    true
}

/// POSITIVE proof that `db_path` is a RevHarness-managed DB.
///
/// This is the single managed-DB predicate that gates EVERY deletion (both the
/// TTL age-based path and the orphan path). A DB qualifies only when it is
/// positively identified, never merely because it is "not nonzero-foreign":
///
///   * RSEM `application_id` (0x5253454D), OR
///   * legacy `application_id == 0` WITH the full RevHarness managed-table set.
///
/// A DB that is app_id 0 AND lacks the RevHarness schema is FOREIGN and is never
/// eligible for deletion. This is the BLOCKER-2 fix: previously app_id 0 was
/// treated as "maybe managed" by default, so a plain foreign SQLite (app_id 0,
/// no schema, old mtime) could be deleted by TTL GC.
fn is_managed_revharness_db(db_path: &Path) -> bool {
    match read_application_id(db_path) {
        Some(REVHARNESS_APP_ID) => true,
        // Legacy: unstamped DB is managed ONLY with positive schema proof.
        Some(0) => has_revharness_schema(db_path),
        // Nonzero non-RSEM id, or unreadable file → foreign.
        _ => false,
    }
}

/// True when `db_path` is NOT a positively-identified RevHarness-managed DB.
///
/// This is the deletion-blocking predicate: any DB that lacks positive managed
/// proof (a plain foreign SQLite, including the app_id-0-no-schema case, or an
/// unreadable file) is "foreign" and must never be deleted. Inverse of
/// `is_managed_revharness_db`.
fn is_foreign_db(db_path: &Path) -> bool {
    !is_managed_revharness_db(db_path)
}

/// Classify a candidate DB for orphan GC. Positive managed-DB proof happens
/// FIRST — a DB that is not positively identified (foreign, incl. app_id-0
/// without the RevHarness schema) is `Foreign` and never an orphan.
fn classify_orphan(db_path: &Path) -> OrphanClass {
    if !is_managed_revharness_db(db_path) {
        return OrphanClass::Foreign;
    }
    match read_project_root_path(db_path) {
        Some(root) if !root.trim().is_empty() => {
            if Path::new(root.trim()).exists() {
                OrphanClass::RootPresent
            } else {
                OrphanClass::Orphan
            }
        }
        // No row, NULL, blank, or missing projects table → unknown.
        _ => OrphanClass::RootUnknown,
    }
}

/// Read `projects.root_path` from a managed DB (single-project DB).
///
/// Returns `None` if the table/row is absent or the value is NULL. A blank
/// string is returned verbatim so the caller can treat it as unknown.
fn read_project_root_path(db_path: &Path) -> Option<String> {
    let conn = Connection::open_with_flags(
        db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    conn.query_row(
        "SELECT root_path FROM projects WHERE root_path IS NOT NULL LIMIT 1",
        [],
        |row| row.get::<_, String>(0),
    )
    .ok()
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
    use crate::test_env::EnvGuard;
    use rusqlite::params;

    /// Run `test` with `SEMANTIC_MCP_HOME` pointed at a fresh, test-owned
    /// `TempDir` while holding the crate-wide env lock for the full duration.
    ///
    /// The `TempDir` is owned here and only its path is exposed to env, so the
    /// gc body always resolves a guaranteed-writable directory and can never be
    /// redirected onto a real platform path by a concurrent env-mutating test.
    /// The [`EnvGuard`] serializes against every other env-mutating test in the
    /// crate (including `paths`) and restores prior env on drop, so a panic
    /// here cannot leak state into — or poison — a sibling test.
    fn with_temp_semantic_home<T>(test: impl FnOnce(&Path) -> T) -> T {
        let guard = EnvGuard::acquire();
        let tmp = tempfile::tempdir().expect("tempdir");
        guard.set_test_harness_home(tmp.path());
        test(tmp.path())
    }

    /// SQL that creates the full RevHarness managed-table set recognized by
    /// `has_revharness_schema`. Mirrors the legacy managed-DB on-disk signature.
    const MANAGED_SCHEMA_SQL: &str = "
        CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, root_path TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS components (id INTEGER PRIMARY KEY);
        CREATE VIRTUAL TABLE IF NOT EXISTS components_fts USING fts5(name);
        CREATE TABLE IF NOT EXISTS _ts_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS capsules (id INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS symbols (id INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS symbol_dependencies (id INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS file_parse_cache (id INTEGER PRIMARY KEY);
    ";

    /// Seed a LEGACY managed DB: `application_id` still 0 (pre-RSEM stamp) but
    /// carrying the full RevHarness schema. This is the realistic legacy-v1 DB
    /// that the TTL/orphan delete paths must keep treating as managed.
    fn seed_db(project_id: &str, last_accessed_seconds: i64) -> PathBuf {
        let db_path = crate::paths::semantic_mcp_db_path(project_id).expect("db path");
        fs::create_dir_all(db_path.parent().expect("db parent")).expect("create db parent");
        let conn = Connection::open(&db_path).expect("open sqlite db");
        conn.execute_batch(MANAGED_SCHEMA_SQL)
            .expect("create managed schema");
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

    /// Recent access so TTL alone would NOT make a DB eligible. Orphan-mode
    /// eligibility must then come exclusively from the missing root_path.
    fn recent_access_seconds() -> i64 {
        now_unix_ms().expect("now") / 1000
    }

    /// Seed a managed RSEM-stamped DB carrying a `projects.root_path`.
    fn seed_rsem_db(project_id: &str, root_path: &Path, last_accessed_seconds: i64) -> PathBuf {
        let db_path = crate::paths::semantic_mcp_db_path(project_id).expect("db path");
        fs::create_dir_all(db_path.parent().expect("db parent")).expect("create db parent");
        let conn = Connection::open(&db_path).expect("open sqlite db");
        conn.execute_batch(&format!(
            "PRAGMA application_id = {REVHARNESS_APP_ID};
             CREATE TABLE IF NOT EXISTS _ts_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS projects (
                 id TEXT PRIMARY KEY,
                 name TEXT NOT NULL,
                 root_path TEXT NOT NULL,
                 created_at TEXT NOT NULL DEFAULT (datetime('now')),
                 updated_at TEXT NOT NULL DEFAULT (datetime('now'))
             );"
        ))
        .expect("seed rsem schema");
        conn.execute(
            "INSERT OR REPLACE INTO _ts_meta(key, value) VALUES('last_accessed', ?1)",
            params![last_accessed_seconds.to_string()],
        )
        .expect("seed last_accessed");
        conn.execute(
            "INSERT OR REPLACE INTO projects(id, name, root_path) VALUES(?1, ?1, ?2)",
            params![project_id, root_path.display().to_string()],
        )
        .expect("seed projects row");
        db_path
    }

    /// Seed an RSEM-stamped DB whose `projects.root_path` is blank.
    fn seed_rsem_db_blank_root(project_id: &str, last_accessed_seconds: i64) -> PathBuf {
        seed_rsem_db(project_id, Path::new(""), last_accessed_seconds)
    }

    /// Seed a FOREIGN SQLite DB (non-RSEM application_id) at the managed path.
    fn seed_foreign_db(project_id: &str) -> PathBuf {
        let db_path = crate::paths::semantic_mcp_db_path(project_id).expect("db path");
        fs::create_dir_all(db_path.parent().expect("db parent")).expect("create db parent");
        let conn = Connection::open(&db_path).expect("open sqlite db");
        // Deliberately NOT 0 and NOT RSEM: a genuinely foreign managed app.
        conn.execute_batch(
            "PRAGMA application_id = 305419896;
             CREATE TABLE foreign_data(x INTEGER);
             INSERT INTO foreign_data(x) VALUES (1);",
        )
        .expect("seed foreign db");
        db_path
    }

    /// Seed a plain FOREIGN SQLite DB with `application_id == 0` and NO
    /// RevHarness schema — the exact reviewer BLOCKER-2 repro. This must be
    /// treated as foreign (never deleted) despite the unstamped app_id.
    ///
    /// `last_accessed_seconds` seeds a `_ts_meta` row so the file reads as OLD
    /// (TTL-eligible). This deliberately forces the deletion path to reach — and
    /// be blocked by — the positive-managed-proof guard, rather than passing only
    /// because a fresh mtime made it TTL-ineligible. Note: the presence of a
    /// `_ts_meta` table alone is NOT enough to be managed; the full managed-table
    /// set is required.
    fn seed_foreign_app_id_zero_db(project_id: &str, last_accessed_seconds: i64) -> PathBuf {
        let db_path = crate::paths::semantic_mcp_db_path(project_id).expect("db path");
        fs::create_dir_all(db_path.parent().expect("db parent")).expect("create db parent");
        let conn = Connection::open(&db_path).expect("open sqlite db");
        // application_id defaults to 0; only an unrelated table + a _ts_meta age
        // marker — none of the rest of the RevHarness managed-table set.
        conn.execute_batch(
            "CREATE TABLE some_unrelated(x INTEGER);
             INSERT INTO some_unrelated(x) VALUES (1);
             CREATE TABLE _ts_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        )
        .expect("seed foreign app_id-0 db");
        conn.execute(
            "INSERT OR REPLACE INTO _ts_meta(key, value) VALUES('last_accessed', ?1)",
            params![last_accessed_seconds.to_string()],
        )
        .expect("seed last_accessed");
        db_path
    }

    #[test]
    fn orphan_detected_when_root_path_missing() {
        with_temp_semantic_home(|_| {
            // root_path points at a path that does not exist on disk.
            let missing = std::env::temp_dir().join("revharness-orphan-missing-root-XYZ");
            let _ = fs::remove_dir_all(&missing);
            assert!(!missing.exists());
            let db_path = seed_rsem_db("orphan_proj", &missing, recent_access_seconds());

            let output = run_gc(GcOptions {
                mode: GcMode::OrphansMissingRoot,
                dry_run: true,
                ..GcOptions::default()
            })
            .expect("run gc");

            assert_eq!(output.candidates.len(), 1, "orphan must be detected");
            assert!(output.deleted.is_empty(), "dry-run deletes nothing");
            assert!(db_path.exists(), "dry-run leaves the DB in place");
        });
    }

    #[test]
    fn orphan_not_detected_when_root_path_exists() {
        with_temp_semantic_home(|_| {
            // root_path points at a path that DOES exist.
            let present = tempfile::tempdir().expect("present root");
            let db_path = seed_rsem_db("live_proj", present.path(), recent_access_seconds());

            let output = run_gc(GcOptions {
                mode: GcMode::OrphansMissingRoot,
                dry_run: false,
                force: true,
                ..GcOptions::default()
            })
            .expect("run gc");

            assert!(
                output.candidates.is_empty(),
                "live project is not an orphan"
            );
            assert!(output.deleted.is_empty());
            assert!(db_path.exists(), "live DB must never be deleted");
        });
    }

    #[test]
    fn orphan_apply_deletes_rsem_orphan() {
        with_temp_semantic_home(|_| {
            let missing = std::env::temp_dir().join("revharness-orphan-apply-XYZ");
            let _ = fs::remove_dir_all(&missing);
            let db_path = seed_rsem_db("apply_orphan", &missing, recent_access_seconds());

            let output = run_gc(GcOptions {
                mode: GcMode::OrphansMissingRoot,
                dry_run: false,
                force: true,
                ..GcOptions::default()
            })
            .expect("run gc");

            assert_eq!(output.deleted.len(), 1, "--apply must delete the orphan");
            assert!(!db_path.exists(), "orphan DB removed");
        });
    }

    #[test]
    fn orphan_apply_does_not_delete_foreign_db() {
        with_temp_semantic_home(|_| {
            let db_path = seed_foreign_db("foreign_proj");

            let output = run_gc(GcOptions {
                mode: GcMode::OrphansMissingRoot,
                dry_run: false,
                force: true,
                ..GcOptions::default()
            })
            .expect("run gc");

            assert!(
                output.candidates.is_empty(),
                "foreign DB is never a candidate"
            );
            assert!(output.deleted.is_empty());
            assert!(db_path.exists(), "foreign DB must never be deleted");
        });
    }

    #[test]
    fn orphan_apply_skips_active_locked_orphan() {
        with_temp_semantic_home(|_| {
            let missing = std::env::temp_dir().join("revharness-orphan-locked-XYZ");
            let _ = fs::remove_dir_all(&missing);
            let db_path = seed_rsem_db("locked_orphan", &missing, recent_access_seconds());
            let _lock = SemanticDbLock::try_acquire(&db_path).expect("hold active lock");

            let output = run_gc(GcOptions {
                mode: GcMode::OrphansMissingRoot,
                dry_run: false,
                force: true,
                ..GcOptions::default()
            })
            .expect("run gc");

            assert_eq!(output.skipped_active.len(), 1, "active orphan is skipped");
            assert!(output.deleted.is_empty());
            assert!(db_path.exists(), "active-locked orphan must not be deleted");
        });
    }

    #[test]
    fn orphan_apply_never_deletes_active_locked_even_with_ignore_active_lock() {
        // BLOCKER #1 regression: force + ignore_active_lock MUST NOT delete a
        // live (active-locked) orphan. The active-lock skip is unconditional on
        // the destructive path; ignore_active_lock can never reach delete.
        with_temp_semantic_home(|_| {
            let missing = std::env::temp_dir().join("revharness-orphan-locked-ignore-XYZ");
            let _ = fs::remove_dir_all(&missing);
            let db_path = seed_rsem_db("locked_ignore_orphan", &missing, recent_access_seconds());
            let _lock = SemanticDbLock::try_acquire(&db_path).expect("hold active lock");

            let output = run_gc(GcOptions {
                mode: GcMode::OrphansMissingRoot,
                dry_run: false,
                force: true,
                ignore_active_lock: true, // explicitly try to bypass
                ..GcOptions::default()
            })
            .expect("run gc");

            assert_eq!(
                output.skipped_active.len(),
                1,
                "active-locked orphan must be skipped even with ignore_active_lock"
            );
            assert!(
                output.deleted.is_empty(),
                "ignore_active_lock must never reach a delete on an active DB"
            );
            assert!(db_path.exists(), "active-locked orphan must survive");
        });
    }

    #[test]
    fn ttl_apply_never_deletes_active_locked_even_with_ignore_active_lock() {
        // BLOCKER #1 regression for the TTL path: an old, active-locked DB must
        // not be deleted even when force + ignore_active_lock are both set.
        with_temp_semantic_home(|_| {
            let db_path = seed_db("ttl_locked_ignore", old_access_seconds());
            let _lock = SemanticDbLock::try_acquire(&db_path).expect("hold active lock");

            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: false,
                force: true,
                ignore_active_lock: true,
                mode: GcMode::Ttl,
                only_project_id: None,
            })
            .expect("run gc");

            assert_eq!(output.skipped_active.len(), 1);
            assert!(output.deleted.is_empty());
            assert!(
                db_path.exists(),
                "active-locked DB must survive force+ignore"
            );
        });
    }

    #[test]
    fn orphan_apply_does_not_delete_blank_root_path() {
        with_temp_semantic_home(|_| {
            // Blank root_path + RECENT access → must fall back to TTL (not eligible).
            let db_path = seed_rsem_db_blank_root("blank_root_proj", recent_access_seconds());

            let output = run_gc(GcOptions {
                mode: GcMode::OrphansMissingRoot,
                dry_run: false,
                force: true,
                ..GcOptions::default()
            })
            .expect("run gc");

            assert!(
                output.candidates.is_empty(),
                "blank root_path must not be treated as orphan"
            );
            assert!(output.deleted.is_empty());
            assert!(db_path.exists(), "blank-root DB must not be deleted");
        });
    }

    #[test]
    fn orphan_blank_root_path_falls_back_to_ttl_when_old() {
        with_temp_semantic_home(|_| {
            // Blank root_path + OLD access → TTL fallback makes it eligible.
            let db_path = seed_rsem_db_blank_root("blank_old_proj", old_access_seconds());

            let output = run_gc(GcOptions {
                mode: GcMode::OrphansMissingRoot,
                dry_run: false,
                force: true,
                ..GcOptions::default()
            })
            .expect("run gc");

            assert_eq!(
                output.deleted.len(),
                1,
                "old blank-root DB ages out via TTL"
            );
            assert!(!db_path.exists());
        });
    }

    #[test]
    fn only_project_id_scopes_delete_to_current_project() {
        // BLOCKER #4 regression: with `only_project_id` set, a force GC must
        // delete ONLY the current project's stale DB and must leave every other
        // project's DB strictly untouched — even though those others are also
        // old enough to be TTL-eligible.
        with_temp_semantic_home(|_| {
            let current = seed_db("current_project", old_access_seconds());
            let other_a = seed_db("other_project_a", old_access_seconds());
            let other_b = seed_db("other_project_b", old_access_seconds());

            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: false,
                force: true,
                ignore_active_lock: false,
                mode: GcMode::Ttl,
                only_project_id: Some("current_project".to_string()),
            })
            .expect("run gc");

            assert_eq!(output.scanned, 1, "only the current project is scanned");
            assert_eq!(output.deleted.len(), 1, "only current project deleted");
            assert!(!current.exists(), "current project DB removed");
            assert!(other_a.exists(), "other project A must be untouched");
            assert!(other_b.exists(), "other project B must be untouched");
        });
    }

    #[test]
    fn only_project_id_none_scans_all_projects() {
        // Sanity: --all-projects (only_project_id None) still sees every project.
        with_temp_semantic_home(|_| {
            seed_db("proj_one", old_access_seconds());
            seed_db("proj_two", old_access_seconds());

            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: true,
                only_project_id: None,
                ..GcOptions::default()
            })
            .expect("run gc");

            assert_eq!(output.scanned, 2, "all projects scanned when unscoped");
            assert_eq!(output.candidates.len(), 2);
        });
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
                mode: GcMode::Ttl,
                only_project_id: None,
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
                mode: GcMode::Ttl,
                only_project_id: None,
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
                mode: GcMode::Ttl,
                only_project_id: None,
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
                mode: GcMode::Ttl,
                only_project_id: None,
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

    // -- BLOCKER-2: positive managed-DB proof required before any deletion --

    #[test]
    fn ttl_apply_never_deletes_foreign_app_id_zero_db() {
        // Reviewer BLOCKER-2 repro: a plain foreign SQLite (app_id 0, no
        // RevHarness schema, OLD mtime) must NOT be deleted by TTL GC. Without
        // positive managed proof it is foreign and is skipped.
        with_temp_semantic_home(|_| {
            let db_path = seed_foreign_app_id_zero_db("foreign_zero_ttl", old_access_seconds());

            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: false,
                force: true,
                ignore_active_lock: false,
                mode: GcMode::Ttl,
                only_project_id: None,
            })
            .expect("run gc");

            assert!(
                output.deleted.is_empty(),
                "foreign app_id-0 DB must never be deleted by TTL GC"
            );
            assert!(
                output.tool_errors.iter().any(|e| e.contains("foreign")),
                "skip reason should name the foreign DB"
            );
            assert!(db_path.exists(), "foreign app_id-0 DB must survive TTL GC");
        });
    }

    #[test]
    fn orphan_apply_never_deletes_foreign_app_id_zero_db() {
        // The same foreign app_id-0 DB must also be invisible to orphan GC: it
        // is classified Foreign, never an orphan candidate.
        with_temp_semantic_home(|_| {
            let db_path = seed_foreign_app_id_zero_db("foreign_zero_orphan", old_access_seconds());

            let output = run_gc(GcOptions {
                mode: GcMode::OrphansMissingRoot,
                dry_run: false,
                force: true,
                ..GcOptions::default()
            })
            .expect("run gc");

            assert!(
                output.candidates.is_empty(),
                "foreign app_id-0 DB is never an orphan candidate"
            );
            assert!(output.deleted.is_empty());
            assert!(
                db_path.exists(),
                "foreign app_id-0 DB must survive orphan GC"
            );
        });
    }

    #[test]
    fn ttl_apply_deletes_legacy_app_id_zero_managed_db() {
        // Legacy managed DB: app_id 0 but WITH the RevHarness schema. It carries
        // positive managed proof, so the legacy-v1 TTL delete path stays intact.
        with_temp_semantic_home(|_| {
            let db_path = seed_db("legacy_managed_ttl", old_access_seconds());
            assert_eq!(
                read_application_id(&db_path),
                Some(0),
                "legacy managed DB is unstamped (app_id 0)"
            );

            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: false,
                force: true,
                ignore_active_lock: false,
                mode: GcMode::Ttl,
                only_project_id: None,
            })
            .expect("run gc");

            assert_eq!(
                output.deleted.len(),
                1,
                "legacy app_id-0 managed DB must remain TTL-eligible"
            );
            assert!(!db_path.exists());
        });
    }

    #[test]
    fn ttl_apply_deletes_rsem_managed_db() {
        // RSEM-stamped managed DB ages out via TTL as before.
        with_temp_semantic_home(|_| {
            let present = tempfile::tempdir().expect("present root");
            let db_path = seed_rsem_db("rsem_ttl", present.path(), old_access_seconds());

            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: false,
                force: true,
                mode: GcMode::Ttl,
                only_project_id: None,
                ..GcOptions::default()
            })
            .expect("run gc");

            assert_eq!(output.deleted.len(), 1, "RSEM managed DB ages out via TTL");
            assert!(!db_path.exists());
        });
    }

    #[test]
    fn orphan_apply_deletes_legacy_app_id_zero_managed_orphan() {
        // A legacy app_id-0 managed DB whose root_path truly no longer exists is
        // still a genuine orphan and pruneable (legacy migration/GC path intact).
        with_temp_semantic_home(|_| {
            let missing = std::env::temp_dir().join("revharness-legacy-orphan-XYZ");
            let _ = fs::remove_dir_all(&missing);
            assert!(!missing.exists());

            // seed_db creates the managed schema with a `projects` table but no
            // row; insert a row pointing at the missing root so orphan detection
            // has a non-blank root_path to test.
            let db_path = seed_db("legacy_orphan", recent_access_seconds());
            let conn = Connection::open(&db_path).expect("open");
            conn.execute(
                "INSERT INTO projects(id, name, root_path) VALUES('legacy_orphan','legacy_orphan',?1)",
                params![missing.display().to_string()],
            )
            .expect("seed missing root row");
            drop(conn);

            let output = run_gc(GcOptions {
                mode: GcMode::OrphansMissingRoot,
                dry_run: false,
                force: true,
                ..GcOptions::default()
            })
            .expect("run gc");

            assert_eq!(
                output.deleted.len(),
                1,
                "legacy managed DB with missing root is a genuine orphan"
            );
            assert!(!db_path.exists());
        });
    }
}
