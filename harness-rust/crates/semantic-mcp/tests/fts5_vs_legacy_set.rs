use std::collections::BTreeSet;

use rusqlite::Connection;
use semantic_mcp::{db, registry, search, ServerContext};
use serde_json::{json, Value};
use tempfile::TempDir;

fn test_ctx() -> (ServerContext, TempDir) {
    let repo = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(repo.path().join("src")).unwrap();
    let conn = Connection::open_in_memory().unwrap();
    db::run_migrations(&conn).unwrap();
    let repo_root = repo.path().canonicalize().unwrap();
    (
        ServerContext::new(conn, "proj".to_string(), repo_root),
        repo,
    )
}

fn semantic_ids(result: &Value) -> BTreeSet<String> {
    result["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|item| item["semantic_id"].as_str())
        .map(str::to_string)
        .collect()
}

#[test]
fn fts5_whole_word_identifier_set_contains_legacy_like_set() {
    let (ctx, repo) = test_ctx();
    let mut components = Vec::new();
    for index in 0..1000 {
        let name = format!("Component{index:04}");
        let file_path = format!("src/component_{index:04}.rs");
        std::fs::write(
            repo.path().join(&file_path),
            format!("pub struct {name};\n"),
        )
        .unwrap();
        components.push(json!({
            "semantic_id": format!("fixture:{name}"),
            "name": name,
            "module": "fixture",
            "file_path": file_path,
            "kind": "struct"
        }));
    }
    registry::handle_upsert(&ctx, &json!({ "components": components })).unwrap();

    let query = "Component0500";
    let fts5 = search::handle_search(
        &ctx,
        &json!({
            "query": query,
            "scope_paths": ["src"],
            "limit": 10,
            "capsule_budget_tokens": 1000
        }),
    )
    .unwrap();
    let legacy = search::handle_search(
        &ctx,
        &json!({
            "query": query,
            "kind": "legacy-like",
            "scope_paths": ["src"],
            "limit": 10,
            "capsule_budget_tokens": 1000
        }),
    )
    .unwrap();

    let fts5_ids = semantic_ids(&fts5);
    let legacy_ids = semantic_ids(&legacy);
    assert!(!legacy_ids.is_empty());
    assert!(fts5_ids.is_superset(&legacy_ids));
}
