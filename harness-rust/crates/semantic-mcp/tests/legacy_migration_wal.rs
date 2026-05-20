use rusqlite::Connection;

#[test]
fn legacy_migration_publishes_main_wal_and_shm_atomically() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let data = tmp.path().join("data");
    std::fs::create_dir_all(&home).unwrap();
    std::env::set_var("HOME", &home);
    std::env::set_var("REVHARNESS_TEST_HARNESS", "1");
    std::env::set_var("SEMANTIC_MCP_HOME", &data);

    let legacy = home
        .join(".semantic-mcp")
        .join("proj_wal")
        .join("semantic.db");
    std::fs::create_dir_all(legacy.parent().unwrap()).unwrap();
    let keeper = Connection::open(&legacy).unwrap();
    keeper
        .execute_batch(
            "
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            CREATE TABLE seed(id INTEGER PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO seed(value) VALUES ('legacy');
            ",
        )
        .unwrap();

    assert!(legacy.exists());
    assert!(semantic_mcp::db::path_with_suffix(&legacy, "-wal").exists());
    assert!(semantic_mcp::db::path_with_suffix(&legacy, "-shm").exists());

    semantic_mcp::db::migrate_legacy_db_if_needed("proj_wal").unwrap();
    let new = shared::paths::semantic_mcp_db_path("proj_wal").unwrap();

    assert!(new.exists());
    assert!(semantic_mcp::db::path_with_suffix(&new, "-wal").exists());
    assert!(semantic_mcp::db::path_with_suffix(&new, "-shm").exists());
    assert!(!legacy.exists());
    assert!(!semantic_mcp::db::path_with_suffix(&legacy, "-wal").exists());
    assert!(!semantic_mcp::db::path_with_suffix(&legacy, "-shm").exists());
    drop(keeper);
}
