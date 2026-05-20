//! Database layer for symbol storage and retrieval.
//!
//! Manages SQLite tables for symbols, symbol dependencies, and file parse
//! cache. Uses `DELETE-then-INSERT` within `IMMEDIATE` transactions for
//! upsert semantics.

use rusqlite::{params, Connection};
use shared::error::AgentError;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::types::{Symbol, SymbolKind};

/// A thin RAII wrapper around a manually-started IMMEDIATE transaction.
///
/// On drop, if `commit()` has not been called, the transaction is rolled back.
struct ImmediateTx<'a> {
    conn: &'a Connection,
    committed: bool,
}

impl<'a> ImmediateTx<'a> {
    fn begin(conn: &'a Connection) -> shared::error::Result<Self> {
        conn.execute_batch("BEGIN IMMEDIATE").map_err(|e| {
            AgentError::Database(format!("failed to begin immediate transaction: {e}"))
        })?;
        Ok(Self {
            conn,
            committed: false,
        })
    }

    fn commit(mut self) -> shared::error::Result<()> {
        self.conn
            .execute_batch("COMMIT")
            .map_err(|e| AgentError::Database(format!("failed to commit transaction: {e}")))?;
        self.committed = true;
        Ok(())
    }
}

impl<'a> Drop for ImmediateTx<'a> {
    fn drop(&mut self) {
        if !self.committed {
            let _ = self.conn.execute_batch("ROLLBACK");
        }
    }
}

/// Grammar version tied to the crate version for cache invalidation.
pub const GRAMMAR_VERSION: &str = env!("CARGO_PKG_VERSION");

// ---------------------------------------------------------------------------
// Migrations
// ---------------------------------------------------------------------------

/// Run idempotent schema migrations for tree-sitter index tables.
///
/// Creates the `_ts_meta`, `symbols`, `symbol_dependencies`, and
/// `file_parse_cache` tables if they do not already exist.
pub fn run_tree_sitter_migrations(conn: &Connection) -> shared::error::Result<()> {
    conn.execute_batch(
        "
        -- Schema version tracking
        CREATE TABLE IF NOT EXISTS _ts_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        INSERT OR REPLACE INTO _ts_meta (key, value)
        VALUES ('schema_version', '1');

        -- Symbols extracted from source files
        CREATE TABLE IF NOT EXISTS symbols (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id      TEXT    NOT NULL,
            file_path       TEXT    NOT NULL,
            file_hash       TEXT    NOT NULL,
            name            TEXT    NOT NULL,
            qualified_name  TEXT,
            kind            TEXT    NOT NULL,
            language        TEXT    NOT NULL,
            start_line      INTEGER NOT NULL,
            end_line        INTEGER NOT NULL,
            start_col       INTEGER NOT NULL,
            end_col         INTEGER NOT NULL,
            signature       TEXT,
            visibility      TEXT,
            parent_symbol_id INTEGER,
            body_hash       TEXT,
            updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
            FOREIGN KEY (parent_symbol_id) REFERENCES symbols(id)
        );

        CREATE INDEX IF NOT EXISTS idx_symbols_project_file
            ON symbols(project_id, file_path);
        CREATE INDEX IF NOT EXISTS idx_symbols_project_name
            ON symbols(project_id, name);
        CREATE INDEX IF NOT EXISTS idx_symbols_parent
            ON symbols(parent_symbol_id);

        -- Dependency edges between symbols
        CREATE TABLE IF NOT EXISTS symbol_dependencies (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id      TEXT    NOT NULL,
            from_symbol_id  INTEGER NOT NULL,
            to_symbol_id    INTEGER,
            to_name         TEXT    NOT NULL,
            kind            TEXT    NOT NULL,
            updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
            FOREIGN KEY (from_symbol_id) REFERENCES symbols(id),
            FOREIGN KEY (to_symbol_id)   REFERENCES symbols(id),
            UNIQUE(project_id, from_symbol_id, to_name, kind)
        );

        CREATE INDEX IF NOT EXISTS idx_deps_from
            ON symbol_dependencies(from_symbol_id);
        CREATE INDEX IF NOT EXISTS idx_deps_to
            ON symbol_dependencies(to_symbol_id);
        CREATE INDEX IF NOT EXISTS idx_deps_project
            ON symbol_dependencies(project_id);

        -- File parse cache for incremental indexing
        CREATE TABLE IF NOT EXISTS file_parse_cache (
            project_id        TEXT    NOT NULL,
            file_path         TEXT    NOT NULL,
            file_hash         TEXT    NOT NULL,
            grammar_version   TEXT    NOT NULL,
            parsed_at         TEXT    NOT NULL,
            symbol_count      INTEGER NOT NULL DEFAULT 0,
            parse_duration_ms INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (project_id, file_path)
        );

        INSERT OR IGNORE INTO _ts_meta (key, value)
        VALUES ('index_version', '0');
        ",
    )
    .map_err(|e| AgentError::Database(format!("failed to run tree-sitter migrations: {e}")))?;

    let cols: Vec<String> = conn
        .prepare("PRAGMA table_info(file_parse_cache)")
        .map_err(|e| AgentError::Database(format!("failed to inspect file_parse_cache: {e}")))?
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| AgentError::Database(format!("failed to read file_parse_cache schema: {e}")))?
        .filter_map(|row| row.ok())
        .collect();

    if !cols.iter().any(|col| col == "updated_at_unix_ms") {
        conn.execute_batch(
            "
            ALTER TABLE file_parse_cache
                ADD COLUMN updated_at_unix_ms INTEGER NOT NULL DEFAULT 0;

            UPDATE file_parse_cache
               SET updated_at_unix_ms = COALESCE(
                   CAST(strftime('%s', parsed_at) AS INTEGER) * 1000,
                   0
               )
             WHERE updated_at_unix_ms = 0;
            ",
        )
        .map_err(|e| {
            AgentError::Database(format!(
                "failed to add file_parse_cache.updated_at_unix_ms: {e}"
            ))
        })?;
    }

    Ok(())
}

