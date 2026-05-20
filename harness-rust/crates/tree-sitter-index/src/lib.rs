//! # tree-sitter-index
//!
//! Tree-sitter based symbol indexing and impact analysis for the agent_base
//! system.
//!
//! This crate provides:
//!
//! - **Symbol extraction** from source files using tree-sitter grammars
//! - **Incremental indexing** with file-hash and grammar-version caching
//! - **Impact analysis** via BFS traversal of the dependency graph
//! - **Language-specific extractors** behind feature gates
//!
//! # Features
//!
//! | Feature | Languages |
//! |---|---|
//! | `lang-rust` (default) | Rust |
//! | `lang-typescript` (default) | TypeScript, JavaScript |
//! | `lang-python` (default) | Python |
//! | `lang-go` | Go |
//! | `lang-shell` | Bash/Shell |
//! | `all-languages` | All of the above |
//!
//! # Path-based API
//!
//! For consumers that do not manage their own database connection (e.g.
//! `agent-core`), use the `*_at_path` convenience functions which open,
//! migrate, and close the database automatically.

pub mod db;
pub mod extractors;
pub mod incremental;
pub mod parser;
pub mod types;

// Re-export primary types at the crate root.
pub use incremental::should_force_full_review;
pub use types::{
    DependencyKind, ImpactReport, IndexConfig, IndexResult, Symbol, SymbolDependency, SymbolKind,
};

use std::path::PathBuf;

use rusqlite::Connection;
use shared::error::AgentError;

// ---------------------------------------------------------------------------
// Path-based convenience API
// ---------------------------------------------------------------------------

/// Open a SQLite connection at the given path, run migrations, and return it.
fn open_and_migrate(db_path: &str) -> shared::error::Result<Connection> {
    let path = std::path::Path::new(db_path);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(AgentError::Io)?;
    }

    let conn = Connection::open(path)
        .map_err(|e| AgentError::Database(format!("failed to open database: {e}")))?;

    conn.pragma_update(None, "journal_mode", "WAL")
        .map_err(|e| AgentError::Database(format!("failed to set WAL mode: {e}")))?;
    conn.pragma_update(None, "synchronous", "NORMAL")
        .map_err(|e| AgentError::Database(format!("failed to set synchronous: {e}")))?;
    conn.pragma_update(None, "busy_timeout", 30000)
        .map_err(|e| AgentError::Database(format!("failed to set busy timeout: {e}")))?;

    db::run_tree_sitter_migrations(&conn)?;
    Ok(conn)
}

/// Index source files using a database at the given path.
///
/// Each entry in `files` is `(file_path, language, file_hash)`.
/// Opens the database, runs migrations, indexes files, and returns the result.
pub fn index_files_at_path(
    db_path: &str,
    project_id: &str,
    files: &[(PathBuf, String, String)],
    config: &IndexConfig,
    gc_orphans: bool,
) -> shared::error::Result<IndexResult> {
    let mut conn = open_and_migrate(db_path)?;
    incremental::index_files(&mut conn, project_id, files, config, gc_orphans)
}

/// Perform impact analysis using a database at the given path.
///
/// Opens the database, runs migrations, and performs BFS impact analysis
/// starting from symbols in the changed files.
pub fn impact_analysis_at_path(
    db_path: &str,
    project_id: &str,
    changed_files: &[&str],
    max_depth: u32,
    max_nodes: u32,
) -> shared::error::Result<ImpactReport> {
    let conn = open_and_migrate(db_path)?;
    incremental::impact_analysis(&conn, project_id, changed_files, max_depth, max_nodes)
}

/// Remove all symbols for a file using a database at the given path.
///
/// Opens the database, runs migrations, and removes all symbols and
/// dependencies associated with the specified file.
pub fn remove_file_symbols_at_path(
    db_path: &str,
    project_id: &str,
    file_path: &str,
) -> shared::error::Result<()> {
    let conn = open_and_migrate(db_path)?;
    db::remove_file_symbols(&conn, project_id, file_path)
}
