//! Helper utilities for hashing, validation, and path normalisation.

use std::path::Path;

use sha2::{Digest, Sha256};
use shared::error::{AgentError, Result};

use crate::constants::TOOL_CONFIG_MAP;

// ---------------------------------------------------------------------------
// Hashing helpers
// ---------------------------------------------------------------------------

/// Native verifier source files that affect verify-cache correctness.
const VERIFY_SURFACE_PATHS: &[&str] = &[
    "harness-rust/crates/agent-core/src/cmd/verify.rs",
    "harness-rust/crates/harness-cache/src/helpers.rs",
];

/// Tools whose verify-cache keys must track native verifier implementation changes.
const VERIFY_SURFACE_TOOLS: &[&str] = &[
    "cargo-check",
    "cargo-test",
    "clippy",
    "eslint",
    "mypy",
    "npm-test",
    "prettier",
    "pytest",
    "ruff",
    "rustfmt",
    "semgrep",
    "shellcheck",
];

/// Compute a SHA-256 hex digest of the configuration file for `tool`.
///
/// Looks up the tool in [`TOOL_CONFIG_MAP`] and hashes the file relative to
/// `project_root`. For native verifier tools, the hash also includes the
/// verifier implementation surface so cache rows are invalidated when the Rust
/// verifier behavior changes. Returns `"no_config"` only when no relevant
/// inputs exist.
pub fn compute_config_hash(tool: &str, project_root: &Path) -> String {
    let include_verify_surface = VERIFY_SURFACE_TOOLS.contains(&tool);
    let config_file = TOOL_CONFIG_MAP
        .iter()
        .find(|(t, _)| *t == tool)
        .map(|(_, f)| *f);

    if config_file.is_none() && !include_verify_surface {
        return "no_config".to_string();
    }

    let mut hasher = Sha256::new();
    let mut has_inputs = false;

    if let Some(config_file) = config_file {
        let path = project_root.join(config_file);
        if let Ok(bytes) = std::fs::read(&path) {
            hasher.update(b"config:");
            hasher.update(config_file.as_bytes());
            hasher.update(b"\0");
            hasher.update(&bytes);
            has_inputs = true;
        }
    }

    if include_verify_surface {
        for relative_path in VERIFY_SURFACE_PATHS {
            let path = project_root.join(relative_path);
            if let Ok(bytes) = std::fs::read(&path) {
                hasher.update(b"verify-surface:");
                hasher.update(relative_path.as_bytes());
                hasher.update(b"\0");
                hasher.update(&bytes);
                has_inputs = true;
            }
        }
    }

    if has_inputs {
        hex::encode(hasher.finalize())
    } else {
        "no_config".to_string()
    }
}

/// Compute a SHA-256 hex digest of the prompt file for `reviewer`.
///
/// The prompt file is expected at `<prompts_dir>/<reviewer>.md`. Returns
/// `"no_prompt"` when the file does not exist.
pub fn compute_prompt_hash(reviewer: &str, prompts_dir: &Path) -> String {
    let path = prompts_dir.join(format!("{reviewer}.md"));
    match std::fs::read(&path) {
        Ok(bytes) => {
            let mut hasher = Sha256::new();
            hasher.update(&bytes);
            hex::encode(hasher.finalize())
        }
        Err(_) => "no_prompt".to_string(),
    }
}

/// Retrieve the version string for the given tool by running `<tool> --version`.
///
/// Returns `"unknown"` if the tool is not installed or the command fails.
pub fn get_tool_version(tool: &str) -> String {
    let binary = match tool {
        "cargo-test" | "cargo-check" => "cargo",
        other => other,
    };

    std::process::Command::new(binary)
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(
                    String::from_utf8_lossy(&o.stdout)
                        .trim()
                        .lines()
                        .next()
                        .unwrap_or("unknown")
                        .to_string(),
                )
            } else {
                None
            }
        })
        .unwrap_or_else(|| "unknown".to_string())
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

/// Maximum allowed size for a findings JSON blob (1 MiB).
const MAX_FINDINGS_BYTES: usize = 1_048_576;

/// Validate that `findings` is well-formed JSON and within the size limit.
pub fn validate_findings(findings: &str) -> Result<()> {
    if findings.len() > MAX_FINDINGS_BYTES {
        return Err(AgentError::Validation(format!(
            "findings exceed 1 MB limit ({} bytes)",
            findings.len()
        )));
    }
    serde_json::from_str::<serde_json::Value>(findings)
        .map_err(|e| AgentError::Validation(format!("findings is not valid JSON: {e}")))?;
    Ok(())
}

