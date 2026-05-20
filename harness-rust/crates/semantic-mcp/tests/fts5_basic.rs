use rusqlite::Connection;
use semantic_mcp::{db, registry, search, ServerContext};
use serde_json::json;
use tempfile::TempDir;

fn test_ctx() -> (ServerContext, TempDir) {
    let repo = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(repo.path().join("src")).unwrap();
    std::fs::write(repo.path().join("src/auth.rs"), "pub struct AuthService;\n").unwrap();

    let conn = Connection::open_in_memory().unwrap();
    db::run_migrations(&conn).unwrap();
    let repo_root = repo.path().canonicalize().unwrap();
    (
        ServerContext::new(conn, "proj".to_string(), repo_root),
        repo,
    )
}

#[test]
fn fts5_upserted_component_is_matchable_with_bm25_rank() {
    let (ctx, _repo) = test_ctx();
    registry::handle_upsert(
        &ctx,
        &json!({
            "components": [{
                "semantic_id": "auth:AuthService",
                "name": "AuthService",
                "module": "auth",
                "file_path": "src/auth.rs",
                "kind": "struct"
            }]
        }),
    )
    .unwrap();

    let bm25_rank: f64 = ctx
        .conn
        .query_row(
            r#"
            SELECT bm25(components_fts)
            FROM components_fts
            WHERE components_fts MATCH '"AuthService"'
            "#,
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(bm25_rank.is_finite());

    let result = search::handle_search(
        &ctx,
        &json!({
            "query": "AuthService",
            "scope_paths": ["src"],
            "limit": 5,
            "capsule_budget_tokens": 500
        }),
    )
    .unwrap();
    assert_eq!(result["items"][0]["source"], "fts5");
    assert_eq!(result["items"][0]["semantic_id"], "auth:AuthService");
}
