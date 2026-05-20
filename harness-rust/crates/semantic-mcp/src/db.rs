//! Database layer for the semantic MCP server.
//!
//! Opens a per-project SQLite database, configures WAL mode, and runs
//! idempotent migrations.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OptionalExtension};

const CURRENT_SCHEMA_VERSION: i64 = 2;
pub const REVHARNESS_APP_ID: i64 = 0x5253_454D;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MigrationPath {
    FastPath,
    Full,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MigrationResult {
    pub path: MigrationPath,
    pub schema_version: i64,
}

/// Resolve the database file path for a given project.
pub fn resolve_db_path(project_id: &str) -> Result<PathBuf, String> {
    shared::paths::semantic_mcp_db_path(project_id).map_err(|e| e.to_string())
}

/// Open a managed project database and complete startup validation.
pub fn open_project_connection(project_id: &str) -> Result<(Connection, PathBuf), String> {
    migrate_legacy_db_if_needed(project_id)?;
    let db_path = resolve_db_path(project_id)?;
    let conn = open_connection(&db_path)?;
    run_migrations(&conn).map_err(|e| format!("migration failed: {e}"))?;
    tree_sitter_index::db::run_tree_sitter_migrations(&conn)
        .map_err(|e| format!("tree-sitter migration failed: {e}"))?;
    validate_or_adopt_application_id(&conn, &db_path)?;
    touch_last_accessed(&conn)?;
    Ok((conn, db_path))
}

/// Open (or create) the SQLite database at the given path.
///
/// Configures WAL journal mode, NORMAL synchronous, and 5-second busy timeout.
pub fn open_connection(db_path: &Path) -> Result<Connection, String> {
    if let Some(parent) = db_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create database directory: {e}"))?;
    }

    let conn = Connection::open(db_path).map_err(|e| format!("failed to open database: {e}"))?;

    conn.pragma_update(None, "journal_mode", "WAL")
        .map_err(|e| format!("failed to set WAL mode: {e}"))?;
    conn.pragma_update(None, "synchronous", "NORMAL")
        .map_err(|e| format!("failed to set synchronous mode: {e}"))?;
    conn.pragma_update(None, "busy_timeout", 5000)
        .map_err(|e| format!("failed to set busy timeout: {e}"))?;

    // Verify connectivity.
    conn.execute_batch("SELECT 1")
        .map_err(|e| format!("database connection test failed: {e}"))?;

    Ok(conn)
}

pub fn migrate_legacy_db_if_needed(project_id: &str) -> Result<(), String> {
    let new = resolve_db_path(project_id)?;
    let Some(legacy) = shared::paths::legacy_db_path(project_id) else {
        return Ok(());
    };
    if !legacy.exists() || new.exists() {
        return Ok(());
    }

    let target_parent = new
        .parent()
        .ok_or_else(|| format!("database path has no parent: {}", new.display()))?;
    fs::create_dir_all(target_parent)
        .map_err(|e| format!("failed to create target database directory: {e}"))?;

    let lock_path = target_parent.join(".migration.lock");
    let lock_file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .read(true)
        .open(&lock_path)
        .map_err(|e| format!("failed to open migration lock {}: {e}", lock_path.display()))?;
    shared::paths::try_lock_exclusive_with_timeout(&lock_file, Duration::from_secs(10))
        .map_err(|e| format!("migration lock contended for {}: {e}", lock_path.display()))?;
    let _guard = scopeguard::guard(&lock_file, |file| {
        let _ = fs2::FileExt::unlock(file);
    });

    if new.exists() {
        return Ok(());
    }

    {
        let conn = Connection::open(&legacy)
            .map_err(|e| format!("failed to open legacy database for checkpoint: {e}"))?;
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
            .map_err(|e| format!("failed to checkpoint legacy WAL: {e}"))?;
    }

    for suffix in ["", "-wal", "-shm"] {
        let src = path_with_suffix(&legacy, suffix);
        if !src.exists() {
            continue;
        }
        let dst_final = path_with_suffix(&new, suffix);
        let dst_partial = path_with_suffix(&new, &format!("{suffix}.partial"));

        fs::copy(&src, &dst_partial).map_err(|e| {
            format!(
                "failed to stage legacy database sidecar {} -> {}: {e}",
                src.display(),
                dst_partial.display()
            )
        })?;

        let src_len = fs::metadata(&src)
            .map_err(|e| format!("failed to stat source {}: {e}", src.display()))?
            .len();
        let dst_len = fs::metadata(&dst_partial)
            .map_err(|e| format!("failed to stat staged {}: {e}", dst_partial.display()))?
            .len();
        if src_len != dst_len {
            let _ = fs::remove_file(&dst_partial);
            return Err(format!(
                "size mismatch on legacy migration sidecar {suffix}: src={src_len} dst={dst_len}"
            ));
        }

        if suffix.is_empty() {
            let mut header = [0_u8; 16];
            fs::File::open(&dst_partial)
                .and_then(|mut file| file.read_exact(&mut header))
                .map_err(|e| {
                    let _ = fs::remove_file(&dst_partial);
                    format!("failed to read staged SQLite header: {e}")
                })?;
            if &header != b"SQLite format 3\0" {
                let _ = fs::remove_file(&dst_partial);
                return Err("staging file is not a valid SQLite database".to_string());
            }
        }

        fs::rename(&dst_partial, &dst_final).map_err(|e| {
            format!(
                "failed to publish staged database sidecar {} -> {}: {e}",
                dst_partial.display(),
                dst_final.display()
            )
        })?;
    }

    for suffix in ["", "-wal", "-shm"] {
        let src = path_with_suffix(&legacy, suffix);
        if src.exists() {
            let _ = fs::remove_file(src);
        }
    }

    tracing::info!(
        target: "semantic_mcp",
        "migrated legacy DB {} -> {}",
        legacy.display(),
        new.display()
    );
    Ok(())
}

