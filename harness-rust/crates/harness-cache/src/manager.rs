//! [`CacheManager`] — the primary public interface to the cache layer.
//!
//! Wraps a SQLite connection and exposes typed read/write/maintenance
//! methods for every cache table.

use std::collections::HashMap;
use std::path::Path;

use chrono::Utc;
use rusqlite::{params, ErrorCode};
use sha2::{Digest, Sha256};
use shared::error::{AgentError, Result};
use tracing::warn;

use crate::db;
use crate::helpers;
use crate::types::*;

/// Compute the capsule cache key from every freshness-sensitive input.
pub fn capsule_cache_key(
    plan: &str,
    changed_files: &[String],
    symbols_digest: &str,
    file_sha_rollup: &str,
    index_version: u64,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(plan.as_bytes());
    for file in changed_files {
        hasher.update(file.as_bytes());
    }
    hasher.update(symbols_digest.as_bytes());
    hasher.update(file_sha_rollup.as_bytes());
    hasher.update(index_version.to_string().as_bytes());
    hex::encode(hasher.finalize())
}

/// Central cache façade.
///
/// All SQL uses parameterised queries. Writes are skipped when the
/// [`disk_full`](Self::disk_full) flag is set (SQLITE_FULL was observed).
pub struct CacheManager {
    conn: rusqlite::Connection,
    project_id: String,
    disk_full: bool,
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

impl CacheManager {
    /// Open (or create) the on-disk cache for `project_id`.
    pub fn new(project_id: &str) -> Result<Self> {
        let conn = db::open_cache_db(project_id)?;
        Ok(Self {
            conn,
            project_id: project_id.to_string(),
            disk_full: false,
        })
    }

    /// Create an in-memory cache — useful for tests.
    pub fn new_in_memory(project_id: &str) -> Result<Self> {
        let conn = db::open_in_memory()?;
        Ok(Self {
            conn,
            project_id: project_id.to_string(),
            disk_full: false,
        })
    }

    /// Return the project ID this cache was opened for.
    pub fn project_id(&self) -> &str {
        &self.project_id
    }
}

// ---------------------------------------------------------------------------
// Verify cache
// ---------------------------------------------------------------------------

impl CacheManager {
    /// Look up a cached verification result.
    ///
    /// Returns `Some` only when `file_hash`, `config_hash`, **and**
    /// `tool_version` all match (HIT). A row that exists but has stale
    /// hashes is treated as a miss.
    pub fn check_verify(
        &self,
        file: &str,
        file_hash: &str,
        tool: &str,
        config_hash: &str,
        tool_version: &str,
    ) -> Option<CachedVerifyResult> {
        self.conn
            .query_row(
                "SELECT tool, status, findings, verified_at
                 FROM verify_cache
                 WHERE file_path = ?1
                   AND tool = ?2
                   AND file_hash = ?3
                   AND config_hash = ?4
                   AND tool_version = ?5",
                params![file, tool, file_hash, config_hash, tool_version],
                |row| {
                    Ok(CachedVerifyResult {
                        tool: row.get(0)?,
                        status: row.get(1)?,
                        findings: row.get(2)?,
                        verified_at: row.get(3)?,
                    })
                },
            )
            .ok()
    }

    /// Store (or replace) a verification result.
    ///
    /// The primary key is `(file_path, tool)` so a new result for the same
    /// file+tool overwrites the old one.
    #[allow(clippy::too_many_arguments)]
    pub fn store_verify(
        &mut self,
        file: &str,
        file_hash: &str,
        tool: &str,
        config_hash: &str,
        tool_version: &str,
        status: &str,
        findings: &str,
    ) -> Result<()> {
        if self.disk_full {
            return Ok(());
        }
        helpers::validate_findings(findings)?;
        let result = self.conn.execute(
            "INSERT OR REPLACE INTO verify_cache
             (file_path, tool, file_hash, config_hash, tool_version, status, findings, verified_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                file,
                tool,
                file_hash,
                config_hash,
                tool_version,
                status,
                findings,
                Utc::now().to_rfc3339()
            ],
        );
        self.handle_write_result(result)
    }
}

// ---------------------------------------------------------------------------
// Review cache
// ---------------------------------------------------------------------------

impl CacheManager {
    /// Look up a cached review.
    ///
    /// Returns `Some` only when `file_hash`, `prompt_hash`, **and**
    /// `head_commit` all match.
    pub fn check_review(
        &self,
        file: &str,
        file_hash: &str,
        reviewer: &str,
        prompt_hash: &str,
        head_commit: &str,
    ) -> Option<CachedReview> {
        self.conn
            .query_row(
                "SELECT reviewer, verdict, findings, reviewed_at
                 FROM review_cache
                 WHERE file_path = ?1
                   AND reviewer = ?2
                   AND file_hash = ?3
                   AND prompt_hash = ?4
                   AND head_commit = ?5",
                params![file, reviewer, file_hash, prompt_hash, head_commit],
                |row| {
                    Ok(CachedReview {
                        reviewer: row.get(0)?,
                        verdict: row.get(1)?,
                        findings: row.get(2)?,
                        reviewed_at: row.get(3)?,
                    })
                },
            )
            .ok()
    }

