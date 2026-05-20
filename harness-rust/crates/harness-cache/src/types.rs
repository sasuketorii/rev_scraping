//! Public types returned by [`CacheManager`](crate::CacheManager) methods.

use serde::{Deserialize, Serialize};

/// A row from the `file_index` table.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileIndexEntry {
    /// Relative file path (normalized, forward-slash).
    pub file_path: String,
    /// SHA-256 hex digest of the file contents.
    pub content_hash: String,
    /// Byte size of the file.
    pub size_bytes: u64,
    /// ISO-8601 timestamp of last indexing.
    pub last_indexed_at: String,
}

/// Cached verification result returned by [`CacheManager::check_verify`](crate::CacheManager::check_verify).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CachedVerifyResult {
    /// Tool name (e.g. `"clippy"`).
    pub tool: String,
    /// Pass / fail / warn status.
    pub status: String,
    /// JSON-encoded findings array.
    pub findings: String,
    /// ISO-8601 timestamp when the result was stored.
    pub verified_at: String,
}

/// Cached review result returned by [`CacheManager::check_review`](crate::CacheManager::check_review).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CachedReview {
    /// Reviewer name (e.g. `"safety"`).
    pub reviewer: String,
    /// Verdict (e.g. `"LGTM"`, `"NEEDS_FIX"`).
    pub verdict: String,
    /// JSON-encoded findings array.
    pub findings: String,
    /// ISO-8601 timestamp when the review was stored.
    pub reviewed_at: String,
}

/// Cached capsule returned by [`CacheManager::check_capsule`](crate::CacheManager::check_capsule).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CachedCapsule {
    /// JSON-encoded capsule body.
    pub json: String,
    /// SHA-256 hex digest of the capsule JSON.
    pub sha256: String,
    /// Estimated token count.
    pub tokens: u32,
    /// ISO-8601 timestamp when last accessed (for LRU).
    pub last_accessed_at: String,
}

/// Aggregate statistics across all cache tables.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CacheStats {
    /// Number of rows in `file_index`.
    pub file_index_count: u64,
    /// Number of rows in `verify_cache`.
    pub verify_cache_count: u64,
    /// Number of rows in `review_cache`.
    pub review_cache_count: u64,
    /// Number of rows in `capsule_cache`.
    pub capsule_cache_count: u64,
    /// Total database size in bytes (page_count * page_size).
    pub total_size_bytes: u64,
}

/// Result of a cache audit run.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AuditResult {
    /// Number of cache entries sampled.
    pub samples_checked: u32,
    /// Number of entries whose config or tool version no longer match.
    pub mismatches: u32,
    /// Ratio of mismatches to samples checked.
    pub mismatch_rate: f64,
    /// Tools whose entire cache was invalidated due to high mismatch rate.
    pub invalidated_tools: Vec<String>,
}

/// Result of a full maintenance run.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MaintenanceResult {
    /// Rows removed by [`CacheManager::gc_deleted_files`](crate::CacheManager::gc_deleted_files).
    pub gc_result: GcResult,
    /// Rows removed by staleness eviction.
    pub stale_evicted: u64,
    /// Whether a VACUUM was performed.
    pub vacuumed: bool,
}

/// Result of garbage-collecting entries for deleted files.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct GcResult {
    /// Number of rows removed from `file_index`.
    pub file_index_removed: u64,
    /// Number of rows removed from `verify_cache`.
    pub verify_cache_removed: u64,
    /// Number of rows removed from `review_cache`.
    pub review_cache_removed: u64,
}