pub fn validate_or_adopt_application_id(conn: &Connection, db_path: &Path) -> Result<(), String> {
    let app_id: i64 = conn
        .query_row("PRAGMA application_id", [], |row| row.get(0))
        .map_err(|e| format!("failed to read application_id: {e}"))?;
    match app_id {
        0 => {
            validate_revharness_schema(conn).map_err(|e| {
                format!(
                    "refusing to adopt DB at {}: schema validation failed before stamp ({e})",
                    db_path.display()
                )
            })?;
            conn.execute_batch(&format!("PRAGMA application_id = {REVHARNESS_APP_ID};"))
                .map_err(|e| format!("failed to stamp application_id: {e}"))?;
            tracing::info!(
                target: "semantic_mcp",
                "adopted application_id = 0x{REVHARNESS_APP_ID:08X} for {}",
                db_path.display()
            );
            Ok(())
        }
        REVHARNESS_APP_ID => Ok(()),
        other => Err(format!(
            "DB at {} has unexpected application_id 0x{other:08X}; refusing foreign DB",
            db_path.display()
        )),
    }
}

pub fn validate_revharness_schema(conn: &Connection) -> Result<(), String> {
    for table in [
        "components",
        "components_fts",
        "_ts_meta",
        "capsules",
        "symbols",
        "symbol_dependencies",
        "file_parse_cache",
    ] {
        let exists: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                rusqlite::params![table],
                |row| row.get(0),
            )
            .unwrap_or(0);
        if exists == 0 {
            return Err(format!("missing required table: {table}"));
        }
    }
    Ok(())
}

pub fn touch_last_accessed(conn: &Connection) -> Result<(), String> {
    let now = chrono::Utc::now().timestamp();
    let last = conn
        .query_row(
            "SELECT value FROM _ts_meta WHERE key = 'last_accessed'",
            [],
            |row| row.get::<_, String>(0),
        )
        .ok()
        .and_then(|value| value.parse::<i64>().ok())
        .unwrap_or(0);
    if now - last >= 60 {
        conn.execute(
            "INSERT OR REPLACE INTO _ts_meta(key, value) VALUES('last_accessed', ?1)",
            rusqlite::params![now.to_string()],
        )
        .map_err(|e| format!("failed to update last_accessed: {e}"))?;
    }
    Ok(())
}

pub fn path_with_suffix(path: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}{}", path.as_os_str().to_string_lossy(), suffix))
}

/// Run all idempotent schema migrations.
///
/// Creates tables if they do not exist and adds indexes.
pub fn run_migrations(conn: &Connection) -> Result<MigrationResult, String> {
    if get_schema_version(conn)? == CURRENT_SCHEMA_VERSION && validate_current_schema(conn).is_ok()
    {
        return Ok(MigrationResult {
            path: MigrationPath::FastPath,
            schema_version: CURRENT_SCHEMA_VERSION,
        });
    }

    conn.execute_batch(SCHEMA_SQL)
        .map_err(|e| format!("failed to run migrations: {e}"))?;

    // Ensure columns exist (idempotent ALTER TABLE).
    for col_def in COLUMN_DEFINITIONS {
        ensure_column(conn, col_def)?;
    }

    // Backfill legacy review_queue_items columns.
    backfill_legacy_review_queue(conn)?;
    backfill_legacy_review_runs(conn)?;
    repair_known_legacy_table_structures(conn)?;
    backfill_components_fts(conn)?;

    // Create indexes.
    conn.execute_batch(INDEX_SQL)
        .map_err(|e| format!("failed to create indexes: {e}"))?;

    validate_current_schema(conn).map_err(|e| {
        let _ = set_schema_version(conn, 0);
        format!("schema validation failed after migrations: {e}")
    })?;
    set_schema_version(conn, CURRENT_SCHEMA_VERSION)?;

    Ok(MigrationResult {
        path: MigrationPath::Full,
        schema_version: get_schema_version(conn)?,
    })
}

/// Required table names for health checks.
pub const REQUIRED_TABLES: &[&str] = &[
    "projects",
    "components",
    "registry_deltas",
    "capsules",
    "outbox_queue",
    "review_queue_items",
    "review_runs",
];

/// List all user tables in the database.
pub fn list_tables(conn: &Connection) -> Result<Vec<String>, String> {
    let mut stmt = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .map_err(|e| format!("failed to list tables: {e}"))?;
    let rows = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|e| format!("failed to query tables: {e}"))?;
    let mut tables = Vec::new();
    for row in rows {
        let name = row.map_err(|e| format!("row error: {e}"))?;
        if !name.starts_with("sqlite_") {
            tables.push(name);
        }
    }
    Ok(tables)
}

/// Assert that all required tables exist, returning the list on success.
pub fn assert_required_tables(conn: &Connection) -> Result<Vec<String>, String> {
    let existing: std::collections::HashSet<String> = list_tables(conn)?.into_iter().collect();
    let missing: Vec<&str> = REQUIRED_TABLES
        .iter()
        .filter(|t| !existing.contains(**t))
        .copied()
        .collect();
    if !missing.is_empty() {
        return Err(format!("missing tables: {}", missing.join(", ")));
    }
    Ok(REQUIRED_TABLES.iter().map(|s| s.to_string()).collect())
}

/// Assert that the current database schema satisfies the runtime contract.
pub fn assert_current_schema(conn: &Connection) -> Result<(), String> {
    validate_current_schema(conn)
}

// ---------------------------------------------------------------------------
// Schema SQL
// ---------------------------------------------------------------------------

const SCHEMA_SQL: &str = r#"
-- projects
CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    root_path TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- components: registry
CREATE TABLE IF NOT EXISTS components (
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
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(project_id, semantic_id)
);

CREATE VIRTUAL TABLE IF NOT EXISTS components_fts USING fts5(
    name,
    semantic_id,
    module,
    kind,
    file_path,
    content='',
    contentless_delete=1,
    tokenize='unicode61 remove_diacritics 2'
);

-- registry_deltas
CREATE TABLE IF NOT EXISTS registry_deltas (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    delta_type TEXT NOT NULL,
    semantic_id TEXT,
    payload TEXT NOT NULL,
    applied_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(project_id, idempotency_key)
);

