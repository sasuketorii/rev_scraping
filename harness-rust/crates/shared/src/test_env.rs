//! Crate-wide test-only serialization for process-global environment mutation.
//!
//! Several test modules in this crate (notably `paths` and `semantic_gc`)
//! mutate process-global environment variables such as
//! `REVHARNESS_TEST_HARNESS`, `SEMANTIC_MCP_HOME`, and
//! `REV_HARNESS_RUST_DB_HOME`. Because `std::env::set_var` / `remove_var`
//! affect the *entire process*, two such tests running concurrently (Rust runs
//! tests on multiple threads by default) can observe each other's environment.
//!
//! Previously each module owned a *different* lock (or no lock at all), so the
//! `paths` test could strip `SEMANTIC_MCP_HOME` out from under a `semantic_gc`
//! test that was mid-flight while holding only its own module-local mutex. The
//! `semantic_gc` test then resolved a real platform data path it could not
//! write, panicked under its held mutex, and POISONED it — cascading into many
//! unrelated failures.
//!
//! This module provides a SINGLE crate-wide lock that every env-mutating test
//! must hold for its full duration, plus an RAII guard that snapshots and
//! restores the relevant variables. The lock is poison-resilient: a panic in
//! one test recovers the guard rather than propagating `PoisonError` to every
//! sibling test.

use std::sync::{Mutex, MutexGuard, OnceLock};

/// The single crate-wide environment-mutation lock.
fn env_lock() -> &'static Mutex<()> {
    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    ENV_LOCK.get_or_init(|| Mutex::new(()))
}

/// Environment variables whose state is snapshotted and restored by
/// [`EnvGuard`]. Any test that mutates one of these must go through the guard.
const MANAGED_VARS: &[&str] = &[
    "REVHARNESS_TEST_HARNESS",
    "SEMANTIC_MCP_HOME",
    "REV_HARNESS_RUST_DB_HOME",
];

/// RAII guard that serializes env-mutating tests and restores prior state.
///
/// Acquiring the guard:
/// 1. Takes the crate-wide lock (poison-resilient — recovers the guard if a
///    previous holder panicked).
/// 2. Snapshots the current value of every [`MANAGED_VARS`] entry.
///
/// On drop it restores each variable to its snapshotted value, so leakage from
/// one test can never poison a sibling.
pub(crate) struct EnvGuard {
    _lock: MutexGuard<'static, ()>,
    snapshot: Vec<(&'static str, Option<String>)>,
}

impl EnvGuard {
    /// Acquire the crate-wide env lock and snapshot managed variables.
    pub(crate) fn acquire() -> Self {
        // Recover from a poisoned lock: a prior test panicking while holding
        // the lock must not fail every subsequent env-mutating test.
        let lock = env_lock().lock().unwrap_or_else(|e| e.into_inner());
        let snapshot = MANAGED_VARS
            .iter()
            .map(|&key| (key, std::env::var(key).ok()))
            .collect();
        Self {
            _lock: lock,
            snapshot,
        }
    }

    /// Convenience: enter explicit test-harness mode pointing at `home`.
    ///
    /// Sets `REVHARNESS_TEST_HARNESS=1` and `SEMANTIC_MCP_HOME=home`. Restored
    /// automatically on drop.
    pub(crate) fn set_test_harness_home(&self, home: &std::path::Path) {
        std::env::set_var("REVHARNESS_TEST_HARNESS", "1");
        std::env::set_var("SEMANTIC_MCP_HOME", home);
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        for (key, value) in &self.snapshot {
            match value {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
    }
}
