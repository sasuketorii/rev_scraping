use rusqlite::Connection;

#[test]
fn application_id_three_state_and_schema_precheck() {
    let tmp = tempfile::tempdir().unwrap();
    std::env::set_var("REVHARNESS_TEST_HARNESS", "1");
    std::env::set_var("SEMANTIC_MCP_HOME", tmp.path());

    let (conn, db_path) = semantic_mcp::db::open_project_connection("proj_marker").unwrap();
    let app_id: i64 = conn
        .query_row("PRAGMA application_id", [], |row| row.get(0))
        .unwrap();
    assert_eq!(app_id, semantic_mcp::db::REVHARNESS_APP_ID);
    drop(conn);

    let (conn, _) = semantic_mcp::db::open_project_connection("proj_marker").unwrap();
    let app_id: i64 = conn
        .query_row("PRAGMA application_id", [], |row| row.get(0))
        .unwrap();
    assert_eq!(app_id, semantic_mcp::db::REVHARNESS_APP_ID);
    drop(conn);

    let conn = Connection::open(&db_path).unwrap();
    conn.execute_batch("PRAGMA application_id = -559038737;")
        .unwrap();
    drop(conn);
    let error = semantic_mcp::db::open_project_connection("proj_marker").unwrap_err();
    assert!(error.contains("unexpected application_id"));

    let missing_schema = tmp.path().join("missing-schema.db");
    let conn = Connection::open(&missing_schema).unwrap();
    conn.execute_batch("CREATE TABLE only_one(id INTEGER PRIMARY KEY);")
        .unwrap();
    let error =
        semantic_mcp::db::validate_or_adopt_application_id(&conn, &missing_schema).unwrap_err();
    assert!(error.contains("schema validation failed"));
}