-- capsules
CREATE TABLE IF NOT EXISTS capsules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    phase TEXT NOT NULL,
    content TEXT NOT NULL,
    token_count INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- outbox_queue
CREATE TABLE IF NOT EXISTS outbox_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- review_queue_items
CREATE TABLE IF NOT EXISTS review_queue_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL,
    event_id TEXT,
    dedupe_key TEXT,
    file_path TEXT NOT NULL,
    queue_state TEXT NOT NULL DEFAULT 'pending',
    first_enqueued_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    last_enqueued_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    last_enqueue_source TEXT NOT NULL DEFAULT 'unknown',
    payload TEXT NOT NULL DEFAULT '{}',
    lease_run_id TEXT,
    lease_event_id TEXT,
    lease_owner TEXT,
    leased_at TEXT,
    lease_expires_at TEXT,
    acknowledged_at TEXT,
    completed_at TEXT,
    completed_run_id TEXT,
    last_error TEXT,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    retry_count INTEGER NOT NULL DEFAULT 0,
    UNIQUE(project_id, file_path),
    CHECK(queue_state IN ('pending', 'leased', 'done'))
);

-- review_runs
CREATE TABLE IF NOT EXISTS review_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL,
    run_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'started',
    phase TEXT,
    iteration INTEGER,
    kind TEXT,
    consumer TEXT,
    reviewer TEXT,
    file_count INTEGER NOT NULL DEFAULT 0,
    files_json TEXT NOT NULL DEFAULT '[]',
    findings_json TEXT NOT NULL DEFAULT '[]',
    summary TEXT,
    result_summary TEXT,
    blocker_summary TEXT,
    report_body TEXT,
    report_hash TEXT,
    error_message TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    completed_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(project_id, run_id),
    CHECK(status IN ('started', 'completed', 'failed'))
);
"#;

// ---------------------------------------------------------------------------
// Column definitions for incremental migration
// ---------------------------------------------------------------------------

struct ColumnDef {
    table: &'static str,
    column: &'static str,
    sql: &'static str,
}

struct TableStructureDef {
    table: &'static str,
    required_fragments: &'static [&'static str],
}

struct IndexDef {
    name: &'static str,
    sql: &'static str,
}

const COLUMN_DEFINITIONS: &[ColumnDef] = &[
    ColumnDef {
        table: "registry_deltas",
        column: "semantic_id",
        sql: "ALTER TABLE registry_deltas ADD COLUMN semantic_id TEXT",
    },
    ColumnDef {
        table: "registry_deltas",
        column: "applied_at",
        sql: "ALTER TABLE registry_deltas ADD COLUMN applied_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z'",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "event_id",
        sql: "ALTER TABLE review_queue_items ADD COLUMN event_id TEXT",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "dedupe_key",
        sql: "ALTER TABLE review_queue_items ADD COLUMN dedupe_key TEXT",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "queue_state",
        sql: "ALTER TABLE review_queue_items ADD COLUMN queue_state TEXT NOT NULL DEFAULT 'pending'",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "first_enqueued_at",
        sql: "ALTER TABLE review_queue_items ADD COLUMN first_enqueued_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z'",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "last_enqueued_at",
        sql: "ALTER TABLE review_queue_items ADD COLUMN last_enqueued_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z'",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "last_enqueue_source",
        sql: "ALTER TABLE review_queue_items ADD COLUMN last_enqueue_source TEXT NOT NULL DEFAULT 'unknown'",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "payload",
        sql: "ALTER TABLE review_queue_items ADD COLUMN payload TEXT NOT NULL DEFAULT '{}'",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "lease_run_id",
        sql: "ALTER TABLE review_queue_items ADD COLUMN lease_run_id TEXT",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "lease_event_id",
        sql: "ALTER TABLE review_queue_items ADD COLUMN lease_event_id TEXT",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "lease_owner",
        sql: "ALTER TABLE review_queue_items ADD COLUMN lease_owner TEXT",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "leased_at",
        sql: "ALTER TABLE review_queue_items ADD COLUMN leased_at TEXT",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "lease_expires_at",
        sql: "ALTER TABLE review_queue_items ADD COLUMN lease_expires_at TEXT",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "acknowledged_at",
        sql: "ALTER TABLE review_queue_items ADD COLUMN acknowledged_at TEXT",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "completed_at",
        sql: "ALTER TABLE review_queue_items ADD COLUMN completed_at TEXT",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "completed_run_id",
        sql: "ALTER TABLE review_queue_items ADD COLUMN completed_run_id TEXT",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "last_error",
        sql: "ALTER TABLE review_queue_items ADD COLUMN last_error TEXT",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "attempt_count",
        sql: "ALTER TABLE review_queue_items ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0",
    },
    ColumnDef {
        table: "review_queue_items",
        column: "retry_count",
        sql: "ALTER TABLE review_queue_items ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0",
    },
    ColumnDef {
        table: "review_runs",
        column: "status",
        sql: "ALTER TABLE review_runs ADD COLUMN status TEXT NOT NULL DEFAULT 'started'",
    },
    ColumnDef {
        table: "review_runs",
        column: "phase",
        sql: "ALTER TABLE review_runs ADD COLUMN phase TEXT",
    },
    ColumnDef {
        table: "review_runs",
        column: "iteration",
        sql: "ALTER TABLE review_runs ADD COLUMN iteration INTEGER",
    },
    ColumnDef {
        table: "review_runs",
        column: "kind",
        sql: "ALTER TABLE review_runs ADD COLUMN kind TEXT",
    },
    ColumnDef {
        table: "review_runs",
        column: "consumer",
        sql: "ALTER TABLE review_runs ADD COLUMN consumer TEXT",
    },
    ColumnDef {
        table: "review_runs",
        column: "reviewer",
        sql: "ALTER TABLE review_runs ADD COLUMN reviewer TEXT",
    },
    ColumnDef {
        table: "review_runs",
        column: "file_count",
        sql: "ALTER TABLE review_runs ADD COLUMN file_count INTEGER NOT NULL DEFAULT 0",
    },
    ColumnDef {
        table: "review_runs",
        column: "files_json",
        sql: "ALTER TABLE review_runs ADD COLUMN files_json TEXT NOT NULL DEFAULT '[]'",
    },
    ColumnDef {
        table: "review_runs",
        column: "findings_json",
        sql: "ALTER TABLE review_runs ADD COLUMN findings_json TEXT NOT NULL DEFAULT '[]'",
    },
    ColumnDef {
        table: "review_runs",
        column: "summary",
        sql: "ALTER TABLE review_runs ADD COLUMN summary TEXT",
    },
    ColumnDef {
        table: "review_runs",
        column: "result_summary",
        sql: "ALTER TABLE review_runs ADD COLUMN result_summary TEXT",
    },
    ColumnDef {
        table: "review_runs",
        column: "blocker_summary",
        sql: "ALTER TABLE review_runs ADD COLUMN blocker_summary TEXT",
    },
    ColumnDef {
        table: "review_runs",
        column: "report_body",
        sql: "ALTER TABLE review_runs ADD COLUMN report_body TEXT",
    },
    ColumnDef {
        table: "review_runs",
        column: "report_hash",
        sql: "ALTER TABLE review_runs ADD COLUMN report_hash TEXT",
    },
    ColumnDef {
        table: "review_runs",
        column: "error_message",
        sql: "ALTER TABLE review_runs ADD COLUMN error_message TEXT",
    },
    ColumnDef {
        table: "review_runs",
        column: "metadata_json",
        sql: "ALTER TABLE review_runs ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}'",
    },
    ColumnDef {
        table: "review_runs",
        column: "started_at",
        sql: "ALTER TABLE review_runs ADD COLUMN started_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z'",
    },
    ColumnDef {
        table: "review_runs",
        column: "completed_at",
        sql: "ALTER TABLE review_runs ADD COLUMN completed_at TEXT",
    },
    ColumnDef {
        table: "review_runs",
        column: "created_at",
        sql: "ALTER TABLE review_runs ADD COLUMN created_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z'",
    },
    ColumnDef {
        table: "review_runs",
        column: "updated_at",
        sql: "ALTER TABLE review_runs ADD COLUMN updated_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z'",
    },
];

