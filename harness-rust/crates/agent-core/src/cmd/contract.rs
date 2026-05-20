//! Task contract module — replaces `task_contract.sh` (2,171 LOC).
//!
//! Extracts, validates, and manages task contracts from execution plans.
//! A task contract is a structured summary of what a coder must accomplish,
//! including required checks, scope files, and constraints.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use chrono::Utc;
use clap::Subcommand;
use serde::{Deserialize, Serialize};
use tempfile::NamedTempFile;
use uuid::Uuid;

use shared::error::{AgentError, Result};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/// Subcommands for the `contract` family.
#[derive(Subcommand)]
pub enum ContractAction {
    /// Extract and emit task contract from plan.
    Emit {
        /// Path to the execution plan.
        #[arg(long)]
        plan: String,
        /// Path for the output contract file.
        #[arg(long)]
        output: String,
    },
    /// Validate a task contract file.
    Validate {
        /// Path to the contract file.
        #[arg(long)]
        file: String,
    },
    /// Read contract ID from file.
    ReadId {
        /// Path to the contract file.
        #[arg(long)]
        file: String,
    },
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A task contract extracted from an execution plan.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskContract {
    /// Unique contract identifier (UUID v4).
    pub id: String,
    /// Path to the source plan file.
    pub plan_path: String,
    /// Human-readable task name (slugified from plan title).
    pub task_name: String,
    /// Required verification checks.
    pub required_checks: Vec<String>,
    /// Files in scope for this task.
    pub scope_files: Vec<String>,
    /// Constraints / invariants that must be maintained.
    pub constraints: Vec<String>,
    /// ISO 8601 creation timestamp.
    pub created_at: String,
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

#[cfg(test)]
/// Characters considered shell metacharacters for injection detection.
const SHELL_META_CHARS: &[char] = &[
    ';', '|', '&', '`', '$', '(', ')', '{', '}', '<', '>', '\n', '!', '#',
];

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Execute a `contract` subcommand.
pub fn run(action: ContractAction) -> Result<()> {
    match action {
        ContractAction::Emit { plan, output } => {
            let repo_root = shared::git::git_repo_root()?;
            let contract = emit_contract(Path::new(&plan), Path::new(&output), &repo_root)?;
            let json = serde_json::to_string_pretty(&contract).map_err(AgentError::Json)?;
            println!("{json}");
            Ok(())
        }
        ContractAction::Validate { file } => {
            validate_contract(Path::new(&file))?;
            println!("Contract is valid.");
            Ok(())
        }
        ContractAction::ReadId { file } => {
            let id = read_contract_id(Path::new(&file))?;
            println!("{id}");
            Ok(())
        }
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Convert text to a URL-safe slug.
///
/// `"My Feature — v2"` becomes `"my-feature-v2"`.
pub fn slugify(text: &str) -> String {
    let lower = text.to_lowercase();
    let slug: String = lower
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();

    // Collapse consecutive hyphens and trim leading/trailing hyphens.
    let mut result = String::new();
    let mut prev_hyphen = true; // treat start as hyphen to trim leading
    for ch in slug.chars() {
        if ch == '-' {
            if !prev_hyphen {
                result.push('-');
            }
            prev_hyphen = true;
        } else {
            result.push(ch);
            prev_hyphen = false;
        }
    }
    // Trim trailing hyphen
    if result.ends_with('-') {
        result.pop();
    }
    result
}

/// Normalize a plan path relative to the repository root.
///
/// Returns a repo-relative path if the plan is inside the repo,
/// otherwise returns the canonical absolute path.
pub fn normalize_plan_path(plan: &str, repo_root: &Path) -> Result<String> {
    let abs = if Path::new(plan).is_absolute() {
        PathBuf::from(plan)
    } else {
        std::env::current_dir().map_err(AgentError::Io)?.join(plan)
    };

    let canonical = abs
        .canonicalize()
        .map_err(|e| AgentError::Validation(format!("cannot resolve plan path '{}': {e}", plan)))?;

    let root_canonical = repo_root
        .canonicalize()
        .unwrap_or_else(|_| repo_root.to_path_buf());

    if let Ok(relative) = canonical.strip_prefix(&root_canonical) {
        Ok(relative.to_string_lossy().to_string())
    } else {
        Ok(canonical.to_string_lossy().to_string())
    }
}

/// Extract a metadata value from a markdown heading line.
///
/// Looks for lines like `## Key: Value` or `# Key: Value` and returns the
/// value portion for the matching key (case-insensitive).
pub fn extract_metadata_value(content: &str, key: &str) -> Option<String> {
    let key_lower = key.to_lowercase();
    for line in content.lines() {
        let trimmed = line.trim().trim_start_matches('#').trim();
        if let Some(rest) = trimmed.strip_prefix(&format!("{}:", &key_lower)) {
            return Some(rest.trim().to_string());
        }
        // Case-insensitive match
        let trimmed_lower = trimmed.to_lowercase();
        if let Some(pos) = trimmed_lower.find(&format!("{}:", &key_lower)) {
            let after_key = &trimmed[pos + key.len() + 1..];
            return Some(after_key.trim().to_string());
        }
    }
    None
}

/// Extract bulleted or numbered list items under a given markdown heading.
///
/// Returns the text content of each list item (without the bullet/number).
pub fn extract_section_items(content: &str, heading: &str) -> Vec<String> {
    let heading_lower = heading.to_lowercase();
    let mut in_section = false;
    let mut items = Vec::new();

    for line in content.lines() {
        let trimmed = line.trim();

        // Check if this line is a heading
        if trimmed.starts_with('#') {
            let heading_text = trimmed.trim_start_matches('#').trim().to_lowercase();
            in_section = heading_text == heading_lower || heading_text.starts_with(&heading_lower);
            continue;
        }

        if !in_section {
            continue;
        }

        // Match bullet items: - item, * item, + item
        if let Some(rest) = trimmed
            .strip_prefix("- ")
            .or_else(|| trimmed.strip_prefix("* "))
            .or_else(|| trimmed.strip_prefix("+ "))
        {
            let item = rest.trim().to_string();
            if !item.is_empty() {
                items.push(item);
            }
            continue;
        }

        // Match numbered items: 1. item, 2) item
        let numbered = trimmed.char_indices().find(|(_, c)| !c.is_ascii_digit());
        if let Some((pos, sep)) = numbered {
            if pos > 0 && (sep == '.' || sep == ')') {
                let rest = trimmed[pos + 1..].trim();
                if !rest.is_empty() {
                    items.push(rest.to_string());
                }
            }
        }
    }

    items
}

/// Extract required checks from a `## Required Checks` section.
pub fn extract_required_checks(content: &str) -> Vec<String> {
    extract_section_items(content, "Required Checks")
}

#[cfg(test)]
/// Detect unquoted shell metacharacters in a string.
pub fn has_shell_metacharacters(text: &str) -> bool {
    text.chars().any(|c| SHELL_META_CHARS.contains(&c))
}

#[cfg(test)]
/// Detect variable expansion patterns (`$FOO`, `${BAR}`).
pub fn has_variable_expansion(text: &str) -> bool {
    let chars: Vec<char> = text.chars().collect();
    for i in 0..chars.len() {
        if chars[i] == '$' {
            // Check for ${...} or $WORD
            if i + 1 < chars.len() {
                let next = chars[i + 1];
                if next == '{' || next.is_ascii_alphabetic() || next == '_' {
                    return true;
                }
            }
        }
    }
    false
}

#[cfg(test)]
/// Detect prefix injection patterns like `ENV=val cmd`.
pub fn detect_prefix_injection(text: &str) -> bool {
    let trimmed = text.trim();
    // Pattern: WORD=VALUE followed by space then a command
    if let Some(eq_pos) = trimmed.find('=') {
        let before_eq = &trimmed[..eq_pos];
        // Check that the part before '=' looks like an env var name
        if !before_eq.is_empty()
            && before_eq
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_')
            && before_eq
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        {
            // Check if there's content after the value (separated by space)
            let after_eq = &trimmed[eq_pos + 1..];
            if after_eq.contains(' ') {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
/// Validate a shell command item for safety.
///
/// Rejects commands with shell metacharacters, variable expansion, or
/// prefix injection patterns.
pub fn validate_command_item(cmd: &str) -> Result<()> {
    if cmd.trim().is_empty() {
        return Err(AgentError::Validation("empty command".to_string()));
    }

    if has_shell_metacharacters(cmd) {
        return Err(AgentError::Validation(format!(
            "command contains shell metacharacters: {}",
            cmd
        )));
    }

    if has_variable_expansion(cmd) {
        return Err(AgentError::Validation(format!(
            "command contains variable expansion: {}",
            cmd
        )));
    }

    if detect_prefix_injection(cmd) {
        return Err(AgentError::Validation(format!(
            "command contains prefix injection pattern: {}",
            cmd
        )));
    }

    Ok(())
}

/// Extract and emit a task contract from a plan file.
///
/// Reads the plan markdown, extracts metadata, scope, checks, and
/// constraints, then writes the contract JSON to `output`.
pub fn emit_contract(plan_path: &Path, output: &Path, repo_root: &Path) -> Result<TaskContract> {
    if !plan_path.exists() {
        return Err(AgentError::NotFound(format!(
            "plan file not found: {}",
            plan_path.display()
        )));
    }

    let content = fs::read_to_string(plan_path).map_err(AgentError::Io)?;
    let normalized = normalize_plan_path(&plan_path.to_string_lossy(), repo_root)?;

    // Extract task name from the first heading or filename
    let task_name = extract_metadata_value(&content, "Task")
        .or_else(|| extract_metadata_value(&content, "Title"))
        .or_else(|| {
            // Use first H1 or H2 heading
            content.lines().find_map(|line| {
                let trimmed = line.trim();
                if trimmed.starts_with("# ") || trimmed.starts_with("## ") {
                    Some(trimmed.trim_start_matches('#').trim().to_string())
                } else {
                    None
                }
            })
        })
        .unwrap_or_else(|| {
            // Fall back to filename stem
            plan_path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("unknown")
                .to_string()
        });

    let slugified_name = slugify(&task_name);

    let required_checks = extract_required_checks(&content);
    let scope_files = extract_section_items(&content, "Scope")
        .into_iter()
        .chain(extract_section_items(&content, "Files"))
        .collect::<Vec<_>>();
    let constraints = extract_section_items(&content, "Constraints")
        .into_iter()
        .chain(extract_section_items(&content, "Invariants"))
        .collect::<Vec<_>>();

    let contract = TaskContract {
        id: Uuid::new_v4().to_string(),
        plan_path: normalized,
        task_name: slugified_name,
        required_checks,
        scope_files,
        constraints,
        created_at: Utc::now().to_rfc3339(),
    };

    // Ensure output directory exists
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(AgentError::Io)?;
    }

    let json = serde_json::to_string_pretty(&contract).map_err(AgentError::Json)?;
    let dir = output.parent().unwrap_or(Path::new("."));
    let mut tmp = NamedTempFile::new_in(dir).map_err(AgentError::Io)?;
    tmp.write_all(json.as_bytes()).map_err(AgentError::Io)?;
    tmp.persist(output).map_err(|e| AgentError::Io(e.error))?;

    tracing::info!(
        "Contract emitted: id={}, task={}",
        contract.id,
        contract.task_name
    );

    Ok(contract)
}

/// Validate a task contract file.
///
/// Checks that the file is valid JSON, has required fields, and that the
/// contract ID is a valid UUID.
pub fn validate_contract(file: &Path) -> Result<()> {
    if !file.exists() {
        return Err(AgentError::NotFound(format!(
            "contract file not found: {}",
            file.display()
        )));
    }

    let content = fs::read_to_string(file).map_err(AgentError::Io)?;
    let contract: TaskContract = serde_json::from_str(&content)
        .map_err(|e| AgentError::Validation(format!("invalid contract JSON: {e}")))?;

    // Validate ID is a UUID
    if Uuid::parse_str(&contract.id).is_err() {
        return Err(AgentError::Validation(format!(
            "contract ID is not a valid UUID: {}",
            contract.id
        )));
    }

    // Validate task name is not empty
    if contract.task_name.trim().is_empty() {
        return Err(AgentError::Validation(
            "contract task_name is empty".to_string(),
        ));
    }

    // Validate plan path is not empty
    if contract.plan_path.trim().is_empty() {
        return Err(AgentError::Validation(
            "contract plan_path is empty".to_string(),
        ));
    }

    tracing::info!("Contract valid: id={}", contract.id);
    Ok(())
}

/// Read the contract ID from a contract file.
pub fn read_contract_id(file: &Path) -> Result<String> {
    if !file.exists() {
        return Err(AgentError::NotFound(format!(
            "contract file not found: {}",
            file.display()
        )));
    }

    let content = fs::read_to_string(file).map_err(AgentError::Io)?;
    let contract: TaskContract = serde_json::from_str(&content)
        .map_err(|e| AgentError::Validation(format!("invalid contract JSON: {e}")))?;

    Ok(contract.id)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_slugify_basic() {
        assert_eq!(slugify("My Feature"), "my-feature");
        assert_eq!(slugify("Hello World!"), "hello-world");
        assert_eq!(slugify("v2.0 Release"), "v2-0-release");
    }

    #[test]
    fn test_slugify_special_chars() {
        assert_eq!(slugify("a--b"), "a-b");
        assert_eq!(slugify("---leading"), "leading");
        assert_eq!(slugify("trailing---"), "trailing");
        assert_eq!(slugify(""), "");
    }

    #[test]
    fn test_extract_metadata_value() {
        let content = "# Plan\n## Task: Implement auth\n## Phase: impl\n";
        assert_eq!(
            extract_metadata_value(content, "Task"),
            Some("Implement auth".to_string())
        );
        assert_eq!(
            extract_metadata_value(content, "Phase"),
            Some("impl".to_string())
        );
        assert_eq!(extract_metadata_value(content, "Missing"), None);
    }

    #[test]
    fn test_extract_section_items_bullets() {
        let content = "# Plan\n## Scope\n- src/main.rs\n- src/lib.rs\n## Other\n- ignore\n";
        let items = extract_section_items(content, "Scope");
        assert_eq!(items, vec!["src/main.rs", "src/lib.rs"]);
    }

    #[test]
    fn test_extract_section_items_numbered() {
        let content = "## Constraints\n1. No breaking changes\n2. Keep backward compat\n";
        let items = extract_section_items(content, "Constraints");
        assert_eq!(items, vec!["No breaking changes", "Keep backward compat"]);
    }

    #[test]
    fn test_extract_required_checks() {
        let content = "## Required Checks\n- cargo test\n- cargo clippy\n- cargo fmt --check\n";
        let checks = extract_required_checks(content);
        assert_eq!(checks.len(), 3);
        assert!(checks.contains(&"cargo test".to_string()));
    }

    #[test]
    fn test_has_shell_metacharacters() {
        assert!(has_shell_metacharacters("foo; bar"));
        assert!(has_shell_metacharacters("foo | bar"));
        assert!(has_shell_metacharacters("foo && bar"));
        assert!(has_shell_metacharacters("$(cmd)"));
        assert!(!has_shell_metacharacters("cargo test"));
        assert!(!has_shell_metacharacters("simple-command"));
    }

    #[test]
    fn test_has_variable_expansion() {
        assert!(has_variable_expansion("echo $HOME"));
        assert!(has_variable_expansion("path=${DIR}/file"));
        assert!(!has_variable_expansion("cargo test"));
        assert!(!has_variable_expansion("no-dollar-sign"));
    }

    #[test]
    fn test_detect_prefix_injection() {
        assert!(detect_prefix_injection("FOO=bar cmd"));
        assert!(detect_prefix_injection("PATH=/usr/bin ls"));
        assert!(!detect_prefix_injection("cargo test"));
        assert!(!detect_prefix_injection("FOO=bar")); // no command after
    }

    #[test]
    fn test_validate_command_item() {
        assert!(validate_command_item("cargo test").is_ok());
        assert!(validate_command_item("npm run build").is_ok());
        assert!(validate_command_item("foo; rm -rf /").is_err());
        assert!(validate_command_item("echo $HOME").is_err());
        assert!(validate_command_item("").is_err());
    }

    #[test]
    fn test_emit_and_read_contract() {
        let dir = tempfile::tempdir().unwrap();
        let plan = dir.path().join("plan.md");
        fs::write(
            &plan,
            "# My Task\n## Required Checks\n- cargo test\n## Scope\n- src/main.rs\n## Constraints\n- No panics\n",
        )
        .unwrap();

        let output = dir.path().join("contract.json");
        let contract = emit_contract(&plan, &output, dir.path()).unwrap();

        assert!(!contract.id.is_empty());
        assert_eq!(contract.task_name, "my-task");
        assert!(contract.required_checks.contains(&"cargo test".to_string()));
        assert!(contract.scope_files.contains(&"src/main.rs".to_string()));
        assert!(contract.constraints.contains(&"No panics".to_string()));

        // Validate
        assert!(validate_contract(&output).is_ok());

        // Read ID
        let id = read_contract_id(&output).unwrap();
        assert_eq!(id, contract.id);
    }

    #[test]
    fn test_validate_contract_invalid_json() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("bad.json");
        fs::write(&file, "not json").unwrap();
        assert!(validate_contract(&file).is_err());
    }

    #[test]
    fn test_validate_contract_missing_file() {
        assert!(validate_contract(Path::new("/nonexistent/contract.json")).is_err());
    }

    #[test]
    fn test_contract_json_roundtrip() {
        let contract = TaskContract {
            id: Uuid::new_v4().to_string(),
            plan_path: "plans/my-plan.md".to_string(),
            task_name: "my-task".to_string(),
            required_checks: vec!["cargo test".to_string()],
            scope_files: vec!["src/main.rs".to_string()],
            constraints: vec!["no panics".to_string()],
            created_at: Utc::now().to_rfc3339(),
        };
        let json = serde_json::to_string(&contract).unwrap();
        let deserialized: TaskContract = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.id, contract.id);
        assert_eq!(deserialized.task_name, "my-task");
    }

    #[test]
    fn serde_roundtrip_snapshot() {
        let contract = TaskContract {
            id: "00000000-0000-0000-0000-000000000000".to_string(),
            plan_path: "fixed/path".to_string(),
            task_name: "fixed-name".to_string(),
            required_checks: vec!["check_a".to_string(), "check_b".to_string()],
            scope_files: vec!["a.rs".to_string()],
            constraints: vec!["no_io".to_string()],
            created_at: "2026-01-01T00:00:00Z".to_string(),
        };
        let json = serde_json::to_string_pretty(&contract).unwrap();
        let snapshot = include_str!("../../tests/fixtures/task_contract_snapshot.json");
        assert_eq!(json.trim(), snapshot.trim());
        let roundtrip: TaskContract = serde_json::from_str(&json).unwrap();
        assert_eq!(roundtrip.id, contract.id);
    }
}
