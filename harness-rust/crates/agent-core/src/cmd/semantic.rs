//! Semantic MCP administration commands.

use std::path::Path;

use clap::Subcommand;

use shared::error::{AgentError, Result};
use shared::semantic_gc::{run_gc, GcOptions, GcOutput};

#[derive(Subcommand, Debug)]
pub enum SemanticAction {
    /// Garbage collect stale managed semantic.db files.
    Gc(GcArgs),
}

#[derive(clap::Args, Debug)]
pub struct GcArgs {
    /// Minimum age, in days, for a semantic.db to be considered stale.
    #[arg(long, default_value_t = 30)]
    pub older_than_days: u64,
    /// Scan only and do not delete files. This is the default behavior.
    #[arg(long, conflicts_with = "force")]
    pub dry_run: bool,
    /// Delete stale candidates.
    #[arg(long, conflicts_with = "dry_run")]
    pub force: bool,
    /// Scan every managed project under the semantic MCP data root.
    #[arg(long)]
    pub all_projects: bool,
    /// Include databases with active locks.
    #[arg(long)]
    pub ignore_active_lock: bool,
    /// Emit stable JSON schema v1.
    #[arg(long)]
    pub json: bool,
}

pub fn run(action: SemanticAction) -> Result<i32> {
    match action {
        SemanticAction::Gc(args) => run_gc_cli(args),
    }
}

fn run_gc_cli(args: GcArgs) -> Result<i32> {
    let options = GcOptions {
        older_than_days: args.older_than_days,
        dry_run: !args.force,
        force: args.force,
        ignore_active_lock: args.ignore_active_lock,
    };

    let mut output = run_gc(options).map_err(AgentError::Validation)?;

    if !args.all_projects {
        let project_id = load_project_id_or_fail()?;
        filter_to_project_id(&mut output, &project_id);
    }

    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&output).map_err(AgentError::Json)?
        );
    } else {
        render_human(&output);
    }

    if output.candidates.is_empty() && output.deleted.is_empty() {
        Ok(0)
    } else {
        Ok(1)
    }
}

fn load_project_id_or_fail() -> Result<String> {
    let repo_root = shared::git::git_repo_root()
        .or_else(|_| std::env::current_dir().map_err(AgentError::Io))?;
    super::project_id::read_project_id(&repo_root)
}

fn filter_to_project_id(output: &mut GcOutput, project_id: &str) {
    output
        .candidates
        .retain(|candidate| semantic_db_path_matches_project(&candidate.path, project_id));
    output
        .skipped_active
        .retain(|candidate| semantic_db_path_matches_project(&candidate.path, project_id));
    output
        .deleted
        .retain(|path| semantic_db_path_matches_project(path, project_id));
    output.scanned = output.candidates.len() + output.skipped_active.len() + output.deleted.len();
    output.freed_bytes = output
        .candidates
        .iter()
        .filter(|candidate| {
            !output.deleted.is_empty() && output.deleted.iter().any(|path| path == &candidate.path)
        })
        .map(|candidate| candidate.size_bytes)
        .sum();
}

fn semantic_db_path_matches_project(path: &str, project_id: &str) -> bool {
    let path = Path::new(path);
    path.file_name().and_then(|name| name.to_str()) == Some("semantic.db")
        && path
            .parent()
            .and_then(|parent| parent.file_name())
            .and_then(|name| name.to_str())
            == Some(project_id)
}

fn render_human(output: &GcOutput) {
    println!("schema_version\t{}", output.schema_version);
    println!("scanned\t{}", output.scanned);
    println!("candidates\t{}", output.candidates.len());
    println!("skipped_active\t{}", output.skipped_active.len());
    println!("deleted\t{}", output.deleted.len());
    println!("freed_bytes\t{}", output.freed_bytes);
    println!("dry_run\t{}", output.dry_run);

    print_candidate_paths("candidate_paths", &output.candidates);
    print_paths("deleted_paths", &output.deleted);
    print_candidate_paths("skipped_active_paths", &output.skipped_active);

    if !output.tool_errors.is_empty() {
        println!("tool_errors");
        for error in output.tool_errors.iter().take(10) {
            println!("  {error}");
        }
        if output.tool_errors.len() > 10 {
            println!("  ... {} more", output.tool_errors.len() - 10);
        }
    }
}

fn print_candidate_paths(label: &str, candidates: &[shared::semantic_gc::GcCandidate]) {
    if candidates.is_empty() {
        return;
    }
    println!("{label}");
    for candidate in candidates.iter().take(10) {
        println!(
            "  {}\t{}\t{}",
            candidate.path, candidate.size_bytes, candidate.last_accessed_unix_ms
        );
    }
    if candidates.len() > 10 {
        println!("  ... {} more", candidates.len() - 10);
    }
}

fn print_paths(label: &str, paths: &[String]) {
    if paths.is_empty() {
        return;
    }
    println!("{label}");
    for path in paths.iter().take(10) {
        println!("  {path}");
    }
    if paths.len() > 10 {
        println!("  ... {} more", paths.len() - 10);
    }
}
