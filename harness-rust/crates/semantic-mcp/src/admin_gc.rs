//! MCP tool wrapper for shared::semantic_gc.
//!
//! The MCP interface remains local to this crate; core GC logic lives in
//! `shared::semantic_gc`.

use serde_json::Value;
use shared::semantic_gc::{self, GcMode, GcOptions as SharedGcOptions};

pub use shared::semantic_gc::{GcCandidate, GcOutput};

#[derive(Debug, Clone, Copy)]
pub struct GcOptions {
    pub older_than_days: u64,
    pub dry_run: bool,
    pub force: bool,
    pub mode: GcMode,
}

impl Default for GcOptions {
    fn default() -> Self {
        let shared = SharedGcOptions::default();
        Self {
            older_than_days: shared.older_than_days,
            dry_run: shared.dry_run,
            force: shared.force,
            mode: shared.mode,
        }
    }
}

impl From<GcOptions> for SharedGcOptions {
    fn from(options: GcOptions) -> Self {
        Self {
            older_than_days: options.older_than_days,
            dry_run: options.dry_run,
            force: options.force,
            ignore_active_lock: false,
            mode: options.mode,
            only_project_id: None,
        }
    }
}

pub fn handle_admin_gc(
    _ctx: &crate::context::ServerContext,
    input: &Value,
) -> Result<Value, String> {
    let options = parse_tool_options(input)?;
    serde_json::to_value(
        semantic_gc::run_gc(options).map_err(|e| format!("sem.admin.gc failed: {e}"))?,
    )
    .map_err(|e| format!("sem.admin.gc failed: serialization: {e}"))
}

pub fn run_gc(options: GcOptions) -> Result<GcOutput, String> {
    semantic_gc::run_gc(options.into())
}

