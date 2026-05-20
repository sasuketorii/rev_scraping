use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use rusqlite::Connection;
use semantic_mcp::context::{NormalizedContext, TopKEntry};
use semantic_mcp::{capsule, Clock, ServerContext};

struct TestClock {
    base_instant: Instant,
    elapsed_ms: Arc<AtomicU64>,
    unix_base_ms: u64,
}

impl Clock for TestClock {
    fn now(&self) -> Instant {
        self.base_instant + Duration::from_millis(self.elapsed_ms.load(Ordering::SeqCst))
    }

    fn now_unix_ms(&self) -> u64 {
        self.unix_base_ms + self.elapsed_ms.load(Ordering::SeqCst)
    }
}

#[test]
fn capsule_rejects_expired_context_token() {
    let elapsed_ms = Arc::new(AtomicU64::new(0));
    let conn = Connection::open_in_memory().unwrap();
    semantic_mcp::db::run_migrations(&conn).unwrap();
    tree_sitter_index::db::run_tree_sitter_migrations(&conn).unwrap();
    let ctx = ServerContext::new(conn, "proj".to_string(), std::env::current_dir().unwrap())
        .with_clock(Box::new(TestClock {
            base_instant: Instant::now(),
            elapsed_ms: Arc::clone(&elapsed_ms),
            unix_base_ms: 1_700_000_000_000,
        }));
    ctx.token_cache.lock().unwrap().put(
        "token-1".to_string(),
        (
            NormalizedContext {
                changed_files: Vec::new(),
                top_k_symbols: Vec::<TopKEntry>::new(),
                file_sha_rollup: semantic_mcp::util::sha256_hex(""),
                index_version: 1,
                issued_at_unix_ms: ctx.clock.now_unix_ms(),
            },
            ctx.clock.now(),
        ),
    );

    elapsed_ms.store(1_801_000, Ordering::SeqCst);
    let error = capsule::handle_capsule(
        &ctx,
        &serde_json::json!({
            "project_id": "proj",
            "task_id": "task-1",
            "phase": "impl",
            "context_token": "token-1"
        }),
    )
    .unwrap_err();
    assert!(error.contains("context_token expired"));
}
