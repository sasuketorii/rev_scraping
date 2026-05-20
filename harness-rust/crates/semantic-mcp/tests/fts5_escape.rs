use rusqlite::Connection;
use semantic_mcp::{db, search, ServerContext};
use serde_json::json;
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

#[test]
fn fts5_escapes_operator_like_user_queries_as_phrases() {
    let (ctx, repo) = test_ctx();
    let cases = [
        ("Quote \" Probe", "quote"),
        ("NEAR Probe", "near"),
        ("OR Probe", "or"),
        ("Star * Probe", "star"),
        ("AND Probe", "and"),
        ("-DashProbe", "dash"),
        ("name:PrefixProbe", "prefix"),
    ];
    for (name, slug) in cases {
        let file_path = format!("src/{slug}.rs");
        std::fs::write(repo.path().join(&file_path), format!("// {name}\n")).unwrap();
        let semantic_id = format!("escape:{slug}");
        ctx.conn
            .execute(
                "INSERT INTO components (
                    project_id, semantic_id, name, module, file_path, kind,
                    exports, imports, hash, status, idem, updated_at
                 ) VALUES (?1, ?2, ?3, 'escape', ?4, 'function', '[]', '[]', '', 'active', '', datetime('now'))",
                rusqlite::params!["proj", semantic_id, name, file_path],
            )
            .unwrap();
        let row_id: i64 = ctx
            .conn
            .query_row(
                "SELECT id FROM components WHERE project_id = 'proj' AND semantic_id = ?1",
                rusqlite::params![format!("escape:{slug}")],
                |row| row.get(0),
            )
            .unwrap();
        ctx.conn
            .execute(
                "INSERT OR REPLACE INTO components_fts(rowid, name, semantic_id, module, kind, file_path)
                 SELECT id, name, semantic_id, module, kind, file_path
                 FROM components
                 WHERE id = ?1",
                rusqlite::params![row_id],
            )
            .unwrap();
    }

    for (query, slug) in cases {
        let result = search::handle_search(
            &ctx,
            &json!({
                "query": query,
                "scope_paths": ["src"],
                "limit": 10,
                "capsule_budget_tokens": 1000
            }),
        )
        .unwrap_or_else(|e| {
            panic!("query {query:?} should be escaped without syntax failure: {e}")
        });
        let ids = result["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|item| item["semantic_id"].as_str())
            .collect::<Vec<_>>();
        assert!(
            ids.contains(&format!("escape:{slug}").as_str()),
            "query {query:?} did not return escape:{slug}: {ids:?}"
        );
    }
}