fn current_unix_ms() -> shared::error::Result<u64> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| AgentError::State(format!("system clock is before unix epoch: {e}")))?;
    u64::try_from(duration.as_millis())
        .map_err(|_| AgentError::State("unix timestamp milliseconds overflowed u64".into()))
}

fn unix_ms_to_i64(unix_ms: u64, label: &str) -> shared::error::Result<i64> {
    i64::try_from(unix_ms).map_err(|_| {
        AgentError::Database(format!("{label} exceeds SQLite INTEGER range: {unix_ms}"))
    })
}

// ---------------------------------------------------------------------------
// Symbol CRUD
// ---------------------------------------------------------------------------

/// Replace all symbols for a file with new ones in an IMMEDIATE transaction.
///
/// Deletes existing symbols (and their dependencies) for the given file,
/// then inserts the new symbols. Returns the inserted symbol IDs.
pub fn upsert_symbols(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
    file_hash: &str,
    symbols: &[(crate::types::RawSymbol, Option<i64>)],
) -> shared::error::Result<Vec<i64>> {
    let tx = ImmediateTx::begin(conn)?;
    let ids = do_upsert_symbols_inner(tx.conn, project_id, file_path, file_hash, symbols)?;
    tx.commit()?;
    Ok(ids)
}

fn do_upsert_symbols_inner(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
    file_hash: &str,
    symbols: &[(crate::types::RawSymbol, Option<i64>)],
) -> shared::error::Result<Vec<i64>> {
    // Delete existing symbols for this file.
    remove_file_symbols_inner(conn, project_id, file_path)?;

    let mut ids = Vec::with_capacity(symbols.len());

    for (raw, parent_id) in symbols {
        let id = insert_symbol(conn, project_id, file_path, file_hash, raw, *parent_id)?;
        ids.push(id);

        // Insert children (e.g. methods in an impl block).
        for child in &raw.children {
            let child_id = insert_symbol(conn, project_id, file_path, file_hash, child, Some(id))?;
            ids.push(child_id);
        }
    }

    Ok(ids)
}

pub fn upsert_symbols_in_tx(
    tx: &rusqlite::Transaction,
    project_id: &str,
    file_path: &str,
    file_hash: &str,
    symbols: &[(crate::types::RawSymbol, Option<i64>)],
) -> shared::error::Result<Vec<i64>> {
    do_upsert_symbols_inner(tx, project_id, file_path, file_hash, symbols)
}

