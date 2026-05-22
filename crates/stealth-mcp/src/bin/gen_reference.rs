// SPDX-License-Identifier: MIT
// Source: rev_scraping Lane E P8 (new binary, original work)
//
//! `gen_reference` — deterministic generator for `docs/MCP_REFERENCE.md`.
//!
//! Thin CLI shell around [`stealth_mcp::reference::render_reference`]. Two
//! modes are supported:
//!
//!   * Default (no flags): regenerate the file in place. Used as part of the
//!     normal "add a tool, regenerate the doc" developer loop.
//!   * `--check`: regenerate into memory and compare against the committed
//!     file. Exits 0 on parity, 1 on drift. The same byte-level comparison
//!     is asserted by the `mcp_reference_freshness` regression test that
//!     runs under `cargo test --workspace`, so drift is caught both by
//!     this binary and by the workspace test suite.
//!
//! Usage:
//!   cargo run -p stealth-mcp --bin gen_reference
//!   cargo run -p stealth-mcp --bin gen_reference -- --check
//!   cargo run -p stealth-mcp --bin gen_reference -- --output /tmp/out.md

#![forbid(unsafe_code)]

use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;

use stealth_mcp::reference::render_reference;

/// Workspace-relative default output path. Resolved against
/// `CARGO_MANIFEST_DIR` so the binary works from any CWD.
const DEFAULT_OUTPUT_REL: &str = "../../docs/MCP_REFERENCE.md";

fn main() -> ExitCode {
    let mut check_only = false;
    let mut output_override: Option<PathBuf> = None;

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--check" => check_only = true,
            "--output" => {
                let v = match args.next() {
                    Some(v) => v,
                    None => {
                        eprintln!("--output requires a path argument");
                        return ExitCode::from(2);
                    }
                };
                output_override = Some(PathBuf::from(v));
            }
            "-h" | "--help" => {
                println!(
                    "gen_reference — regenerate docs/MCP_REFERENCE.md\n\n\
                     Usage:\n  \
                     gen_reference [--check] [--output PATH]\n\n\
                     Flags:\n  \
                     --check        Compare without writing; exit 1 on drift.\n  \
                     --output PATH  Override default destination.\n"
                );
                return ExitCode::SUCCESS;
            }
            other => {
                eprintln!("unknown argument: {other}");
                return ExitCode::from(2);
            }
        }
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let target_path = output_override.unwrap_or_else(|| manifest_dir.join(DEFAULT_OUTPUT_REL));

    let generated = render_reference();

    if check_only {
        let current = match fs::read_to_string(&target_path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!(
                    "gen_reference --check: cannot read {}: {e}",
                    target_path.display()
                );
                return ExitCode::from(1);
            }
        };
        if current == generated {
            return ExitCode::SUCCESS;
        }
        eprintln!(
            "gen_reference --check: {} is stale. Re-run `cargo run -p stealth-mcp --bin gen_reference` and commit the result.",
            target_path.display()
        );
        let mut line_no = 0usize;
        for (a, b) in current.lines().zip(generated.lines()) {
            line_no += 1;
            if a != b {
                eprintln!("first drift at line {line_no}:");
                eprintln!("  committed:   {a}");
                eprintln!("  regenerated: {b}");
                break;
            }
        }
        return ExitCode::from(1);
    }

    if let Some(parent) = target_path.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            eprintln!("cannot create {}: {e}", parent.display());
            return ExitCode::from(1);
        }
    }
    if let Err(e) = fs::write(&target_path, &generated) {
        eprintln!("cannot write {}: {e}", target_path.display());
        return ExitCode::from(1);
    }
    println!("wrote {}", target_path.display());
    ExitCode::SUCCESS
}
