// SPDX-License-Identifier: MIT
// Source: design adapted from Scrapling adaptive selector (BSD-3-Clause), https://github.com/D4Vinci/Scrapling

//! `stealth-parse` — Adaptive element relocation + SQLite WAL cache.
//!
//! Provides element fingerprint persistence and similarity-based relocation
//! for resilient long-running scraping agents.

pub mod fingerprint;
pub mod relocate;
pub mod store;

pub use fingerprint::{fingerprint_from_html, similarity, ElementFingerprint, NodeRef};
pub use relocate::{LocateOutcome, Relocator};
pub use store::ParseStore;

#[cfg(test)]
mod tests;
