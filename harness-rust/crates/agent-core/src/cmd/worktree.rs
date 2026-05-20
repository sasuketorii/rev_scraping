//! Git worktree management module — replaces hydra (1,486 LOC).
//!
//! Manages parallel development via git worktrees: creating, closing,
//! listing, preflight checks, dependency analysis, merge ordering,
//! and rollback operations.

use std::collections::{HashMap, HashSet, VecDeque};
use std::process::Command;

use clap::Subcommand;
use serde::{Deserialize, Serialize};

use shared::error::{AgentError, Result};
use shared::types::WorktreeInfo;

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/// Subcommands for the `worktree` family.
#[derive(Subcommand)]
pub enum WorktreeAction {
    /// Create new worktree for a task.
    New {
        /// Task name (used as branch name suffix).
        #[arg(long)]
        task: String,
        /// Base ref to branch from (default: default branch).
        #[arg(long)]
        base: Option<String>,
    },
    /// Close worktree (cleanup).
    Close {
        /// Task name.
        #[arg(long)]
        task: String,
        /// Force removal even if changes exist.
        #[arg(long)]
        force: bool,
    },
    /// List active worktrees.
    List,
    /// Run preflight checks for a worktree.
    Preflight {
        /// Task name.
        #[arg(long)]
        task: String,
        /// Output as JSON.
        #[arg(long)]
        json: bool,
    },
    /// Preflight all worktrees.
    PreflightAll,
    /// Show merge order.
    MergeOrder {
        /// Output as JSON.
        #[arg(long)]
        json: bool,
        /// Comma-separated list of tasks to include.
        #[arg(long)]
        include: Option<String>,
    },
    /// Rollback operations.
    Rollback {
        #[command(subcommand)]
        action: RollbackAction,
    },
}

/// Rollback subcommands.
#[derive(Subcommand)]
pub enum RollbackAction {
    /// Rollback last merge/PR.
    Last,
    /// Rollback a specific PR.
    Pr {
        /// PR number to rollback.
        number: u32,
    },
    /// Rollback to a specific commit.
    ToCommit {
        /// Commit SHA to rollback to.
        commit: String,
    },
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Warning about files shared across multiple worktrees.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SharedFileWarning {
    /// Path to the shared file.
    pub file: String,
    /// Worktrees that modify this file.
    pub worktrees: Vec<String>,
}

/// Dependency between two worktrees/tasks.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Dependency {
    /// Task that depends on another.
    pub from: String,
    /// Task being depended upon.
    pub to: String,
    /// Kind of dependency (e.g. `"file"`, `"module"`, `"explicit"`).
    pub kind: String,
}

/// Result of a merge conflict check.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConflictResult {
    /// Whether conflicts were detected.
    pub has_conflicts: bool,
    /// List of files with conflicts.
    pub conflicting_files: Vec<String>,
}

/// Full preflight report for a worktree.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreflightReport {
    /// Task name.
    pub task: String,
    /// Overall verdict: `"PASS"` or `"BLOCK"`.
    pub verdict: String,
    /// Shared file warnings.
    pub shared_files: Vec<SharedFileWarning>,
    /// Detected dependencies.
    pub dependencies: Vec<Dependency>,
    /// Conflict check results.
    pub conflicts: ConflictResult,
    /// Additional warnings.
    pub warnings: Vec<String>,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Execute a `worktree` subcommand.
