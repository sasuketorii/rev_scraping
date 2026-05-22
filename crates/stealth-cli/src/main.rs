// SPDX-License-Identifier: MIT
//! rev-stealth binary forwarder.
//!
//! v1.3 Lane H Slice A: the real CLI lives in `stealth_cli::run()` so that
//! `cargo install rev-stealth` from crates.io builds against the same library
//! surface that the workspace binary uses. Keep this file ≤ a handful of lines.

#![forbid(unsafe_code)]

fn main() -> std::process::ExitCode {
    std::process::ExitCode::from(stealth_cli::run() as u8)
}
