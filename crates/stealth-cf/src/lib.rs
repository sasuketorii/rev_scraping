// SPDX-License-Identifier: MIT
// Source: design adapted from Scrapling (BSD-3-Clause), https://github.com/D4Vinci/Scrapling
// No verbatim code copy; only the detection/click/polling algorithm pattern is adapted.
//
// stealth-cf — Cloudflare Turnstile/Interstitial challenge **resilience evaluator**.
//
// This crate is defender-facing: it measures how a target site's Cloudflare
// challenge surface behaves against a synthetic interaction (testbed). It does
// not implement an offensive solver and never bundles upstream secrets.

pub mod detect;
pub mod evaluator;
pub mod page;
pub mod types;

pub use detect::detect_from_html;
pub use evaluator::CfEvaluator;
pub use page::{BoundingBox, PageOps};
pub use types::{ChallengeType, SolveOpts, SolveOutcome};
