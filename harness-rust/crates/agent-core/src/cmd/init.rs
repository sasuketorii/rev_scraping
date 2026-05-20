//! Project initialization module — replaces `init-project.sh` (393 LOC) +
//! `bootstrap.sh` (310 LOC).
//!
//! Creates the standard directory layout, template files, and checks for
//! required development tools.

use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::Command;

use clap::Subcommand;
use serde::{Deserialize, Serialize};
use tempfile::NamedTempFile;

use shared::error::{AgentError, Result};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/// Subcommands for the `init` family.
#[derive(Subcommand)]
pub enum InitAction {
    /// Initialize project directories and templates.
    Project {
        /// Project name (used for templates and project ID).
        #[arg(long)]
        name: String,
    },
    /// Run bootstrap checks (verify required tools are installed).
    Bootstrap,
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Result of a tool availability check.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCheck {
    /// Tool name.
    pub name: String,
    /// Whether the tool is installed and accessible.
    pub available: bool,
    /// Version string, if available.
    pub version: Option<String>,
    /// Whether this tool is required (vs. optional).
    pub required: bool,
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Required tools for the agent framework.
const REQUIRED_TOOLS: &[&str] = &["git", "jq"];

/// Optional but recommended tools.
const OPTIONAL_TOOLS: &[&str] = &["claude", "codex", "cargo", "node", "npm", "pnpm", "gh"];

/// Directories to create during project initialization.
const INIT_DIRECTORIES: &[&str] = &[
    ".agent/active/prompts",
    ".agent/active/sow",
    ".agent/archive/plans",
    ".agent/archive/sow",
    ".agent/archive/prompts",
    ".agent/archive/feedback",
    ".agent/archive/test",
    ".agent/archive/docs",
    ".claude/tmp",
    ".claude/commands/lib",
    ".claude/hooks",
    ".claude/skills",
    ".shared",
];

/// Lines to add to .gitignore.
const GITIGNORE_ENTRIES: &[&str] = &[
    "# Agent framework",
    ".claude/tmp/",
    "*.lock.d/",
    ".state.lock/",
];

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Execute an `init` subcommand.
pub fn run(action: InitAction) -> Result<()> {
    match action {
        InitAction::Project { name } => {
            let repo_root = shared::git::git_repo_root()
                .unwrap_or_else(|_| std::env::current_dir().unwrap_or_default());

            shared::validation::validate_identifier(&name, "project name")?;

            tracing::info!("Initializing project: {name}");

            create_directories(&repo_root)?;
            create_requirements_template(&repo_root.join(".agent/requirements.md"))?;
            create_project_context(&repo_root.join(".agent/PROJECT_CONTEXT.md"), &name)?;
            update_gitignore(&repo_root)?;

            // Bootstrap project ID
            let _ = super::project_id::bootstrap_project_id(&repo_root, Some(&name));

            println!("Project '{name}' initialized at {}", repo_root.display());
            println!();
            println!("Next steps:");
            println!("  1. Edit .agent/requirements.md with your requirements");
            println!("  2. Edit .agent/PROJECT_CONTEXT.md with project-specific context");
            println!("  3. Run `agent-core init bootstrap` to verify tools");
            Ok(())
        }
        InitAction::Bootstrap => {
            let checks = check_required_tools();
            let mut all_ok = true;

            println!("=== Bootstrap Check ===");
            println!();
            println!("Required tools:");
            for check in &checks {
                if check.required {
                    let status = if check.available { "OK" } else { "MISSING" };
                    let version = check
                        .version
                        .as_deref()
                        .map(|v| format!(" ({v})"))
                        .unwrap_or_default();
                    println!("  [{status}] {}{version}", check.name);
                    if check.required && !check.available {
                        all_ok = false;
                    }
                }
            }

            println!();
            println!("Optional tools:");
            for check in &checks {
                if !check.required {
                    let status = if check.available { "OK" } else { "---" };
                    let version = check
                        .version
                        .as_deref()
                        .map(|v| format!(" ({v})"))
                        .unwrap_or_default();
                    println!("  [{status}] {}{version}", check.name);
                }
            }

            println!();
            if all_ok {
                println!("All required tools are available.");
            } else {
                println!("Some required tools are missing. Install them before proceeding.");
                return Err(AgentError::Config("missing required tools".to_string()));
            }

            // Also output as JSON for machine consumption
            let json = serde_json::to_string_pretty(&checks).map_err(AgentError::Json)?;
            tracing::debug!("Bootstrap check result: {json}");

            Ok(())
        }
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create all required directories for the agent framework.
pub fn create_directories(project_root: &Path) -> Result<()> {
    for dir in INIT_DIRECTORIES {
        let path = project_root.join(dir);
        if !path.exists() {
            fs::create_dir_all(&path).map_err(|e| {
                AgentError::Io(std::io::Error::new(
                    e.kind(),
                    format!("failed to create directory {}: {e}", path.display()),
                ))
            })?;
            tracing::debug!("Created: {}", path.display());
        }
    }
    Ok(())
}

/// Create the requirements template file.
///
/// Only creates the file if it does not already exist.
pub fn create_requirements_template(path: &Path) -> Result<()> {
    if path.exists() {
        tracing::debug!("Requirements template already exists: {}", path.display());
        return Ok(());
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(AgentError::Io)?;
    }

    let template = r#"# Requirements

## Overview
<!-- Describe the overall project goals and requirements -->

## Functional Requirements
<!-- List functional requirements -->
- [ ] Requirement 1
- [ ] Requirement 2

## Non-Functional Requirements
<!-- List non-functional requirements (performance, security, etc.) -->
- [ ] NFR 1

## Constraints
<!-- List any constraints or limitations -->

## Acceptance Criteria
<!-- Define how success is measured -->
"#;

    let dir = path.parent().unwrap_or(Path::new("."));
    let mut tmp = NamedTempFile::new_in(dir).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to create temp file for requirements template: {e}"),
        ))
    })?;
    tmp.write_all(template.as_bytes()).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to write requirements template: {e}"),
        ))
    })?;
    tmp.persist(path).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.error.kind(),
            format!("failed to persist requirements template: {}", e.error),
        ))
    })?;

    tracing::info!("Created requirements template: {}", path.display());
    Ok(())
}

