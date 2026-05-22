// SPDX-License-Identifier: MIT
// Source: rev_scraping Lane C P3.3 (stealth-agent-contracts crate, original work)
//! Progress reporting and cooperative cancellation primitives.
//!
//! [`ProgressTracker`] pairs a [`ProgressToken`] with a thread-safe progress
//! snapshot and an atomic cancel flag, so long-running operations (spider
//! crawls, authentication flows, batch ops) can:
//!
//! 1. publish incremental progress that an MCP server can forward as a
//!    `notifications/progress` message (keyed by the embedded `progressToken`);
//! 2. cooperatively check `is_cancelled()` at safe checkpoints and abort cleanly
//!    when the agent issues a cancel request;
//! 3. let watchers `wait_for_update().await` for the next progress edge instead
//!    of busy-polling.
//!
//! The type is intentionally cheap to clone (all state lives behind `Arc`) so
//! producer/consumer halves can be moved into separate tasks without bespoke
//! channel plumbing.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use tokio::sync::Notify;

use crate::token::ProgressToken;

/// Immutable snapshot of a [`ProgressTracker`]'s mutable progress state.
///
/// Returned by [`ProgressTracker::snapshot`] as a by-value copy so callers
/// observe a consistent point-in-time view without holding the internal lock.
#[derive(Debug, Clone)]
pub struct ProgressState {
    /// Units of work completed so far (monotonic, non-decreasing per tracker).
    pub completed: u64,
    /// Optional total units of work. `None` means the total is unknown
    /// (e.g. open-ended crawl) and the receiver should render as indeterminate.
    pub total: Option<u64>,
    /// Optional human-readable status message attached to the last report.
    pub message: Option<String>,
    /// Wall-clock instant of the most recent `report` call.
    pub last_update: Instant,
}

/// Shared progress + cancel primitive for a single long-running operation.
///
/// Cloning a `ProgressTracker` yields another handle to the same underlying
/// state; this is the intended pattern for splitting between the worker task
/// (which calls [`report`](Self::report)) and a watcher / cancel issuer.
#[derive(Debug, Clone)]
pub struct ProgressTracker {
    token: ProgressToken,
    state: Arc<Mutex<ProgressState>>,
    cancel: Arc<AtomicBool>,
    notify: Arc<Notify>,
}

impl ProgressTracker {
    /// Construct a tracker bound to `token` with an optional `total` work unit
    /// count. Initial `completed = 0`, no message, `last_update = now`.
    pub fn new(token: ProgressToken, total: Option<u64>) -> Self {
        Self {
            token,
            state: Arc::new(Mutex::new(ProgressState {
                completed: 0,
                total,
                message: None,
                last_update: Instant::now(),
            })),
            cancel: Arc::new(AtomicBool::new(false)),
            notify: Arc::new(Notify::new()),
        }
    }

    /// Borrow the bound [`ProgressToken`]. Used by MCP servers to populate the
    /// `progressToken` field of outgoing `notifications/progress` messages.
    pub fn token(&self) -> &ProgressToken {
        &self.token
    }

    /// Publish a progress update. `completed` is the new running total of
    /// completed units (callers should pass cumulative counts, not deltas).
    /// `message` overwrites the previous message (pass `None` to clear).
    ///
    /// All current waiters from [`wait_for_update`](Self::wait_for_update) are
    /// woken via `Notify::notify_waiters` (broadcast semantics).
    pub fn report(&self, completed: u64, message: Option<String>) {
        {
            let mut guard = self
                .state
                .lock()
                .expect("ProgressTracker state mutex poisoned");
            guard.completed = completed;
            guard.message = message;
            guard.last_update = Instant::now();
        }
        // notify_waiters wakes every waiter currently parked; new callers
        // after this point will wait for the next report (no stored permit).
        self.notify.notify_waiters();
    }

    /// Take a consistent by-value snapshot of the current progress state.
    pub fn snapshot(&self) -> ProgressState {
        self.state
            .lock()
            .expect("ProgressTracker state mutex poisoned")
            .clone()
    }

