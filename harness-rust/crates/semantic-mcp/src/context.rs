//! Server context holding the database connection and project metadata.

use crate::clock::{Clock, SystemClock};
use lru::LruCache;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::num::NonZeroUsize;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const TOKEN_CACHE_CAPACITY: usize = 256;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TopKEntry {
    pub qualified_name: String,
    pub name: String,
    pub file_path: String,
    pub kind: String,
    pub rank_score: f64,
    pub rationale: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NormalizedContext {
    pub changed_files: Vec<String>,
    pub top_k_symbols: Vec<TopKEntry>,
    pub file_sha_rollup: String,
    pub index_version: u64,
    pub issued_at_unix_ms: u64,
}

pub type TokenCache = LruCache<String, (NormalizedContext, Instant)>;

/// Shared server context passed to all tool handlers.
#[allow(dead_code)]
pub struct ServerContext {
    /// The project identifier.
    pub project_id: String,
    /// Canonical repository root used to validate repo-relative paths.
    pub repo_root: PathBuf,
    /// Path to the SQLite database file.
    pub db_path: String,
    /// Open database connection.
    pub conn: Connection,
    /// Clock used for context token TTL checks.
    pub clock: Box<dyn Clock>,
    /// Server-issued context token cache.
    pub token_cache: Arc<Mutex<TokenCache>>,
}

impl ServerContext
where
    Self: Sized,
{
    pub fn new(conn: Connection, project_id: String, repo_root: PathBuf) -> Self {
        Self {
            db_path: ":memory:".to_string(),
            conn,
            project_id,
            repo_root,
            clock: Box::new(SystemClock),
            token_cache: new_token_cache(),
        }
    }

    pub fn with_db_path(mut self, db_path: String) -> Self {
        self.db_path = db_path;
        self
    }

    pub fn with_clock(mut self, clock: Box<dyn Clock>) -> Self {
        self.clock = clock;
        self
    }

    pub fn with_token_cache(mut self, cache: Arc<Mutex<TokenCache>>) -> Self {
        self.token_cache = cache;
        self
    }

    pub fn put_token_with_sweep(
        &self,
        token: String,
        normalized: NormalizedContext,
        ttl: Duration,
    ) -> Result<(), String> {
        let now = self.clock.now();
        let mut cache = self
            .token_cache
            .lock()
            .map_err(|_| "token cache lock poisoned".to_string())?;
        let expired = cache
            .iter()
            .filter(|(_, (_, issued_at))| {
                now.checked_duration_since(*issued_at)
                    .map(|age| age > ttl)
                    .unwrap_or(false)
            })
            .map(|(key, _)| key.clone())
            .collect::<Vec<_>>();
        for key in expired {
            cache.pop(&key);
        }
        cache.put(token, (normalized, now));
        Ok(())
    }
}

pub fn new_token_cache() -> Arc<Mutex<TokenCache>> {
    Arc::new(Mutex::new(LruCache::new(
        NonZeroUsize::new(TOKEN_CACHE_CAPACITY).unwrap(),
    )))
}
