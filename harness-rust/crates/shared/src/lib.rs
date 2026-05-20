//! # shared
//!
//! Common types, error handling, logging, file locking, and git utilities
//! used by all crates in the agent_base workspace.
//!
//! This crate is the foundation layer — every other crate depends on it.

pub mod error;
pub mod freshness;
pub mod git;
pub mod lock;
pub mod logging;
pub mod paths;
pub mod ranker;
pub mod semantic_gc;
pub mod semantic_lock;
pub mod types;
pub mod validation;

// Re-export the most commonly used items at the crate root.
pub use error::{AgentError, Result};
pub use types::*;