    /// Store (or replace) a review result.
    #[allow(clippy::too_many_arguments)]
    pub fn store_review(
        &mut self,
        file: &str,
        file_hash: &str,
        reviewer: &str,
        prompt_hash: &str,
        head_commit: &str,
        verdict: &str,
        findings: &str,
    ) -> Result<()> {
        if self.disk_full {
            return Ok(());
        }
        helpers::validate_findings(findings)?;
        let result = self.conn.execute(
            "INSERT OR REPLACE INTO review_cache
             (file_path, reviewer, file_hash, prompt_hash, head_commit, verdict, findings, reviewed_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                file,
                reviewer,
                file_hash,
                prompt_hash,
                head_commit,
                verdict,
                findings,
                Utc::now().to_rfc3339()
            ],
        );
        self.handle_write_result(result)
    }
}

// ---------------------------------------------------------------------------
// Capsule cache (LRU)
// ---------------------------------------------------------------------------

impl CacheManager {
    /// Look up a cached capsule by context hash.
    ///
    /// On a hit, automatically touches `last_accessed_at` for LRU tracking.
    pub fn check_capsule(&self, context_hash: &str) -> Option<CachedCapsule> {
        let result = self
            .conn
            .query_row(
                "SELECT json, sha256, tokens, last_accessed_at
                 FROM capsule_cache
                 WHERE context_hash = ?1",
                params![context_hash],
                |row| {
                    Ok(CachedCapsule {
                        json: row.get(0)?,
                        sha256: row.get(1)?,
                        tokens: row.get::<_, u32>(2)?,
                        last_accessed_at: row.get(3)?,
                    })
                },
            )
            .ok();

        if result.is_some() {
            let _ = self.touch_capsule(context_hash);
        }

        result
    }

    /// Store (or replace) a capsule.
    pub fn store_capsule(
        &mut self,
        context_hash: &str,
        json: &str,
        sha256: &str,
        tokens: u32,
    ) -> Result<()> {
        if self.disk_full {
            return Ok(());
        }
        let now = Utc::now().to_rfc3339();
        let result = self.conn.execute(
            "INSERT OR REPLACE INTO capsule_cache
             (context_hash, json, sha256, tokens, created_at, last_accessed_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![context_hash, json, sha256, tokens, &now, &now],
        );
        self.handle_write_result(result)
    }

    /// Touch the `last_accessed_at` timestamp for LRU tracking.
    pub fn touch_capsule(&self, context_hash: &str) -> Result<()> {
        self.conn
            .execute(
                "UPDATE capsule_cache SET last_accessed_at = ?1 WHERE context_hash = ?2",
                params![Utc::now().to_rfc3339(), context_hash],
            )
            .map(|_| ())
            .map_err(|e| AgentError::Database(format!("touch_capsule failed: {e}")))
    }
}

// ---------------------------------------------------------------------------
// File index
// ---------------------------------------------------------------------------

impl CacheManager {
    /// Look up a file index entry.
    pub fn check_file_index(&self, file: &str) -> Option<FileIndexEntry> {
        self.conn
            .query_row(
                "SELECT file_path, content_hash, size_bytes, last_indexed_at
                 FROM file_index
                 WHERE file_path = ?1",
                params![file],
                |row| {
                    Ok(FileIndexEntry {
                        file_path: row.get(0)?,
                        content_hash: row.get(1)?,
                        size_bytes: row.get::<_, u64>(2)?,
                        last_indexed_at: row.get(3)?,
                    })
                },
            )
            .ok()
    }