/// Create the project context file.
///
/// Only creates the file if it does not already exist.
pub fn create_project_context(path: &Path, name: &str) -> Result<()> {
    if path.exists() {
        tracing::debug!("Project context already exists: {}", path.display());
        return Ok(());
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(AgentError::Io)?;
    }

    let template = format!(
        r#"# Project Context: {name}

## Project Overview
<!-- Describe what this project does -->

## Tech Stack
<!-- List the primary technologies used -->

## Repository Structure
<!-- Describe the repository layout -->

## Development Workflow
<!-- Describe the development process -->

## Key Conventions
<!-- List important coding conventions and patterns -->

## External Dependencies
<!-- List external services or APIs this project depends on -->
"#
    );

    let dir = path.parent().unwrap_or(Path::new("."));
    let mut tmp = NamedTempFile::new_in(dir).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to create temp file for project context: {e}"),
        ))
    })?;
    tmp.write_all(template.as_bytes()).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to write project context: {e}"),
        ))
    })?;
    tmp.persist(path).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.error.kind(),
            format!("failed to persist project context: {}", e.error),
        ))
    })?;

    tracing::info!("Created project context: {}", path.display());
    Ok(())
}

/// Update .gitignore with agent framework entries.
///
/// Appends entries only if they are not already present.
pub fn update_gitignore(root: &Path) -> Result<()> {
    let gitignore_path = root.join(".gitignore");

    let existing = if gitignore_path.exists() {
        fs::read_to_string(&gitignore_path).map_err(AgentError::Io)?
    } else {
        String::new()
    };

    let mut additions = Vec::new();
    for entry in GITIGNORE_ENTRIES {
        if !existing.contains(entry) {
            additions.push(*entry);
        }
    }

    if additions.is_empty() {
        tracing::debug!(".gitignore already up to date");
        return Ok(());
    }

    let mut content = existing;
    if !content.is_empty() && !content.ends_with('\n') {
        content.push('\n');
    }
    content.push('\n');
    for entry in &additions {
        content.push_str(entry);
        content.push('\n');
    }

    fs::write(&gitignore_path, content).map_err(|e| {
        AgentError::Io(std::io::Error::new(
            e.kind(),
            format!("failed to update .gitignore: {e}"),
        ))
    })?;

    tracing::info!("Updated .gitignore with {} new entries", additions.len());
    Ok(())
}

