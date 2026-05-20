//! MCP tool wrapper for shared::semantic_gc.
//!
//! The MCP interface remains local to this crate; core GC logic lives in
//! `shared::semantic_gc`.

use serde_json::Value;
use shared::semantic_gc::{self, GcOptions as SharedGcOptions};

pub use shared::semantic_gc::{GcCandidate, GcOutput};

#[derive(Debug, Clone, Copy)]
pub struct GcOptions {
    pub older_than_days: u64,
    pub dry_run: bool,
    pub force: bool,
}

impl Default for GcOptions {
    fn default() -> Self {
        let shared = SharedGcOptions::default();
        Self {
            older_than_days: shared.older_than_days,
            dry_run: shared.dry_run,
            force: shared.force,
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
    Ok(options)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use serde_json::json;
    use std::path::Path;
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
}
