//! Cache administration commands for `agent-core`.

use std::fs;
use std::path::Path;

use clap::Subcommand;

use harness_cache::{helpers as cache_helpers, CacheManager};
use shared::error::{AgentError, Result};

/// Administrative cache operations.
#[derive(Subcommand)]
pub enum CacheAction {
    /// Show cache statistics for a project.
    Stats {
        /// Project identifier used for the shared semantic/cache database.
        #[arg(long)]
        project_id: String,
    },
    /// Clear all cache tables for a project.
    Clear {
        /// Project identifier used for the shared semantic/cache database.
        #[arg(long)]
        project_id: String,
    },
    /// Clear cache rows related to a single file.
    ClearFile {
        /// Project identifier used for the shared semantic/cache database.
        #[arg(long)]
        project_id: String,
        /// Relative file path to clear.
        #[arg(long)]
        file: String,
    },
    /// Evict stale cache entries older than the configured age.
    Evict {
        /// Project identifier used for the shared semantic/cache database.
        #[arg(long)]
        project_id: String,
        /// Maximum age in days.
        #[arg(long, default_value = "7")]
        max_age_days: u32,
    },
    /// Audit a sample of verify-cache rows for stale config/tool metadata.
    Audit {
        /// Project identifier used for the shared semantic/cache database.
        #[arg(long)]
        project_id: String,
        /// Number of sampled rows.
        #[arg(long, default_value = "10")]
        sample_size: u32,
    },
}

/// Execute a `cache` subcommand.
pub fn run(action: CacheAction) -> Result<()> {
    match action {
        CacheAction::Stats { project_id } => {
            let cache = CacheManager::new(&project_id)?;
            let json =
                serde_json::to_string_pretty(&cache.get_cache_stats()).map_err(AgentError::Json)?;
            println!("{json}");
            Ok(())
        }
        CacheAction::Clear { project_id } => {
            let cache = CacheManager::new(&project_id)?;
            cache.clear_all()?;
            println!("cleared");
            Ok(())
        }
        CacheAction::ClearFile { project_id, file } => {
            let cache = CacheManager::new(&project_id)?;
            let repo_root = shared::git::git_repo_root()?;
            let normalized = normalize_cache_file_path(&file, &repo_root)?;
            cache.clear_file(&normalized)?;
            println!("cleared");
            Ok(())
        }
        CacheAction::Evict {
            project_id,
            max_age_days,
        } => {
            let cache = CacheManager::new(&project_id)?;
            let evicted = cache.evict_stale(max_age_days)?;
            println!("{evicted}");
            Ok(())
        }
        CacheAction::Audit {
            project_id,
            sample_size,
        } => {
            let cache = CacheManager::new(&project_id)?;
            let repo_root = shared::git::git_repo_root()?;
            ensure_audit_repo_matches_project_id(&project_id, &repo_root)?;
            let json = serde_json::to_string_pretty(&cache.audit(sample_size, &repo_root)?)
                .map_err(AgentError::Json)?;
            println!("{json}");
            Ok(())
        }
    }
}

fn normalize_cache_file_path(file: &str, repo_root: &Path) -> Result<String> {
    cache_helpers::validate_and_normalize_path(file, repo_root)
}

fn ensure_audit_repo_matches_project_id(project_id: &str, repo_root: &Path) -> Result<()> {
    let artifact_path = repo_root.join(".shared/project_id");
    let repo_project_id = fs::read_to_string(&artifact_path)
        .map_err(AgentError::Io)?
        .trim()
        .to_string();

    if repo_project_id != project_id {
        return Err(AgentError::Validation(format!(
            "cache audit project_id mismatch: repo {} declares {}, got {}",
            repo_root.display(),
            repo_project_id,
            project_id
        )));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::{ensure_audit_repo_matches_project_id, normalize_cache_file_path};

    #[test]
    fn normalize_cache_file_path_converts_backslashes() {
        let dir = tempfile::tempdir().unwrap();
        let normalized = normalize_cache_file_path("src\\main.rs", dir.path()).unwrap();
        assert_eq!(normalized, "src/main.rs");
    }

    #[test]
    fn normalize_cache_file_path_rejects_traversal() {
        let dir = tempfile::tempdir().unwrap();
        assert!(normalize_cache_file_path("../etc/passwd", dir.path()).is_err());
    }

    #[test]
    fn ensure_audit_repo_matches_project_id_accepts_matching_repo() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join(".shared")).unwrap();
        fs::write(dir.path().join(".shared/project_id"), "demo-project\n").unwrap();

        assert!(ensure_audit_repo_matches_project_id("demo-project", dir.path()).is_ok());
    }

    #[test]
    fn ensure_audit_repo_matches_project_id_rejects_mismatch() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join(".shared")).unwrap();
        fs::write(dir.path().join(".shared/project_id"), "demo-project\n").unwrap();

        assert!(ensure_audit_repo_matches_project_id("other-project", dir.path()).is_err());
    }
}