/// Check for required and optional development tools.
///
/// Returns a list of tool checks with availability and version information.
pub fn check_required_tools() -> Vec<ToolCheck> {
    let mut checks = Vec::new();

    for &tool in REQUIRED_TOOLS {
        checks.push(check_tool(tool, true));
    }

    for &tool in OPTIONAL_TOOLS {
        checks.push(check_tool(tool, false));
    }

    checks
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Check a single tool's availability and version.
fn check_tool(name: &str, required: bool) -> ToolCheck {
    let available = command_exists(name);
    let version = if available {
        get_tool_version(name)
    } else {
        None
    };

    ToolCheck {
        name: name.to_string(),
        available,
        version,
        required,
    }
}

/// Check whether a command is available on `$PATH`.
fn command_exists(cmd: &str) -> bool {
    Command::new("which")
        .arg(cmd)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Try to get the version string of a tool.
fn get_tool_version(name: &str) -> Option<String> {
    let output = Command::new(name).arg("--version").output().ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let first_line = stdout.lines().next()?;

    // Extract just the version number if possible
    Some(first_line.trim().to_string())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_directories() {
        let dir = tempfile::tempdir().unwrap();
        create_directories(dir.path()).unwrap();

        for subdir in INIT_DIRECTORIES {
            assert!(
                dir.path().join(subdir).exists(),
                "directory not created: {subdir}"
            );
        }
    }

    #[test]
    fn test_create_directories_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        create_directories(dir.path()).unwrap();
        // Second call should not fail
        create_directories(dir.path()).unwrap();
    }

    #[test]
    fn test_create_requirements_template() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("requirements.md");
        create_requirements_template(&path).unwrap();

        assert!(path.exists());
        let content = fs::read_to_string(&path).unwrap();
        assert!(content.contains("# Requirements"));
        assert!(content.contains("Functional Requirements"));
    }

    #[test]
    fn test_create_requirements_template_no_overwrite() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("requirements.md");
        fs::write(&path, "existing content").unwrap();

        create_requirements_template(&path).unwrap();
        let content = fs::read_to_string(&path).unwrap();
        assert_eq!(content, "existing content");
    }

    #[test]
    fn test_create_project_context() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("PROJECT_CONTEXT.md");
        create_project_context(&path, "test-project").unwrap();

        assert!(path.exists());
        let content = fs::read_to_string(&path).unwrap();
        assert!(content.contains("test-project"));
        assert!(content.contains("Tech Stack"));
    }

    #[test]
    fn test_update_gitignore_new() {
        let dir = tempfile::tempdir().unwrap();
        update_gitignore(dir.path()).unwrap();

        let content = fs::read_to_string(dir.path().join(".gitignore")).unwrap();
        assert!(content.contains(".claude/tmp/"));
        assert!(content.contains("# Agent framework"));
    }

    #[test]
    fn test_update_gitignore_existing() {
        let dir = tempfile::tempdir().unwrap();
        let gitignore = dir.path().join(".gitignore");
        fs::write(&gitignore, "node_modules/\n").unwrap();

        update_gitignore(dir.path()).unwrap();

        let content = fs::read_to_string(&gitignore).unwrap();
        assert!(content.contains("node_modules/"));
        assert!(content.contains(".claude/tmp/"));
    }

    #[test]
    fn test_update_gitignore_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        update_gitignore(dir.path()).unwrap();
        let content1 = fs::read_to_string(dir.path().join(".gitignore")).unwrap();

        update_gitignore(dir.path()).unwrap();
        let content2 = fs::read_to_string(dir.path().join(".gitignore")).unwrap();

        assert_eq!(content1, content2);
    }

    #[test]
    fn test_check_required_tools() {
        let checks = check_required_tools();
        // Should have entries for both required and optional tools
        assert!(!checks.is_empty());

        // git should be required
        let git_check = checks.iter().find(|c| c.name == "git");
        assert!(git_check.is_some());
        assert!(git_check.unwrap().required);
    }

    #[test]
    fn test_tool_check_json_roundtrip() {
        let check = ToolCheck {
            name: "git".to_string(),
            available: true,
            version: Some("2.40.0".to_string()),
            required: true,
        };
        let json = serde_json::to_string(&check).unwrap();
        let deserialized: ToolCheck = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.name, "git");
        assert!(deserialized.available);
    }
}
