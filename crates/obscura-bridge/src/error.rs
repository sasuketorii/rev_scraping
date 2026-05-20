// SPDX-License-Identifier: MIT
// Source: derived from obscura (Apache-2.0), https://github.com/h4ckf0r0day/obscura

use thiserror::Error;

pub type Result<T> = std::result::Result<T, BridgeError>;

#[derive(Debug, Error)]
pub enum BridgeError {
    #[error("obscura binary not found at {path}")]
    BinaryNotFound { path: String },

    #[error("obscura subprocess failed to start: {0}")]
    SpawnFailed(#[source] std::io::Error),

    #[error("obscura subprocess exited before becoming ready: status={status:?}")]
    EarlyExit { status: Option<i32> },

    #[error("timed out waiting for obscura CDP endpoint to become ready")]
    StartupTimeout,

    #[error("CDP client error: {0}")]
    Cdp(String),

    #[error("URL rejected by bridge SSRF guard: {reason}")]
    SsrfDenied { reason: String },

    #[error("invalid URL: {0}")]
    InvalidUrl(#[from] url::ParseError),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("bridge has been shut down")]
    AlreadyShutdown,

    #[error("operation timed out after {ms} ms")]
    Timeout { ms: u128 },

    #[error("{0}")]
    Other(String),
}

impl From<chromiumoxide::error::CdpError> for BridgeError {
    fn from(e: chromiumoxide::error::CdpError) -> Self {
        BridgeError::Cdp(e.to_string())
    }
}

impl From<serde_json::Error> for BridgeError {
    fn from(e: serde_json::Error) -> Self {
        BridgeError::Other(format!("serde_json: {e}"))
    }
}
