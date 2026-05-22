// SPDX-License-Identifier: MIT
// Source: rev_scraping Lane C P1 (stealth-agent-contracts crate, original work)
//! # stealth-agent-contracts
//!
//! Shared type contracts between `stealth-cli`, `stealth-mcp`, and other
//! stealth-* crates. This crate exists to centralize cross-crate types and
//! prevent cyclic dependencies between CLI and MCP layers.
//!
//! All public types here are intended to be stable wire-format contracts
//! (serde Serialize+Deserialize) usable across process boundaries.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod error;
pub mod progress;
pub mod rate;
pub mod token;

pub use error::{all_error_kind_docs, ErrorEnvelope, ErrorKind, ErrorKindDoc};
pub use progress::{ProgressState, ProgressTracker};
pub use rate::{
    CompletionRecord, IdempotencyKey, PerHostRateLimiter, RateLimitConfig, RateLimitReason,
    RateLimitWait, ToolRateLimiter, DEFAULT_IDEMPOTENCY_TTL_SECS,
};
pub use token::{ProgressToken, SessionId};