    /// Insert or update a file index entry.
    pub fn update_file_index(&mut self, entry: &FileIndexEntry) -> Result<()> {
        if self.disk_full {
            return Ok(());
        }
        let result = self.conn.execute(
            "INSERT OR REPLACE INTO file_index
             (file_path, content_hash, size_bytes, last_indexed_at)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                entry.file_path,
                entry.content_hash,
                entry.size_bytes,
                entry.last_indexed_at
            ],
        );
        self.handle_write_result(result)
    }
}

// ---------------------------------------------------------------------------
// Audit
// ---------------------------------------------------------------------------

impl CacheManager {
    /// Audit a random sample of verify_cache entries for staleness.
    ///
    /// For each sampled entry, recomputes the current `config_hash` and
    /// `tool_version`. If the stored values differ, the entry is counted as a
    /// mismatch. When the mismatch rate for a given tool exceeds 20%, the
    /// tool's entire cache is invalidated.
    pub fn audit(&self, sample_size: u32, project_root: &Path) -> Result<AuditResult> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT file_path, tool, config_hash, tool_version
                 FROM verify_cache
                 ORDER BY RANDOM()
                 LIMIT ?1",
            )
            .map_err(|e| AgentError::Database(e.to_string()))?;

        let rows: Vec<(String, String, String, String)> = stmt
            .query_map(params![sample_size], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })
            .map_err(|e| AgentError::Database(e.to_string()))?
            .filter_map(|r| r.ok())
            .collect();

        let samples_checked = rows.len() as u32;
        let mut mismatches: u32 = 0;
        // Track per-tool: (mismatches, total)
        let mut tool_stats: HashMap<String, (u32, u32)> = HashMap::new();

        for (_file_path, tool, stored_config_hash, stored_tool_version) in &rows {
            let current_config_hash = helpers::compute_config_hash(tool, project_root);
            let current_tool_version = helpers::get_tool_version(tool);

            let entry = tool_stats.entry(tool.clone()).or_insert((0, 0));
            entry.1 += 1;

            if *stored_config_hash != current_config_hash
                || *stored_tool_version != current_tool_version
            {
                mismatches += 1;
                entry.0 += 1;
            }
        }

        let mismatch_rate = if samples_checked > 0 {
            f64::from(mismatches) / f64::from(samples_checked)
        } else {
            0.0
        };

        // Invalidate tools with > 20% mismatch rate
        let mut invalidated_tools = Vec::new();
        for (tool, (tool_mismatches, tool_total)) in &tool_stats {
            let tool_rate = f64::from(*tool_mismatches) / f64::from(*tool_total);
            if tool_rate > 0.2 {
                self.conn
                    .execute("DELETE FROM verify_cache WHERE tool = ?1", params![tool])
                    .map_err(|e| AgentError::Database(e.to_string()))?;
                invalidated_tools.push(tool.clone());
            }
        }

        Ok(AuditResult {
            samples_checked,
            mismatches,
            mismatch_rate,
            invalidated_tools,
        })
    }
}

// ---------------------------------------------------------------------------
// Cross-cache invalidation
// ---------------------------------------------------------------------------

impl CacheManager {
    /// Delete review cache entries after any verify cache miss.
    ///
    /// Review cache rows are currently keyed by normalized `coder_output`
    /// paths, while verify cache misses are detected on changed source files.
    /// Without a dependency mapping between those surfaces, the safe behavior
    /// is to flush review cache globally and force a fresh review pass.
    pub fn invalidate_review_on_verify_miss(&self) -> Result<()> {
        self.conn
            .execute("DELETE FROM review_cache", [])
            .map(|_| ())
            .map_err(|e| AgentError::Database(format!("invalidate_review failed: {e}")))
    }
}

// ---------------------------------------------------------------------------
// Maintenance
// ---------------------------------------------------------------------------

impl CacheManager {
    /// Run all maintenance operations: GC, staleness eviction, LRU
    /// enforcement, WAL checkpoint, and conditional VACUUM.
    pub fn maintenance(
        &self,
        max_age_days: u32,
        existing_files: &[String],
    ) -> Result<MaintenanceResult> {
        let gc_result = self.gc_deleted_files(existing_files)?;
        let stale_evicted = self.evict_stale(max_age_days)?;
        self.enforce_capsule_lru(10_000)?;
        self.wal_checkpoint()?;
        let vacuumed = self.vacuum_if_needed()?;

        Ok(MaintenanceResult {
            gc_result,
            stale_evicted,
            vacuumed,
        })
    }

