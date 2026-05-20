//! Database initialisation and schema management.
//!
//! The cache layer shares a SQLite database with semantic-mcp.  We use a
//! private `_cache_meta` table (not `PRAGMA user_version`) to track schema
//! versions so the two systems can evolve independently.

use rusqlite::Connection;
use shared::error::{AgentError, Result};
use tracing::{info, warn};

/// Well-known cache table names that may be dropped on corruption.
///
/// These are **cache-owned** tables. The semantic-mcp core tables are never
/// touched.
const CACHE_TABLES: &[&str] = &[
    "file_index",
    "verify_cache",
    "review_cache",
    "capsule_cache",
];

/// Current schema version for the cache tables.
const SCHEMA_VERSION: u32 = 1;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Open (or create) the cache database for `project_id`.
///
/// The database lives at the shared semantic MCP v2 path. WAL journaling and
/// `NORMAL` synchronous mode are enabled for performance.
pub fn open_cache_db(project_id: &str) -> Result<Connection> {
    let db_path = shared::paths::semantic_mcp_db_path(project_id)?;
    let dir = db_path.parent().ok_or_else(|| {
        AgentError::Database(format!(
            "semantic db path has no parent: {}",
            db_path.display()
        ))
    })?;
    std::fs::create_dir_all(dir).map_err(|e| {
        AgentError::Database(format!(
            "failed to create db directory {}: {e}",
            dir.display()
        ))
    })?;

    let conn = Connection::open(&db_path)
        .map_err(|e| AgentError::Database(format!("failed to open database: {e}")))?;

    configure_pragmas(&conn)?;
    run_quick_check(&conn)?;
    ensure_schema(&conn)?;

    Ok(conn)
}

/// Open an in-memory database — used for testing.
pub fn open_in_memory() -> Result<Connection> {
    let conn = Connection::open_in_memory()
        .map_err(|e| AgentError::Database(format!("failed to open in-memory db: {e}")))?;

    configure_pragmas(&conn)?;
    ensure_schema(&conn)?;

    Ok(conn)
}

// ---------------------------------------------------------------------------
// Schema management
// ---------------------------------------------------------------------------

/// Create cache tables if they do not exist.
pub fn ensure_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS _cache_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS file_index (
            file_path       TEXT PRIMARY KEY,
            content_hash    TEXT NOT NULL,
            size_bytes      INTEGER NOT NULL,
            last_indexed_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS verify_cache (
            file_path    TEXT NOT NULL,
            tool         TEXT NOT NULL,
            file_hash    TEXT NOT NULL,
            config_hash  TEXT NOT NULL,
            tool_version TEXT NOT NULL,
            status       TEXT NOT NULL,
            findings     TEXT NOT NULL,
            verified_at  TEXT NOT NULL,
            PRIMARY KEY (file_path, tool)
        );

        CREATE TABLE IF NOT EXISTS review_cache (
            file_path    TEXT NOT NULL,
            reviewer     TEXT NOT NULL,
            file_hash    TEXT NOT NULL,
            prompt_hash  TEXT NOT NULL,
            head_commit  TEXT NOT NULL,
            verdict      TEXT NOT NULL,
            findings     TEXT NOT NULL,
            reviewed_at  TEXT NOT NULL,
            PRIMARY KEY (file_path, reviewer)
        );

        CREATE TABLE IF NOT EXISTS capsule_cache (
            context_hash    TEXT PRIMARY KEY,
            json            TEXT NOT NULL,
            sha256          TEXT NOT NULL,
            tokens          INTEGER NOT NULL,
            created_at      TEXT NOT NULL,
            last_accessed_at TEXT NOT NULL
        );
        ",
    )
    .map_err(|e| AgentError::Database(format!("failed to create schema: {e}")))?;

    // Create indexes for common query patterns
    conn.execute_batch(
        "
        CREATE INDEX IF NOT EXISTS idx_file_index_hash ON file_index(content_hash);
        CREATE INDEX IF NOT EXISTS idx_verify_cache_tool ON verify_cache(tool);
        CREATE INDEX IF NOT EXISTS idx_review_cache_reviewer ON review_cache(reviewer);
        CREATE INDEX IF NOT EXISTS idx_capsule_cache_accessed ON capsule_cache(last_accessed_at);
        ",
    )
    .map_err(|e| AgentError::Database(format!("failed to create indexes: {e}")))?;

    // Record schema version
    conn.execute(
        "INSERT OR REPLACE INTO _cache_meta (key, value) VALUES ('schema_version', ?1)",
        rusqlite::params![SCHEMA_VERSION.to_string()],
    )
    .map_err(|e| AgentError::Database(format!("failed to record schema version: {e}")))?;

    Ok(())
}