struct RequiredTableColumns {
    table: &'static str,
    columns: &'static [&'static str],
}

const REQUIRED_TABLE_COLUMNS: &[RequiredTableColumns] = &[
    RequiredTableColumns {
        table: "projects",
        columns: &["id", "name", "root_path", "created_at", "updated_at"],
    },
    RequiredTableColumns {
        table: "components",
        columns: &[
            "id",
            "project_id",
            "semantic_id",
            "name",
            "module",
            "file_path",
            "kind",
            "exports",
            "imports",
            "hash",
            "figma_ref",
            "status",
            "inactive_reason",
            "security_level",
            "idem",
            "updated_at",
        ],
    },
    RequiredTableColumns {
        table: "registry_deltas",
        columns: &[
            "id",
            "project_id",
            "idempotency_key",
            "delta_type",
            "semantic_id",
            "payload",
            "applied_at",
        ],
    },
    RequiredTableColumns {
        table: "capsules",
        columns: &[
            "id",
            "project_id",
            "task_id",
            "phase",
            "content",
            "token_count",
            "created_at",
        ],
    },
    RequiredTableColumns {
        table: "outbox_queue",
        columns: &[
            "id",
            "project_id",
            "event_type",
            "payload",
            "status",
            "created_at",
        ],
    },
    RequiredTableColumns {
        table: "review_queue_items",
        columns: &[
            "id",
            "project_id",
            "event_id",
            "dedupe_key",
            "file_path",
            "queue_state",
            "first_enqueued_at",
            "last_enqueued_at",
            "last_enqueue_source",
            "payload",
            "lease_run_id",
            "lease_event_id",
            "lease_owner",
            "leased_at",
            "lease_expires_at",
            "acknowledged_at",
            "completed_at",
            "completed_run_id",
            "last_error",
            "attempt_count",
            "retry_count",
        ],
    },
    RequiredTableColumns {
        table: "review_runs",
        columns: &[
            "id",
            "project_id",
            "run_id",
            "status",
            "phase",
            "iteration",
            "kind",
            "consumer",
            "reviewer",
            "file_count",
            "files_json",
            "findings_json",
            "summary",
            "result_summary",
            "blocker_summary",
            "report_body",
            "report_hash",
            "error_message",
            "metadata_json",
            "started_at",
            "completed_at",
            "created_at",
            "updated_at",
        ],
    },
];

const REQUIRED_TABLE_STRUCTURES: &[TableStructureDef] = &[
    TableStructureDef {
        table: "components",
        required_fragments: &["unique(project_id, semantic_id)"],
    },
    TableStructureDef {
        table: "registry_deltas",
        required_fragments: &[
            "applied_at text not null default (datetime('now'))",
            "unique(project_id, idempotency_key)",
        ],
    },
    TableStructureDef {
        table: "review_queue_items",
        required_fragments: &[
            "unique(project_id, file_path)",
            "check(queue_state in ('pending', 'leased', 'done'))",
        ],
    },
    TableStructureDef {
        table: "review_runs",
        required_fragments: &[
            "unique(project_id, run_id)",
            "check(status in ('started', 'completed', 'failed'))",
        ],
    },
];

fn ensure_column(conn: &Connection, def: &ColumnDef) -> Result<(), String> {
    let columns = get_table_columns(conn, def.table)?;
    if columns.contains(&def.column.to_string()) {
        return Ok(());
    }
    conn.execute_batch(def.sql)
        .map_err(|e| format!("failed to add column {}.{}: {e}", def.table, def.column))?;
    Ok(())
}

fn get_table_columns(conn: &Connection, table: &str) -> Result<Vec<String>, String> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|e| format!("failed to get columns for {table}: {e}"))?;
    let rows = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| format!("failed to query columns: {e}"))?;
    let mut cols = Vec::new();
    for row in rows {
        cols.push(row.map_err(|e| format!("column row error: {e}"))?);
    }
    Ok(cols)
}

