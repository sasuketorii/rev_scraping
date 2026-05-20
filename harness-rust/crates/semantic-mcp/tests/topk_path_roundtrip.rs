use rusqlite::Connection;
use semantic_mcp::{context_top_k, ServerContext};
use tree_sitter_index::IndexConfig;

#[test]
fn topk_returns_repo_relative_symbol_paths() {
    let repo_root = tempfile::tempdir().unwrap();
    let src_dir = repo_root.path().join("src");
    std::fs::create_dir_all(&src_dir).unwrap();
    let file_path = src_dir.join("lib.rs");
    std::fs::write(
        &file_path,
        "pub fn alpha() {}\npub fn beta() { alpha(); }\n",
    )
    .unwrap();
    let repo_root_path = repo_root.path().canonicalize().unwrap();
    let file_path = file_path.canonicalize().unwrap();

    let mut conn = Connection::open_in_memory().unwrap();
    semantic_mcp::db::run_migrations(&conn).unwrap();
    tree_sitter_index::db::run_tree_sitter_migrations(&conn).unwrap();
    tree_sitter_index::incremental::index_files(
        &mut conn,
        "proj",
        &[(file_path.clone(), "rust".to_string(), "hash-1".to_string())],
        &IndexConfig::default(),
        false,
    )
    .unwrap();

    let ctx = ServerContext::new(conn, "proj".to_string(), repo_root_path);
    let response = context_top_k::handle_context_top_k(
        &ctx,
        &serde_json::json!({
            "project_id": "proj",
            "task_id": "task-1",
            "phase": "impl",
            "changed_files": ["src/lib.rs"],
            "k": 8
        }),
    )
    .unwrap();
    let entries = response["top_k_symbols"].as_array().unwrap();
    assert!(!entries.is_empty());
    for entry in entries {
        let file_path = entry["file_path"].as_str().unwrap();
        assert!(
            !file_path.starts_with('/'),
            "path should be repo-relative: {file_path}"
        );
        assert_eq!(file_path, "src/lib.rs");
    }
}
