//! `sem.health` tool implementation.
//!
//! Checks database connectivity and verifies all required tables exist.

use serde::Serialize;
use serde_json::Value;

use crate::context::ServerContext;
use crate::db;

/// Number of MCP tools provided by this server.
const TOOL_COUNT: usize = 10;
/// Server version.
const VERSION: &str = "0.1.0";

/// Response from the health check tool.
#[derive(Debug, Serialize)]
pub struct HealthResponse {
    /// Always "ok" on success.
    pub status: String,
    /// List of verified tables.
    pub tables: Vec<String>,
    /// Server version.
    pub version: String,
    /// Number of tools registered.
    pub tool_count: usize,
}

/// Execute the `sem.health` tool.
pub fn handle_health(ctx: &ServerContext) -> Result<Value, String> {
    // Verify connectivity.
    ctx.conn
        .execute_batch("SELECT 1")
        .map_err(|e| format!("sem.health failed: database not reachable: {e}"))?;

    // Verify required tables.
    let tables =
        db::assert_required_tables(&ctx.conn).map_err(|e| format!("sem.health failed: {e}"))?;
    db::assert_current_schema(&ctx.conn).map_err(|e| format!("sem.health failed: {e}"))?;

    let response = HealthResponse {
        status: "ok".to_string(),
        tables,
        version: VERSION.to_string(),
        tool_count: TOOL_COUNT,
    };

    serde_json::to_value(response)
        .map_err(|e| format!("sem.health failed: serialization error: {e}"))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::ServerContext;
    use rusqlite::Connection;

    type TestContext = ServerContext;

    fn test_ctx(project_id: &str) -> TestContext {
        let conn = Connection::open_in_memory().unwrap();
        crate::db::run_migrations(&conn).unwrap();
        tree_sitter_index::db::run_tree_sitter_migrations(&conn).unwrap();
        ServerContext::new(
            conn,
            project_id.to_string(),
            std::env::current_dir().unwrap(),
        )
    }

    #[test]
    fn test_health_returns_ok() {
        let ctx = test_ctx("test-project");
        let result = handle_health(&ctx).unwrap();
        assert_eq!(result["status"], "ok");
    }

    #[test]
    fn test_health_returns_required_tables() {
        let ctx = test_ctx("test-project");
        let result = handle_health(&ctx).unwrap();
        let tables = result["tables"].as_array().unwrap();
        assert!(tables.len() >= 7);
        let table_names: Vec<&str> = tables.iter().map(|t| t.as_str().unwrap()).collect();
        assert!(table_names.contains(&"components"));
        assert!(table_names.contains(&"capsules"));
        assert!(table_names.contains(&"review_queue_items"));
        assert!(table_names.contains(&"review_runs"));
    }

    #[test]
    fn test_health_returns_version_and_tool_count() {
        let ctx = test_ctx("test-project");
        let result = handle_health(&ctx).unwrap();
        assert_eq!(result["version"], "0.1.0");
        assert_eq!(result["tool_count"], 10);
    }

    #[test]
    fn startup_health_validate_current_schema_without_legacy_data_scan() {
        let ctx = test_ctx("test-project");
        ctx.conn
            .execute(
                "INSERT INTO review_runs (
                    project_id, run_id, status, summary, result_summary
                 ) VALUES (?1, ?2, ?3, ?4, NULL)",
                rusqlite::params![
                    "test-project",
                    "legacy-row-with-unbackfilled-result-summary",
                    "started",
                    "legacy summary"
                ],
            )
            .unwrap();

        let rerun = crate::db::run_migrations(&ctx.conn).unwrap();
        assert_eq!(rerun.schema_version, 2);
        crate::db::assert_current_schema(&ctx.conn).unwrap();
        let result = handle_health(&ctx).unwrap();
        assert_eq!(result["status"], "ok");
    }

    #[test]
    fn health_fails_closed_when_components_lacks_semantic_id_unique() {
        let conn = Connection::open_in_memory().unwrap();
        crate::db::run_migrations(&conn).unwrap();
        conn.execute_batch(
            "
            ALTER TABLE components RENAME TO components_old;
            CREATE TABLE components (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                semantic_id TEXT NOT NULL,
                name TEXT NOT NULL,
                module TEXT NOT NULL,
                file_path TEXT NOT NULL,
                kind TEXT NOT NULL,
                exports TEXT DEFAULT '[]',
                imports TEXT DEFAULT '[]',
                hash TEXT NOT NULL,
                figma_ref TEXT,
                status TEXT NOT NULL DEFAULT 'active',
                inactive_reason TEXT,
                security_level TEXT,
                idem TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            DROP TABLE components_old;
            ",
        )
        .unwrap();
        let ctx = ServerContext::new(
            conn,
            "test-project".to_string(),
            std::env::current_dir().unwrap(),
        );

        let result = handle_health(&ctx);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("required table structures"));
    }
}