fn backfill_legacy_review_queue(conn: &Connection) -> Result<(), String> {
    // Backfill dedupe_key from file_path where NULL.
    conn.execute_batch(
        "UPDATE review_queue_items SET dedupe_key = file_path WHERE dedupe_key IS NULL",
    )
    .map_err(|e| format!("failed to backfill dedupe_key: {e}"))?;
    // Backfill retry_count where NULL.
    conn.execute_batch("UPDATE review_queue_items SET retry_count = 0 WHERE retry_count IS NULL")
        .map_err(|e| format!("failed to backfill retry_count: {e}"))?;
    Ok(())
}

fn backfill_legacy_review_runs(conn: &Connection) -> Result<(), String> {
    conn.execute_batch(
        "UPDATE review_runs
         SET result_summary = summary
         WHERE result_summary IS NULL
           AND summary IS NOT NULL",
    )
    .map_err(|e| format!("failed to backfill result_summary: {e}"))?;
    Ok(())
}

fn backfill_components_fts(conn: &Connection) -> Result<(), String> {
    conn.execute_batch(
        r#"
        INSERT INTO components_fts(rowid, name, semantic_id, module, kind, file_path)
        SELECT id, name, semantic_id, module, kind, file_path
        FROM components
        WHERE id NOT IN (SELECT rowid FROM components_fts);
        "#,
    )
    .map_err(|e| format!("failed to backfill components_fts: {e}"))?;
    Ok(())
}

fn repair_known_legacy_table_structures(conn: &Connection) -> Result<(), String> {
    repair_legacy_review_queue_items(conn)?;
    repair_legacy_review_runs(conn)?;
    Ok(())
}

fn repair_legacy_review_queue_items(conn: &Connection) -> Result<(), String> {
    if has_required_table_structure(conn, "review_queue_items")? {
        return Ok(());
    }

    let columns = get_table_columns(conn, "review_queue_items")?;
    for required in ["id", "project_id", "file_path"] {
        if !columns.iter().any(|column| column == required) {
            return Ok(());
        }
    }

    conn.execute_batch(
        r#"
        ALTER TABLE review_queue_items RENAME TO review_queue_items__legacy_rebuild;
        CREATE TABLE review_queue_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id TEXT NOT NULL,
            event_id TEXT,
            dedupe_key TEXT,
            file_path TEXT NOT NULL,
            queue_state TEXT NOT NULL DEFAULT 'pending',
            first_enqueued_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            last_enqueued_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            last_enqueue_source TEXT NOT NULL DEFAULT 'unknown',
            payload TEXT NOT NULL DEFAULT '{}',
            lease_run_id TEXT,
            lease_event_id TEXT,
            lease_owner TEXT,
            leased_at TEXT,
            lease_expires_at TEXT,
            acknowledged_at TEXT,
            completed_at TEXT,
            completed_run_id TEXT,
            last_error TEXT,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            retry_count INTEGER NOT NULL DEFAULT 0,
            UNIQUE(project_id, file_path),
            CHECK(queue_state IN ('pending', 'leased', 'done'))
        );
        INSERT INTO review_queue_items (
            id, project_id, event_id, dedupe_key, file_path, queue_state,
            first_enqueued_at, last_enqueued_at, last_enqueue_source, payload,
            lease_run_id, lease_event_id, lease_owner, leased_at, lease_expires_at,
            acknowledged_at, completed_at, completed_run_id, last_error,
            attempt_count, retry_count
        )
        SELECT
            id, project_id, event_id, dedupe_key, file_path, queue_state,
            first_enqueued_at, last_enqueued_at, last_enqueue_source, payload,
            lease_run_id, lease_event_id, lease_owner, leased_at, lease_expires_at,
            acknowledged_at, completed_at, completed_run_id, last_error,
            attempt_count, retry_count
        FROM review_queue_items__legacy_rebuild;
        DROP TABLE review_queue_items__legacy_rebuild;
        "#,
    )
    .map_err(|e| format!("failed to rebuild legacy review_queue_items: {e}"))
}

fn repair_legacy_review_runs(conn: &Connection) -> Result<(), String> {
    if has_required_table_structure(conn, "review_runs")? {
        return Ok(());
    }

    let columns = get_table_columns(conn, "review_runs")?;
    for required in ["id", "project_id", "run_id"] {
        if !columns.iter().any(|column| column == required) {
            return Ok(());
        }
    }

    conn.execute_batch(
        r#"
        ALTER TABLE review_runs RENAME TO review_runs__legacy_rebuild;
        CREATE TABLE review_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'started',
            phase TEXT,
            iteration INTEGER,
            kind TEXT,
            consumer TEXT,
            reviewer TEXT,
            file_count INTEGER NOT NULL DEFAULT 0,
            files_json TEXT NOT NULL DEFAULT '[]',
            findings_json TEXT NOT NULL DEFAULT '[]',
            summary TEXT,
            result_summary TEXT,
            blocker_summary TEXT,
            report_body TEXT,
            report_hash TEXT,
            error_message TEXT,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            completed_at TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            UNIQUE(project_id, run_id),
            CHECK(status IN ('started', 'completed', 'failed'))
        );
        INSERT INTO review_runs (
            id, project_id, run_id, status, phase, iteration, kind, consumer,
            reviewer, file_count, files_json, findings_json, summary,
            result_summary, blocker_summary, report_body, report_hash,
            error_message, metadata_json, started_at, completed_at, created_at,
            updated_at
        )
        SELECT
            id, project_id, run_id, status, phase, iteration, kind, consumer,
            reviewer, file_count, files_json, findings_json, summary,
            result_summary, blocker_summary, report_body, report_hash,
            error_message, metadata_json, started_at, completed_at, created_at,
            updated_at
        FROM review_runs__legacy_rebuild;
        DROP TABLE review_runs__legacy_rebuild;
        "#,
    )
    .map_err(|e| format!("failed to rebuild legacy review_runs: {e}"))
}

fn get_schema_version(conn: &Connection) -> Result<i64, String> {
    conn.query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(|e| format!("failed to read schema version: {e}"))
}

