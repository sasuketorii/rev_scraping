//! Unified error types for the agent_base system.
//!
//! All crates return [`AgentError`] via the [`Result`] type alias.

use thiserror::Error;

/// Top-level error type covering every failure mode in agent_base.
#[derive(Error, Debug)]
pub enum AgentError {
    /// Filesystem I/O failure.
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    /// JSON serialization / deserialization failure.
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    /// File-lock acquisition or release failure.
    #[error("Lock error: {0}")]
    Lock(String),

    /// State machine invariant violation.
    #[error("State error: {0}")]
    State(String),

    /// Input validation failure (identifiers, paths, etc.).
    #[error("Validation error: {0}")]
    Validation(String),

    /// Git CLI invocation failure.
    #[error("Git error: {0}")]
    Git(String),

    /// Operation exceeded its deadline.
    #[error("Timeout: {0}")]
    Timeout(String),

    /// External command returned a non-zero exit code.
    #[error("Command failed: {0}")]
    Command(String),

    /// A required resource was not found.
    #[error("Not found: {0}")]
    NotFound(String),

    /// Configuration is missing or invalid.
    #[error("Configuration error: {0}")]
    Config(String),

    /// Database operation failure.
    #[error("Database error: {0}")]
    Database(String),
}

/// Convenience alias used throughout the workspace.
pub type Result<T> = std::result::Result<T, AgentError>;
