use std::collections::HashSet;

use rusqlite::{params, Connection, TransactionBehavior};
use tree_sitter_index::{db, incremental, IndexConfig};

fn count_by_file(conn: &Connection, table: &str, project_id: &str, file_path: &str) -> i64 {
    let sql = match table {
        "symbols" => "SELECT COUNT(*) FROM symbols WHERE project_id = ?1 AND file_path = ?2",
        "file_parse_cache" => {
            "SELECT COUNT(*) FROM file_parse_cache WHERE project_id = ?1 AND file_path = ?2"
        }
        _ => panic!("unsupported table: {table}"),
    };
    conn.query_row(sql, params![project_id, file_path], |row| row.get(0))
        .unwrap()
}

fn dependency_count_from_file(conn: &Connection, project_id: &str, file_path: &str) -> i64 {
    conn.query_row(
        "SELECT COUNT(*)
         FROM symbol_dependencies
         WHERE project_id = ?1
           AND from_symbol_id IN (
               SELECT id FROM symbols WHERE project_id = ?1 AND file_path = ?2
           )",
        params![project_id, file_path],
        |row| row.get(0),
    )
    .unwrap()
}

#[test]
fn gc_removes_symbols_dependencies_and_cache_for_paths_missing_from_snapshot() {
    let mut conn = Connection::open_in_memory().unwrap();
    db::run_tree_sitter_migrations(&conn).unwrap();

    let dir = tempfile::tempdir().unwrap();
    let a_path = dir.path().join("a.rs");
    let b_path = dir.path().join("b.rs");
    let c_path = dir.path().join("c.rs");
    std::fs::write(&a_path, "pub fn a() {}\n").unwrap();
    std::fs::write(&b_path, "pub fn b() {}\n").unwrap();
    std::fs::write(&c_path, "pub fn c() { a(); }\n").unwrap();

    // (read_path = absolute tempdir path, index_key = repo-relative DB value).
    let a_file = "a.rs".to_string();
    let b_file = "b.rs".to_string();
    let c_file = "c.rs".to_string();
    let all_files = vec![
        (
            a_path.clone(),
            std::path::PathBuf::from(&a_file),
            "rust".to_string(),
            "hash-a".to_string(),
        ),
        (
            b_path.clone(),
            std::path::PathBuf::from(&b_file),
            "rust".to_string(),
            "hash-b".to_string(),
        ),
        (
            c_path.clone(),
            std::path::PathBuf::from(&c_file),
            "rust".to_string(),
            "hash-c".to_string(),
        ),
    ];
    incremental::index_files(&mut conn, "proj", &all_files, &IndexConfig::default(), true).unwrap();
    assert!(count_by_file(&conn, "symbols", "proj", &c_file) > 0);
    assert!(dependency_count_from_file(&conn, "proj", &c_file) > 0);
    assert_eq!(count_by_file(&conn, "file_parse_cache", "proj", &c_file), 1);
    conn.execute(
        "UPDATE file_parse_cache SET updated_at_unix_ms = 0 WHERE project_id = ?1",
        params!["proj"],
    )
    .unwrap();

    let snapshot_files = vec![
        (
            a_path,
            std::path::PathBuf::from(&a_file),
            "rust".to_string(),
            "hash-a".to_string(),
        ),
        (
            b_path,
            std::path::PathBuf::from(&b_file),
            "rust".to_string(),
            "hash-b".to_string(),
        ),
    ];
    incremental::index_files(
        &mut conn,
        "proj",
        &snapshot_files,
        &IndexConfig::default(),
        true,
    )
    .unwrap();

    assert_eq!(count_by_file(&conn, "symbols", "proj", &c_file), 0);
    assert_eq!(dependency_count_from_file(&conn, "proj", &c_file), 0);
    assert_eq!(count_by_file(&conn, "file_parse_cache", "proj", &c_file), 0);

    assert!(count_by_file(&conn, "symbols", "proj", &a_file) > 0);
    assert!(count_by_file(&conn, "symbols", "proj", &b_file) > 0);
    assert_eq!(count_by_file(&conn, "file_parse_cache", "proj", &a_file), 1);
    assert_eq!(count_by_file(&conn, "file_parse_cache", "proj", &b_file), 1);
}

#[test]
fn gc_generation_guard_preserves_rows_newer_than_transaction_start() {
    let mut conn = Connection::open_in_memory().unwrap();
    db::run_tree_sitter_migrations(&conn).unwrap();

    let dir = tempfile::tempdir().unwrap();
    let c_path = dir.path().join("c.rs");
    std::fs::write(&c_path, "pub fn c() {}\n").unwrap();
    let c_file = "c.rs".to_string();
    let files = vec![(
        c_path,
        std::path::PathBuf::from(&c_file),
        "rust".to_string(),
        "hash-c".to_string(),
    )];
    incremental::index_files(&mut conn, "proj", &files, &IndexConfig::default(), true).unwrap();

    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    let tx_start_unix_ms = 1_u64;
    let updated = tx
        .execute(
            "UPDATE file_parse_cache
             SET updated_at_unix_ms = ?1
             WHERE project_id = ?2 AND file_path = ?3",
            params![2_i64, "proj", &c_file],
        )
        .unwrap();
    assert_eq!(updated, 1);

    let snapshot_paths = HashSet::new();
    let report =
        db::gc_symbols_not_in_snapshot_in_tx(&tx, "proj", &snapshot_paths, tx_start_unix_ms)
            .unwrap();
    assert_eq!(report, db::GcReport::default());
    tx.commit().unwrap();

    assert!(count_by_file(&conn, "symbols", "proj", &c_file) > 0);
    assert_eq!(count_by_file(&conn, "file_parse_cache", "proj", &c_file), 1);
}