fn set_schema_version(conn: &Connection, version: i64) -> Result<(), String> {
    conn.pragma_update(None, "user_version", version)
        .map_err(|e| format!("failed to set schema version: {e}"))
}

fn validate_current_schema(conn: &Connection) -> Result<(), String> {
    if !has_required_tables_and_columns(conn)? {
        return Err("required tables or columns missing".to_string());
    }
    if !has_components_fts(conn)? {
        return Err("components_fts virtual table missing".to_string());
    }
    if !has_required_table_structures(conn)? {
        return Err("required table structures missing".to_string());
    }
    if !has_required_indexes(conn)? {
        return Err("required indexes missing".to_string());
    }
    Ok(())
}

fn has_required_tables_and_columns(conn: &Connection) -> Result<bool, String> {
    for table_def in REQUIRED_TABLE_COLUMNS {
        let columns = get_table_columns(conn, table_def.table)?;
        if columns.is_empty() {
            return Ok(false);
        }
        for required in table_def.columns {
            if !columns.iter().any(|column| column == required) {
                return Ok(false);
            }
        }
    }

    Ok(true)
}

fn has_components_fts(conn: &Connection) -> Result<bool, String> {
    let exists: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'components_fts' LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| format!("failed to inspect components_fts: {e}"))?;
    Ok(exists.is_some())
}

fn has_required_table_structures(conn: &Connection) -> Result<bool, String> {
    for definition in REQUIRED_TABLE_STRUCTURES {
        if !has_required_table_structure(conn, definition.table)? {
            return Ok(false);
        }
    }

    Ok(true)
}

fn has_required_table_structure(conn: &Connection, table: &str) -> Result<bool, String> {
    let definition = match REQUIRED_TABLE_STRUCTURES
        .iter()
        .find(|definition| definition.table == table)
    {
        Some(definition) => definition,
        None => return Ok(true),
    };

    let sql: Option<String> = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1",
            rusqlite::params![definition.table],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| format!("failed to inspect table {}: {e}", definition.table))?;
    let normalized = normalize_sql(sql.as_deref());
    for fragment in definition.required_fragments {
        if !normalized.contains(&normalize_sql(Some(fragment))) {
            return Ok(false);
        }
    }

    Ok(true)
}

fn has_required_indexes(conn: &Connection) -> Result<bool, String> {
    for definition in INDEX_DEFINITIONS {
        let sql: Option<String> = conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?1 LIMIT 1",
                rusqlite::params![definition.name],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| format!("failed to inspect index {}: {e}", definition.name))?;
        if normalize_sql(sql.as_deref()) != normalize_sql(Some(definition.sql)) {
            return Ok(false);
        }
    }

    Ok(true)
}

