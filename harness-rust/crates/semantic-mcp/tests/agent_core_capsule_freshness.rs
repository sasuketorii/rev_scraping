use std::process::Command;

use agent_core::cmd::capsule::build_capsule_with_symbols;
use rusqlite::Connection;
use tree_sitter_index::IndexConfig;

struct CurrentDirGuard {
    previous: std::path::PathBuf,
}

impl CurrentDirGuard {
    fn enter(path: &std::path::Path) -> Self {
        let previous = std::env::current_dir().unwrap();
        std::env::set_current_dir(path).unwrap();
        Self { previous }
    }
}

impl Drop for CurrentDirGuard {
    fn drop(&mut self) {
        std::env::set_current_dir(&self.previous).unwrap();
    }
}

#[test]
fn agent_core_capsule_freshness_changes_rollup_and_sha() {
    let repo_root = tempfile::tempdir().unwrap();
    let status = Command::new("git")
        .arg("init")
        .current_dir(repo_root.path())
        .status()
        .unwrap();
    assert!(status.success());

    let repo_root_path = repo_root.path().canonicalize().unwrap();
    let _cwd = CurrentDirGuard::enter(&repo_root_path);
    let src_dir = repo_root_path.join("src");
    std::fs::create_dir_all(&src_dir).unwrap();
    let file_path = src_dir.join("lib.rs");
    std::fs::write(&file_path, "pub fn alpha() {}\n").unwrap();
    let file_path = file_path.canonicalize().unwrap();
    let plan_path = repo_root_path.join("plan.md");
    std::fs::write(&plan_path, "task_id: task-freshness\n- constraint: test\n").unwrap();
    let db_path = repo_root_path.join("semantic.db");

    let mut conn = Connection::open(&db_path).unwrap();
    tree_sitter_index::db::run_tree_sitter_migrations(&conn).unwrap();
    tree_sitter_index::incremental::index_files(
        &mut conn,
        "proj",
        &[(
            file_path.clone(),
            std::path::PathBuf::from("src/lib.rs"),
            "rust".to_string(),
            "hash-1".to_string(),
        )],
        &IndexConfig::default(),
        false, // gc_orphans: test does not exercise snapshot diff
    )
    .unwrap();

    let changed_files = vec!["src/lib.rs".to_string()];
    let first = build_capsule_with_symbols(&plan_path, &changed_files, 220, &db_path, "proj", None)
        .unwrap();
    assert!(!first.file_sha_rollup.is_empty());

    // file_parse_cache is now keyed by the repo-relative index_key.
    conn.execute(
        "UPDATE file_parse_cache SET file_hash = ?1 WHERE project_id = ?2 AND file_path = ?3",
        rusqlite::params!["hash-2", "proj", "src/lib.rs"],
    )
    .unwrap();

    let second =
        build_capsule_with_symbols(&plan_path, &changed_files, 220, &db_path, "proj", None)
            .unwrap();
    assert_ne!(first.file_sha_rollup, second.file_sha_rollup);
    assert_ne!(first.sha256, second.sha256);
}
