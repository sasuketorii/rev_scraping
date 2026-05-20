//! Input validation utilities.
//!
//! Port of the shell validation helpers from `lib/utils.sh` and
//! `lib/session.sh`.

use std::sync::LazyLock;

use regex::Regex;

use crate::error::{AgentError, Result};
use crate::types::{CodexRole, EffortLevel};

// ---------------------------------------------------------------------------
// Compiled regexes
// ---------------------------------------------------------------------------

/// Identifier pattern — alphanumeric plus `-`, `_`, `.`.
static IDENTIFIER_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[a-zA-Z0-9._-]+$").expect("identifier regex"));

/// jq path pattern — e.g. `.foo`, `.foo_bar`, `.foo[0]`, `.foo.bar[1].baz`.
static JQ_PATH_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(\.[a-zA-Z_][a-zA-Z0-9_]*|\[[0-9]+\])+$").expect("jq path regex")
});

/// Session ID pattern — alphanumeric plus hyphen and underscore.
static SESSION_ID_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[a-zA-Z0-9_-]+$").expect("session ID regex"));

/// Project ID pattern — alphanumeric plus hyphen and underscore, max 64 chars.
static PROJECT_ID_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[a-zA-Z0-9_-]+$").expect("project ID regex"));

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Validate a general-purpose identifier (task names, phase names, etc.).
///
/// Allowed characters: `[a-zA-Z0-9._-]`.
/// Mirrors `_validate_identifier` from `lib/utils.sh`.
pub fn validate_identifier(value: &str, name: &str) -> Result<()> {
    if value.is_empty() {
        return Err(AgentError::Validation(format!(
            "invalid {name}: value must not be empty"
        )));
    }
    if !IDENTIFIER_RE.is_match(value) {
        return Err(AgentError::Validation(format!(
            "invalid {name}: {value} (allowed: alphanumeric, -, _, .)"
        )));
    }
    Ok(())
}

/// Validate a jq-style JSON path for backward compatibility with shell callers.
///
/// Accepts patterns like `.foo`, `.foo_bar`, `.foo[0]`, `.foo.bar[1].baz`.
pub fn validate_jq_path(path: &str) -> Result<()> {
    if path.is_empty() || !JQ_PATH_RE.is_match(path) {
        return Err(AgentError::Validation(format!(
            "invalid jq path: {path} (allowed: .identifier, [index], combinations)"
        )));
    }
    Ok(())
}

/// Validate a session identifier.
///
/// Rules (matching `_validate_session_id` in `session.sh`):
/// - Non-empty
/// - 8..=64 characters
/// - Only `[a-zA-Z0-9_-]`
pub fn validate_session_id(id: &str) -> Result<()> {
    if id.is_empty() {
        return Err(AgentError::Validation(
            "session ID must not be empty".into(),
        ));
    }
    let len = id.len();
    if !(8..=64).contains(&len) {
        return Err(AgentError::Validation(format!(
            "session ID length {len} out of range 8..64"
        )));
    }
    if !SESSION_ID_RE.is_match(id) {
        return Err(AgentError::Validation(format!(
            "session ID contains invalid characters: {id}"
        )));
    }
    Ok(())
}

/// Validate a project identifier.
///
/// Rules:
/// - Non-empty
/// - Max 64 characters
/// - Only `[a-zA-Z0-9_-]`
/// - Must not be the literal string `"agent_base"` (reserved)
pub fn validate_project_id(id: &str) -> Result<()> {
    if id.is_empty() {
        return Err(AgentError::Validation(
            "project ID must not be empty".into(),
        ));
    }
    if id.len() > 64 {
        return Err(AgentError::Validation(format!(
            "project ID too long: {} chars (max 64)",
            id.len()
        )));
    }
    if !PROJECT_ID_RE.is_match(id) {
        return Err(AgentError::Validation(format!(
            "project ID contains invalid characters: {id} (allowed: [a-zA-Z0-9_-])"
        )));
    }
    if id == "agent_base" {
        return Err(AgentError::Validation(
            "project ID 'agent_base' is reserved".into(),
        ));
    }
    Ok(())
}

