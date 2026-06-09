use rusqlite::Connection;

fn seed_db(path: &std::path::Path, last_accessed_seconds: i64) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS _ts_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        ",
    )
    .unwrap();
    conn.execute(
        "INSERT OR REPLACE INTO _ts_meta(key, value) VALUES('last_accessed', ?1)",
        rusqlite::params![last_accessed_seconds.to_string()],
    )
    .unwrap();
}

#[test]
fn gc_dry_run_reports_candidates_without_deleting() {
    let tmp = tempfile::tempdir().unwrap();
    std::env::set_var("REVHARNESS_TEST_HARNESS", "1");
    std::env::set_var("SEMANTIC_MCP_HOME", tmp.path());

    let old = shared::paths::semantic_mcp_db_path("old_proj").unwrap();
    let recent = shared::paths::semantic_mcp_db_path("recent_proj").unwrap();
    let now = chrono::Utc::now().timestamp();
    seed_db(&old, now - 40 * 24 * 60 * 60);
    seed_db(&recent, now);

    let output = semantic_mcp::admin_gc::run_gc(semantic_mcp::admin_gc::GcOptions {
        older_than_days: 30,
        dry_run: true,
        force: false,
        ..Default::default()
    })
    .unwrap();

    assert_eq!(output.scanned, 2);
    assert_eq!(output.candidates.len(), 1);
    assert!(output.candidates[0].path.ends_with("old_proj/semantic.db"));
    assert!(output.deleted.is_empty());
    assert_eq!(output.freed_bytes, 0);
    assert!(old.exists());
    assert!(recent.exists());
}
