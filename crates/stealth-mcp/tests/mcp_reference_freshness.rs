// SPDX-License-Identifier: MIT
// Source: rev_scraping Lane E P8 (new test, original work)
//
//! Freshness gate for `docs/MCP_REFERENCE.md`.
//!
//! Regenerates the document via [`stealth_mcp::reference::render_reference`]
//! and compares against the committed file. Any drift fails the test, and
//! the failure message tells the developer the exact command to run:
//!
//!   cargo run -p stealth-mcp --bin gen_reference
//!
//! Lives in `stealth-mcp/tests/` so it runs as part of
//! `cargo test --workspace` and gates every PR locally and in CI without
//! requiring a dedicated workflow job. P11 may add a dedicated CI job that
//! invokes the generator's `--check` mode for a clearer failure surface,
//! but this regression test is the deterministic gate on its own.

use std::path::PathBuf;

use stealth_mcp::reference::render_reference;

/// Path of the committed reference document, resolved relative to this
/// crate's manifest directory so the test works regardless of how `cargo`
/// chose CWD.
fn committed_reference_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../docs/MCP_REFERENCE.md")
}

#[test]
fn mcp_reference_is_in_sync_with_sources() {
    let path = committed_reference_path();
    let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "could not read {}: {e}. Did you delete docs/MCP_REFERENCE.md? \
             Run `cargo run -p stealth-mcp --bin gen_reference` to regenerate.",
            path.display()
        )
    });

    let generated = render_reference();

    if committed != generated {
        // Find the first differing line to make the failure actionable
        // without spamming the test log with the whole file.
        let mut line_no = 0usize;
        let mut first_diff: Option<(String, String, usize)> = None;
        for (a, b) in committed.lines().zip(generated.lines()) {
            line_no += 1;
            if a != b {
                first_diff = Some((a.to_string(), b.to_string(), line_no));
                break;
            }
        }

        let detail = match first_diff {
            Some((a, b, n)) => {
                format!("first drift at line {n}:\n  committed:   {a}\n  regenerated: {b}\n")
            }
            None => {
                // No line-level diff but bytes differ — must be length.
                format!(
                    "committed length = {}, regenerated length = {}",
                    committed.len(),
                    generated.len()
                )
            }
        };

        panic!(
            "docs/MCP_REFERENCE.md is stale.\n\n{detail}\n\
             Regenerate with:\n  \
             cargo run -p stealth-mcp --bin gen_reference\n\n\
             Then commit the updated file."
        );
    }
}

#[test]
fn render_reference_is_deterministic() {
    // Belt-and-suspenders: rendering twice in the same test process must
    // produce byte-identical output. Catches non-deterministic ordering
    // (e.g. someone swapping BTreeMap for HashMap inside the renderer).
    let a = render_reference();
    let b = render_reference();
    assert_eq!(a, b, "render_reference must be byte-stable");
}