pub fn run(action: WorktreeAction) -> Result<()> {
    match action {
        WorktreeAction::New { task, base } => {
            cmd_new(&task, base.as_deref())?;
            Ok(())
        }
        WorktreeAction::Close { task, force } => {
            cmd_close(&task, force)?;
            Ok(())
        }
        WorktreeAction::List => {
            let worktrees = cmd_list()?;
            for wt in &worktrees {
                let branch = wt.branch.as_deref().unwrap_or("(detached)");
                println!(
                    "{}\t{}\t{}",
                    wt.path,
                    &wt.head[..7.min(wt.head.len())],
                    branch
                );
            }
            Ok(())
        }
        WorktreeAction::Preflight { task, json } => {
            let worktrees = cmd_list()?;
            let report = preflight_run(&task, &worktrees)?;
            if json {
                let out = serde_json::to_string_pretty(&report).map_err(AgentError::Json)?;
                println!("{out}");
            } else {
                println!("Task: {}", report.task);
                println!("Verdict: {}", report.verdict);
                if !report.shared_files.is_empty() {
                    println!("Shared files:");
                    for sf in &report.shared_files {
                        println!("  {} (in: {})", sf.file, sf.worktrees.join(", "));
                    }
                }
                if !report.warnings.is_empty() {
                    println!("Warnings:");
                    for w in &report.warnings {
                        println!("  - {w}");
                    }
                }
            }
            Ok(())
        }
        WorktreeAction::PreflightAll => {
            let worktrees = cmd_list()?;
            for wt in &worktrees {
                let task = wt
                    .branch
                    .as_deref()
                    .and_then(|b| b.rsplit('/').next())
                    .unwrap_or("unknown");
                match preflight_run(task, &worktrees) {
                    Ok(report) => {
                        println!("{}: {}", report.task, report.verdict);
                    }
                    Err(e) => {
                        tracing::warn!("Preflight failed for {task}: {e}");
                    }
                }
            }
            Ok(())
        }
        WorktreeAction::MergeOrder { json, include } => {
            let worktrees = cmd_list()?;

            let filtered: Vec<WorktreeInfo> = if let Some(ref inc) = include {
                let tasks: HashSet<&str> = inc.split(',').map(|s| s.trim()).collect();
                worktrees
                    .into_iter()
                    .filter(|wt| {
                        wt.branch
                            .as_deref()
                            .is_some_and(|b| tasks.iter().any(|t| b.contains(t)))
                    })
                    .collect()
            } else {
                worktrees
            };

            let deps = detect_dependencies(&filtered);
            let ordered = merge_order(&filtered, &deps);

            if json {
                let names: Vec<String> = ordered
                    .iter()
                    .filter_map(|wt| {
                        wt.branch
                            .as_deref()
                            .and_then(|b| b.rsplit('/').next())
                            .map(String::from)
                    })
                    .collect();
                let out = serde_json::to_string_pretty(&names).map_err(AgentError::Json)?;
                println!("{out}");
            } else {
                println!("Merge order:");
                for (i, wt) in ordered.iter().enumerate() {
                    let name = wt.branch.as_deref().unwrap_or(&wt.path);
                    println!("  {}. {}", i + 1, name);
                }
            }
            Ok(())
        }
        WorktreeAction::Rollback { action } => match action {
            RollbackAction::Last => rollback_last(),
            RollbackAction::Pr { number } => rollback_pr(number),
            RollbackAction::ToCommit { commit } => rollback_to_commit(&commit),
        },
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Get the default branch name (main or master).
pub fn get_default_branch() -> Result<String> {
    let remote_head = Command::new("git")
        .args(["symbolic-ref", "refs/remotes/origin/HEAD"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| {
            let full_ref = String::from_utf8_lossy(&output.stdout).trim().to_string();
            full_ref.rsplit('/').next().map(str::to_string)
        });

    let has_branch = |branch: &str| {
        Command::new("git")
            .args(["rev-parse", "--verify", &format!("refs/heads/{branch}")])
            .output()
            .map(|output| output.status.success())
            .unwrap_or(false)
    };

    let current = Command::new("git")
        .args(["branch", "--show-current"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|branch| !branch.is_empty());

    Ok(select_default_branch(
        remote_head.as_deref(),
        has_branch("main"),
        has_branch("master"),
        has_branch("develop"),
        current.as_deref(),
    ))
}

fn select_default_branch(
    remote_head: Option<&str>,
    has_main: bool,
    has_master: bool,
    has_develop: bool,
    current: Option<&str>,
) -> String {
    if let Some(remote_head) = remote_head {
        if !remote_head.is_empty() {
            return remote_head.to_string();
        }
    }
    if has_main {
        return "main".to_string();
    }
    if has_master {
        return "master".to_string();
    }
    if has_develop {
        return "develop".to_string();
    }
    if let Some(current) = current {
        if !current.is_empty() {
            return current.to_string();
        }
    }
    "main".to_string()
}

/// Resolve the base ref for branching.
pub fn resolve_base_ref(base: Option<&str>) -> Result<String> {
    match base {
        Some(b) => {
            // Verify the ref exists
            let output = Command::new("git")
                .args(["rev-parse", "--verify", b])
                .output()
                .map_err(|e| AgentError::Git(format!("failed to verify ref: {e}")))?;
            if !output.status.success() {
                return Err(AgentError::Git(format!("ref not found: {b}")));
            }
            Ok(b.to_string())
        }
        None => get_default_branch(),
    }
}

/// Create a new worktree for a task.
pub fn cmd_new(task: &str, base: Option<&str>) -> Result<()> {
    shared::validation::validate_identifier(task, "task name")?;

    let base_ref = resolve_base_ref(base)?;
    let branch_name = format!("task/{task}");
    let repo_root = shared::git::git_repo_root()?;
    let worktree_path = repo_root
        .parent()
        .unwrap_or(&repo_root)
        .join(format!("worktrees/{task}"));

    tracing::info!(
        "Creating worktree: branch={branch_name}, base={base_ref}, path={}",
        worktree_path.display()
    );

    // Create the worktree with a new branch
    let output = Command::new("git")
        .args([
            "worktree",
            "add",
            "-b",
            &branch_name,
            &worktree_path.to_string_lossy(),
            &base_ref,
        ])
        .output()
        .map_err(|e| AgentError::Git(format!("failed to create worktree: {e}")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AgentError::Git(format!(
            "worktree creation failed: {}",
            stderr.trim()
        )));
    }

    println!("Worktree created: {}", worktree_path.display());
    println!("Branch: {branch_name}");
    Ok(())
}

/// Close (remove) a worktree for a task.
pub fn cmd_close(task: &str, force: bool) -> Result<()> {
    shared::validation::validate_identifier(task, "task name")?;

    let repo_root = shared::git::git_repo_root()?;
    let worktree_path = repo_root
        .parent()
        .unwrap_or(&repo_root)
        .join(format!("worktrees/{task}"));

    if !worktree_path.exists() {
        return Err(AgentError::NotFound(format!(
            "worktree not found: {}",
            worktree_path.display()
        )));
    }

    tracing::info!("Closing worktree: {}", worktree_path.display());

    let mut args = vec!["worktree", "remove"];
    if force {
        args.push("--force");
    }
    args.push(&worktree_path.to_string_lossy());

    // Workaround: to_string_lossy returns Cow, need to bind it
    let path_str = worktree_path.to_string_lossy().to_string();
    let mut cmd_args = vec!["worktree", "remove"];
    if force {
        cmd_args.push("--force");
    }
    cmd_args.push(&path_str);

    let output = Command::new("git")
        .args(&cmd_args)
        .output()
        .map_err(|e| AgentError::Git(format!("failed to remove worktree: {e}")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AgentError::Git(format!(
            "worktree removal failed: {}",
            stderr.trim()
        )));
    }

    println!("Worktree closed: {task}");
    Ok(())
}

/// List all active worktrees.
pub fn cmd_list() -> Result<Vec<WorktreeInfo>> {
    shared::git::git_worktree_list()
}

/// Check for files modified in multiple worktrees.
pub fn preflight_check_shared_files(
    task: &str,
    worktrees: &[WorktreeInfo],
) -> Result<Vec<SharedFileWarning>> {
    let default_branch = get_default_branch()?;
    let mut file_to_worktrees: HashMap<String, Vec<String>> = HashMap::new();

    for wt in worktrees {
        let branch = match &wt.branch {
            Some(b) => b.clone(),
            None => continue,
        };

        // Skip the main worktree and non-task branches
        let branch_short = branch.rsplit('/').next().unwrap_or(&branch);
        if branch_short == default_branch {
            continue;
        }

        // Get changed files relative to default branch
        let output = Command::new("git")
            .args([
                "-C",
                &wt.path,
                "diff",
                "--name-only",
                &default_branch,
                "HEAD",
            ])
            .output();

        if let Ok(o) = output {
            if o.status.success() {
                let files = String::from_utf8_lossy(&o.stdout);
                for file in files.lines().filter(|l| !l.is_empty()) {
                    file_to_worktrees
                        .entry(file.to_string())
                        .or_default()
                        .push(branch_short.to_string());
                }
            }
        }
    }

    // Filter to files modified in multiple worktrees including this task
    let warnings: Vec<SharedFileWarning> = file_to_worktrees
        .into_iter()
        .filter(|(_, wts)| wts.len() > 1 && wts.iter().any(|w| w.contains(task)))
        .map(|(file, worktrees)| SharedFileWarning { file, worktrees })
        .collect();

    Ok(warnings)
}

/// Analyze dependencies between worktrees based on shared files.
pub fn preflight_analyze_dependencies(
    task: &str,
    worktrees: &[WorktreeInfo],
) -> Result<Vec<Dependency>> {
    let shared_files = preflight_check_shared_files(task, worktrees)?;
    let mut deps = Vec::new();

    for sf in &shared_files {
        for other in &sf.worktrees {
            if other != task {
                deps.push(Dependency {
                    from: task.to_string(),
                    to: other.clone(),
                    kind: "file".to_string(),
                });
            }
        }
    }

    // Deduplicate
    deps.sort_by(|a, b| (&a.from, &a.to).cmp(&(&b.from, &b.to)));
    deps.dedup_by(|a, b| a.from == b.from && a.to == b.to);

    Ok(deps)
}

/// Run a merge conflict check against the base branch.
pub fn preflight_run_conflict_check(task: &str, base: &str) -> Result<ConflictResult> {
    let branch_name = format!("task/{task}");

    // Try a merge dry-run using git merge-tree
    let output = Command::new("git")
        .args(["merge-tree", base, &branch_name])
        .output();

    match output {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            let conflicting_files: Vec<String> = stdout
                .lines()
                .filter(|l| l.starts_with("CONFLICT"))
                .filter_map(|l| {
                    // Extract filename from CONFLICT lines
                    l.rsplit(' ').next().map(String::from)
                })
                .collect();

            Ok(ConflictResult {
                has_conflicts: !conflicting_files.is_empty(),
                conflicting_files,
            })
        }
        Err(_) => {
            // Fallback: assume no conflicts if merge-tree is not available
            tracing::warn!("git merge-tree not available; skipping conflict check");
            Ok(ConflictResult {
                has_conflicts: false,
                conflicting_files: Vec::new(),
            })
        }
    }
}

/// Detect dependencies across all worktrees based on shared file modifications.
pub fn detect_dependencies(worktrees: &[WorktreeInfo]) -> Vec<Dependency> {
    let default_branch = get_default_branch().unwrap_or_else(|_| "main".to_string());
    let mut file_to_branches: HashMap<String, Vec<String>> = HashMap::new();

    for wt in worktrees {
        let branch = match &wt.branch {
            Some(b) => b.clone(),
            None => continue,
        };

        let branch_short = branch.rsplit('/').next().unwrap_or(&branch).to_string();
        if branch_short == default_branch {
            continue;
        }

        let output = Command::new("git")
            .args([
                "-C",
                &wt.path,
                "diff",
                "--name-only",
                &default_branch,
                "HEAD",
            ])
            .output();

        if let Ok(o) = output {
            if o.status.success() {
                let files = String::from_utf8_lossy(&o.stdout);
                for file in files.lines().filter(|l| !l.is_empty()) {
                    file_to_branches
                        .entry(file.to_string())
                        .or_default()
                        .push(branch_short.clone());
                }
            }
        }
    }

    let mut deps = Vec::new();
    for branches in file_to_branches.values() {
        if branches.len() > 1 {
            for i in 0..branches.len() {
                for j in (i + 1)..branches.len() {
                    deps.push(Dependency {
                        from: branches[i].clone(),
                        to: branches[j].clone(),
                        kind: "file".to_string(),
                    });
                }
            }
        }
    }

    deps.sort_by(|a, b| (&a.from, &a.to).cmp(&(&b.from, &b.to)));
    deps.dedup_by(|a, b| a.from == b.from && a.to == b.to);
    deps
}

/// Check for circular dependencies.
///
/// Returns a list of cycle descriptions (empty if no cycles).
pub fn check_circular_deps(deps: &[Dependency]) -> Vec<String> {
    let mut adj: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut nodes: HashSet<&str> = HashSet::new();

    for dep in deps {
        adj.entry(dep.from.as_str())
            .or_default()
            .push(dep.to.as_str());
        nodes.insert(dep.from.as_str());
        nodes.insert(dep.to.as_str());
    }

    let mut cycles = Vec::new();
    let mut visited: HashSet<&str> = HashSet::new();
    let mut in_stack: HashSet<&str> = HashSet::new();

    for node in &nodes {
        if !visited.contains(node) {
            let mut stack: Vec<(&str, usize)> = vec![(node, 0)];
            let mut path: Vec<&str> = vec![node];
            in_stack.insert(node);

            while let Some((current, idx)) = stack.last_mut() {
                let neighbors = adj.get(current).map(|v| v.as_slice()).unwrap_or(&[]);
                if *idx < neighbors.len() {
                    let next = neighbors[*idx];
                    *idx += 1;

                    if in_stack.contains(next) {
                        cycles.push(format!("cycle: {} -> {}", path.join(" -> "), next));
                    } else if !visited.contains(next) {
                        in_stack.insert(next);
                        path.push(next);
                        stack.push((next, 0));
                    }
                } else {
                    visited.insert(current);
                    in_stack.remove(current);
                    path.pop();
                    stack.pop();
                }
            }
        }
    }

    cycles
}

/// Compute a merge order for worktrees based on dependencies.
///
/// Uses topological sort. Worktrees with no dependencies come first.
pub fn merge_order(worktrees: &[WorktreeInfo], deps: &[Dependency]) -> Vec<WorktreeInfo> {
    let default_branch = get_default_branch().unwrap_or_else(|_| "main".to_string());
    merge_order_with_default_branch(worktrees, deps, &default_branch)
}

fn merge_order_with_default_branch(
    worktrees: &[WorktreeInfo],
    deps: &[Dependency],
    default_branch: &str,
) -> Vec<WorktreeInfo> {
    // Build name -> worktree map
    let name_map: HashMap<String, &WorktreeInfo> = worktrees
        .iter()
        .filter_map(|wt| {
            let branch = wt.branch.as_deref()?;
            let short = branch.rsplit('/').next()?;
            if short == default_branch {
                return None;
            }
            Some((short.to_string(), wt))
        })
        .collect();

    // Build adjacency for topological sort
    let mut in_degree: HashMap<&str, usize> = HashMap::new();
    let mut adj: HashMap<&str, Vec<&str>> = HashMap::new();

    for name in name_map.keys() {
        in_degree.entry(name.as_str()).or_insert(0);
    }

    for dep in deps {
        if name_map.contains_key(&dep.from) && name_map.contains_key(&dep.to) {
            adj.entry(dep.to.as_str())
                .or_default()
                .push(dep.from.as_str());
            *in_degree.entry(dep.from.as_str()).or_insert(0) += 1;
        }
    }

    // Kahn's algorithm
    let mut queue: VecDeque<&str> = in_degree
        .iter()
        .filter(|(_, &deg)| deg == 0)
        .map(|(&name, _)| name)
        .collect();

    let mut ordered: Vec<WorktreeInfo> = Vec::new();

    while let Some(node) = queue.pop_front() {
        if let Some(wt) = name_map.get(node) {
            ordered.push((*wt).clone());
        }

        if let Some(neighbors) = adj.get(node) {
            for &next in neighbors {
                if let Some(deg) = in_degree.get_mut(next) {
                    *deg = deg.saturating_sub(1);
                    if *deg == 0 {
                        queue.push_back(next);
                    }
                }
            }
        }
    }

    // Append any remaining (circular) worktrees
    for wt in worktrees {
        let branch = wt.branch.as_deref().unwrap_or("");
        let short = branch.rsplit('/').next().unwrap_or("");
        if short != default_branch && !ordered.iter().any(|o| o.path == wt.path) {
            ordered.push(wt.clone());
        }
    }

    ordered
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Run full preflight for a task.
fn preflight_run(task: &str, worktrees: &[WorktreeInfo]) -> Result<PreflightReport> {
    let shared_files = preflight_check_shared_files(task, worktrees)?;
    let dependencies = preflight_analyze_dependencies(task, worktrees)?;

    let base = get_default_branch()?;
    let conflicts = preflight_run_conflict_check(task, &base).unwrap_or(ConflictResult {
        has_conflicts: false,
        conflicting_files: Vec::new(),
    });

    let mut warnings = Vec::new();

    // Check for circular deps
    let all_deps = detect_dependencies(worktrees);
    let cycles = check_circular_deps(&all_deps);
    for cycle in &cycles {
        warnings.push(format!("Circular dependency detected: {cycle}"));
    }

    if !shared_files.is_empty() {
        warnings.push(format!(
            "{} shared file(s) detected across worktrees",
            shared_files.len()
        ));
    }

    let verdict = if conflicts.has_conflicts {
        "BLOCK"
    } else {
        "PASS"
    };

    Ok(PreflightReport {
        task: task.to_string(),
        verdict: verdict.to_string(),
        shared_files,
        dependencies,
        conflicts,
        warnings,
    })
}

/// Rollback the last merge.
fn rollback_last() -> Result<()> {
    tracing::info!("Rolling back last merge...");
    let output = Command::new("git")
        .args(["revert", "--no-commit", "HEAD"])
        .output()
        .map_err(|e| AgentError::Git(format!("revert failed: {e}")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AgentError::Git(format!(
            "rollback failed: {}",
            stderr.trim()
        )));
    }

    println!("Last merge reverted (staged, not yet committed).");
    println!("Review changes and commit when ready.");
    Ok(())
}

/// Rollback a specific PR by reverting its merge commit.
fn rollback_pr(number: u32) -> Result<()> {
    tracing::info!("Rolling back PR #{number}...");

    // Find the merge commit for this PR using git log
    let output = Command::new("git")
        .args([
            "log",
            "--merges",
            "--oneline",
            "--grep",
            &format!("#{number}"),
            "-1",
        ])
        .output()
        .map_err(|e| AgentError::Git(format!("failed to find PR merge commit: {e}")))?;

    if !output.status.success() || output.stdout.is_empty() {
        return Err(AgentError::NotFound(format!(
            "merge commit for PR #{number} not found"
        )));
    }

    let line = String::from_utf8_lossy(&output.stdout);
    let commit_sha = line
        .split_whitespace()
        .next()
        .ok_or_else(|| AgentError::Git("could not parse merge commit".to_string()))?;

    let revert = Command::new("git")
        .args(["revert", "--no-commit", "-m", "1", commit_sha])
        .output()
        .map_err(|e| AgentError::Git(format!("revert failed: {e}")))?;

    if !revert.status.success() {
        let stderr = String::from_utf8_lossy(&revert.stderr);
        return Err(AgentError::Git(format!(
            "rollback of PR #{number} failed: {}",
            stderr.trim()
        )));
    }

    println!("PR #{number} merge reverted (staged, not yet committed).");
    Ok(())
}

/// Rollback to a specific commit.
fn rollback_to_commit(commit: &str) -> Result<()> {
    shared::validation::validate_identifier(commit, "commit SHA")?;

    tracing::info!("Rolling back to commit {commit}...");

    // Verify the commit exists
    let verify = Command::new("git")
        .args(["rev-parse", "--verify", commit])
        .output()
        .map_err(|e| AgentError::Git(format!("failed to verify commit: {e}")))?;

    if !verify.status.success() {
        return Err(AgentError::NotFound(format!("commit not found: {commit}")));
    }

    let output = Command::new("git")
        .args(["revert", "--no-commit", &format!("{commit}..HEAD")])
        .output()
        .map_err(|e| AgentError::Git(format!("revert failed: {e}")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(AgentError::Git(format!(
            "rollback to {commit} failed: {}",
            stderr.trim()
        )));
    }

    println!("Rolled back to {commit} (staged, not yet committed).");
    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_check_circular_deps_none() {
        let deps = vec![
            Dependency {
                from: "a".to_string(),
                to: "b".to_string(),
                kind: "file".to_string(),
            },
            Dependency {
                from: "b".to_string(),
                to: "c".to_string(),
                kind: "file".to_string(),
            },
        ];
        let cycles = check_circular_deps(&deps);
        assert!(cycles.is_empty());
    }

    #[test]
    fn test_check_circular_deps_cycle() {
        let deps = vec![
            Dependency {
                from: "a".to_string(),
                to: "b".to_string(),
                kind: "file".to_string(),
            },
            Dependency {
                from: "b".to_string(),
                to: "a".to_string(),
                kind: "file".to_string(),
            },
        ];
        let cycles = check_circular_deps(&deps);
        assert!(!cycles.is_empty());
    }

    #[test]
    fn test_check_circular_deps_empty() {
        let cycles = check_circular_deps(&[]);
        assert!(cycles.is_empty());
    }

    #[test]
    fn test_select_default_branch_precedence() {
        assert_eq!(
            select_default_branch(Some("trunk"), true, true, true, Some("scratch")),
            "trunk"
        );
        assert_eq!(
            select_default_branch(None, true, true, true, Some("scratch")),
            "main"
        );
        assert_eq!(
            select_default_branch(None, false, true, true, Some("scratch")),
            "master"
        );
        assert_eq!(
            select_default_branch(None, false, false, true, Some("scratch")),
            "develop"
        );
        assert_eq!(
            select_default_branch(None, false, false, false, Some("scratch")),
            "scratch"
        );
        assert_eq!(
            select_default_branch(None, false, false, false, None),
            "main"
        );
    }

    #[test]
    fn test_merge_order_no_deps() {
        let worktrees = vec![
            WorktreeInfo {
                path: "/wt/feat-a".to_string(),
                head: "def5678".to_string(),
                branch: Some("refs/heads/task/dogfood-alpha".to_string()),
            },
            WorktreeInfo {
                path: "/wt/feat-b".to_string(),
                head: "ghi9012".to_string(),
                branch: Some("refs/heads/task/dogfood-beta".to_string()),
            },
        ];

        let ordered = merge_order_with_default_branch(&worktrees, &[], "main");
        let branches: HashSet<_> = ordered
            .iter()
            .filter_map(|wt| wt.branch.as_deref())
            .collect();
        // Both should appear; order is unspecified without deps.
        assert_eq!(ordered.len(), 2);
        assert_eq!(
            branches,
            HashSet::from([
                "refs/heads/task/dogfood-alpha",
                "refs/heads/task/dogfood-beta"
            ])
        );
    }

    #[test]
    fn test_conflict_result_json_roundtrip() {
        let result = ConflictResult {
            has_conflicts: true,
            conflicting_files: vec!["src/main.rs".to_string()],
        };
        let json = serde_json::to_string(&result).unwrap();
        let deserialized: ConflictResult = serde_json::from_str(&json).unwrap();
        assert!(deserialized.has_conflicts);
        assert_eq!(deserialized.conflicting_files.len(), 1);
    }

    #[test]
    fn test_preflight_report_json_roundtrip() {
        let report = PreflightReport {
            task: "my-task".to_string(),
            verdict: "PASS".to_string(),
            shared_files: Vec::new(),
            dependencies: Vec::new(),
            conflicts: ConflictResult {
                has_conflicts: false,
                conflicting_files: Vec::new(),
            },
            warnings: Vec::new(),
        };
        let json = serde_json::to_string(&report).unwrap();
        let deserialized: PreflightReport = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.verdict, "PASS");
    }

    #[test]
    fn test_dependency_json_roundtrip() {
        let dep = Dependency {
            from: "task-a".to_string(),
            to: "task-b".to_string(),
            kind: "file".to_string(),
        };
        let json = serde_json::to_string(&dep).unwrap();
        let deserialized: Dependency = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.from, "task-a");
    }
}