    /// Remove cache entries for files that no longer exist on disk.
    pub fn gc_deleted_files(&self, existing_files: &[String]) -> Result<GcResult> {
        // Collect indexed files
        let mut stmt = self
            .conn
            .prepare("SELECT file_path FROM file_index")
            .map_err(|e| AgentError::Database(e.to_string()))?;

        let indexed: Vec<String> = stmt
            .query_map([], |row| row.get(0))
            .map_err(|e| AgentError::Database(e.to_string()))?
            .filter_map(|r| r.ok())
            .collect();

        let mut file_index_removed: u64 = 0;
        let mut verify_cache_removed: u64 = 0;
        let mut review_cache_removed: u64 = 0;

        for file in &indexed {
            if !existing_files.contains(file) {
                self.conn
                    .execute("DELETE FROM file_index WHERE file_path = ?1", params![file])
                    .map_err(|e| AgentError::Database(e.to_string()))?;
                file_index_removed += 1;

                let v = self
                    .conn
                    .execute(
                        "DELETE FROM verify_cache WHERE file_path = ?1",
                        params![file],
                    )
                    .map_err(|e| AgentError::Database(e.to_string()))?;
                verify_cache_removed += v as u64;

                let r = self
                    .conn
                    .execute(
                        "DELETE FROM review_cache WHERE file_path = ?1",
                        params![file],
                    )
                    .map_err(|e| AgentError::Database(e.to_string()))?;
                review_cache_removed += r as u64;
            }
        }

        Ok(GcResult {
            file_index_removed,
            verify_cache_removed,
            review_cache_removed,
        })
    }

    /// Remove entries older than `max_age_days` across all tables.
    ///
    /// Deletion is batched at 1000 rows per table to avoid holding long
    /// locks.
    pub fn evict_stale(&self, max_age_days: u32) -> Result<u64> {
        let cutoff = Utc::now() - chrono::Duration::days(i64::from(max_age_days));
        let cutoff_str = cutoff.to_rfc3339();

        let tables_and_columns: &[(&str, &str)] = &[
            ("file_index", "last_indexed_at"),
            ("verify_cache", "verified_at"),
            ("review_cache", "reviewed_at"),
            ("capsule_cache", "last_accessed_at"),
        ];

        let mut total: u64 = 0;
        for (table, col) in tables_and_columns {
            let sql = format!(
                "DELETE FROM {table} WHERE rowid IN \
                 (SELECT rowid FROM {table} WHERE {col} < ?1 LIMIT 1000)"
            );
            loop {
                let deleted = self
                    .conn
                    .execute(&sql, params![cutoff_str])
                    .map_err(|e| AgentError::Database(e.to_string()))?
                    as u64;
                total += deleted;
                if deleted < 1000 {
                    break;
                }
            }
        }

        Ok(total)
    }

    /// Enforce LRU on capsule_cache by evicting the oldest entries beyond
    /// `max_entries`.
    pub fn enforce_capsule_lru(&self, max_entries: u32) -> Result<()> {
        self.conn
            .execute(
                "DELETE FROM capsule_cache WHERE rowid IN (
                    SELECT rowid FROM capsule_cache
                    ORDER BY last_accessed_at ASC
                    LIMIT max(0, (SELECT count(*) FROM capsule_cache) - ?1)
                 )",
                params![max_entries],
            )
            .map(|_| ())
            .map_err(|e| AgentError::Database(format!("enforce_capsule_lru failed: {e}")))
    }

    /// Request a WAL checkpoint (PASSIVE — non-blocking).
    pub fn wal_checkpoint(&self) -> Result<()> {
        self.conn
            .execute_batch("PRAGMA wal_checkpoint(PASSIVE)")
            .map_err(|e| AgentError::Database(format!("wal_checkpoint failed: {e}")))
    }

    /// Run `VACUUM` if the free-list is non-trivial.
    ///
    /// Returns `true` if a VACUUM was actually performed.
    pub fn vacuum_if_needed(&self) -> Result<bool> {
        let freelist: u32 = self
            .conn
            .query_row("PRAGMA freelist_count", [], |row| row.get(0))
            .map_err(|e| AgentError::Database(e.to_string()))?;

        if freelist > 100 {
            self.conn
                .execute_batch("VACUUM")
                .map_err(|e| AgentError::Database(format!("vacuum failed: {e}")))?;
            Ok(true)
        } else {
            Ok(false)
        }
    }
}