/// Return the current schema version from `_cache_meta`, or `None` if the
/// table does not exist.
pub fn get_schema_version(conn: &Connection) -> Option<u32> {
    conn.query_row(
        "SELECT value FROM _cache_meta WHERE key = 'schema_version'",
        [],
        |row| {
            let val: String = row.get(0)?;
            Ok(val.parse::<u32>().unwrap_or(0))
        },
    )
    .ok()
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Configure WAL mode, sync, and busy timeout.
fn configure_pragmas(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA busy_timeout = 30000;
        ",
    )
    .map_err(|e| AgentError::Database(format!("failed to set pragmas: {e}")))?;
    Ok(())
}

/// Run `PRAGMA quick_check` and drop cache tables on failure.
fn run_quick_check(conn: &Connection) -> Result<()> {
    let result: String = conn
        .query_row("PRAGMA quick_check", [], |row| row.get(0))
        .map_err(|e| AgentError::Database(format!("quick_check failed: {e}")))?;

    if result != "ok" {
        warn!("quick_check returned: {result} — dropping cache tables");
        drop_cache_tables(conn)?;
        info!("cache tables dropped; will recreate schema");
    }
    Ok(())
}

/// Drop only cache-owned tables (never semantic-mcp core tables).
pub fn drop_cache_tables(conn: &Connection) -> Result<()> {
    for table in CACHE_TABLES {
        conn.execute(&format!("DROP TABLE IF EXISTS {table}"), [])
            .map_err(|e| AgentError::Database(format!("failed to drop table {table}: {e}")))?;
    }
    // Always drop the meta table last
    conn.execute("DROP TABLE IF EXISTS _cache_meta", [])
        .map_err(|e| AgentError::Database(format!("failed to drop table _cache_meta: {e}")))?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_schema_created() {
        let conn = open_in_memory().unwrap();
        // Verify tables exist by querying them
        let count = |t: &str| -> i64 {
            conn.query_row(&format!("SELECT count(*) FROM {t}"), [], |r| r.get(0))
                .unwrap()
        };
        assert_eq!(count("file_index"), 0);
        assert_eq!(count("verify_cache"), 0);
        assert_eq!(count("review_cache"), 0);
        assert_eq!(count("capsule_cache"), 0);
    }

    #[test]
    fn schema_version_recorded() {
        let conn = open_in_memory().unwrap();
        let version = get_schema_version(&conn);
        assert_eq!(version, Some(SCHEMA_VERSION));
    }

    #[test]
    fn drop_cache_tables_only() {
        let conn = open_in_memory().unwrap();
        // Create a fake semantic-mcp table
        conn.execute("CREATE TABLE semantic_core (id INTEGER PRIMARY KEY)", [])
            .unwrap();

        drop_cache_tables(&conn).unwrap();

        // semantic_core should survive
        let count: i64 = conn
            .query_row("SELECT count(*) FROM semantic_core", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 0);

        // cache tables should be gone
        let result: std::result::Result<i64, _> =
            conn.query_row("SELECT count(*) FROM file_index", [], |r| r.get(0));
        assert!(result.is_err());
    }

    #[test]
    fn ensure_schema_is_idempotent() {
        let conn = open_in_memory().unwrap();
        // Call ensure_schema again — should not fail
        ensure_schema(&conn).unwrap();
        ensure_schema(&conn).unwrap();
    }
}