    /// Cooperative cancel checkpoint. Long-running ops should call this at
    /// safe interruption points (between requests, between pages, etc.) and
    /// abort cleanly when it returns `true`. Uses `Acquire` ordering so the
    /// caller synchronizes-with the `Release` store in [`cancel`](Self::cancel).
    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::Acquire)
    }

    /// Request cancellation. Idempotent: repeated calls are a no-op after the
    /// first. Always wakes current waiters so a parked task observing the flag
    /// can exit promptly.
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Release);
        self.notify.notify_waiters();
    }

    /// Wait for the next [`report`](Self::report) or [`cancel`](Self::cancel)
    /// edge. Returns a `Future` so callers can compose with
    /// `tokio::time::timeout` for bounded polling.
    ///
    /// Note: only edges that occur *after* this future starts awaiting are
    /// observed (no stored permit). To observe an initial state, take a
    /// [`snapshot`](Self::snapshot) before awaiting.
    pub fn wait_for_update(&self) -> impl std::future::Future<Output = ()> + '_ {
        self.notify.notified()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;

    // Compile-time assertion: ProgressTracker is Send + Sync so it can cross
    // task / thread boundaries when cloned into worker + watcher halves.
    const _: fn() = || {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ProgressTracker>();
        assert_send_sync::<ProgressState>();
    };

    #[test]
    fn tracker_reports_completed() {
        let t = ProgressTracker::new(ProgressToken::new(), Some(100));
        assert_eq!(t.snapshot().completed, 0);
        t.report(42, Some("halfway-ish".into()));
        let s = t.snapshot();
        assert_eq!(s.completed, 42);
        assert_eq!(s.total, Some(100));
        assert_eq!(s.message.as_deref(), Some("halfway-ish"));
        t.report(100, None);
        let s2 = t.snapshot();
        assert_eq!(s2.completed, 100);
        assert!(s2.message.is_none(), "None message must clear prior value");
    }

    #[test]
    fn tracker_snapshot_is_consistent() {
        // snapshot returns an owned clone; mutating tracker after snapshot
        // must not retroactively change the captured snapshot.
        let t = ProgressTracker::new(ProgressToken::new(), None);
        t.report(7, Some("seven".into()));
        let snap = t.snapshot();
        t.report(99, Some("ninety-nine".into()));
        assert_eq!(snap.completed, 7);
        assert_eq!(snap.message.as_deref(), Some("seven"));
        assert_eq!(snap.total, None);
        // current state advanced independently
        assert_eq!(t.snapshot().completed, 99);
    }

    #[test]
    fn cancel_flag_propagates() {
        let t = ProgressTracker::new(ProgressToken::new(), Some(10));
        assert!(!t.is_cancelled());
        t.cancel();
        assert!(t.is_cancelled());
        // Idempotent: second cancel must not panic and flag stays true.
        t.cancel();
        t.cancel();
        assert!(t.is_cancelled());

        // Clone observes the same flag (shared Arc<AtomicBool>).
        let t2 = t.clone();
        assert!(t2.is_cancelled());
    }

    #[tokio::test]
    async fn wait_for_update_resolves_after_report() {
        let t = ProgressTracker::new(ProgressToken::new(), Some(3));
        let t_writer = t.clone();

        // Park a waiter, then spawn a task that reports after we've started
        // awaiting. Bound by timeout so a missed wakeup fails the test
        // instead of hanging CI.
        let waiter = tokio::spawn(async move {
            tokio::time::timeout(std::time::Duration::from_secs(2), t.wait_for_update())
                .await
                .expect("wait_for_update must resolve within 2s");
            t.snapshot().completed
        });

        // Give the waiter a chance to park before notifying.
        tokio::task::yield_now().await;
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        t_writer.report(1, Some("tick".into()));

        let observed = waiter.await.expect("waiter task panicked");
        assert_eq!(observed, 1);

        // cancel() must also wake waiters.
        let t3 = ProgressTracker::new(ProgressToken::new(), None);
        let t3_canceller = t3.clone();
        let cancel_waiter = tokio::spawn(async move {
            tokio::time::timeout(std::time::Duration::from_secs(2), t3.wait_for_update())
                .await
                .expect("cancel must wake waiters");
            t3.is_cancelled()
        });
        tokio::task::yield_now().await;
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        t3_canceller.cancel();
        assert!(cancel_waiter.await.expect("cancel waiter panicked"));
    }

    #[test]
    fn multiple_concurrent_reports_no_data_race() {
        // Stress: many threads hammering report() on shared tracker. Final
        // snapshot must be one of the reported values (no torn read), and
        // the mutex must not be poisoned. We don't assert monotonicity
        // because report() accepts arbitrary cumulative values; we only
        // assert that internal invariants survive concurrent access.
        let t = Arc::new(ProgressTracker::new(ProgressToken::new(), Some(1000)));
        let mut handles = Vec::new();
        for tid in 0..8u64 {
            let tt = Arc::clone(&t);
            handles.push(thread::spawn(move || {
                for i in 0..50u64 {
                    let v = tid * 100 + i;
                    tt.report(v, Some(format!("t{tid}-{i}")));
                    // also exercise snapshot under contention
                    let _ = tt.snapshot();
                }
            }));
        }
        for h in handles {
            h.join().expect("worker thread panicked");
        }
        // Mutex still usable after the storm -> no poison.
        let final_snap = t.snapshot();
        assert!(
            final_snap.completed <= 8 * 100,
            "completed within reported range"
        );
        assert!(final_snap.message.is_some());
        assert_eq!(final_snap.total, Some(1000));
    }
}
