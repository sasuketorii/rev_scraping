use std::sync::{Arc, Barrier};
use std::thread;

use rusqlite::Connection;
use tree_sitter_index::{db, incremental, IndexConfig};

#[test]
fn index_version_increments_monotonically_for_repeated_indexing() {
    let mut conn = Connection::open_in_memory().unwrap();
    db::run_tree_sitter_migrations(&conn).unwrap();

    let dir = tempfile::tempdir().unwrap();
    let file_path = dir.path().join("lib.rs");
    std::fs::write(&file_path, "fn hello() {}\n").unwrap();
    let config = IndexConfig::default();

    for expected in 1..=8_u64 {
        let files = vec![(
            file_path.clone(),
            "rust".to_string(),
            format!("hash-{expected}"),
        )];
        incremental::index_files(&mut conn, "proj", &files, &config, false).unwrap();
        assert_eq!(db::read_index_version(&conn).unwrap(), expected);
    }
}

#[test]
fn index_version_serializes_two_concurrent_writers_without_skip_or_duplicate() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("semantic.db");
    let a_path = dir.path().join("a.rs");
    let b_path = dir.path().join("b.rs");
    std::fs::write(&a_path, "fn a() {}\n").unwrap();
    std::fs::write(&b_path, "fn b() {}\n").unwrap();
    {
        let conn = Connection::open(&db_path).unwrap();
        conn.pragma_update(None, "journal_mode", "WAL").unwrap();
        conn.pragma_update(None, "busy_timeout", 30000).unwrap();
        db::run_tree_sitter_migrations(&conn).unwrap();
    }

    let barrier = Arc::new(Barrier::new(2));
    let mut handles = Vec::new();
    for (path, hash) in [(a_path, "hash-a"), (b_path, "hash-b")] {
        let db_path = db_path.clone();
        let barrier = Arc::clone(&barrier);
        handles.push(thread::spawn(move || {
            barrier.wait();
            let files = vec![(path, "rust".to_string(), hash.to_string())];
            let mut conn = Connection::open(&db_path).unwrap();
            conn.pragma_update(None, "busy_timeout", 30000).unwrap();
            incremental::index_files(&mut conn, "proj", &files, &IndexConfig::default(), false)
                .unwrap();
        }));
    }

    for handle in handles {
        handle.join().unwrap();
    }

    let conn = Connection::open(&db_path).unwrap();
    db::run_tree_sitter_migrations(&conn).unwrap();
    assert_eq!(db::read_index_version(&conn).unwrap(), 2);
}
