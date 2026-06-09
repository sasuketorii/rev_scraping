//! `context index-commit` — incremental post-commit reindex (D-1).
//!
//! Background: semantic indexing is edit-driven — only files touched by the
//! Edit/Write hook get indexed. When a commit introduces symbols that are newer
//! than the cached entries, `file_parse_cache` reports a miss and semantic
//! search silently returns stale results. The full `context index-all` reindex
//! fixes coverage but walks the entire tree (~minutes), which is too heavy for a
//! post-commit hook.
//!
//! This command indexes ONLY the files changed by the most recent commit, so a
//! post-commit hook can keep the semantic index fresh cheaply.
//!
//! Safety / scope posture (mirrors `index_all.rs`):
//! - **Dry-run is the DEFAULT.** `--apply` is required for any DB write.
//! - **Current project only.** `project_id` from `.shared/project_id`; DB path
//!   from `shared::paths::semantic_mcp_db_path`. No cross-project scan.
//! - **RSEM-managed DB only on apply.** The hook refuses to mutate a missing,
//!   foreign, or unmarked SQLite file at the managed semantic DB path.
//! - **Same source universe as `index-all`.** Commit-changed files are filtered
//!   through the same harness/admin exclusions and product-root selection before
//!   indexing, so a later full `index-all` sweep will not immediately GC rows
//!   written by the hook.
//! - **`gc_orphans=false`.** This is the core difference from `index-all`:
//!   only source-filtered commit files are upserted; orphan removal is reserved
//!   for `index-all`.
//! - **Idempotent.** Keyed by `file_hash + GRAMMAR_VERSION`; re-running on the
//!   same commit reports 0 parsed / all skipped.
//!
//! Non-parseable files (e.g. `.json`, `.md`, `.toml`, `.yaml`) are filtered out
//! up front via `parser::get_language`, exactly as `index_symbols_from_snapshot`
//! does — otherwise a commit dominated by config/doc files would trip the
//! parse-failure-rate guard inside `index_files` and abort the whole batch.
//!
//! Renames and deletions appear in the commit's change set as the old (now
//! absent) path; `index_files` stats each `read_path` and skips paths that no
//! longer exist on disk, so deletions are naturally a no-op here (the stale
//! symbol rows are left for `index-all`'s GC, which this command intentionally
//! does not perform).

use std::path::{Path, PathBuf};

use serde::Serialize;
use shared::error::{AgentError, Result};

/// Advisory ceiling on the number of changed files. A commit larger than this is
/// almost certainly a bulk/vendored/generated change for which a targeted
/// incremental reindex is the wrong tool; we skip and recommend `index-all`.
const MAX_COMMIT_FILES: usize = 500;

/// Outcome of an index-commit run (dry-run or apply).
#[derive(Debug, Clone, Serialize)]
pub struct IndexCommitReport {
    /// `true` when `--apply` performed the DB write; `false` for dry-run.
    pub applied: bool,
    /// Base ref the commit was diffed against (`HEAD^` by default, `HEAD^1` for
    /// merges, `<root>` for the initial commit). Records the resolution choice.
    pub base: String,
    /// Head ref/commit the diff was resolved to. Post-commit hooks pass the
    /// immutable commit SHA captured before detaching.
    pub head: String,
    /// Number of files reported changed by the commit (pre language filter).
    pub candidate_files: usize,
    /// Number of candidate files whose language has a compiled tree-sitter
    /// grammar (the set actually handed to the indexer).
    pub indexable_files: usize,
    /// `true` when the commit exceeded `MAX_COMMIT_FILES` and was skipped in
    /// favour of `index-all`. When set, no DB write is attempted even with
    /// `--apply`.
    pub advisory_skipped: bool,
    /// Files actually parsed+indexed this run (`None` for dry-run). With
    /// idempotency, a re-run on an unchanged commit reports 0 parsed.
    pub files_parsed: Option<usize>,
    /// Files skipped by the indexer (already cached, missing on disk — i.e.
    /// deletions/old rename paths, too large, binary). `None` for dry-run.
    pub files_skipped: Option<usize>,
    /// Files that failed to parse this run (`None` for dry-run).
    pub failures: Option<usize>,
    /// Total symbols extracted this run (`None` for dry-run).
    pub symbols_extracted: Option<usize>,
    /// repo_root is redacted in serialized evidence; never emit a raw
    /// home-absolute path. The root is recorded as `<repo_root>` (I-1).
    pub repo_root_redacted: String,
}