/// Insert a single symbol row and return its ID.
fn insert_symbol(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
    file_hash: &str,
    raw: &crate::types::RawSymbol,
    parent_id: Option<i64>,
) -> shared::error::Result<i64> {
    conn.execute(
        "INSERT INTO symbols (
            project_id, file_path, file_hash, name, qualified_name,
            kind, language, start_line, end_line, start_col, end_col,
            signature, visibility, parent_symbol_id, body_hash
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
        params![
            project_id,
            file_path,
            file_hash,
            raw.name,
            raw.qualified_name,
            raw.kind.to_string(),
            raw.language,
            raw.start_line,
            raw.end_line,
            raw.start_col,
            raw.end_col,
            raw.signature,
            raw.visibility,
            parent_id,
            raw.body_hash,
        ],
    )
    .map_err(|e| AgentError::Database(format!("failed to insert symbol: {e}")))?;

    Ok(conn.last_insert_rowid())
}

/// Insert dependency records for a project.
pub fn upsert_dependencies(
    conn: &Connection,
    project_id: &str,
    deps: &[(i64, crate::extractors::RawDependency)],
) -> shared::error::Result<()> {
    let tx = ImmediateTx::begin(conn)?;
    do_upsert_dependencies_inner(tx.conn, project_id, deps)?;
    tx.commit()?;
    Ok(())
}

fn do_upsert_dependencies_inner(
    conn: &Connection,
    project_id: &str,
    deps: &[(i64, crate::extractors::RawDependency)],
) -> shared::error::Result<()> {
    for (from_id, dep) in deps {
        conn.execute(
            "INSERT OR IGNORE INTO symbol_dependencies (project_id, from_symbol_id, to_symbol_id, to_name, kind)
             VALUES (?1, ?2, NULL, ?3, ?4)",
            params![project_id, from_id, dep.to_name, dep.kind.to_string()],
        )
        .map_err(|e| AgentError::Database(format!("failed to insert dependency: {e}")))?;
    }
    Ok(())
}

pub fn upsert_dependencies_in_tx(
    tx: &rusqlite::Transaction,
    project_id: &str,
    deps: &[(i64, crate::extractors::RawDependency)],
) -> shared::error::Result<()> {
    do_upsert_dependencies_inner(tx, project_id, deps)
}

