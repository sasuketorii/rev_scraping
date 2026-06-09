//! `context migrate-paths` — repo-relative path migration for existing
//! per-project semantic DBs (root-cause 2.2).
//!
//! Background: before the path flip, `symbols.file_path` and
//! `file_parse_cache.file_path` were stored ABSOLUTE (a home-absolute host
//! path). After the
//! flip the writer stores repo-relative paths (matching `components` and the
//! `scope_paths` / `path_prefix` query contract). Existing DBs still hold
//! absolute rows, so `sem.symbols.search` with a repo-relative `path_prefix`
//! returns 0 rows and host paths leak (I-1). This tool rewrites those rows to
//! repo-relative in place.
//!
//! Safety posture (mirrors orphan-GC / `admin_gc.rs`):
//! - **Dry-run is the DEFAULT.** `--apply` is required for any DB write.
//! - **Current project only.** The project_id is resolved from `.shared/project_id`
//!   and the DB path from `shared::paths::semantic_mcp_db_path`. No cross-project
//!   scan.
//! - **RSEM `application_id` guard.** The DB must carry the RevHarness marker.
//! - **Trusted root.** `repo_root` is read from `projects.root_path`; if it is
//!   blank/missing the tool REFUSES (never guesses a root).
//!
//! Strategy:
//! - Classify absolute vs relative row counts in both tables.
//! - `0 absolute` → no-op (idempotent).
//! - Rows whose absolute path is NOT under `root_path` (a collision/foreign row)
//!   → SQL-strip is unsafe; fall back to a full source reindex + orphan GC.
//! - Absolute-only and all under root, no relative collision → transactional SQL
//!   strip `substr(file_path, length(root)+2)` on both tables.
//! - Either way, increment `_ts_meta.index_version` once to invalidate in-flight
//!   context tokens.
//!
//! Post-verify: `SELECT COUNT(*) ... WHERE file_path GLOB '/*'` must be 0 for
//! both tables.

use std::path::{Path, PathBuf};

use rusqlite::Connection;
use serde::Serialize;
use shared::error::{AgentError, Result};

use super::context::{context_update, index_symbols_from_snapshot};

