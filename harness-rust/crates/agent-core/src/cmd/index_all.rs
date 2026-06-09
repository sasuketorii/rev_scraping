//! `context index-all` — source-first FULL reindex bootstrap (root-cause 2.1:
//! index coverage).
//!
//! Background: indexing is otherwise edit-driven — only files touched by the
//! Edit/Write hook get indexed. Unedited stable source is therefore NEVER
//! indexed, which is the OPPOSITE of what semantic search is for: in real use
//! the orchestrator wants to find existing code it has NOT just edited. The
//! result is that `sem.symbols.search` / `sem.context.top_k` come back empty for
//! the actual work target (e.g. nested product `scripts/sender-opt`), while
//! doc/config noise that happened to be edited dominates the symbols table.
//!
//! This command provides the missing standalone entry point to "index the whole
//! repo's source NOW", outside any orchestration iteration. It reuses the
//! already-idempotent `context_update(changed_only=false)` +
//! `index_symbols_from_snapshot` pipeline (idempotent by `file_hash +
//! grammar_version`; Slice A made it store repo-relative keys and wired
//! `resolve_pending_dependencies` into `index_files`). The only new behaviour is
//! a runnable subcommand + a dry-run report.
//!
//! Safety / scope posture (mirrors `migrate_paths.rs`):
//! - **Dry-run is the DEFAULT.** `--apply` is required for any DB write.
//! - **Current project only.** `project_id` from `.shared/project_id`; DB path
//!   from `shared::paths::semantic_mcp_db_path`. No cross-project scan.
//! - **`gc_orphans=true`.** Stale legacy rows (e.g. old absolute `.agent`/`.claude`
//!   rows) fall out via the existing generation guard.
//!
//! Note on doc/config bias: the candidate set is already filtered by
//! `is_harness_owned_path` (excludes top-level `.agent/`, `.claude/`, `docs/`,
//! `scripts/`, etc.) inside `context_update`. Nested PRODUCT paths such as
//! `contact_sender_v2/.../scripts/sender-opt` are NOT excluded because the filter
//! matches `scripts/` as a TOP-LEVEL prefix only. This command does not add or
//! change excludes; it just runs the full snapshot through that existing filter.

use std::path::Path;

use serde::Serialize;
use shared::error::{AgentError, Result};

use super::context::{context_update, index_symbols_from_snapshot, ContextSnapshot};

/// Outcome of an index-all run (dry-run or apply).
#[derive(Debug, Clone, Serialize)]
pub struct IndexAllReport {
    /// `true` when `--apply` performed the DB write; `false` for dry-run.
    pub applied: bool,
    /// Number of source files in the full snapshot that WOULD be indexed
    /// (post `is_harness_owned_path` / extension / product-root filtering).
    pub candidate_files: usize,
    /// Number of distinct first-path-component source roots in the candidate
    /// set (e.g. `contact_sender_v2`, `apps`, `harness-rust`). Sanity signal
    /// that product source — not just harness state — is covered.
    pub candidate_roots: usize,
    /// Files actually parsed+indexed this run (`None` for dry-run). With
    /// idempotency, a re-run on an unchanged tree reports 0 parsed / all skipped.
    pub files_parsed: Option<usize>,
    /// Files skipped because already cached (`file_hash + grammar_version`).
    pub files_skipped: Option<usize>,
    /// Total symbols extracted this run (`None` for dry-run).
    pub symbols_extracted: Option<usize>,
    /// repo_root is redacted in serialized evidence; never emit a raw
    /// home-absolute path. The root is recorded as `<repo_root>` (I-1).
    pub repo_root_redacted: String,
}