/// Replace all symbols **and** dependencies for a file in one IMMEDIATE transaction.
///
/// This is the preferred entry point for callers that have both symbols and
/// dependencies ready at the same time (avoids a second transaction).
pub fn upsert_file_symbols(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
    file_hash: &str,
    symbols: &[(crate::types::RawSymbol, Option<i64>)],
    dependencies: &[(i64, crate::extractors::RawDependency)],
) -> shared::error::Result<Vec<i64>> {
    let tx = ImmediateTx::begin(conn)?;

    let ids = do_upsert_symbols_inner(tx.conn, project_id, file_path, file_hash, symbols)?;
    do_upsert_dependencies_inner(tx.conn, project_id, dependencies)?;

    tx.commit()?;
    Ok(ids)
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/// Return all symbols in a given file.
pub fn symbols_in_file(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
) -> shared::error::Result<Vec<Symbol>> {
    let mut stmt = conn
        .prepare(
            "SELECT id, file_path, file_hash, name, qualified_name, kind, language,
                    start_line, end_line, start_col, end_col, signature, visibility,
                    parent_symbol_id, body_hash
             FROM symbols
             WHERE project_id = ?1 AND file_path = ?2
             ORDER BY start_line",
        )
        .map_err(|e| AgentError::Database(format!("failed to prepare query: {e}")))?;

    let rows = stmt
        .query_map(params![project_id, file_path], row_to_symbol)
        .map_err(|e| AgentError::Database(format!("failed to query symbols: {e}")))?;

    collect_rows(rows)
}

/// Return all symbols matching a given name within a project.
pub fn symbols_by_name(
    conn: &Connection,
    project_id: &str,
    name: &str,
) -> shared::error::Result<Vec<Symbol>> {
    let mut stmt = conn
        .prepare(
            "SELECT id, file_path, file_hash, name, qualified_name, kind, language,
                    start_line, end_line, start_col, end_col, signature, visibility,
                    parent_symbol_id, body_hash
             FROM symbols
             WHERE project_id = ?1 AND name = ?2
             ORDER BY file_path, start_line",
        )
        .map_err(|e| AgentError::Database(format!("failed to prepare query: {e}")))?;

    let rows = stmt
        .query_map(params![project_id, name], row_to_symbol)
        .map_err(|e| AgentError::Database(format!("failed to query symbols by name: {e}")))?;

    collect_rows(rows)
}

/// Return all symbols that depend on the given symbol (reverse dependencies).
pub fn dependents_of(conn: &Connection, symbol_id: i64) -> shared::error::Result<Vec<Symbol>> {
    let mut stmt = conn
        .prepare(
            "SELECT s.id, s.file_path, s.file_hash, s.name, s.qualified_name, s.kind,
                    s.language, s.start_line, s.end_line, s.start_col, s.end_col,
                    s.signature, s.visibility, s.parent_symbol_id, s.body_hash
             FROM symbols s
             INNER JOIN symbol_dependencies d ON d.from_symbol_id = s.id
             WHERE d.to_symbol_id = ?1
             ORDER BY s.file_path, s.start_line",
        )
        .map_err(|e| AgentError::Database(format!("failed to prepare dependents query: {e}")))?;

    let rows = stmt
        .query_map(params![symbol_id], row_to_symbol)
        .map_err(|e| AgentError::Database(format!("failed to query dependents: {e}")))?;

    collect_rows(rows)
}

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

/// Check whether a file has been parsed with the current grammar version
/// and its content hash has not changed.
pub fn is_file_cached(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
    file_hash: &str,
    grammar_version: &str,
) -> shared::error::Result<bool> {
    let mut stmt = conn
        .prepare(
            "SELECT COUNT(*) FROM file_parse_cache
             WHERE project_id = ?1
               AND file_path = ?2
               AND file_hash = ?3
               AND grammar_version = ?4",
        )
        .map_err(|e| AgentError::Database(format!("failed to prepare cache query: {e}")))?;

    let count: i64 = stmt
        .query_row(
            params![project_id, file_path, file_hash, grammar_version],
            |row| row.get(0),
        )
        .map_err(|e| AgentError::Database(format!("failed to check cache: {e}")))?;

    Ok(count > 0)
}

/// Values written to one `file_parse_cache` row.
pub struct ParseCacheUpdate<'a> {
    pub project_id: &'a str,
    pub file_path: &'a str,
    pub file_hash: &'a str,
    pub grammar_version: &'a str,
    pub symbol_count: u32,
    pub parse_duration_ms: u64,
    pub updated_at_unix_ms: u64,
}

/// Update the parse cache entry for a file.
pub fn update_parse_cache(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
    file_hash: &str,
    grammar_version: &str,
    symbol_count: u32,
    parse_duration_ms: u64,
) -> shared::error::Result<()> {
    let tx = ImmediateTx::begin(conn)?;
    let update = ParseCacheUpdate {
        project_id,
        file_path,
        file_hash,
        grammar_version,
        symbol_count,
        parse_duration_ms,
        updated_at_unix_ms: current_unix_ms()?,
    };
    do_update_parse_cache_inner(tx.conn, &update)?;
    tx.commit()?;
    Ok(())
}

fn do_update_parse_cache_inner(
    conn: &Connection,
    update: &ParseCacheUpdate<'_>,
) -> shared::error::Result<()> {
    let updated_at_unix_ms =
        unix_ms_to_i64(update.updated_at_unix_ms, "updated_at_unix_ms")?;
    conn.execute(
        "INSERT OR REPLACE INTO file_parse_cache
         (project_id, file_path, file_hash, grammar_version, parsed_at, symbol_count,
          parse_duration_ms, updated_at_unix_ms)
         VALUES (?1, ?2, ?3, ?4, datetime('now'), ?5, ?6, ?7)",
        params![
            update.project_id,
            update.file_path,
            update.file_hash,
            update.grammar_version,
            update.symbol_count,
            update.parse_duration_ms,
            updated_at_unix_ms,
        ],
    )
    .map_err(|e| AgentError::Database(format!("failed to update parse cache: {e}")))?;

    Ok(())
}