fn normalize_sql(sql: Option<&str>) -> String {
    sql.unwrap_or("")
        .replace("IF NOT EXISTS", "")
        .replace("if not exists", "")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

// ---------------------------------------------------------------------------
// Index SQL
// ---------------------------------------------------------------------------

const INDEX_DEFINITIONS: &[IndexDef] = &[
    IndexDef {
        name: "idx_components_project_file_path",
        sql: "CREATE INDEX IF NOT EXISTS idx_components_project_file_path ON components(project_id, file_path, semantic_id ASC)",
    },
    IndexDef {
        name: "idx_components_project_status_updated",
        sql: "CREATE INDEX IF NOT EXISTS idx_components_project_status_updated ON components(project_id, status, updated_at DESC)",
    },
    IndexDef {
        name: "idx_components_project_name_status_updated",
        sql: "CREATE INDEX IF NOT EXISTS idx_components_project_name_status_updated ON components(project_id, name, status, updated_at DESC, semantic_id ASC)",
    },
    IndexDef {
        name: "idx_capsules_project_task_phase_created_at",
        sql: "CREATE INDEX IF NOT EXISTS idx_capsules_project_task_phase_created_at ON capsules(project_id, task_id, phase, created_at DESC, id DESC)",
    },
    IndexDef {
        name: "idx_review_queue_items_project_state",
        sql: "CREATE INDEX IF NOT EXISTS idx_review_queue_items_project_state ON review_queue_items(project_id, queue_state, first_enqueued_at ASC, id ASC)",
    },
    IndexDef {
        name: "idx_review_queue_items_project_lease_expiry",
        sql: "CREATE INDEX IF NOT EXISTS idx_review_queue_items_project_lease_expiry ON review_queue_items(project_id, lease_expires_at)",
    },
    IndexDef {
        name: "idx_review_queue_items_project_event",
        sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_review_queue_items_project_event ON review_queue_items(project_id, event_id) WHERE event_id IS NOT NULL",
    },
    IndexDef {
        name: "idx_review_queue_items_project_dedupe_active",
        sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_review_queue_items_project_dedupe_active ON review_queue_items(project_id, dedupe_key) WHERE dedupe_key IS NOT NULL AND queue_state IN ('pending', 'leased')",
    },
    IndexDef {
        name: "idx_review_runs_project_updated",
        sql: "CREATE INDEX IF NOT EXISTS idx_review_runs_project_updated ON review_runs(project_id, updated_at DESC, id DESC)",
    },
    IndexDef {
        name: "idx_review_runs_project_phase_kind",
        sql: "CREATE INDEX IF NOT EXISTS idx_review_runs_project_phase_kind ON review_runs(project_id, phase, kind, created_at DESC)",
    },
];

const INDEX_SQL: &str = r#"
CREATE INDEX IF NOT EXISTS idx_components_project_file_path
    ON components(project_id, file_path, semantic_id ASC);

CREATE INDEX IF NOT EXISTS idx_components_project_status_updated
    ON components(project_id, status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_components_project_name_status_updated
    ON components(project_id, name, status, updated_at DESC, semantic_id ASC);

CREATE INDEX IF NOT EXISTS idx_capsules_project_task_phase_created_at
    ON capsules(project_id, task_id, phase, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_review_queue_items_project_state
    ON review_queue_items(project_id, queue_state, first_enqueued_at ASC, id ASC);

CREATE INDEX IF NOT EXISTS idx_review_queue_items_project_lease_expiry
    ON review_queue_items(project_id, lease_expires_at);

CREATE UNIQUE INDEX IF NOT EXISTS idx_review_queue_items_project_event
    ON review_queue_items(project_id, event_id)
    WHERE event_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_review_queue_items_project_dedupe_active
    ON review_queue_items(project_id, dedupe_key)
    WHERE dedupe_key IS NOT NULL AND queue_state IN ('pending', 'leased');

CREATE INDEX IF NOT EXISTS idx_review_runs_project_updated
    ON review_runs(project_id, updated_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_review_runs_project_phase_kind
    ON review_runs(project_id, phase, kind, created_at DESC);
"#;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_in_memory_and_migrate() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        run_migrations(&conn).expect("migrations");
        let tables = assert_required_tables(&conn).expect("required tables");
        assert!(tables.contains(&"components".to_string()));
        assert!(tables.contains(&"review_runs".to_string()));
    }

    #[test]
    fn list_tables_after_migration() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        run_migrations(&conn).expect("migrations");
        let tables = list_tables(&conn).expect("list");
        assert!(tables.len() >= 7);
    }

    #[test]
    fn run_migrations_upgrades_legacy_review_tables() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        conn.execute_batch(
            "
            CREATE TABLE registry_deltas (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                delta_type TEXT NOT NULL,
                semantic_id TEXT,
                payload TEXT NOT NULL,
                applied_at TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE(project_id, idempotency_key)
            );
            CREATE TABLE review_queue_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                queue_state TEXT NOT NULL DEFAULT 'pending',
                first_enqueued_at TEXT NOT NULL DEFAULT '2026-04-01T00:00:00Z',
                last_enqueued_at TEXT NOT NULL DEFAULT '2026-04-01T00:00:00Z',
                last_enqueue_source TEXT NOT NULL DEFAULT 'legacy',
                payload TEXT NOT NULL DEFAULT '{}',
                attempt_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE review_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                run_id TEXT NOT NULL,
                summary TEXT
            );
            INSERT INTO review_queue_items (
                project_id,
                file_path,
                queue_state,
                first_enqueued_at,
                last_enqueued_at,
                last_enqueue_source,
                payload,
                attempt_count
            ) VALUES (
                'proj1',
                'src/review/legacy.ts',
                'pending',
                '2026-04-01T00:00:00Z',
                '2026-04-01T00:00:00Z',
                'legacy',
                '{}',
                0
            );
            INSERT INTO review_runs (
                project_id,
                run_id,
                summary
            ) VALUES (
                'proj1',
                'legacy-run-001',
                'legacy summary'
            );
            ",
        )
        .expect("legacy schema");

        run_migrations(&conn).expect("migrations");

        let queue_columns = get_table_columns(&conn, "review_queue_items").expect("queue columns");
        let run_columns = get_table_columns(&conn, "review_runs").expect("run columns");
        assert!(queue_columns.contains(&"event_id".to_string()));
        assert!(queue_columns.contains(&"lease_event_id".to_string()));
        assert!(queue_columns.contains(&"acknowledged_at".to_string()));
        assert!(queue_columns.contains(&"retry_count".to_string()));
        assert!(run_columns.contains(&"phase".to_string()));
        assert!(run_columns.contains(&"result_summary".to_string()));
        assert!(run_columns.contains(&"report_body".to_string()));
        assert!(run_columns.contains(&"updated_at".to_string()));

        let (dedupe_key, retry_count): (Option<String>, i64) = conn
            .query_row(
                "SELECT dedupe_key, retry_count
                 FROM review_queue_items
                 WHERE project_id = ?1 AND file_path = ?2",
                rusqlite::params!["proj1", "src/review/legacy.ts"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("legacy row");
        let result_summary: Option<String> = conn
            .query_row(
                "SELECT result_summary
                 FROM review_runs
                 WHERE project_id = ?1 AND run_id = ?2",
                rusqlite::params!["proj1", "legacy-run-001"],
                |row| row.get(0),
            )
            .expect("legacy run row");
        assert_eq!(dedupe_key.as_deref(), Some("src/review/legacy.ts"));
        assert_eq!(retry_count, 0);
        assert_eq!(result_summary.as_deref(), Some("legacy summary"));
    }

    #[test]
    fn run_migrations_marks_current_schema_and_fast_paths_subsequent_runs() {
        let conn = Connection::open_in_memory().expect("open in-memory db");

        let first = run_migrations(&conn).expect("first migration");
        let second = run_migrations(&conn).expect("second migration");
        let user_version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .expect("user_version");

        assert_eq!(
            first,
            MigrationResult {
                path: MigrationPath::Full,
                schema_version: CURRENT_SCHEMA_VERSION,
            }
        );
        assert_eq!(
            second,
            MigrationResult {
                path: MigrationPath::FastPath,
                schema_version: CURRENT_SCHEMA_VERSION,
            }
        );
        assert_eq!(user_version, CURRENT_SCHEMA_VERSION);
    }

    #[test]
    fn run_migrations_replays_legacy_schema_even_with_current_marker() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        conn.execute_batch(
            "
            CREATE TABLE review_queue_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                queue_state TEXT NOT NULL DEFAULT 'pending',
                first_enqueued_at TEXT NOT NULL,
                last_enqueued_at TEXT NOT NULL,
                last_enqueue_source TEXT NOT NULL DEFAULT 'legacy',
                payload TEXT NOT NULL DEFAULT '{}',
                attempt_count INTEGER NOT NULL DEFAULT 0,
                UNIQUE(project_id, file_path)
            );
            CREATE TABLE review_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                run_id TEXT NOT NULL,
                summary TEXT
            );
            PRAGMA user_version = 1;
            ",
        )
        .expect("legacy schema with mismatched marker");

        let result = run_migrations(&conn).expect("migrations");
        let queue_columns = get_table_columns(&conn, "review_queue_items").expect("queue columns");
        let run_columns = get_table_columns(&conn, "review_runs").expect("run columns");

        assert_eq!(
            result,
            MigrationResult {
                path: MigrationPath::Full,
                schema_version: CURRENT_SCHEMA_VERSION,
            }
        );
        assert!(queue_columns.contains(&"event_id".to_string()));
        assert!(queue_columns.contains(&"dedupe_key".to_string()));
        assert!(queue_columns.contains(&"lease_event_id".to_string()));
        assert!(queue_columns.contains(&"acknowledged_at".to_string()));
        assert!(queue_columns.contains(&"retry_count".to_string()));
        assert!(run_columns.contains(&"phase".to_string()));
        assert!(run_columns.contains(&"result_summary".to_string()));
        assert!(run_columns.contains(&"report_body".to_string()));
        assert!(run_columns.contains(&"updated_at".to_string()));
    }

    #[test]
    fn run_migrations_does_not_fast_path_when_registry_deltas_lacks_applied_at() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        assert_eq!(
            run_migrations(&conn).expect("initial migration"),
            MigrationResult {
                path: MigrationPath::Full,
                schema_version: CURRENT_SCHEMA_VERSION,
            }
        );

        conn.execute_batch(
            "
            ALTER TABLE registry_deltas RENAME TO registry_deltas_old;
            CREATE TABLE registry_deltas (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                delta_type TEXT NOT NULL,
                semantic_id TEXT,
                payload TEXT NOT NULL,
                UNIQUE(project_id, idempotency_key)
            );
            INSERT INTO registry_deltas (id, project_id, idempotency_key, delta_type, semantic_id, payload)
            SELECT id, project_id, idempotency_key, delta_type, semantic_id, payload
            FROM registry_deltas_old;
            DROP TABLE registry_deltas_old;
            PRAGMA user_version = 1;
            ",
        )
        .expect("registry_deltas without applied_at");

        let first = run_migrations(&conn);
        let second = run_migrations(&conn);
        let columns = get_table_columns(&conn, "registry_deltas").expect("registry_deltas columns");
        let user_version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .expect("user_version");

        assert!(first.is_err());
        assert!(second.is_err());
        assert_eq!(user_version, 0);
        assert!(columns.contains(&"applied_at".to_string()));
    }

    #[test]
    fn run_migrations_does_not_fast_path_when_review_runs_lacks_constraints() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        assert_eq!(
            run_migrations(&conn).expect("initial migration"),
            MigrationResult {
                path: MigrationPath::Full,
                schema_version: CURRENT_SCHEMA_VERSION,
            }
        );

        conn.execute_batch(
            "
            ALTER TABLE review_runs RENAME TO review_runs_old;
            CREATE TABLE review_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                run_id TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'started',
                phase TEXT,
                iteration INTEGER,
                kind TEXT,
                consumer TEXT,
                reviewer TEXT,
                file_count INTEGER NOT NULL DEFAULT 0,
                files_json TEXT NOT NULL DEFAULT '[]',
                findings_json TEXT NOT NULL DEFAULT '[]',
                summary TEXT,
                result_summary TEXT,
                blocker_summary TEXT,
                report_body TEXT,
                report_hash TEXT,
                error_message TEXT,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
                completed_at TEXT,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            );
            INSERT INTO review_runs (
                id, project_id, run_id, status, phase, iteration, kind, consumer, reviewer, file_count,
                files_json, findings_json, summary, result_summary, blocker_summary, report_body, report_hash,
                error_message, metadata_json, started_at, completed_at, created_at, updated_at
            )
            SELECT
                id, project_id, run_id, status, phase, iteration, kind, consumer, reviewer, file_count,
                files_json, findings_json, summary, result_summary, blocker_summary, report_body, report_hash,
                error_message, metadata_json, started_at, completed_at, created_at, updated_at
            FROM review_runs_old;
            DROP TABLE review_runs_old;
            PRAGMA user_version = 1;
            ",
        )
        .expect("review_runs without constraints");

        let first = run_migrations(&conn).expect("first replay");
        let second = run_migrations(&conn).expect("second replay");
        let review_runs_sql: String = conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'review_runs'",
                [],
                |row| row.get(0),
            )
            .expect("review_runs sql");

        assert_eq!(
            first,
            MigrationResult {
                path: MigrationPath::Full,
                schema_version: CURRENT_SCHEMA_VERSION,
            }
        );
        assert_eq!(
            second,
            MigrationResult {
                path: MigrationPath::FastPath,
                schema_version: CURRENT_SCHEMA_VERSION,
            }
        );
        assert!(review_runs_sql.contains("UNIQUE(project_id, run_id)"));
        assert!(review_runs_sql.contains("CHECK(status IN ('started', 'completed', 'failed'))"));
    }

    #[test]
    fn migrations_fail_closed_on_invalid_schema_user_version_zero() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        conn.execute_batch(
            "
            CREATE TABLE registry_deltas (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                delta_type TEXT NOT NULL,
                semantic_id TEXT,
                payload TEXT NOT NULL,
                applied_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00Z',
                UNIQUE(project_id, idempotency_key)
            );
            PRAGMA user_version = 0;
            ",
        )
        .expect("invalid registry_deltas schema");

        let result = run_migrations(&conn);
        let user_version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .expect("user_version");

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("schema validation failed"));
        assert_eq!(user_version, 0);
    }

    #[test]
    fn migrations_fail_closed_when_components_lacks_semantic_id_unique() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        assert_eq!(
            run_migrations(&conn).expect("initial migration"),
            MigrationResult {
                path: MigrationPath::Full,
                schema_version: CURRENT_SCHEMA_VERSION,
            }
        );

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
            INSERT INTO components (
                id, project_id, semantic_id, name, module, file_path, kind,
                exports, imports, hash, figma_ref, status, inactive_reason,
                security_level, idem, updated_at
            )
            SELECT
                id, project_id, semantic_id, name, module, file_path, kind,
                exports, imports, hash, figma_ref, status, inactive_reason,
                security_level, idem, updated_at
            FROM components_old;
            DROP TABLE components_old;
            PRAGMA user_version = 1;
            ",
        )
        .expect("components without unique");

        let result = run_migrations(&conn);
        let user_version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .expect("user_version");

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("schema validation failed"));
        assert_eq!(user_version, 0);
    }
}
