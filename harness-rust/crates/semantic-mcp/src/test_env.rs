//! Crate-internal test-only serialization for process-global env mutation.
//!
//! Mirrors `shared::test_env`. Two distinct test modules in this crate mutate
//! process-global state that all feeds the same path resolver
//! (`shared::paths::semantic_mcp_data_root`):
//!
//! * `admin_gc` tests set `REVHARNESS_TEST_HARNESS` / `SEMANTIC_MCP_HOME`
//!   (the explicit test-harness override branch), and
//! * `main_loop` tests set `HOME` / `USERPROFILE` (the platform-data-root
//!   branch).
//!
//! Previously each module owned a *separate* lock, so they could run
//! concurrently in the same test binary. Because `SEMANTIC_MCP_HOME` is honored
//! under `#[cfg(test)]`, an `admin_gc` test's override could redirect a
//! concurrent `main_loop` test's resolution (and vice-versa), risking a
//! write/delete against an unexpected path. A SINGLE crate-wide lock plus
//! save/restore eliminates that race; the lock is poison-resilient so a panic
//! in one test never fails every sibling.

use std::sync::{Mutex, MutexGuard, OnceLock};

fn env_lock() -> &'static Mutex<()> {
    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    ENV_LOCK.get_or_init(|| Mutex::new(()))
}

/// Acquire the single crate-wide env lock, poison-resilient, WITHOUT taking an
/// env snapshot. For call sites that already manage their own save/restore but
/// must still serialize against every other env-mutating test in this crate.
pub(crate) fn lock_only() -> MutexGuard<'static, ()> {
    env_lock().lock().unwrap_or_else(|e| e.into_inner())
}

/// Variables snapshotted and restored by [`EnvGuard`] — the union of every
/// process-global var any env-mutating test in this crate touches.
const MANAGED_VARS: &[&str] = &[
    "REVHARNESS_TEST_HARNESS",
    "SEMANTIC_MCP_HOME",
    "HOME",
    "USERPROFILE",
];

/// RAII guard: takes the single crate-wide env lock (recovering from poison)
/// and restores managed vars on drop.
pub(crate) struct EnvGuard {
    _lock: MutexGuard<'static, ()>,
    snapshot: Vec<(&'static str, Option<String>)>,
}

impl EnvGuard {
    pub(crate) fn acquire() -> Self {
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

    /// Enter explicit test-harness mode pointing at `home`.
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