/// Outcome of a migrate-paths run (dry-run or apply).
#[derive(Debug, Clone, Serialize)]
pub struct MigratePathsReport {
    pub applied: bool,
    pub strategy: Strategy,
    pub symbols_absolute_before: i64,
    pub symbols_relative_before: i64,
    pub file_parse_cache_absolute_before: i64,
    pub file_parse_cache_relative_before: i64,
    /// Absolute rows whose path is NOT under the trusted repo_root (collision /
    /// foreign rows that block a safe SQL strip).
    pub rows_outside_root: i64,
    /// After apply: absolute rows remaining (must be 0). `None` for dry-run.
    pub symbols_absolute_after: Option<i64>,
    pub file_parse_cache_absolute_after: Option<i64>,
    /// repo_root is redacted in serialized evidence; never emit a raw
    /// home-absolute host path.
    pub repo_root_redacted: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Strategy {
    /// 0 absolute rows — nothing to do.
    NoOp,
    /// Absolute-only, all under root, no collision — transactional SQL strip.
    SqlStrip,
    /// Mixed / collision / rows outside root — full source reindex + GC.
    Reindex,
}

/// Entry point for `context migrate-paths`.
pub fn run(apply: bool, evidence: Option<&Path>) -> Result<MigratePathsReport> {
    let repo_root_cwd = shared::git::git_repo_root()
        .or_else(|_| std::env::current_dir().map_err(AgentError::Io))?;
    let project_id = super::project_id::read_project_id(&repo_root_cwd)?;
    let db_path = shared::paths::semantic_mcp_db_path(&project_id)?;

    if !db_path.exists() {
        return Err(AgentError::NotFound(format!(
            "semantic.db not found for project {project_id} at {}",
            db_path.display()
        )));
    }

    // RSEM application_id guard: refuse to touch a non-RevHarness DB.
    assert_rsem_marked(&db_path)?;

    let conn = Connection::open(&db_path)
        .map_err(|e| AgentError::Database(format!("failed to open semantic.db: {e}")))?;

    // Trusted root from projects.root_path. REFUSE if blank/missing.
    let trusted_root = read_trusted_root(&conn)?;
    let root_for_strip = normalize_root(&trusted_root);
    // BLOCKER1 guard: a root that normalizes to "" or "/" (or any
    // non-absolute / suspiciously-shallow value) would make classify() treat
    // every absolute row as under-root and apply_sql_strip() would strip the
    // leading slash off EVERY path (`/etc/passwd` -> `etc/passwd`) while
    // post-verify still passes. Fail closed before any classification.
    validate_strip_root(&root_for_strip, &trusted_root)?;

    let report = classify(&conn, &root_for_strip)?;
    let strategy = report.strategy;

    let mut out = report;
    out.applied = apply;
    out.repo_root_redacted = "<repo_root>".to_string();

    if apply {
        match strategy {
            Strategy::NoOp => {
                // Idempotent: nothing to write.
            }
            Strategy::SqlStrip => {
                apply_sql_strip(&conn, &root_for_strip)?;
            }
            Strategy::Reindex => {
                drop(conn);
                reindex_from_source(&trusted_root, &db_path, &project_id)?;
            }
        }

        // Re-open (reindex dropped the conn) and verify + bump index_version.
        let conn = Connection::open(&db_path)
            .map_err(|e| AgentError::Database(format!("failed to reopen semantic.db: {e}")))?;
        if !matches!(strategy, Strategy::NoOp) {
            bump_index_version(&conn)?;
        }
        let sym_abs_after = count_absolute(&conn, "symbols")?;
        let fpc_abs_after = count_absolute(&conn, "file_parse_cache")?;
        if sym_abs_after != 0 || fpc_abs_after != 0 {
            return Err(AgentError::State(format!(
                "migrate-paths verification failed: absolute rows remain (symbols={sym_abs_after}, file_parse_cache={fpc_abs_after})"
            )));
        }
        out.symbols_absolute_after = Some(sym_abs_after);
        out.file_parse_cache_absolute_after = Some(fpc_abs_after);
    }

    if let Some(evidence_path) = evidence {
        write_evidence_row(evidence_path, &out)?;
    }

    Ok(out)
}

/// Verify the DB carries the RSEM `application_id` marker without mutating it.
fn assert_rsem_marked(db_path: &Path) -> Result<()> {
    let conn = Connection::open_with_flags(
        db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| AgentError::Database(format!("failed to open semantic.db read-only: {e}")))?;
    let app_id: i64 = conn
        .query_row("PRAGMA application_id", [], |row| row.get(0))
        .map_err(|e| AgentError::Database(format!("failed to read application_id: {e}")))?;
    if app_id != shared::semantic_gc::REVHARNESS_APP_ID {
        return Err(AgentError::Validation(format!(
            "refusing to migrate: semantic.db is not RevHarness-managed (application_id={app_id:#x}, expected {:#x})",
            shared::semantic_gc::REVHARNESS_APP_ID
        )));
    }
    Ok(())
}

/// Read the trusted repo root from `projects.root_path`. REFUSE if blank.
fn read_trusted_root(conn: &Connection) -> Result<String> {
    let root: Option<String> = conn
        .query_row(
            "SELECT root_path FROM projects WHERE root_path IS NOT NULL LIMIT 1",
            [],
            |row| row.get(0),
        )
        .ok();
    match root {
        Some(r) if !r.trim().is_empty() => Ok(r.trim().to_string()),
        _ => Err(AgentError::Validation(
            "refusing to migrate: projects.root_path is blank/missing; cannot derive a trusted repo root (never guess)".to_string(),
        )),
    }
}

/// Normalize the root to forward slashes with NO trailing slash, so
/// `substr(file_path, length(root)+2)` strips `<root>/` cleanly.
fn normalize_root(root: &str) -> String {
    let r = root.replace('\\', "/");
    r.trim_end_matches('/').to_string()
}

/// BLOCKER1 guard: refuse to use a trusted root that is unsafe for a leading
/// `<root>/` strip. A safe root must:
///   - be non-empty after normalization (rejects `""` and bare `/`, both of
///     which normalize to `""` and would make every absolute row look
///     under-root, stripping the leading slash off `/etc/passwd`);
///   - be an absolute POSIX path (`/...`);
///   - have at least two non-empty path segments (reasonable depth; a single
///     top-level segment like `/etc` is too shallow to trust as a repo root and
///     risks mass mis-strip);
///   - exist on disk as a directory (the trusted root is a real checkout).
///
/// `normalized` is the forward-slashed, trailing-slash-trimmed form;
/// `raw` is the original `projects.root_path` value (used for the on-disk check
/// and the error message context, redacted to depth — never a raw
/// home-absolute host path).
fn validate_strip_root(normalized: &str, raw: &str) -> Result<()> {
    if normalized.is_empty() {
        return Err(AgentError::Validation(
            "refusing to migrate: trusted root normalizes to empty or \"/\" — \
             a bare/blank root would strip the leading slash off every absolute \
             path; root must be an absolute path of reasonable depth"
                .to_string(),
        ));
    }
    if !normalized.starts_with('/') {
        return Err(AgentError::Validation(
            "refusing to migrate: trusted root is not an absolute POSIX path \
             (must start with '/'); never guess a non-absolute root"
                .to_string(),
        ));
    }
    // Count non-empty segments after the leading slash. `/etc` -> 1 (too
    // shallow); `/srv/work/checkout/project` -> 4.
    let depth = normalized
        .split('/')
        .filter(|seg| !seg.is_empty())
        .count();
    if depth < 2 {
        return Err(AgentError::Validation(format!(
            "refusing to migrate: trusted root is suspiciously shallow \
             (depth={depth}, need >= 2 segments); a shallow root risks \
             mis-stripping unrelated absolute paths"
        )));
    }
    // The trusted root must be a real directory on disk. Use the raw value so
    // platform-native separators resolve correctly.
    let root_path = Path::new(raw);
    if !root_path.is_dir() {
        return Err(AgentError::Validation(
            "refusing to migrate: trusted root does not exist on disk as a \
             directory; cannot trust it for a path strip"
                .to_string(),
        ));
    }
    Ok(())
}

fn classify(conn: &Connection, root: &str) -> Result<MigratePathsReport> {
    let sym_abs = count_absolute(conn, "symbols")?;
    let sym_rel = count_relative(conn, "symbols")?;
    let fpc_abs = count_absolute(conn, "file_parse_cache")?;
    let fpc_rel = count_relative(conn, "file_parse_cache")?;

    // Absolute rows NOT under the trusted root → SQL strip would produce a wrong
    // key; these force a full reindex.
    let outside_root =
        count_absolute_outside_root(conn, "symbols", root)?
            + count_absolute_outside_root(conn, "file_parse_cache", root)?;

    let strategy = if sym_abs == 0 && fpc_abs == 0 {
        Strategy::NoOp
    } else if outside_root > 0 {
        // Collision / foreign absolute rows: SQL strip unsafe → reindex.
        Strategy::Reindex
    } else {
        // Absolute-only-under-root. If relative rows already coexist there is a
        // potential post-strip key collision; prefer a clean reindex.
        if sym_rel > 0 || fpc_rel > 0 {
            Strategy::Reindex
        } else {
            Strategy::SqlStrip
        }
    };

    Ok(MigratePathsReport {
        applied: false,
        strategy,
        symbols_absolute_before: sym_abs,
        symbols_relative_before: sym_rel,
        file_parse_cache_absolute_before: fpc_abs,
        file_parse_cache_relative_before: fpc_rel,
        rows_outside_root: outside_root,
        symbols_absolute_after: None,
        file_parse_cache_absolute_after: None,
        repo_root_redacted: "<repo_root>".to_string(),
    })
}

fn count_absolute(conn: &Connection, table: &str) -> Result<i64> {
    // GLOB '/*' matches any path beginning with '/'. On Windows absolute paths
    // were stored forward-slashed too (path_to_forward_slashes), but the legacy
    // leak we care about is the POSIX home-absolute host-path form.
    let sql = format!("SELECT COUNT(*) FROM {table} WHERE file_path GLOB '/*'");
    conn.query_row(&sql, [], |row| row.get(0))
        .map_err(|e| AgentError::Database(format!("count_absolute({table}) failed: {e}")))
}

fn count_relative(conn: &Connection, table: &str) -> Result<i64> {
    let sql = format!("SELECT COUNT(*) FROM {table} WHERE file_path NOT GLOB '/*'");
    conn.query_row(&sql, [], |row| row.get(0))
        .map_err(|e| AgentError::Database(format!("count_relative({table}) failed: {e}")))
}

fn count_absolute_outside_root(conn: &Connection, table: &str, root: &str) -> Result<i64> {
    // Absolute rows that do NOT start with `<root>/`.
    let prefix = format!("{root}/");
    let sql = format!(
        "SELECT COUNT(*) FROM {table} WHERE file_path GLOB '/*' AND substr(file_path, 1, ?1) <> ?2"
    );
    conn.query_row(&sql, rusqlite::params![prefix.len() as i64, prefix], |row| {
        row.get(0)
    })
    .map_err(|e| AgentError::Database(format!("count_outside_root({table}) failed: {e}")))
}

/// Transactionally strip `<root>/` from both tables AND verify the result
/// BEFORE committing. `substr(file_path, length(root)+2)` drops the root plus
/// its trailing slash. Only rows under the root are touched (classify already
/// guaranteed there are no outside rows in the SqlStrip strategy, but the WHERE
/// guard keeps it defensive).
///
/// BLOCKER2: the strip and the post-verify live in ONE transaction. We commit
/// only if verification passes; on ANY failure the tx is dropped (rolled back)
/// so the DB is byte-for-byte unchanged. This closes the commit-before-verify
/// window where a malformed under-root row (e.g.
/// `/srv/work/checkout/project//src/a.rs` -> `/src/a.rs`) would otherwise leave an
/// absolute-looking key persisted after a failed run.
fn apply_sql_strip(conn: &Connection, root: &str) -> Result<()> {
    let prefix = format!("{root}/");
    let prefix_len = prefix.len() as i64;
    let tx = conn
        .unchecked_transaction()
        .map_err(|e| AgentError::Database(format!("failed to begin migration tx: {e}")))?;
    for table in ["symbols", "file_parse_cache"] {
        let sql = format!(
            "UPDATE {table} SET file_path = substr(file_path, ?1 + 2) \
             WHERE file_path GLOB '/*' AND substr(file_path, 1, ?2) = ?3"
        );
        tx.execute(
            &sql,
            rusqlite::params![root.len() as i64, prefix_len, prefix],
        )
        .map_err(|e| AgentError::Database(format!("strip {table} failed: {e}")))?;
    }

    // In-transaction verification. Any failure returns Err WITHOUT calling
    // commit(), so the tx Drop rolls back and the DB is untouched.
    for table in ["symbols", "file_parse_cache"] {
        // 1. No absolute rows may remain.
        let abs: i64 = tx
            .query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE file_path GLOB '/*'"),
                [],
                |r| r.get(0),
            )
            .map_err(|e| AgentError::Database(format!("in-tx verify count({table}) failed: {e}")))?;
        if abs != 0 {
            return Err(AgentError::State(format!(
                "migrate-paths in-tx verification failed: {abs} absolute row(s) remain in {table} after strip; rolling back, DB unchanged"
            )));
        }
        // 2. No key may have become empty or otherwise non-sane. A sane
        //    repo-relative key is non-empty and does NOT start with '/'.
        //    A malformed under-root source (double slash, trailing-slash root)
        //    would have stripped to a leading-slash artifact or an empty
        //    string — catch both. GLOB '/*' above already covers leading
        //    slash; the empty check is the remaining gap.
        let empty: i64 = tx
            .query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE file_path = '' OR file_path IS NULL"),
                [],
                |r| r.get(0),
            )
            .map_err(|e| AgentError::Database(format!("in-tx verify empty({table}) failed: {e}")))?;
        if empty != 0 {
            return Err(AgentError::State(format!(
                "migrate-paths in-tx verification failed: {empty} empty/NULL key(s) in {table} after strip; rolling back, DB unchanged"
            )));
        }
    }

    tx.commit()
        .map_err(|e| AgentError::Database(format!("failed to commit migration tx: {e}")))
}