// ---------------------------------------------------------------------------
// Admin
// ---------------------------------------------------------------------------

impl CacheManager {
    /// Return aggregate row counts for all cache tables.
    pub fn get_cache_stats(&self) -> CacheStats {
        let count = |table: &str| -> u64 {
            self.conn
                .query_row(&format!("SELECT count(*) FROM {table}"), [], |row| {
                    row.get(0)
                })
                .unwrap_or(0)
        };

        let total_size_bytes: u64 = self
            .conn
            .query_row(
                "SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()",
                [],
                |row| row.get(0),
            )
            .unwrap_or(0);

        CacheStats {
            file_index_count: count("file_index"),
            verify_cache_count: count("verify_cache"),
            review_cache_count: count("review_cache"),
            capsule_cache_count: count("capsule_cache"),
            total_size_bytes,
        }
    }

    /// Delete all rows from the four cache tables but keep the tables
    /// themselves.
    pub fn clear_cache_only(&self) -> Result<()> {
        self.conn
            .execute_batch(
                "DELETE FROM file_index;
                 DELETE FROM verify_cache;
                 DELETE FROM review_cache;
                 DELETE FROM capsule_cache;",
            )
            .map_err(|e| AgentError::Database(format!("clear_cache_only failed: {e}")))
    }

    /// Drop and recreate all cache tables (including `_cache_meta`).
    pub fn clear_all(&self) -> Result<()> {
        db::drop_cache_tables(&self.conn)?;
        db::ensure_schema(&self.conn)?;
        Ok(())
    }

