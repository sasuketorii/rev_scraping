use rusqlite::Connection;
use semantic_mcp::{db, registry, search, search::fts5_escape, ServerContext};
use serde_json::{json, Value};
use tempfile::TempDir;

fn test_ctx() -> (ServerContext, TempDir) {
    let repo = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(repo.path().join("src")).unwrap();
    std::fs::write(
        repo.path().join("src/partial.rs"),
        "pub fn outer_innerValue() {}\n",
    )
    .unwrap();
    let conn = Connection::open_in_memory().unwrap();
    db::run_migrations(&conn).unwrap();
    let repo_root = repo.path().canonicalize().unwrap();
    (
        ServerContext::new(conn, "proj".to_string(), repo_root),
        repo,
    )
}

fn ids(result: &Value) -> Vec<String> {
    result["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|item| item["semantic_id"].as_str())
        .map(str::to_string)
        .collect()
}

#[test]
fn partial_identifier_substring_is_legacy_like_only_without_prefix_search() {
    let (ctx, _repo) = test_ctx();
    registry::handle_upsert(
        &ctx,
        &json!({
            "components": [{
                "semantic_id": "partial:outer_innerValue",
                "name": "outer_innerValue",
                "module": "partial",
                "file_path": "src/partial.rs",
                "kind": "function"
            }]
        }),
    )
    .unwrap();

    let fts5 = search::handle_search(
        &ctx,
        &json!({
            "query": "_inner",
            "scope_paths": ["src"],
            "limit": 10,
            "capsule_budget_tokens": 1000
        }),
    )
    .unwrap();
    let legacy = search::handle_search(
        &ctx,
        &json!({
            "query": "_inner",
            "kind": "legacy-like",
            "scope_paths": ["src"],
            "limit": 10,
            "capsule_budget_tokens": 1000
        }),
    )
    .unwrap();

    assert!(!ids(&fts5).contains(&"partial:outer_innerValue".to_string()));
    assert!(ids(&legacy).contains(&"partial:outer_innerValue".to_string()));
}

#[test]
fn fts5_with_prefix_star_is_phrase_escaped_as_literal() {
    let escaped = fts5_escape("freshness*");
    assert_eq!(escaped, r#""freshness*""#);
}