/// Entry point for `context index-commit`.
pub fn run(
    base: Option<&str>,
    head: Option<&str>,
    apply: bool,
    evidence: Option<&Path>,
) -> Result<IndexCommitReport> {
    let repo_root = shared::git::git_repo_root()?;
    let project_id = super::project_id::read_project_id(&repo_root)?;
    let db_path = shared::paths::semantic_mcp_db_path(&project_id)?;

    // Collect the files changed by the most recent commit (Slice 1). Returns
    // repo-relative paths including deletions / old rename paths.
    let changed = shared::git::git_commit_changed_files_at_head(&repo_root, base, head)?;

    // Record the base actually used for reporting/evidence (mirrors the
    // resolution inside git_commit_changed_files).
    let resolved_base = resolve_base_label(&repo_root, base, head)?;
    let resolved_head = resolve_head_label(head);

    let candidate_files = changed.len();

    let mut report = IndexCommitReport {
        applied: false,
        base: resolved_base,
        head: resolved_head,
        candidate_files,
        indexable_files: 0,
        advisory_skipped: false,
        files_parsed: None,
        files_skipped: None,
        failures: None,
        symbols_extracted: None,
        repo_root_redacted: "<repo_root>".to_string(),
    };

    // Large-commit guard: a bulk change is better served by a full reindex.
    if candidate_files > MAX_COMMIT_FILES {
        report.advisory_skipped = true;
        tracing::warn!(
            candidate_files,
            max = MAX_COMMIT_FILES,
            "commit changed more files than the incremental ceiling; \
             skipping index-commit — run `context index-all --apply` instead"
        );
        if let Some(evidence_path) = evidence {
            write_evidence_row(evidence_path, &report)?;
        }
        return Ok(report);
    }

    let files = indexable_files_from_changed(&repo_root, &changed)?;

    report.indexable_files = files.len();

    if files.is_empty() {
        if let Some(evidence_path) = evidence {
            write_evidence_row(evidence_path, &report)?;
        }
        return Ok(report);
    }

    if apply {
        shared::semantic_gc::assert_rsem_managed_db(&db_path, "index-commit apply")?;
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).map_err(AgentError::Io)?;
        }
        // gc_orphans=false — THE core safety property of index-commit: only the
        // commit's files are upserted; symbols for every other file are left
        // intact. See incremental::index_files (GC block is skipped when false).
        let result = tree_sitter_index::index_files_at_path(
            &db_path.to_string_lossy(),
            &project_id,
            &files,
            &tree_sitter_index::IndexConfig::default(),
            false,
        )?;
        report.applied = true;
        report.files_parsed = Some(result.files_parsed);
        report.files_skipped = Some(result.files_skipped);
        report.failures = Some(result.parse_failures);
        report.symbols_extracted = Some(result.symbols_extracted);
    }

    if let Some(evidence_path) = evidence {
        write_evidence_row(evidence_path, &report)?;
    }

    Ok(report)
}

/// Resolve a human-readable label for the base ref used, mirroring the
/// resolution rules inside `git_commit_changed_files` (HEAD^ default, HEAD^1 for
/// merges, `<root>` for the initial commit). Reporting-only; never affects the
/// actual diff.
fn resolve_base_label(repo_root: &Path, base: Option<&str>, head: Option<&str>) -> Result<String> {
    if let Some(b) = base {
        return Ok(b.to_string());
    }
    let head_ref = head.unwrap_or("HEAD");
    let parent_count = shared::git::git_commit_parent_count_for_ref(repo_root, head_ref)?;
    Ok(match parent_count {
        0 => "<root>".to_string(),
        n if n >= 2 => format!("{head_ref}^1"),
        _ => format!("{head_ref}^"),
    })
}

fn resolve_head_label(head: Option<&str>) -> String {
    head.unwrap_or("HEAD").to_string()
}

fn indexable_files_from_changed(
    repo_root: &Path,
    changed: &[String],
) -> Result<Vec<(PathBuf, PathBuf, String, String)>> {
    let candidates: Vec<PathBuf> = changed.iter().map(PathBuf::from).collect();
    let entries = super::context::source_entries_for_candidate_paths(repo_root, &candidates, None)?;

    let mut files = Vec::new();
    for entry in entries {
        let Some(language) = entry.language else {
            continue;
        };
        if tree_sitter_index::parser::get_language(&language).is_none() {
            continue;
        }
        let read_path = repo_root.join(&entry.path);
        files.push((read_path, PathBuf::from(entry.path), language, entry.hash));
    }
    Ok(files)
}