    /// Remove all cache entries for a single file.
    pub fn clear_file(&self, file: &str) -> Result<()> {
        self.conn
            .execute("DELETE FROM file_index WHERE file_path = ?1", params![file])
            .map_err(|e| AgentError::Database(e.to_string()))?;
        self.conn
            .execute(
                "DELETE FROM verify_cache WHERE file_path = ?1",
                params![file],
            )
            .map_err(|e| AgentError::Database(e.to_string()))?;
        self.conn
            .execute(
                "DELETE FROM review_cache WHERE file_path = ?1",
                params![file],
            )
            .map_err(|e| AgentError::Database(e.to_string()))?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Internal: disk-full guard
// ---------------------------------------------------------------------------

impl CacheManager {
    /// Handle a write result. On SQLITE_FULL, set the `disk_full` flag
    /// and silently succeed (cache is best-effort).
    fn handle_write_result(
        &mut self,
        result: std::result::Result<usize, rusqlite::Error>,
    ) -> Result<()> {
        match result {
            Ok(_) => Ok(()),
            Err(e) => {
                if is_disk_full(&e) {
                    warn!("SQLITE_FULL detected — disabling further cache writes");
                    self.disk_full = true;
                    Ok(())
                } else {
                    Err(AgentError::Database(e.to_string()))
                }
            }
        }
    }
}

/// Check if a rusqlite error is SQLITE_FULL.
fn is_disk_full(e: &rusqlite::Error) -> bool {
    matches!(
        e,
        rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error {
                code: ErrorCode::DiskFull,
                ..
            },
            _
        )
    )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn make_cm() -> CacheManager {
        CacheManager::new_in_memory("test_project").unwrap()
    }

    // -- verify cache --

    #[test]
    fn verify_cache_hit() {
        let mut cm = make_cm();
        cm.store_verify("src/main.rs", "abc", "clippy", "cfg1", "v1", "pass", "[]")
            .unwrap();
        let hit = cm.check_verify("src/main.rs", "abc", "clippy", "cfg1", "v1");
        assert!(hit.is_some());
        assert_eq!(hit.unwrap().status, "pass");
    }

    #[test]
    fn verify_cache_miss_on_hash_change() {
        let mut cm = make_cm();
        cm.store_verify("src/main.rs", "abc", "clippy", "cfg1", "v1", "pass", "[]")
            .unwrap();
        let miss = cm.check_verify("src/main.rs", "def", "clippy", "cfg1", "v1");
        assert!(miss.is_none());
    }

    #[test]
    fn verify_cache_miss_on_config_change() {
        let mut cm = make_cm();
        cm.store_verify("src/main.rs", "abc", "clippy", "cfg1", "v1", "pass", "[]")
            .unwrap();
        let miss = cm.check_verify("src/main.rs", "abc", "clippy", "cfg2", "v1");
        assert!(miss.is_none());
    }

    #[test]
    fn verify_cache_miss_on_version_change() {
        let mut cm = make_cm();
        cm.store_verify("src/main.rs", "abc", "clippy", "cfg1", "v1", "pass", "[]")
            .unwrap();
        let miss = cm.check_verify("src/main.rs", "abc", "clippy", "cfg1", "v2");
        assert!(miss.is_none());
    }

    // -- review cache --

    #[test]
    fn review_cache_hit() {
        let mut cm = make_cm();
        cm.store_review("src/main.rs", "abc", "safety", "ph1", "head1", "LGTM", "[]")
            .unwrap();
        let hit = cm.check_review("src/main.rs", "abc", "safety", "ph1", "head1");
        assert!(hit.is_some());
        assert_eq!(hit.unwrap().verdict, "LGTM");
    }

    #[test]
    fn review_cache_miss_on_hash_change() {
        let mut cm = make_cm();
        cm.store_review("src/main.rs", "abc", "safety", "ph1", "head1", "LGTM", "[]")
            .unwrap();
        assert!(cm
            .check_review("src/main.rs", "def", "safety", "ph1", "head1")
            .is_none());
    }

    #[test]
    fn review_cache_miss_on_prompt_change() {
        let mut cm = make_cm();
        cm.store_review("src/main.rs", "abc", "safety", "ph1", "head1", "LGTM", "[]")
            .unwrap();
        assert!(cm
            .check_review("src/main.rs", "abc", "safety", "ph2", "head1")
            .is_none());
    }

    #[test]
    fn review_cache_miss_on_head_change() {
        let mut cm = make_cm();
        cm.store_review("src/main.rs", "abc", "safety", "ph1", "head1", "LGTM", "[]")
            .unwrap();
        assert!(cm
            .check_review("src/main.rs", "abc", "safety", "ph1", "head2")
            .is_none());
    }

    // -- capsule cache --

    #[test]
    fn capsule_cache_hit() {
        let mut cm = make_cm();
        cm.store_capsule("ctx1", r#"{"body":"x"}"#, "sha1", 50)
            .unwrap();
        let hit = cm.check_capsule("ctx1");
        assert!(hit.is_some());
        assert_eq!(hit.unwrap().tokens, 50);
    }

    #[test]
    fn capsule_cache_miss() {
        let cm = make_cm();
        assert!(cm.check_capsule("nonexistent").is_none());
    }

    #[test]
    fn capsule_lru_enforcement() {
        let mut cm = make_cm();
        for i in 0..5 {
            cm.store_capsule(
                &format!("ctx{i}"),
                &format!(r#"{{"i":{i}}}"#),
                &format!("sha{i}"),
                10,
            )
            .unwrap();
        }
        cm.enforce_capsule_lru(3).unwrap();
        let stats = cm.get_cache_stats();
        assert_eq!(stats.capsule_cache_count, 3);
    }

    #[test]
    fn capsule_touch_updates_last_accessed() {
        let mut cm = make_cm();
        cm.store_capsule("ctx1", r#"{"a":1}"#, "sha1", 10).unwrap();
        let before = cm.check_capsule("ctx1").unwrap().last_accessed_at;
        // Touch after a tiny delay
        std::thread::sleep(std::time::Duration::from_millis(10));
        cm.touch_capsule("ctx1").unwrap();
        let after = cm.check_capsule("ctx1").unwrap().last_accessed_at;
        assert_ne!(before, after);
    }

    // -- file index --

    #[test]
    fn file_index_roundtrip() {
        let mut cm = make_cm();
        let entry = FileIndexEntry {
            file_path: "src/lib.rs".to_string(),
            content_hash: "abc123".to_string(),
            size_bytes: 1024,
            last_indexed_at: "2024-01-01T00:00:00Z".to_string(),
        };
        cm.update_file_index(&entry).unwrap();
        let loaded = cm.check_file_index("src/lib.rs");
        assert!(loaded.is_some());
        assert_eq!(loaded.unwrap(), entry);
    }

    #[test]
    fn file_index_update() {
        let mut cm = make_cm();
        let entry1 = FileIndexEntry {
            file_path: "src/lib.rs".to_string(),
            content_hash: "old".to_string(),
            size_bytes: 100,
            last_indexed_at: "2024-01-01T00:00:00Z".to_string(),
        };
        cm.update_file_index(&entry1).unwrap();

        let entry2 = FileIndexEntry {
            content_hash: "new".to_string(),
            size_bytes: 200,
            ..entry1.clone()
        };
        cm.update_file_index(&entry2).unwrap();

        let loaded = cm.check_file_index("src/lib.rs").unwrap();
        assert_eq!(loaded.content_hash, "new");
        assert_eq!(loaded.size_bytes, 200);
    }

    // -- invalidate review on verify miss --

    #[test]
    fn invalidate_review_on_verify_miss() {
        let mut cm = make_cm();
        cm.store_review(
            "artifacts/coder_output_a.md",
            "abc",
            "safety",
            "ph1",
            "head1",
            "LGTM",
            "[]",
        )
        .unwrap();
        cm.store_review(
            "artifacts/coder_output_b.md",
            "def",
            "security",
            "ph2",
            "head1",
            "LGTM",
            "[]",
        )
        .unwrap();
        cm.invalidate_review_on_verify_miss().unwrap();
        assert!(cm
            .check_review(
                "artifacts/coder_output_a.md",
                "abc",
                "safety",
                "ph1",
                "head1"
            )
            .is_none());
        assert!(cm
            .check_review(
                "artifacts/coder_output_b.md",
                "def",
                "security",
                "ph2",
                "head1"
            )
            .is_none());
    }

    // -- gc_deleted_files --

    #[test]
    fn gc_removes_orphaned_entries() {
        let mut cm = make_cm();
        let entry = FileIndexEntry {
            file_path: "deleted.rs".to_string(),
            content_hash: "abc".to_string(),
            size_bytes: 100,
            last_indexed_at: "2024-01-01T00:00:00Z".to_string(),
        };
        cm.update_file_index(&entry).unwrap();
        cm.store_verify("deleted.rs", "abc", "clippy", "cfg", "v1", "pass", "[]")
            .unwrap();
        cm.store_review("deleted.rs", "abc", "safety", "ph", "head", "LGTM", "[]")
            .unwrap();

        // existing_files does NOT include deleted.rs
        let result = cm.gc_deleted_files(&["src/main.rs".to_string()]).unwrap();
        assert_eq!(result.file_index_removed, 1);
        assert_eq!(result.verify_cache_removed, 1);
        assert_eq!(result.review_cache_removed, 1);

        assert!(cm.check_file_index("deleted.rs").is_none());
    }

    // -- evict_stale --

    #[test]
    fn evict_stale_removes_old_entries() {
        let cm = make_cm();
        // Insert an entry with an old timestamp
        cm.conn
            .execute(
                "INSERT INTO file_index (file_path, content_hash, size_bytes, last_indexed_at)
                 VALUES ('old.rs', 'abc', 100, '2020-01-01T00:00:00Z')",
                [],
            )
            .unwrap();
        cm.conn
            .execute(
                "INSERT INTO verify_cache
                 (file_path, tool, file_hash, config_hash, tool_version, status, findings, verified_at)
                 VALUES ('old.rs', 'clippy', 'abc', 'cfg', 'v1', 'pass', '[]', '2020-01-01T00:00:00Z')",
                [],
            )
            .unwrap();

        let evicted = cm.evict_stale(30).unwrap();
        assert!(evicted >= 2);
    }

    // -- maintenance --

    #[test]
    fn maintenance_runs_all_steps() {
        let mut cm = make_cm();
        let entry = FileIndexEntry {
            file_path: "alive.rs".to_string(),
            content_hash: "abc".to_string(),
            size_bytes: 100,
            last_indexed_at: chrono::Utc::now().to_rfc3339(),
        };
        cm.update_file_index(&entry).unwrap();

        let result = cm.maintenance(90, &["alive.rs".to_string()]).unwrap();
        // alive.rs should not be GC'd
        assert_eq!(result.gc_result.file_index_removed, 0);
    }

    // -- admin --

    #[test]
    fn clear_cache_only_empties_tables() {
        let mut cm = make_cm();
        cm.store_verify("a.rs", "h", "clippy", "c", "v", "pass", "[]")
            .unwrap();
        cm.clear_cache_only().unwrap();
        let stats = cm.get_cache_stats();
        assert_eq!(stats.verify_cache_count, 0);
    }

    #[test]
    fn clear_file_removes_single_file() {
        let mut cm = make_cm();
        cm.store_verify("a.rs", "h", "clippy", "c", "v", "pass", "[]")
            .unwrap();
        cm.store_verify("b.rs", "h", "clippy", "c", "v", "pass", "[]")
            .unwrap();
        cm.clear_file("a.rs").unwrap();
        assert!(cm.check_verify("a.rs", "h", "clippy", "c", "v").is_none());
        assert!(cm.check_verify("b.rs", "h", "clippy", "c", "v").is_some());
    }

    #[test]
    fn clear_all_recreates_schema() {
        let mut cm = make_cm();
        cm.store_verify("a.rs", "h", "clippy", "c", "v", "pass", "[]")
            .unwrap();
        cm.clear_all().unwrap();
        let stats = cm.get_cache_stats();
        assert_eq!(stats.verify_cache_count, 0);
        // Schema should still work
        cm.store_verify("b.rs", "h", "clippy", "c", "v", "pass", "[]")
            .unwrap();
        assert_eq!(cm.get_cache_stats().verify_cache_count, 1);
    }

    #[test]
    fn get_cache_stats_counts() {
        let mut cm = make_cm();
        cm.store_verify("a.rs", "h", "clippy", "c", "v", "pass", "[]")
            .unwrap();
        cm.store_review("a.rs", "h", "safety", "p", "hd", "LGTM", "[]")
            .unwrap();
        cm.store_capsule("ctx", r#"{"x":1}"#, "sha", 10).unwrap();
        let entry = FileIndexEntry {
            file_path: "a.rs".to_string(),
            content_hash: "h".to_string(),
            size_bytes: 50,
            last_indexed_at: "2024-01-01T00:00:00Z".to_string(),
        };
        cm.update_file_index(&entry).unwrap();

        let stats = cm.get_cache_stats();
        assert_eq!(stats.file_index_count, 1);
        assert_eq!(stats.verify_cache_count, 1);
        assert_eq!(stats.review_cache_count, 1);
        assert_eq!(stats.capsule_cache_count, 1);
    }

    // -- schema versioning --

    #[test]
    fn schema_version_roundtrip() {
        let cm = make_cm();
        let version = db::get_schema_version(&cm.conn);
        assert!(version.is_some());
        assert!(version.unwrap() >= 1);
    }

    // -- store_verify replaces on same PK --

    #[test]
    fn verify_insert_or_replace() {
        let mut cm = make_cm();
        cm.store_verify("a.rs", "h1", "clippy", "c1", "v1", "fail", "[]")
            .unwrap();
        cm.store_verify(
            "a.rs",
            "h2",
            "clippy",
            "c2",
            "v2",
            "pass",
            r#"[{"ok":true}]"#,
        )
        .unwrap();
        // Only the latest should exist
        assert_eq!(cm.get_cache_stats().verify_cache_count, 1);
        let hit = cm.check_verify("a.rs", "h2", "clippy", "c2", "v2");
        assert!(hit.is_some());
        assert_eq!(hit.unwrap().status, "pass");
    }

    // -- review insert or replace --

    #[test]
    fn review_insert_or_replace() {
        let mut cm = make_cm();
        cm.store_review("a.rs", "h1", "safety", "p1", "hd1", "NEEDS_FIX", "[]")
            .unwrap();
        cm.store_review("a.rs", "h2", "safety", "p2", "hd2", "LGTM", "[]")
            .unwrap();
        assert_eq!(cm.get_cache_stats().review_cache_count, 1);
    }

    // -- disk_full guard --

    #[test]
    fn disk_full_flag_skips_writes() {
        let mut cm = make_cm();
        cm.disk_full = true;
        // store_verify should silently succeed
        cm.store_verify("a.rs", "h", "clippy", "c", "v", "pass", "[]")
            .unwrap();
        assert_eq!(cm.get_cache_stats().verify_cache_count, 0);
    }
}
