use rusqlite::Connection;
use semantic_mcp::{capsule, context_top_k, ServerContext};
use tree_sitter_index::IndexConfig;

#[test]
fn capsule_fails_closed_when_file_parse_cache_changes_after_token_issue() {
    let repo_root = tempfile::tempdir().unwrap();
    let repo_root_path = repo_root.path().canonicalize().unwrap();
    let db_path = repo_root_path.join("semantic.db");
    let src_dir = repo_root_path.join("src");
    std::fs::create_dir_all(&src_dir).unwrap();
    let file_path = src_dir.join("lib.rs");
    std::fs::write(&file_path, "pub fn alpha() {}\n").unwrap();
    let file_path = file_path.canonicalize().unwrap();

    let mut conn = semantic_mcp::db::open_connection(&db_path).unwrap();
    semantic_mcp::db::run_migrations(&conn).unwrap();
    tree_sitter_index::db::run_tree_sitter_migrations(&conn).unwrap();
    tree_sitter_index::incremental::index_files(
        &mut conn,
        "proj",
        &[(
            file_path.clone(),
            std::path::PathBuf::from("src/lib.rs"),
            "rust".to_string(),
            "hash-1".to_string(),
        )],
        &IndexConfig::default(),
        false,
    )
    .unwrap();
    let ctx = ServerContext::new(conn, "proj".to_string(), repo_root_path.clone())
        .with_db_path(db_path.display().to_string());

    let topk = context_top_k::handle_context_top_k(
        &ctx,
        &serde_json::json!({
            "project_id": "proj",
            "task_id": "task-1",
            "phase": "impl",
            "changed_files": ["src/lib.rs"]
        }),
    )
    .unwrap();
    let token = topk["context_token"].as_str().unwrap();

    let mut second_conn = Connection::open(&db_path).unwrap();
    second_conn
        .pragma_update(None, "busy_timeout", 30000)
        .unwrap();
    tree_sitter_index::incremental::index_files(
        &mut second_conn,
        "proj",
        &[(
            file_path,
            std::path::PathBuf::from("src/lib.rs"),
            "rust".to_string(),
            "hash-2".to_string(),
        )],
        &IndexConfig::default(),
        false,
    )
    .unwrap();

    let error = capsule::handle_capsule(
        &ctx,
        &serde_json::json!({
            "project_id": "proj",
            "task_id": "task-1",
            "phase": "impl",
            "context_token": token
        }),
    )
    .unwrap_err();
    assert!(error.contains("file_parse_cache changed since context_token was issued"));
    assert!(error.contains("cache freshness violation"));

    let persisted_capsules: i64 = ctx
        .conn
        .query_row("SELECT COUNT(*) FROM capsules", [], |row| row.get(0))
        .unwrap();
    assert_eq!(
        persisted_capsules, 0,
        "STALE context_token must not emit or persist a capsule body"
    );
}