/// Full source reindex fallback for mixed/colliding DBs. Builds a fresh repo-map
/// snapshot from the trusted root and re-indexes with repo-relative keys and
/// `gc_orphans=true`, which removes stale absolute rows via the generation
/// guard.
fn reindex_from_source(trusted_root: &str, db_path: &Path, project_id: &str) -> Result<()> {
    let root = PathBuf::from(trusted_root);
    if !root.is_dir() {
        return Err(AgentError::Validation(format!(
            "refusing to reindex: trusted root {} does not exist on disk",
            root.display()
        )));
    }
    // context_update resolves the repo via git_repo_root()/cwd, so run it from
    // the trusted root.
    let prev_cwd = std::env::current_dir().map_err(AgentError::Io)?;
    std::env::set_current_dir(&root).map_err(AgentError::Io)?;
    let result = (|| -> Result<()> {
        let tmp = tempfile::tempdir().map_err(AgentError::Io)?;
        let snapshot = tmp.path().join("repomap.json");
        let plan = tmp.path().join("plan.md");
        std::fs::write(&plan, "").map_err(AgentError::Io)?;
        context_update(&plan, &snapshot, false, None)?;
        index_symbols_from_snapshot(&snapshot, db_path, project_id)?;
        Ok(())
    })();
    // Always restore cwd.
    std::env::set_current_dir(&prev_cwd).map_err(AgentError::Io)?;
    result
}