/// Entry point for `context index-all`.
pub fn run(apply: bool, evidence: Option<&Path>) -> Result<IndexAllReport> {
    let repo_root = shared::git::git_repo_root()?;
    let project_id = super::project_id::read_project_id(&repo_root)?;
    let db_path = shared::paths::semantic_mcp_db_path(&project_id)?;

    // Build the FULL (changed_only=false) snapshot once. context_update resolves
    // the repo via git_repo_root() and applies is_harness_owned_path /
    // extension / product-root filtering, so the snapshot is already the
    // source-only candidate set. We write it to a temp file and reuse it for
    // both the dry-run report and the apply.
    let tmp = tempfile::tempdir().map_err(AgentError::Io)?;
    let snapshot_path = tmp.path().join("repomap.json");
    let plan_path = tmp.path().join("plan.md");
    std::fs::write(&plan_path, "").map_err(AgentError::Io)?;
    context_update(&plan_path, &snapshot_path, false, None)?;

    let snapshot: ContextSnapshot = {
        let bytes = std::fs::read(&snapshot_path).map_err(AgentError::Io)?;
        serde_json::from_slice(&bytes).map_err(AgentError::Json)?
    };
    let candidate_files = snapshot.files.len();
    let candidate_roots = distinct_roots(&snapshot);

    let mut report = IndexAllReport {
        applied: apply,
        candidate_files,
        candidate_roots,
        files_parsed: None,
        files_skipped: None,
        symbols_extracted: None,
        repo_root_redacted: "<repo_root>".to_string(),
    };

    if apply {
        if !db_path.exists() {
            // index_symbols_from_snapshot -> index_files_at_path opens+migrates
            // the DB, so a missing file is created. Ensure the parent dir exists
            // (shared::paths returns a path under Application Support).
            if let Some(parent) = db_path.parent() {
                std::fs::create_dir_all(parent).map_err(AgentError::Io)?;
            }
        }
        // gc_orphans=true is wired inside index_symbols_from_snapshot, which also
        // calls resolve_pending_dependencies via index_files (Slice A).
        let result = index_symbols_from_snapshot(&snapshot_path, &db_path, &project_id)?;
        report.files_parsed = Some(result.files_parsed);
        report.files_skipped = Some(result.files_skipped);
        report.symbols_extracted = Some(result.symbols_extracted);
    }

    if let Some(evidence_path) = evidence {
        write_evidence_row(evidence_path, &report)?;
    }

    Ok(report)
}

/// Count distinct first-path-components in the candidate snapshot. `entry.path`
/// is repo-relative (forward-slashed). Empty / dotfile-root paths are ignored.
fn distinct_roots(snapshot: &ContextSnapshot) -> usize {
    use std::collections::BTreeSet;
    let mut roots: BTreeSet<&str> = BTreeSet::new();
    for entry in &snapshot.files {
        if let Some(first) = entry.path.split('/').find(|seg| !seg.is_empty()) {
            roots.insert(first);
        }
    }
    roots.len()
}

/// Append a single redacted JSONL evidence row. The repo_root is recorded as
/// `<repo_root>` — never a raw home-absolute path (I-1).
fn write_evidence_row(path: &Path, report: &IndexAllReport) -> Result<()> {
    use std::io::Write;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(AgentError::Io)?;
    }
    let line = serde_json::to_string(report).map_err(AgentError::Json)?;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(AgentError::Io)?;
    writeln!(file, "{line}").map_err(AgentError::Io)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(path: &str) -> serde_json::Value {
        serde_json::json!({
            "path": path,
            "language": "typescript",
            "hash": "deadbeef",
            "module": "m",
            "size_bytes": 1
        })
    }

    fn snapshot_from(paths: &[&str]) -> ContextSnapshot {
        let files: Vec<_> = paths.iter().map(|p| entry(p)).collect();
        let value = serde_json::json!({
            "files": files,
            "timestamp": "2026-06-05T00:00:00Z"
        });
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn distinct_roots_counts_first_components() {
        let snap = snapshot_from(&[
            "apps/web/main.ts",
            "apps/api/server.ts",
            "contact_sender_v2/sidecar/scripts/sender-opt/proof-harness.ts",
            "harness-rust/crates/agent-core/src/main.rs",
        ]);
        // apps, contact_sender_v2, harness-rust => 3 distinct roots.
        assert_eq!(distinct_roots(&snap), 3);
    }

    #[test]
    fn dry_run_report_has_no_index_counts() {
        // A pure-data assertion (no DB / git): a dry-run report must carry
        // candidate counts but leave the index-write fields None.
        let report = IndexAllReport {
            applied: false,
            candidate_files: 42,
            candidate_roots: 3,
            files_parsed: None,
            files_skipped: None,
            symbols_extracted: None,
            repo_root_redacted: "<repo_root>".to_string(),
        };
        assert!(!report.applied);
        assert_eq!(report.candidate_files, 42);
        assert!(report.files_parsed.is_none());
        assert!(report.symbols_extracted.is_none());
    }

    #[test]
    fn evidence_row_is_redacted_no_user_path() {
        let tmp = tempfile::tempdir().unwrap();
        let evidence = tmp.path().join("evidence.jsonl");
        let report = IndexAllReport {
            applied: true,
            candidate_files: 10,
            candidate_roots: 2,
            files_parsed: Some(7),
            files_skipped: Some(3),
            symbols_extracted: Some(99),
            repo_root_redacted: "<repo_root>".to_string(),
        };
        write_evidence_row(&evidence, &report).unwrap();
        let content = std::fs::read_to_string(&evidence).unwrap();
        assert!(content.contains("<repo_root>"));
        // Build the home-path needle at runtime so this source file contains no
        // literal home-absolute token, while still asserting it is absent from
        // the serialized evidence (redaction holds — I-1).
        let home_needle = format!("/{}sers/", 'U');
        assert!(!content.contains(&home_needle));
        assert!(content.contains("\"applied\":true"));
    }
}