pub fn update_parse_cache_in_tx(
    tx: &rusqlite::Transaction,
    update: &ParseCacheUpdate<'_>,
) -> shared::error::Result<()> {
    do_update_parse_cache_inner(tx, update)
}

pub fn read_index_version(conn: &Connection) -> shared::error::Result<u64> {
    do_read_index_version_inner(conn)
}

fn do_read_index_version_inner(conn: &Connection) -> shared::error::Result<u64> {
    let s: String = conn
        .query_row(
            "SELECT value FROM _ts_meta WHERE key = 'index_version'",
            [],
            |r| r.get(0),
        )
        .map_err(|e| AgentError::Database(format!("_ts_meta.index_version missing: {e}")))?;
    s.parse::<u64>()
        .map_err(|_| AgentError::Database(format!("_ts_meta.index_version is non-numeric: {s:?}")))
}

pub fn read_index_version_in_tx(tx: &rusqlite::Transaction) -> shared::error::Result<u64> {
    do_read_index_version_inner(tx)
}

pub fn increment_index_version_in_tx(tx: &rusqlite::Transaction) -> shared::error::Result<u64> {
    let current = do_read_index_version_inner(tx)?;
    let next = current
        .checked_add(1)
        .ok_or_else(|| AgentError::Database("_ts_meta.index_version overflow".into()))?;
    let affected = tx
        .execute(
            "UPDATE _ts_meta SET value = ?1 WHERE key = 'index_version'",
            [next.to_string()],
        )
        .map_err(|e| AgentError::Database(format!("failed to update index_version: {e}")))?;
    if affected != 1 {
        return Err(AgentError::Database(format!(
            "_ts_meta.index_version update affected {affected} rows (expected 1)"
        )));
    }
    Ok(next)
}

// ---------------------------------------------------------------------------
// Removal
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GcReport {
    pub removed_files: usize,
    pub removed_symbols: usize,
    pub removed_dependencies: usize,
}

/// Remove indexed files that are no longer present in the current snapshot.
///
/// A file is eligible only when its parse-cache generation predates the
/// caller's transaction start. This keeps rows written by a newer writer out
/// of the GC target set when callers coordinate via SQLite writer locks.
pub fn gc_symbols_not_in_snapshot_in_tx(
    tx: &rusqlite::Transaction,
    project_id: &str,
    snapshot_paths_absolute: &std::collections::HashSet<String>,
    tx_start_unix_ms: u64,
) -> shared::error::Result<GcReport> {
    let tx_start_unix_ms = unix_ms_to_i64(tx_start_unix_ms, "tx_start_unix_ms")?;
    let mut stmt = tx
        .prepare("SELECT DISTINCT file_path FROM symbols WHERE project_id = ?1")
        .map_err(|e| AgentError::Database(format!("failed to prepare GC file query: {e}")))?;
    let rows = stmt
        .query_map(params![project_id], |row| row.get::<_, String>(0))
        .map_err(|e| AgentError::Database(format!("failed to query GC file paths: {e}")))?;

    let mut report = GcReport::default();
    for row in rows {
        let file_path =
            row.map_err(|e| AgentError::Database(format!("failed to read GC file path: {e}")))?;
        if snapshot_paths_absolute.contains(&file_path) {
            continue;
        }

        let eligible_cache_rows: i64 = tx
            .query_row(
                "SELECT COUNT(*) FROM file_parse_cache
                 WHERE project_id = ?1
                   AND file_path = ?2
                   AND updated_at_unix_ms < ?3",
                params![project_id, file_path, tx_start_unix_ms],
                |row| row.get(0),
            )
            .map_err(|e| {
                AgentError::Database(format!("failed to check GC generation guard: {e}"))
            })?;
        if eligible_cache_rows == 0 {
            continue;
        }

        let removed_from_deps = tx
            .execute(
                "DELETE FROM symbol_dependencies
                 WHERE from_symbol_id IN (
                     SELECT id FROM symbols WHERE project_id = ?1 AND file_path = ?2
                 )",
                params![project_id, file_path],
            )
            .map_err(|e| AgentError::Database(format!("failed to delete GC from-deps: {e}")))?;

        let removed_to_deps = tx
            .execute(
                "DELETE FROM symbol_dependencies
                 WHERE to_symbol_id IN (
                     SELECT id FROM symbols WHERE project_id = ?1 AND file_path = ?2
                 )",
                params![project_id, file_path],
            )
            .map_err(|e| AgentError::Database(format!("failed to delete GC to-deps: {e}")))?;

        let removed_symbols = tx
            .execute(
                "DELETE FROM symbols WHERE project_id = ?1 AND file_path = ?2",
                params![project_id, file_path],
            )
            .map_err(|e| AgentError::Database(format!("failed to delete GC symbols: {e}")))?;

        let removed_cache_rows = tx
            .execute(
                "DELETE FROM file_parse_cache WHERE project_id = ?1 AND file_path = ?2",
                params![project_id, file_path],
            )
            .map_err(|e| AgentError::Database(format!("failed to delete GC cache rows: {e}")))?;

        if removed_symbols > 0 || removed_cache_rows > 0 {
            report.removed_files += 1;
        }
        report.removed_symbols += removed_symbols;
        report.removed_dependencies += removed_from_deps + removed_to_deps;
    }

    Ok(report)
}

