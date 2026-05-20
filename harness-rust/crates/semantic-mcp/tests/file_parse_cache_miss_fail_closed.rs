use rusqlite::Connection;
use semantic_mcp::{context_top_k, ServerContext};

#[test]
fn topk_fails_closed_when_file_parse_cache_entry_is_missing() {
    let repo_root = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(repo_root.path().join("src")).unwrap();
    std::fs::write(repo_root.path().join("src/lib.rs"), "fn alpha() {}\n").unwrap();

    let conn = Connection::open_in_memory().unwrap();
    semantic_mcp::db::run_migrations(&conn).unwrap();
    tree_sitter_index::db::run_tree_sitter_migrations(&conn).unwrap();
    let ctx = ServerContext::new(
        conn,
        "proj".to_string(),
        repo_root.path().canonicalize().unwrap(),
    );

    let error = context_top_k::handle_context_top_k(
        &ctx,
        &serde_json::json!({
            "project_id": "proj",
            "task_id": "task-1",
            "phase": "impl",
            "changed_files": ["src/lib.rs"]
        }),
    )
    .unwrap_err();
    assert!(error.contains("file_parse_cache miss"));
    assert!(error.contains("run context update first"));
}
