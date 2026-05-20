// SPDX-License-Identifier: MIT
// Source: design adapted from Scrapling (BSD-3-Clause), https://github.com/D4Vinci/Scrapling
// No verbatim code copy; only the detection/click/polling algorithm pattern is adapted.

/// Detected Cloudflare challenge type on a page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChallengeType {
    /// Embedded Turnstile widget (script tag from challenges.cloudflare.com/turnstile/v...).
    Turnstile,
    /// Full-page interstitial ("Just a moment..." style).
    Interstitial,
    /// Legacy JS challenge (e.g. `cf-mitigated` / `cf-chl-bypass` markers).
    JsChallenge,
    /// No Cloudflare challenge detected.
    None,
}

/// Configuration knobs for [`crate::CfEvaluator::evaluate_turnstile_resilience`].
#[derive(Debug, Clone)]
pub struct SolveOpts {
    /// Inclusive lower / exclusive upper bound for click-down delay (ms).
    pub jitter_ms: (u32, u32),
    /// Maximum number of evaluation attempts before giving up.
    pub max_attempts: u32,
    /// Polling interval (ms) used inside `wait_cleared`.
    pub poll_interval_ms: u64,
    /// Per-attempt time budget (seconds) to wait for the challenge to clear.
    pub clear_timeout_secs: u64,
}

impl Default for SolveOpts {
    fn default() -> Self {
        Self {
            jitter_ms: (100, 200),
            max_attempts: 3,
            poll_interval_ms: 500,
            clear_timeout_secs: 10,
        }
    }
}

/// Outcome of an evaluator run.
#[derive(Debug, PartialEq, Eq)]
pub enum SolveOutcome {
    /// Challenge cleared after the interaction.
    Cleared,
    /// Page still showed the interstitial after `max_attempts`.
    StillBlocked,
    /// No clear signal within the per-attempt timeout (terminal).
    Timeout,
    /// Page had no Turnstile challenge — nothing to evaluate.
    NonTurnstile,
}