/// Maximum allowed length for a normalised file path.
const MAX_PATH_LEN: usize = 4096;

/// Validate and normalise a file path.
///
/// Rejects absolute paths, paths containing `..`, and paths longer than
/// [`MAX_PATH_LEN`]. Returns the normalised (forward-slash) relative path.
pub fn validate_and_normalize_path(file_path: &str, _project_root: &Path) -> Result<String> {
    if file_path.len() > MAX_PATH_LEN {
        return Err(AgentError::Validation(format!(
            "path exceeds {MAX_PATH_LEN} characters"
        )));
    }

    // Reject absolute paths
    if file_path.starts_with('/') || file_path.starts_with('\\') {
        return Err(AgentError::Validation(
            "absolute paths are not allowed".to_string(),
        ));
    }

    // Windows-style absolute (e.g. C:\...)
    if file_path.len() >= 2 && file_path.as_bytes()[1] == b':' {
        return Err(AgentError::Validation(
            "absolute paths are not allowed".to_string(),
        ));
    }

    // Reject path traversal
    let normalized = file_path.replace('\\', "/");
    for component in normalized.split('/') {
        if component == ".." {
            return Err(AgentError::Validation(
                "path traversal (..) is not allowed".to_string(),
            ));
        }
    }

    Ok(normalized)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, path::PathBuf};

    #[test]
    fn validate_findings_accepts_valid_json() {
        assert!(validate_findings(r#"{"ok": true}"#).is_ok());
        assert!(validate_findings("[]").is_ok());
    }

    #[test]
    fn validate_findings_rejects_invalid_json() {
        assert!(validate_findings("not json").is_err());
    }

    #[test]
    fn validate_findings_rejects_oversized() {
        let big = "x".repeat(MAX_FINDINGS_BYTES + 1);
        assert!(validate_findings(&big).is_err());
    }

    #[test]
    fn normalize_rejects_dotdot() {
        let root = PathBuf::from("/tmp");
        assert!(validate_and_normalize_path("../etc/passwd", &root).is_err());
        assert!(validate_and_normalize_path("foo/../../bar", &root).is_err());
    }

    #[test]
    fn normalize_rejects_absolute() {
        let root = PathBuf::from("/tmp");
        assert!(validate_and_normalize_path("/etc/passwd", &root).is_err());
    }

    #[test]
    fn normalize_rejects_long_path() {
        let root = PathBuf::from("/tmp");
        let long = "a/".repeat(MAX_PATH_LEN);
        assert!(validate_and_normalize_path(&long, &root).is_err());
    }

    #[test]
    fn normalize_accepts_valid_path() {
        let root = PathBuf::from("/tmp");
        let result = validate_and_normalize_path("src/main.rs", &root);
        assert_eq!(result.unwrap(), "src/main.rs");
    }

    #[test]
    fn normalize_converts_backslashes() {
        let root = PathBuf::from("/tmp");
        let result = validate_and_normalize_path("src\\lib.rs", &root);
        assert_eq!(result.unwrap(), "src/lib.rs");
    }

    #[test]
    fn compute_config_hash_missing_tool() {
        let root = PathBuf::from("/nonexistent");
        assert_eq!(compute_config_hash("unknown_tool", &root), "no_config");
    }

    #[test]
    fn compute_config_hash_changes_when_verifier_surface_changes() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();

        fs::write(root.join(".eslintrc.json"), "{}").unwrap();
        for relative_path in VERIFY_SURFACE_PATHS {
            let path = root.join(relative_path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, format!("initial:{relative_path}")).unwrap();
        }

        let before = compute_config_hash("eslint", root);
        assert_ne!(before, "no_config");

        fs::write(
            root.join(VERIFY_SURFACE_PATHS[0]),
            "modified verifier surface",
        )
        .unwrap();

        let after = compute_config_hash("eslint", root);
        assert_ne!(before, after);
    }

    #[test]
    fn compute_config_hash_for_semgrep_uses_verifier_surface_without_config() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();

        for relative_path in VERIFY_SURFACE_PATHS {
            let path = root.join(relative_path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, format!("surface:{relative_path}")).unwrap();
        }

        let hash = compute_config_hash("semgrep", root);
        assert_ne!(hash, "no_config");
    }

    #[test]
    fn compute_prompt_hash_missing_file() {
        let root = PathBuf::from("/nonexistent");
        assert_eq!(compute_prompt_hash("safety", &root), "no_prompt");
    }

    #[test]
    fn get_tool_version_unknown_binary() {
        assert_eq!(
            get_tool_version("definitely_not_a_real_tool_xyz"),
            "unknown"
        );
    }
}