/// Increment `_ts_meta.index_version` once to invalidate in-flight tokens.
fn bump_index_version(conn: &Connection) -> Result<()> {
    let current: Option<String> = conn
        .query_row(
            "SELECT value FROM _ts_meta WHERE key = 'index_version'",
            [],
            |row| row.get(0),
        )
        .ok();
    let next = current
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0)
        .saturating_add(1);
    conn.execute(
        "INSERT INTO _ts_meta(key, value) VALUES('index_version', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![next.to_string()],
    )
    .map_err(|e| AgentError::Database(format!("failed to bump index_version: {e}")))?;
    Ok(())
}

/// Append a single redacted JSONL evidence row. The repo_root is recorded as
/// `<repo_root>` — never the raw home-absolute host path (I-1).
fn write_evidence_row(path: &Path, report: &MigratePathsReport) -> Result<()> {
    use std::io::Write;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(AgentError::Io)?;
    }
    let line = serde_json::to_string(report).map_err(AgentError::Json)?;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(AgentError::Io)?;
    writeln!(file, "{line}").map_err(AgentError::Io)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a neutral, on-disk repo root inside a tempdir. No personal
    /// personal home-directory layout is hardcoded anywhere in these tests; the
    /// root is a real directory of reasonable depth that passes
    /// `validate_strip_root`. Returns `(guard, root_string)` where the
    /// normalized POSIX form of `root_string` is what classify/strip use.
    fn neutral_root() -> (tempfile::TempDir, String) {
        // tempdir() yields e.g. /tmp/.tmpXXXXXX (depth >= 2, absolute, exists).
        let tmp = tempfile::tempdir().unwrap();
        // Add a synthetic project segment so it reads like a repo checkout and
        // is comfortably deep even on platforms with a shallow temp dir.
        let root_dir = tmp.path().join("revh-test-project");
        std::fs::create_dir_all(&root_dir).unwrap();
        let root = root_dir.to_string_lossy().replace('\\', "/");
        (tmp, root)
    }

    /// Seed a DB whose `projects.root_path` is `root`. The DB lives in its own
    /// tempdir (separate from the root tempdir) so callers can keep both alive.
    fn seed_db(root: &str) -> (tempfile::TempDir, PathBuf, Connection) {
        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("semantic.db");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(&format!(
            "PRAGMA application_id = {};",
            shared::semantic_gc::REVHARNESS_APP_ID
        ))
        .unwrap();
        conn.execute_batch(
            "CREATE TABLE _ts_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, root_path TEXT);
             CREATE TABLE symbols (id INTEGER PRIMARY KEY, file_path TEXT NOT NULL);
             CREATE TABLE file_parse_cache (id INTEGER PRIMARY KEY, file_path TEXT NOT NULL);",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO _ts_meta(key, value) VALUES('index_version', '5')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO projects(id, name, root_path) VALUES('p', 'p', ?1)",
            rusqlite::params![root],
        )
        .unwrap();
        (tmp, db_path, conn)
    }

    fn insert_abs(conn: &Connection, table: &str, root: &str, rel: &str) {
        conn.execute(
            &format!("INSERT INTO {table}(file_path) VALUES(?1)"),
            rusqlite::params![format!("{root}/{rel}")],
        )
        .unwrap();
    }

    #[test]
    fn read_trusted_root_refuses_blank() {
        let (_tmp, _db, conn) = seed_db("");
        assert!(read_trusted_root(&conn).is_err());
    }

    // ---- BLOCKER1: refuse empty / "/" / relative / shallow / nonexistent ----

    #[test]
    fn validate_strip_root_refuses_empty() {
        // root_path "" normalizes to "" -> must refuse before any classify.
        assert!(validate_strip_root(&normalize_root(""), "").is_err());
    }

    #[test]
    fn validate_strip_root_refuses_bare_slash() {
        // root_path "/" normalizes to "" -> the mass-mis-strip trap. Refuse.
        assert_eq!(normalize_root("/"), "");
        assert!(validate_strip_root(&normalize_root("/"), "/").is_err());
    }

    #[test]
    fn validate_strip_root_refuses_relative() {
        // A non-absolute root (no leading slash) must be refused.
        assert!(validate_strip_root(&normalize_root("project/src"), "project/src").is_err());
    }

    #[test]
    fn validate_strip_root_refuses_shallow() {
        // A single top-level segment is too shallow to trust.
        assert!(validate_strip_root(&normalize_root("/etc"), "/etc").is_err());
    }

    #[test]
    fn validate_strip_root_refuses_nonexistent_dir() {
        // Absolute + deep but not present on disk -> refuse.
        let bogus = "/nonexistent-revh/aaa/bbb/ccc";
        assert!(validate_strip_root(&normalize_root(bogus), bogus).is_err());
    }

    #[test]
    fn validate_strip_root_accepts_real_deep_dir() {
        let (_guard, root) = neutral_root();
        validate_strip_root(&normalize_root(&root), &root).unwrap();
    }

    #[test]
    fn run_refuses_when_root_is_bare_slash_db_untouched() {
        // End-to-end: seed a DB whose root_path is "/" with a fake outside-root
        // absolute row. validate_strip_root must fire before any write so the
        // /etc/passwd-style key is never stripped.
        let (_tmp, _db, conn) = seed_db("/");
        conn.execute(
            "INSERT INTO symbols(file_path) VALUES('/etc/passwd')",
            [],
        )
        .unwrap();
        let trusted = read_trusted_root(&conn).unwrap();
        let normalized = normalize_root(&trusted);
        assert!(validate_strip_root(&normalized, &trusted).is_err());
        // DB untouched: the row is still its original absolute literal.
        let stored: String = conn
            .query_row("SELECT file_path FROM symbols LIMIT 1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(stored, "/etc/passwd");
    }

    // ---- Happy path: clean absolute-only rows under a proper root ----

    #[test]
    fn sql_strip_converts_absolute_to_relative_and_verifies_zero() {
        let (_guard, root) = neutral_root();
        let (_tmp, _db, conn) = seed_db(&root);
        insert_abs(&conn, "symbols", &root, "src/a.rs");
        insert_abs(&conn, "file_parse_cache", &root, "src/a.rs");

        let normalized = normalize_root(&root);
        validate_strip_root(&normalized, &root).unwrap();
        let report = classify(&conn, &normalized).unwrap();
        assert_eq!(report.strategy, Strategy::SqlStrip);
        assert_eq!(report.symbols_absolute_before, 1);
        assert_eq!(report.rows_outside_root, 0);

        apply_sql_strip(&conn, &normalized).unwrap();
        assert_eq!(count_absolute(&conn, "symbols").unwrap(), 0);
        assert_eq!(count_absolute(&conn, "file_parse_cache").unwrap(), 0);
        let stored: String = conn
            .query_row("SELECT file_path FROM symbols LIMIT 1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(stored, "src/a.rs");
    }

    // ---- BLOCKER2: malformed under-root row -> tx ROLLS BACK, DB unchanged ----

    #[test]
    fn sql_strip_rolls_back_on_malformed_double_slash_row_db_unchanged() {
        let (_guard, root) = neutral_root();
        let (_tmp, _db, conn) = seed_db(&root);
        // A clean under-root row plus a MALFORMED one with a double slash that
        // strips to a leading-slash artifact (`/src/bad.rs`). classify still
        // sees it as under-root (prefix matches), so strategy is SqlStrip, but
        // the in-tx verify must catch the absolute-looking key and roll back.
        let clean = format!("{root}/src/good.rs");
        let malformed = format!("{root}//src/bad.rs");
        conn.execute(
            "INSERT INTO symbols(file_path) VALUES(?1)",
            rusqlite::params![clean],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO symbols(file_path) VALUES(?1)",
            rusqlite::params![malformed],
        )
        .unwrap();

        let normalized = normalize_root(&root);
        // Snapshot exact rows before the attempted strip.
        let before: Vec<String> = {
            let mut stmt = conn
                .prepare("SELECT file_path FROM symbols ORDER BY id")
                .unwrap();
            let rows: Vec<String> = stmt
                .query_map([], |r| r.get(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect();
            rows
        };
        assert_eq!(report_strategy(&conn, &normalized), Strategy::SqlStrip);

        let err = apply_sql_strip(&conn, &normalized);
        assert!(err.is_err(), "malformed row must cause rollback, got Ok");

        // DB unchanged: rows identical to the pre-strip snapshot.
        let after: Vec<String> = {
            let mut stmt = conn
                .prepare("SELECT file_path FROM symbols ORDER BY id")
                .unwrap();
            let rows: Vec<String> = stmt
                .query_map([], |r| r.get(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect();
            rows
        };
        assert_eq!(before, after, "rollback must leave rows byte-for-byte");
    }

    fn report_strategy(conn: &Connection, normalized: &str) -> Strategy {
        classify(conn, normalized).unwrap().strategy
    }

    // ---- outside-root /etc/passwd-style row -> classify flags it, no strip ----

    #[test]
    fn classify_reindex_when_absolute_outside_root_never_strips() {
        let (_guard, root) = neutral_root();
        let (_tmp, _db, conn) = seed_db(&root);
        // Outside-root absolute literal (e.g. /etc/passwd) must NOT be stripped.
        conn.execute(
            "INSERT INTO symbols(file_path) VALUES('/etc/passwd')",
            [],
        )
        .unwrap();
        let normalized = normalize_root(&root);
        let report = classify(&conn, &normalized).unwrap();
        // Strategy falls back to Reindex (never SqlStrip), and the foreign row
        // is counted as outside-root so a SQL strip is never attempted on it.
        assert_eq!(report.strategy, Strategy::Reindex);
        assert_eq!(report.rows_outside_root, 1);
        // The row is untouched by classify.
        let stored: String = conn
            .query_row("SELECT file_path FROM symbols LIMIT 1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(stored, "/etc/passwd");
    }

    #[test]
    fn classify_noop_when_already_relative() {
        let (_guard, root) = neutral_root();
        let (_tmp, _db, conn) = seed_db(&root);
        conn.execute("INSERT INTO symbols(file_path) VALUES('src/a.rs')", [])
            .unwrap();
        let report = classify(&conn, &normalize_root(&root)).unwrap();
        assert_eq!(report.strategy, Strategy::NoOp);
    }

    #[test]
    fn bump_index_version_increments() {
        let (_guard, root) = neutral_root();
        let (_tmp, _db, conn) = seed_db(&root);
        bump_index_version(&conn).unwrap();
        let v: String = conn
            .query_row(
                "SELECT value FROM _ts_meta WHERE key='index_version'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(v, "6");
    }
}
