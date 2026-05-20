use rusqlite::Connection;

#[test]
fn foreign_application_id_is_rejected_fail_closed() {
    let tmp = tempfile::tempdir().unwrap();
    std::env::set_var("REVHARNESS_TEST_HARNESS", "1");
    std::env::set_var("SEMANTIC_MCP_HOME", tmp.path());

    let db_path = shared::paths::semantic_mcp_db_path("foreign").unwrap();
    std::fs::create_dir_all(db_path.parent().unwrap()).unwrap();
    let conn = Connection::open(&db_path).unwrap();
    conn.execute_batch(
        "
        CREATE TABLE foreign_table(id INTEGER PRIMARY KEY);
        PRAGMA application_id = -559038737;
        ",
    )
    .unwrap();
    drop(conn);

    let error = semantic_mcp::db::open_project_connection("foreign").unwrap_err();
    assert!(error.contains("unexpected application_id"));
}