fn parse_tool_options(input: &Value) -> Result<SharedGcOptions, String> {
    let obj = input
        .as_object()
        .ok_or_else(|| "sem.admin.gc failed: arguments must be an object".to_string())?;
    let mut options = SharedGcOptions::default();
    if let Some(value) = obj.get("older_than_days") {
        options.older_than_days = value
            .as_u64()
            .ok_or_else(|| "sem.admin.gc failed: older_than_days must be an integer".to_string())?;
    }
    if let Some(value) = obj.get("dry_run") {
        options.dry_run = value
            .as_bool()
            .ok_or_else(|| "sem.admin.gc failed: dry_run must be a boolean".to_string())?;
    }
    if let Some(value) = obj.get("force") {
        options.force = value
            .as_bool()
            .ok_or_else(|| "sem.admin.gc failed: force must be a boolean".to_string())?;
    }
    if let Some(value) = obj.get("ignore_active_lock") {
        options.ignore_active_lock = value.as_bool().ok_or_else(|| {
            "sem.admin.gc failed: ignore_active_lock must be a boolean".to_string()
        })?;
    }
    // Orphan (dispose-together) mode. Accept either a boolean
    // `prune_missing_root` or a `mode: "orphans"|"ttl"` string. Both default
    // to TTL when absent, preserving the existing destructive-safe behavior.
    if let Some(value) = obj.get("prune_missing_root") {
        let on = value.as_bool().ok_or_else(|| {
            "sem.admin.gc failed: prune_missing_root must be a boolean".to_string()
        })?;
        options.mode = if on {
            GcMode::OrphansMissingRoot
        } else {
            GcMode::Ttl
        };
    }
    if let Some(value) = obj.get("mode") {
        let mode = value
            .as_str()
            .ok_or_else(|| "sem.admin.gc failed: mode must be a string".to_string())?;
        options.mode = match mode {
            "ttl" => GcMode::Ttl,
            "orphans" | "prune_missing_root" => GcMode::OrphansMissingRoot,
            other => {
                return Err(format!(
                    "sem.admin.gc failed: unknown mode '{other}' (expected 'ttl' or 'orphans')"
                ))
            }
        };
    }
    Ok(options)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_env::EnvGuard;
    use rusqlite::Connection;
    use serde_json::json;
    use std::path::Path;

    /// Run `test` with `SEMANTIC_MCP_HOME` pointed at a fresh, test-owned
    /// `TempDir`, holding the crate-wide env lock for the full duration so it
    /// never races a concurrent `main_loop` env-mutating test. The guard
    /// restores prior env on drop, so a panic here cannot leak to a sibling.
    fn with_temp_semantic_home<T>(test: impl FnOnce(&Path) -> T) -> T {
        let guard = EnvGuard::acquire();
        let tmp = tempfile::tempdir().expect("tempdir");
        guard.set_test_harness_home(tmp.path());
        test(tmp.path())
    }

    fn seed_db(path: &Path, last_accessed_seconds: i64) {
        std::fs::create_dir_all(path.parent().expect("db parent")).expect("create parent");
        let conn = Connection::open(path).expect("open sqlite");
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
            rusqlite::params![last_accessed_seconds.to_string()],
        )
        .expect("seed last_accessed");
    }

    #[test]
    fn handle_admin_gc_delegates_to_shared_run_gc() {
        with_temp_semantic_home(|_| {
            let db_path = shared::paths::semantic_mcp_db_path("smoke_project").expect("db path");
            let old_seconds =
                (shared::semantic_gc::now_unix_ms().expect("now") / 1000) - (40 * 24 * 60 * 60);
            seed_db(&db_path, old_seconds);
            let conn = Connection::open_in_memory().expect("memory db");
            let ctx = crate::context::ServerContext::new(
                conn,
                "smoke_project".to_string(),
                std::env::current_dir().expect("cwd"),
            );

            let value = handle_admin_gc(
                &ctx,
                &json!({
                    "older_than_days": 30,
                    "dry_run": true,
                    "force": false
                }),
            )
            .expect("handle admin gc");

            assert_eq!(value["schema_version"], 1);
            assert_eq!(value["candidates"].as_array().expect("candidates").len(), 1);
        });
    }

    #[test]
    fn parse_tool_options_accepts_ignore_active_lock() {
        let options = parse_tool_options(&json!({
            "older_than_days": 7,
            "dry_run": true,
            "force": false,
            "ignore_active_lock": true
        }))
        .expect("parse options");

        assert_eq!(options.older_than_days, 7);
        assert!(options.ignore_active_lock);
    }

    #[test]
    fn parse_tool_options_defaults_to_ttl_mode() {
        let options = parse_tool_options(&json!({})).expect("parse options");
        assert_eq!(options.mode, GcMode::Ttl);
        assert!(options.dry_run, "dry-run must be the default");
    }

    #[test]
    fn parse_tool_options_accepts_prune_missing_root() {
        let options =
            parse_tool_options(&json!({ "prune_missing_root": true })).expect("parse options");
        assert_eq!(options.mode, GcMode::OrphansMissingRoot);
    }

    #[test]
    fn parse_tool_options_accepts_mode_orphans() {
        let options = parse_tool_options(&json!({ "mode": "orphans" })).expect("parse options");
        assert_eq!(options.mode, GcMode::OrphansMissingRoot);
    }

    #[test]
    fn parse_tool_options_rejects_unknown_mode() {
        let err = parse_tool_options(&json!({ "mode": "nuke" })).expect_err("unknown mode");
        assert!(err.contains("unknown mode"));
    }

    /// Build a real RSEM-stamped managed DB at the managed path, with the full
    /// runtime schema (via `db::run_migrations`) and a poisoned `root_path`.
    fn seed_managed_db_with_root(project_id: &str, root_path: &str) -> std::path::PathBuf {
        let db_path = shared::paths::semantic_mcp_db_path(project_id).expect("db path");
        std::fs::create_dir_all(db_path.parent().expect("parent")).expect("create parent");
        let conn = Connection::open(&db_path).expect("open sqlite");
        conn.execute_batch(&format!(
            "PRAGMA application_id = {};",
            shared::semantic_gc::REVHARNESS_APP_ID
        ))
        .expect("stamp rsem");
        crate::db::run_migrations(&conn).expect("migrations");
        // `run_migrations` builds the semantic-mcp schema but `_ts_meta`,
        // `symbols`, `symbol_dependencies`, and `file_parse_cache` are created by
        // the tree-sitter-index layer at runtime. Create the full managed-table
        // set here so the DB is positively recognized as managed by GC.
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS _ts_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS symbols (id INTEGER PRIMARY KEY);
             CREATE TABLE IF NOT EXISTS symbol_dependencies (id INTEGER PRIMARY KEY);
             CREATE TABLE IF NOT EXISTS file_parse_cache (id INTEGER PRIMARY KEY);",
        )
        .expect("create runtime managed tables");
        let now = shared::semantic_gc::now_unix_ms().expect("now") / 1000;
        conn.execute(
            "INSERT OR REPLACE INTO _ts_meta(key, value) VALUES('last_accessed', ?1)",
            rusqlite::params![now.to_string()],
        )
        .expect("seed last_accessed");
        conn.execute(
            "INSERT OR REPLACE INTO projects(id, name, root_path) VALUES(?1, ?1, ?2)",
            rusqlite::params![project_id, root_path],
        )
        .expect("seed poisoned root");
        db_path
    }

    #[test]
    fn blocker1_repaired_root_is_not_pruned_by_orphan_gc() {
        // BLOCKER-1 end-to-end: a managed DB holding a WRONG non-blank root_path
        // is opened with the CORRECT trusted --repo-root. After repair, the
        // stored root_path points at the real (existing) project root, so
        // orphan-GC must NOT delete it.
        with_temp_semantic_home(|_| {
            // The real project root that DOES exist on disk.
            let real_root = tempfile::tempdir().expect("real root");
            // A wrong, non-blank root that does NOT exist → would look like an
            // orphan to the un-repaired GC.
            let wrong_root = std::env::temp_dir().join("revharness-blocker1-wrong-root-XYZ");
            let _ = std::fs::remove_dir_all(&wrong_root);
            assert!(!wrong_root.exists());

            let db_path =
                seed_managed_db_with_root("blocker1_proj", &wrong_root.display().to_string());

            // Repair: open with the trusted (correct) repo_root.
            let conn = Connection::open(&db_path).expect("reopen");
            crate::db::record_project_root_and_pointer(
                &conn,
                "blocker1_proj",
                real_root.path(),
                &db_path,
            )
            .expect("repair root_path");
            let repaired: String = conn
                .query_row(
                    "SELECT root_path FROM projects WHERE id='blocker1_proj'",
                    [],
                    |r| r.get(0),
                )
                .expect("row");
            assert_eq!(
                repaired,
                real_root.path().display().to_string(),
                "poisoned root_path must be repaired to the trusted repo_root"
            );
            drop(conn);

            // Orphan-GC must now leave the DB alone (root exists).
            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: false,
                force: true,
                mode: GcMode::OrphansMissingRoot,
            })
            .expect("run gc");
            assert!(
                output.deleted.is_empty(),
                "repaired live DB must NOT be pruned by orphan GC"
            );
            assert!(db_path.exists(), "live DB must survive after repair");
        });
    }

    #[test]
    fn blocker1_genuine_orphan_still_pruneable() {
        // Counterpart: a managed DB whose root_path is correctly set to a path
        // that truly no longer exists IS still pruneable (orphan detection still
        // works for genuine orphans — repair must not over-suppress).
        with_temp_semantic_home(|_| {
            let missing = std::env::temp_dir().join("revharness-blocker1-genuine-orphan-XYZ");
            let _ = std::fs::remove_dir_all(&missing);
            assert!(!missing.exists());

            let db_path =
                seed_managed_db_with_root("genuine_orphan_proj", &missing.display().to_string());

            let output = run_gc(GcOptions {
                older_than_days: 30,
                dry_run: false,
                force: true,
                mode: GcMode::OrphansMissingRoot,
            })
            .expect("run gc");

            assert_eq!(
                output.deleted.len(),
                1,
                "genuine orphan (missing root) must still be pruneable"
            );
            assert!(!db_path.exists());
        });
    }
}
