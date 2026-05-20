use std::fs;

#[test]
fn placement_v2_surfaces_use_shared_path() {
    let tmp = tempfile::tempdir().unwrap();
    std::env::set_var("REVHARNESS_TEST_HARNESS", "1");
    std::env::set_var("SEMANTIC_MCP_HOME", tmp.path());

    let expected = tmp.path().join("v1").join("proj_v2").join("semantic.db");
    assert_eq!(
        shared::paths::semantic_mcp_db_path("proj_v2").unwrap(),
        expected
    );
    assert_eq!(
        semantic_mcp::db::resolve_db_path("proj_v2").unwrap(),
        expected
    );

    let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let agent_core = fs::read_to_string(
        manifest_dir
            .join("../agent-core/src/cmd/orchestrate.rs")
            .canonicalize()
            .unwrap(),
    )
    .unwrap();
    let harness_cache = fs::read_to_string(
        manifest_dir
            .join("../harness-cache/src/db.rs")
            .canonicalize()
            .unwrap(),
    )
    .unwrap();
    assert!(agent_core.contains("shared::paths::semantic_mcp_db_path(project_id)"));
    assert!(harness_cache.contains("shared::paths::semantic_mcp_db_path(project_id)"));
}
