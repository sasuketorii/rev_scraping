use rusqlite::Connection;
use semantic_mcp::{capsule, ServerContext};

#[test]
fn capsule_rejects_caller_supplied_top_k_symbols() {
    let conn = Connection::open_in_memory().unwrap();
    semantic_mcp::db::run_migrations(&conn).unwrap();
    tree_sitter_index::db::run_tree_sitter_migrations(&conn).unwrap();
    let ctx = ServerContext::new(conn, "proj".to_string(), std::env::current_dir().unwrap());

    let error = capsule::handle_capsule(
        &ctx,
        &serde_json::json!({
            "project_id": "proj",
            "task_id": "task-1",
            "phase": "impl",
            "context_token": "token-1",
            "context": {
                "top_k_symbols": ["caller:supplied"]
            }
        }),
    )
    .unwrap_err();
    assert!(error.contains("top_k_symbols is server-issued"));
    assert!(error.contains("provide context_token instead"));
}