/// Remove all symbols and associated dependencies for a file.
///
/// Removes dependencies where the file's symbols appear on **either** side
/// of the edge (both `from_symbol_id` and `to_symbol_id`).
pub fn remove_file_symbols(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
) -> shared::error::Result<()> {
    let tx = ImmediateTx::begin(conn)?;

    remove_file_symbols_inner(tx.conn, project_id, file_path)?;

    tx.commit()?;
    Ok(())
}

/// Remove symbols and dependencies for a file (runs within a caller-managed transaction).
fn remove_file_symbols_inner(
    conn: &Connection,
    project_id: &str,
    file_path: &str,
) -> shared::error::Result<()> {
    // Delete dependencies where this file's symbols are the source.
    conn.execute(
        "DELETE FROM symbol_dependencies
         WHERE from_symbol_id IN (
             SELECT id FROM symbols WHERE project_id = ?1 AND file_path = ?2
         )",
        params![project_id, file_path],
    )
    .map_err(|e| AgentError::Database(format!("failed to delete from-dependencies: {e}")))?;

    // Delete dependencies where this file's symbols are the target.
    conn.execute(
        "DELETE FROM symbol_dependencies
         WHERE to_symbol_id IN (
             SELECT id FROM symbols WHERE project_id = ?1 AND file_path = ?2
         )",
        params![project_id, file_path],
    )
    .map_err(|e| AgentError::Database(format!("failed to delete to-dependencies: {e}")))?;

    // Delete the symbols themselves.
    conn.execute(
        "DELETE FROM symbols WHERE project_id = ?1 AND file_path = ?2",
        params![project_id, file_path],
    )
    .map_err(|e| AgentError::Database(format!("failed to delete symbols: {e}")))?;

    // Remove cache entry.
    conn.execute(
        "DELETE FROM file_parse_cache WHERE project_id = ?1 AND file_path = ?2",
        params![project_id, file_path],
    )
    .map_err(|e| AgentError::Database(format!("failed to delete cache entry: {e}")))?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

/// Resolve pending dependencies by matching `to_name` against known symbol names.
///
/// First tries exact `qualified_name` match (only if unambiguous), then falls
/// back to `name` match (only if exactly one match). Ambiguous dependencies
/// are left with `to_symbol_id = NULL`.
///
/// Returns `(resolved_count, ambiguous_count)`.
pub fn resolve_pending_dependencies(
    conn: &Connection,
    project_id: &str,
) -> shared::error::Result<(u32, u32)> {
    // Step 1: Resolve by qualified_name (exact match, unambiguous).
    let resolved_qualified = conn.execute(
        "UPDATE symbol_dependencies SET to_symbol_id = (
            SELECT s.id FROM symbols s
            WHERE s.project_id = ?1
              AND s.qualified_name = symbol_dependencies.to_name
        ) WHERE project_id = ?1 AND to_symbol_id IS NULL
          AND (SELECT COUNT(*) FROM symbols s WHERE s.project_id = ?1 AND s.qualified_name = symbol_dependencies.to_name) = 1",
        params![project_id],
    ).map_err(|e| AgentError::Database(e.to_string()))? as u32;

    // Step 2: Resolve by name (only if exactly 1 match).
    let resolved_name = conn.execute(
        "UPDATE symbol_dependencies SET to_symbol_id = (
            SELECT s.id FROM symbols s
            WHERE s.project_id = ?1
              AND s.name = symbol_dependencies.to_name
        ) WHERE project_id = ?1 AND to_symbol_id IS NULL
          AND (SELECT COUNT(*) FROM symbols s WHERE s.project_id = ?1 AND s.name = symbol_dependencies.to_name) = 1",
        params![project_id],
    ).map_err(|e| AgentError::Database(e.to_string()))? as u32;

    // Ambiguous ones stay NULL.
    let ambiguous: u32 = conn.query_row(
        "SELECT COUNT(*) FROM symbol_dependencies WHERE project_id = ?1 AND to_symbol_id IS NULL",
        params![project_id],
        |r| r.get(0),
    ).unwrap_or(0);

    Ok((resolved_qualified + resolved_name, ambiguous))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Map a database row to a [`Symbol`].
