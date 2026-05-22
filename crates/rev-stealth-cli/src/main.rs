// SPDX-License-Identifier: MIT
//
// `rev-stealth-cli` placeholder binary.
//
// Lane H (v1.3) plumbing-only: this stub exists so the crate's manifest
// can be validated end-to-end via `cargo publish --dry-run -p rev-stealth-cli`.
// At v1.3.0 release cut, this `main` becomes a one-line forwarder to the
// real CLI entrypoint exposed by the internal `stealth-cli` workspace crate
// (planned: `pub async fn run() -> ExitCode` on a new `lib.rs`).
//
// Why placeholder, not a real wiring today:
//   `stealth-cli` is `publish = false` (workspace-internal, 13 reverse deps).
//   Depending on it via path makes `cargo publish` reject the wrapper.
//   The lib-target + re-export refactor is a release-time concern, not
//   plumbing-time.

#![forbid(unsafe_code)]

fn main() -> std::process::ExitCode {
    eprintln!(
        "rev-stealth-cli {} placeholder binary.\n\
         This is the Lane H plumbing stub. The real CLI entrypoint is wired \
         at the v1.3.0 release cut.\n\
         For now, build the workspace binary directly:\n  \
         cargo install --git https://github.com/sasuketorii/rev_scraping \
         --bin rev-stealth stealth-cli",
        env!("CARGO_PKG_VERSION")
    );
    std::process::ExitCode::from(3) // permanent: not yet wired
}