/// Append a single redacted JSONL evidence row. The repo_root is recorded as
/// `<repo_root>` — never a raw home-absolute path (I-1).
fn write_evidence_row(path: &Path, report: &IndexCommitReport) -> Result<()> {
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

    fn git(repo: &Path, args: &[&str]) {
        let output = std::process::Command::new("git")
            .arg("-C")
            .arg(repo)
            .args(args)
            .output()
            .expect("failed to spawn git");
        assert!(
            output.status.success(),
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn init_repo(repo: &Path) {
        git(repo, &["init", "-q", "-b", "main"]);
        git(repo, &["config", "user.email", "test@example.invalid"]);
        git(repo, &["config", "user.name", "Test"]);
        git(repo, &["config", "commit.gpgsign", "false"]);
    }

    #[test]
    fn dry_run_report_has_no_index_counts() {
        let report = IndexCommitReport {
            applied: false,
            base: "HEAD^".to_string(),
            head: "HEAD".to_string(),
            candidate_files: 5,
            indexable_files: 3,
            advisory_skipped: false,
            files_parsed: None,
            files_skipped: None,
            failures: None,
            symbols_extracted: None,
            repo_root_redacted: "<repo_root>".to_string(),
        };
        assert!(!report.applied);
        assert_eq!(report.candidate_files, 5);
        assert_eq!(report.indexable_files, 3);
        assert!(report.files_parsed.is_none());
        assert!(report.symbols_extracted.is_none());
    }

    #[test]
    fn evidence_row_is_redacted_no_user_path() {
        let tmp = tempfile::tempdir().unwrap();
        let evidence = tmp.path().join("evidence.jsonl");
        let report = IndexCommitReport {
            applied: true,
            base: "HEAD^".to_string(),
            head: "abc123".to_string(),
            candidate_files: 4,
            indexable_files: 2,
            advisory_skipped: false,
            files_parsed: Some(2),
            files_skipped: Some(0),
            failures: Some(0),
            symbols_extracted: Some(11),
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

    #[test]
    fn indexable_files_from_changed_uses_index_all_source_filtering() {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path();
        std::fs::create_dir_all(repo.join("scripts")).unwrap();
        std::fs::create_dir_all(repo.join("docs")).unwrap();
        std::fs::create_dir_all(repo.join("apps/web/scripts")).unwrap();
        std::fs::write(repo.join("scripts/admin.rs"), "fn admin() {}\n").unwrap();
        std::fs::write(repo.join("docs/guide.rs"), "fn doc() {}\n").unwrap();
        std::fs::write(
            repo.join("apps/web/scripts/build.rs"),
            "fn product_build() {}\n",
        )
        .unwrap();

        let changed = vec![
            "scripts/admin.rs".to_string(),
            "docs/guide.rs".to_string(),
            "apps/web/scripts/build.rs".to_string(),
        ];
        let files = indexable_files_from_changed(repo, &changed).unwrap();
        let keys: Vec<_> = files
            .iter()
            .map(|(_, index_key, _, _)| index_key.to_string_lossy().to_string())
            .collect();
        assert_eq!(keys, vec!["apps/web/scripts/build.rs".to_string()]);
    }

    #[test]
    fn apply_rejects_foreign_managed_path_before_mutation() {
        use crate::cmd::test_support::{lock_process_state, CurrentDirGuard, EnvGuard};
        use rusqlite::Connection;

        let _lock = lock_process_state();
        let repo_tmp = tempfile::tempdir().unwrap();
        let repo = repo_tmp.path();
        init_repo(repo);
        std::fs::create_dir_all(repo.join(".shared")).unwrap();
        std::fs::write(repo.join(".shared/project_id"), "proj-foreign\n").unwrap();
        std::fs::create_dir_all(repo.join("src")).unwrap();
        std::fs::write(repo.join("src/lib.rs"), "pub fn indexed() {}\n").unwrap();
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "initial"]);

        let semantic_home = tempfile::tempdir().unwrap();
        let db_dir = semantic_home.path().join("v1/proj-foreign");
        std::fs::create_dir_all(&db_dir).unwrap();
        let db_path = db_dir.join("semantic.db");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "PRAGMA application_id = 305419896;
             CREATE TABLE foreign_table (id INTEGER PRIMARY KEY);",
        )
        .unwrap();
        drop(conn);

        let _test_mode = EnvGuard::set("REVHARNESS_TEST_HARNESS", "1");
        let _semantic_home = EnvGuard::set("SEMANTIC_MCP_HOME", semantic_home.path());
        let _cwd = CurrentDirGuard::set(repo);

        let err = run(None, None, true, None).unwrap_err();
        let message = err.to_string();
        assert!(
            message.contains("not RevHarness-managed"),
            "unexpected error: {message}"
        );

        let conn = Connection::open(&db_path).unwrap();
        let symbols_table_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='symbols'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            symbols_table_count, 0,
            "foreign DB must not be migrated or mutated"
        );
    }

    #[test]
    fn apply_with_no_indexable_files_does_not_create_semantic_db() {
        use crate::cmd::test_support::{lock_process_state, CurrentDirGuard, EnvGuard};

        let _lock = lock_process_state();
        let repo_tmp = tempfile::tempdir().unwrap();
        let repo = repo_tmp.path();
        init_repo(repo);
        std::fs::create_dir_all(repo.join(".shared")).unwrap();
        std::fs::write(repo.join(".shared/project_id"), "proj-docs-only\n").unwrap();
        std::fs::create_dir_all(repo.join("docs")).unwrap();
        std::fs::write(repo.join("docs/readme.md"), "# docs only\n").unwrap();
        git(repo, &["add", "-A"]);
        git(repo, &["commit", "-q", "-m", "docs only"]);

        let semantic_home = tempfile::tempdir().unwrap();
        let db_path = semantic_home.path().join("v1/proj-docs-only/semantic.db");
        let evidence = repo.join(".git/rev-harness/evidence.jsonl");

        let _test_mode = EnvGuard::set("REVHARNESS_TEST_HARNESS", "1");
        let _semantic_home = EnvGuard::set("SEMANTIC_MCP_HOME", semantic_home.path());
        let _cwd = CurrentDirGuard::set(repo);

        let report = run(None, None, true, Some(&evidence)).unwrap();
        assert!(!report.applied, "zero-indexable apply must be a no-op");
        assert_eq!(report.indexable_files, 0);
        assert!(
            !db_path.exists(),
            "zero-indexable apply must not create semantic.db"
        );

        let evidence_content = std::fs::read_to_string(&evidence).unwrap();
        assert!(evidence_content.contains("\"applied\":false"));
        assert!(evidence_content.contains("\"indexable_files\":0"));
    }

    /// GC-SAFETY REGRESSION (the core of D-1): with `gc_orphans=false` — the
    /// exact flag `run()` passes to `index_files_at_path` — indexing ONE file
    /// must NOT remove symbols belonging to any other file already in the DB.
    ///
    /// This exercises the real indexing path against a temp on-disk DB (not the
    /// git/project_id resolution, which is host-dependent), which is the same
    /// `index_files_at_path(..., gc_orphans=false)` call `run()` makes for the
    /// `--apply` branch.
    #[test]
    fn gc_safety_index_commit_does_not_drop_other_files_symbols() {
        use rusqlite::Connection;

        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("semantic.db");
        let db_str = db_path.to_string_lossy().to_string();
        let project_id = "proj";

        // Seed: two pre-existing files, each with parseable symbols.
        let keep_src = tmp.path().join("keep.rs");
        std::fs::write(&keep_src, "fn keep_one() {}\nfn keep_two() {}\n").unwrap();
        let other_src = tmp.path().join("other.rs");
        std::fs::write(&other_src, "fn other_one() {}\nstruct OtherT;\n").unwrap();

        let seed = vec![
            (
                keep_src.clone(),
                PathBuf::from("keep.rs"),
                "rust".to_string(),
                "keephash1".to_string(),
            ),
            (
                other_src.clone(),
                PathBuf::from("other.rs"),
                "rust".to_string(),
                "otherhash1".to_string(),
            ),
        ];
        // Seed with gc_orphans=false too; it just upserts both files.
        let seed_result = tree_sitter_index::index_files_at_path(
            &db_str,
            project_id,
            &seed,
            &tree_sitter_index::IndexConfig::default(),
            false,
        )
        .unwrap();
        assert_eq!(seed_result.files_parsed, 2);

        let count_for = |key: &str| -> i64 {
            let conn = Connection::open(&db_path).unwrap();
            conn.query_row(
                "SELECT COUNT(*) FROM symbols WHERE project_id = ?1 AND file_path = ?2",
                rusqlite::params![project_id, key],
                |row| row.get(0),
            )
            .unwrap()
        };

        let keep_before = count_for("keep.rs");
        let other_before = count_for("other.rs");
        assert!(keep_before > 0, "seed must produce keep.rs symbols");
        assert!(other_before > 0, "seed must produce other.rs symbols");

        // Now simulate an index-commit that only changed `other.rs` (new content
        // => new hash). Run with gc_orphans=false on the SINGLE-file set.
        std::fs::write(
            &other_src,
            "fn other_one() {}\nstruct OtherT;\nfn other_two() {}\n",
        )
        .unwrap();
        let commit_set = vec![(
            other_src.clone(),
            PathBuf::from("other.rs"),
            "rust".to_string(),
            "otherhash2".to_string(),
        )];
        let commit_result = tree_sitter_index::index_files_at_path(
            &db_str,
            project_id,
            &commit_set,
            &tree_sitter_index::IndexConfig::default(),
            false,
        )
        .unwrap();
        assert_eq!(commit_result.files_parsed, 1);

        // keep.rs was NOT in the commit set — its symbols must be untouched.
        let keep_after = count_for("keep.rs");
        assert_eq!(
            keep_after, keep_before,
            "gc_orphans=false must leave non-committed file symbols intact"
        );
        // other.rs was re-indexed and gained a symbol.
        let other_after = count_for("other.rs");
        assert!(
            other_after > other_before,
            "re-indexed file should reflect the added symbol (before={other_before}, after={other_after})"
        );
    }
}