fn row_to_symbol(row: &rusqlite::Row) -> rusqlite::Result<Symbol> {
    let kind_str: String = row.get(5)?;
    let kind = kind_str
        .parse::<SymbolKind>()
        .unwrap_or(SymbolKind::Function);

    Ok(Symbol {
        id: row.get(0)?,
        file_path: row.get(1)?,
        file_hash: row.get(2)?,
        name: row.get(3)?,
        qualified_name: row.get(4)?,
        kind,
        language: row.get(6)?,
        start_line: row.get(7)?,
        end_line: row.get(8)?,
        start_col: row.get(9)?,
        end_col: row.get(10)?,
        signature: row.get(11)?,
        visibility: row.get(12)?,
        parent_symbol_id: row.get(13)?,
        body_hash: row.get(14)?,
    })
}

/// Collect query result rows into a `Vec<Symbol>`.
fn collect_rows(
    rows: rusqlite::MappedRows<'_, impl FnMut(&rusqlite::Row) -> rusqlite::Result<Symbol>>,
) -> shared::error::Result<Vec<Symbol>> {
    let mut result = Vec::new();
    for row in rows {
        let sym =
            row.map_err(|e| AgentError::Database(format!("failed to read symbol row: {e}")))?;
        result.push(sym);
    }
    Ok(result)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::RawSymbol;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        run_tree_sitter_migrations(&conn).unwrap();
        conn
    }

    fn make_raw_symbol(name: &str, kind: SymbolKind) -> RawSymbol {
        RawSymbol {
            name: name.to_string(),
            qualified_name: None,
            kind,
            language: "rust".to_string(),
            start_line: 1,
            end_line: 10,
            start_col: 0,
            end_col: 0,
            signature: None,
            visibility: None,
            body_hash: None,
            children: Vec::new(),
        }
    }

    #[test]
    fn migrations_create_all_tables() {
        let conn = setup_db();
        let mut stmt = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            .unwrap();
        let tables: Vec<String> = stmt
            .query_map([], |row| row.get(0))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect();
        assert!(tables.contains(&"symbols".to_string()));
        assert!(tables.contains(&"symbol_dependencies".to_string()));
        assert!(tables.contains(&"file_parse_cache".to_string()));
        assert!(tables.contains(&"_ts_meta".to_string()));
    }

    #[test]
    fn upsert_symbols_roundtrip() {
        let conn = setup_db();
        let raw = make_raw_symbol("my_func", SymbolKind::Function);
        let ids = upsert_symbols(&conn, "proj1", "src/main.rs", "abc123", &[(raw, None)]).unwrap();
        assert_eq!(ids.len(), 1);

        let syms = symbols_in_file(&conn, "proj1", "src/main.rs").unwrap();
        assert_eq!(syms.len(), 1);
        assert_eq!(syms[0].name, "my_func");
        assert_eq!(syms[0].kind, SymbolKind::Function);
        assert_eq!(syms[0].file_hash, "abc123");
    }

    #[test]
    fn upsert_replaces_existing() {
        let conn = setup_db();
        let raw1 = make_raw_symbol("old_func", SymbolKind::Function);
        upsert_symbols(&conn, "proj1", "src/lib.rs", "hash1", &[(raw1, None)]).unwrap();

        let raw2 = make_raw_symbol("new_func", SymbolKind::Function);
        upsert_symbols(&conn, "proj1", "src/lib.rs", "hash2", &[(raw2, None)]).unwrap();

        let syms = symbols_in_file(&conn, "proj1", "src/lib.rs").unwrap();
        assert_eq!(syms.len(), 1);
        assert_eq!(syms[0].name, "new_func");
    }

    #[test]
    fn remove_file_symbols_removes_both_dependency_sides() {
        let conn = setup_db();

        // Create symbols in two files.
        let raw_a = make_raw_symbol("func_a", SymbolKind::Function);
        let ids_a = upsert_symbols(&conn, "proj1", "a.rs", "h1", &[(raw_a, None)]).unwrap();

        let raw_b = make_raw_symbol("func_b", SymbolKind::Function);
        let ids_b = upsert_symbols(&conn, "proj1", "b.rs", "h2", &[(raw_b, None)]).unwrap();

        // Create a dependency: a -> b.
        conn.execute(
            "INSERT INTO symbol_dependencies (project_id, from_symbol_id, to_symbol_id, to_name, kind)
             VALUES ('proj1', ?1, ?2, 'func_b', 'calls')",
            params![ids_a[0], ids_b[0]],
        )
        .unwrap();

        // Remove file b — should clean up the dependency.
        remove_file_symbols(&conn, "proj1", "b.rs").unwrap();

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM symbol_dependencies", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(
            count, 0,
            "dependency should be removed when target file is removed"
        );
    }

    #[test]
    fn resolve_pending_dependencies_fills_to_symbol_id() {
        let conn = setup_db();

        let raw = make_raw_symbol("target_fn", SymbolKind::Function);
        let ids = upsert_symbols(&conn, "proj1", "lib.rs", "h1", &[(raw, None)]).unwrap();

        let raw_caller = make_raw_symbol("caller_fn", SymbolKind::Function);
        let caller_ids =
            upsert_symbols(&conn, "proj1", "main.rs", "h2", &[(raw_caller, None)]).unwrap();

        // Insert unresolved dependency.
        conn.execute(
            "INSERT INTO symbol_dependencies (project_id, from_symbol_id, to_symbol_id, to_name, kind)
             VALUES ('proj1', ?1, NULL, 'target_fn', 'calls')",
            params![caller_ids[0]],
        )
        .unwrap();

        let (resolved, _ambiguous) = resolve_pending_dependencies(&conn, "proj1").unwrap();
        assert!(resolved > 0);

        let to_id: Option<i64> = conn
            .query_row(
                "SELECT to_symbol_id FROM symbol_dependencies WHERE from_symbol_id = ?1",
                params![caller_ids[0]],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(to_id, Some(ids[0]));
    }

    #[test]
    fn is_file_cached_checks_hash_and_grammar_version() {
        let conn = setup_db();

        assert!(!is_file_cached(&conn, "proj1", "f.rs", "hash1", "0.1.0").unwrap());

        update_parse_cache(&conn, "proj1", "f.rs", "hash1", "0.1.0", 3, 42).unwrap();
        assert!(is_file_cached(&conn, "proj1", "f.rs", "hash1", "0.1.0").unwrap());

        // Different hash → not cached.
        assert!(!is_file_cached(&conn, "proj1", "f.rs", "hash2", "0.1.0").unwrap());

        // Different grammar version → not cached.
        assert!(!is_file_cached(&conn, "proj1", "f.rs", "hash1", "0.2.0").unwrap());
    }

    #[test]
    fn symbols_by_name_query() {
        let conn = setup_db();
        let raw = make_raw_symbol("find_me", SymbolKind::Function);
        upsert_symbols(&conn, "proj1", "a.rs", "h1", &[(raw, None)]).unwrap();

        let results = symbols_by_name(&conn, "proj1", "find_me").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "find_me");

        let empty = symbols_by_name(&conn, "proj1", "not_there").unwrap();
        assert!(empty.is_empty());
    }
}
