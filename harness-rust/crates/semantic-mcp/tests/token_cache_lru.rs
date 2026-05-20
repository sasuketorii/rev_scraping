use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use rusqlite::Connection;
use semantic_mcp::context::{NormalizedContext, TopKEntry};
use semantic_mcp::{Clock, ServerContext};

struct TestClock {
    base: Instant,
    elapsed_ms: Arc<AtomicU64>,
}

impl Clock for TestClock {
    fn now(&self) -> Instant {
        self.base + Duration::from_millis(self.elapsed_ms.load(Ordering::SeqCst))
    }

    fn now_unix_ms(&self) -> u64 {
        self.elapsed_ms.load(Ordering::SeqCst)
    }
}

fn normalized(ctx: &ServerContext) -> NormalizedContext {
    NormalizedContext {
        changed_files: Vec::new(),
        top_k_symbols: Vec::<TopKEntry>::new(),
        file_sha_rollup: semantic_mcp::util::sha256_hex(""),
        index_version: 1,
        issued_at_unix_ms: ctx.clock.now_unix_ms(),
    }
}

#[test]
fn token_cache_is_lru_capped_and_sweeps_expired_entries() {
    let elapsed_ms = Arc::new(AtomicU64::new(0));
    let conn = Connection::open_in_memory().unwrap();
    let ctx = ServerContext::new(conn, "proj".to_string(), std::env::current_dir().unwrap())
        .with_clock(Box::new(TestClock {
            base: Instant::now(),
            elapsed_ms: Arc::clone(&elapsed_ms),
        }));

    for idx in 0..257 {
        ctx.put_token_with_sweep(
            format!("token-{idx}"),
            normalized(&ctx),
            Duration::from_secs(1800),
        )
        .unwrap();
    }
    {
        let mut cache = ctx.token_cache.lock().unwrap();
        assert_eq!(cache.len(), 256);
        assert!(cache.get("token-0").is_none());
        assert!(cache.get("token-256").is_some());
    }

    ctx.put_token_with_sweep(
        "expired".to_string(),
        normalized(&ctx),
        Duration::from_secs(1),
    )
    .unwrap();
    elapsed_ms.store(2_000, Ordering::SeqCst);
    ctx.put_token_with_sweep(
        "fresh".to_string(),
        normalized(&ctx),
        Duration::from_secs(1),
    )
    .unwrap();
    let mut cache = ctx.token_cache.lock().unwrap();
    assert!(cache.get("expired").is_none());
    assert!(cache.get("fresh").is_some());
}
