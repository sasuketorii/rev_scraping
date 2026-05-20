//! Logging / tracing initialisation with colored output.
//!
//! Matches the shell log format: `[INFO]`, `[WARN]`, `[ERROR]`, `[OK]`, `[DEBUG]`.
//!
//! Respects the `LOG_LEVEL` environment variable (falls back to `RUST_LOG`,
//! then defaults to `info`).

use tracing_subscriber::EnvFilter;

/// Initialise the global tracing subscriber.
///
/// Priority for log level: `LOG_LEVEL` > `RUST_LOG` > `"info"`.
/// Timestamps are emitted in ISO 8601 / RFC 3339 format.
///
/// Call once at program startup.  Subsequent calls are no-ops.
pub fn init() {
    let filter = if let Ok(level) = std::env::var("LOG_LEVEL") {
        EnvFilter::new(level)
    } else {
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"))
    };

    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .try_init();
}

// ---------------------------------------------------------------------------
// Convenience macros matching the shell log helpers
// ---------------------------------------------------------------------------

/// Log an informational message (maps to `tracing::info!`).
#[macro_export]
macro_rules! log_info {
    ($($arg:tt)*) => { tracing::info!($($arg)*) };
}

/// Log a warning (maps to `tracing::warn!`).
#[macro_export]
macro_rules! log_warn {
    ($($arg:tt)*) => { tracing::warn!($($arg)*) };
}

/// Log an error (maps to `tracing::error!`).
#[macro_export]
macro_rules! log_error {
    ($($arg:tt)*) => { tracing::error!($($arg)*) };
}

/// Log a success / OK message (uses `tracing::info!` with an `[OK]` prefix).
#[macro_export]
macro_rules! log_success {
    ($($arg:tt)*) => { tracing::info!(target: "ok", $($arg)*) };
}

/// Log a debug message (maps to `tracing::debug!`).
#[macro_export]
macro_rules! log_debug {
    ($($arg:tt)*) => { tracing::debug!($($arg)*) };
}