/// Validate and parse an effort level string.
pub fn validate_effort_level(level: &str) -> Result<EffortLevel> {
    level.parse::<EffortLevel>().map_err(AgentError::Validation)
}

/// Validate and parse a Codex role string.
pub fn validate_codex_role(role: &str) -> Result<CodexRole> {
    role.parse::<CodexRole>().map_err(AgentError::Validation)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- identifier --

    #[test]
    fn valid_identifier() {
        assert!(validate_identifier("my-task.v1", "test").is_ok());
        assert!(validate_identifier("foo_bar", "test").is_ok());
        assert!(validate_identifier("A1", "test").is_ok());
    }

    #[test]
    fn invalid_identifier() {
        assert!(validate_identifier("", "test").is_err());
        assert!(validate_identifier("bad/path", "test").is_err());
        assert!(validate_identifier("no spaces", "test").is_err());
    }

    // -- jq path --

    #[test]
    fn valid_jq_paths() {
        assert!(validate_jq_path(".foo").is_ok());
        assert!(validate_jq_path(".foo_bar").is_ok());
        assert!(validate_jq_path(".foo[0]").is_ok());
        assert!(validate_jq_path(".foo.bar[1].baz").is_ok());
    }

    #[test]
    fn invalid_jq_paths() {
        assert!(validate_jq_path("").is_err());
        assert!(validate_jq_path("foo").is_err());
        assert!(validate_jq_path(".[0]bad").is_err());
    }

    // -- session ID --

    #[test]
    fn valid_session_id() {
        assert!(validate_session_id("abcd1234").is_ok());
        assert!(validate_session_id("550e8400-e29b-41d4-a716-446655440000").is_ok());
        assert!(validate_session_id("my_session-01").is_ok());
    }

    #[test]
    fn invalid_session_id() {
        assert!(validate_session_id("").is_err()); // empty
        assert!(validate_session_id("abc").is_err()); // too short
        assert!(validate_session_id("abc!@#$%^&*()").is_err()); // bad chars
        let long = "a".repeat(65);
        assert!(validate_session_id(&long).is_err()); // too long
    }

    // -- project ID --

    #[test]
    fn valid_project_id() {
        assert!(validate_project_id("my-project").is_ok());
        assert!(validate_project_id("proj_123").is_ok());
    }

    #[test]
    fn invalid_project_id() {
        assert!(validate_project_id("").is_err());
        assert!(validate_project_id("agent_base").is_err()); // reserved
        assert!(validate_project_id("bad/id").is_err());
        let long = "a".repeat(65);
        assert!(validate_project_id(&long).is_err());
    }

    // -- effort level --

    #[test]
    fn valid_effort_levels() {
        assert_eq!(validate_effort_level("low").unwrap(), EffortLevel::Low);
        assert_eq!(
            validate_effort_level("medium").unwrap(),
            EffortLevel::Medium
        );
        assert_eq!(validate_effort_level("high").unwrap(), EffortLevel::High);
        assert_eq!(validate_effort_level("max").unwrap(), EffortLevel::Max);
    }

    #[test]
    fn invalid_effort_level() {
        assert!(validate_effort_level("ultra").is_err());
        assert!(validate_effort_level("").is_err());
    }

    // -- codex role --

    #[test]
    fn valid_codex_roles() {
        assert_eq!(
            validate_codex_role("standard").unwrap(),
            CodexRole::Standard
        );
        assert_eq!(
            validate_codex_role("reviewer").unwrap(),
            CodexRole::Reviewer
        );
    }

    #[test]
    fn invalid_codex_role() {
        assert!(validate_codex_role("admin").is_err());
        assert!(validate_codex_role("").is_err());
    }
}
