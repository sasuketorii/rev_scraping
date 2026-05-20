//! Cache layer for the agent_base verification, review, and capsule pipelines.
//!
//! This crate provides [`CacheManager`], a SQLite-backed cache that stores
//! verification results, code review verdicts, prompt capsules (with LRU
//! eviction), and a file content index.  It coexists with the semantic-mcp
//! database by using its own `_cache_meta` table for schema versioning
//! (leaving `PRAGMA user_version` to semantic-mcp).
//!
//! # Quick start
//!
//! ```no_run
//! use harness_cache::CacheManager;
//!
//! let cm = CacheManager::new("my_project").expect("open cache");
//! // check / store verify, review, capsule, file_index ...
//! ```

pub mod constants;
pub mod db;
pub mod helpers;
pub mod manager;
pub mod types;

pub use manager::{capsule_cache_key, CacheManager};
pub use types::{
    AuditResult, CacheStats, CachedCapsule, CachedReview, CachedVerifyResult, FileIndexEntry,
    GcResult, MaintenanceResult,
};
