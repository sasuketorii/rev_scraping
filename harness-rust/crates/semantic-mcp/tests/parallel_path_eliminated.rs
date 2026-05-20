#[test]
fn agent_core_imports_shared_freshness() {
    let root = workspace_root();
    let source = std::fs::read_to_string(root.join("crates/agent-core/src/cmd/capsule.rs"))
        .expect("read agent-core capsule source");
    assert!(
        source.contains("use shared::freshness::"),
        "agent-core capsule path must import shared::freshness"
    );
}

#[test]
fn context_topk_has_no_local_freshness_helpers() {
    let root = workspace_root();
    let source = std::fs::read_to_string(root.join("crates/semantic-mcp/src/context_top_k.rs"))
        .expect("read context_top_k source");
    assert!(
        !source.contains("fn compute_file_sha_rollup"),
        "context_top_k must not keep a local compute_file_sha_rollup implementation"
    );
    assert!(
        !source.contains("fn read_index_version"),
        "context_top_k must not keep a local read_index_version implementation"
    );
}

fn workspace_root() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(std::path::Path::parent)
        .expect("workspace root")
        .to_path_buf()
}
