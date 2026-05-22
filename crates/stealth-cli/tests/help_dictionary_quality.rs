// SPDX-License-Identifier: MIT
//
// Lane G.2 — CLI --help dictionary quality gate.
//
// Walks every sub-command in `.agent/v1.3/cli-surface.json` (Lane G.1 output)
// and asserts that each `rev-stealth <path> --help` contains three required
// sections — `EXAMPLES:`, `EXIT CODES:`, and `ENV:` — and that the listed
// exit codes match the surface JSON expectation for that command.
//
// This is a machine-graded acceptance check for the per-command --help
// "dictionary quality" upgrade. It does not test prose; it locks the
// structural contract so regressions (e.g. someone adding a new sub-command
// without updating `after_help`) fail CI deterministically.
//
// Skipping rules:
//   * Leaf commands whose surface entry has zero exit codes are skipped
//     entirely (none exist in the current surface, but the rule is
//     future-proof).
//   * Parent commands that are containers for further sub-commands
//     (e.g. `captcha`, `vpn`, `config`, `config profile`, `auth`, `hermes`,
//     `browser`) are required to ALSO carry the three sections; clap
//     surfaces the parent's `after_help` on the parent --help page, and
//     downstream operators read it as the discovery entry-point.

use serde::Deserialize;
use std::collections::HashSet;
use std::path::PathBuf;
use std::process::Command;

fn surface_json_path() -> PathBuf {
    // CARGO_MANIFEST_DIR = crates/stealth-cli; the surface JSON sits at
    // <workspace_root>/.agent/v1.3/cli-surface.json.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(".agent")
        .join("v1.3")
        .join("cli-surface.json")
}

fn bin_path() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

#[derive(Debug, Deserialize)]
struct Surface {
    root: Node,
}

#[derive(Debug, Deserialize)]
struct Node {
    path: Vec<String>,
    #[serde(default)]
    exit_codes: Vec<i32>,
    #[serde(default)]
    subcommands: Vec<Node>,
}

fn walk<'a>(node: &'a Node, acc: &mut Vec<&'a Node>) {
    // Skip the synthetic root (empty path) — `rev-stealth --help` is the
    // top-level binary help, which is checked separately by the existing
    // suite. We only enforce the dictionary contract on real sub-commands.
    if !node.path.is_empty() {
        acc.push(node);
    }
    for child in &node.subcommands {
        walk(child, acc);
    }
}

fn run_help(path: &[String]) -> String {
    let mut cmd = Command::new(bin_path());
    for seg in path {
        cmd.arg(seg);
    }
    cmd.arg("--help");
    // Force a stable environment so the output is deterministic regardless
    // of operator shell. `NO_COLOR=1` keeps clap from injecting ANSI codes,
    // which would otherwise survive into the assertions on terminals that
    // advertise color support.
    cmd.env("NO_COLOR", "1");
    cmd.env_remove("TERM");
    let out = cmd
        .output()
        .unwrap_or_else(|e| panic!("spawn `rev-stealth {} --help` failed: {e}", path.join(" ")));
    if !out.status.success() {
        panic!(
            "`rev-stealth {} --help` exited {:?}\nstdout:\n{}\nstderr:\n{}",
            path.join(" "),
            out.status.code(),
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr),
        );
    }
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// Parse the exit-code rows out of an `EXIT CODES:` block.
///
/// Each row is expected to start with `  <code>  <Variant>  <description>`
/// where `<code>` is a non-negative integer in `[0, 9]` (the workspace's
/// ExitCode contract). We collect the integer prefix only; the variant
/// label is enforced loosely (must be ASCII alphanumeric) but not pinned
/// to the rust enum names — the surface JSON is the source of truth.
fn parse_exit_codes_block(help: &str) -> HashSet<i32> {
    let mut codes = HashSet::new();
    let mut in_block = false;
    for line in help.lines() {
        if line.starts_with("EXIT CODES:") {
            in_block = true;
            continue;
        }
        if in_block {
            // Block ends at first blank line or new section header.
            let t = line.trim_end();
            if t.is_empty() {
                in_block = false;
                continue;
            }
            // Lines must be indented (clap renders after_help verbatim, so
            // our 2-space indent survives). A non-indented line marks the
            // start of a new section.
            if !line.starts_with(' ') {
                in_block = false;
                continue;
            }
            // Parse leading integer.
            let stripped = line.trim_start();
            let head: String = stripped
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect();
            if let Ok(n) = head.parse::<i32>() {
                codes.insert(n);
            }
        }
    }
    codes
}

#[test]
fn every_subcommand_has_examples_exit_codes_and_env_sections() {
    let raw = std::fs::read_to_string(surface_json_path()).unwrap_or_else(|e| {
        panic!(
            "could not read surface JSON at {}: {e}",
            surface_json_path().display()
        )
    });
    let surface: Surface = serde_json::from_str(&raw).expect("surface JSON shape");

    let mut nodes: Vec<&Node> = Vec::new();
    walk(&surface.root, &mut nodes);
    assert!(
        !nodes.is_empty(),
        "surface JSON walked to zero sub-commands — check schema"
    );

    let mut failures: Vec<String> = Vec::new();

    for node in &nodes {
        let path_display = node.path.join(" ");
        let help = run_help(&node.path);

        // 1. EXAMPLES section present + at least one `$ rev-stealth ...` line.
        if !help.contains("EXAMPLES:") {
            failures.push(format!("`{path_display}` missing EXAMPLES: section"));
        } else {
            // Find the EXAMPLES block and count `$ rev-stealth` lines.
            let example_lines = help
                .lines()
                .skip_while(|l| !l.starts_with("EXAMPLES:"))
                .skip(1)
                .take_while(|l| l.starts_with(' ') || l.trim().is_empty())
                .filter(|l| l.trim_start().starts_with("$ rev-stealth"))
                .count();
            if example_lines == 0 {
                failures.push(format!(
                    "`{path_display}` EXAMPLES: block has no `$ rev-stealth ...` lines"
                ));
            }
            if example_lines > 5 {
                failures.push(format!(
                    "`{path_display}` EXAMPLES: block has {example_lines} examples (spec cap = 5)"
                ));
            }
        }

        // 2. EXIT CODES section present, and its codes match the surface
        //    expectation when the surface entry actually pins a set.
        if !help.contains("EXIT CODES:") {
            failures.push(format!("`{path_display}` missing EXIT CODES: section"));
        } else if !node.exit_codes.is_empty() {
            let help_codes = parse_exit_codes_block(&help);
            let expected: HashSet<i32> = node.exit_codes.iter().copied().collect();
            let missing: Vec<_> = expected.difference(&help_codes).copied().collect();
            let extra: Vec<_> = help_codes.difference(&expected).copied().collect();
            if !missing.is_empty() || !extra.is_empty() {
                failures.push(format!(
                    "`{path_display}` EXIT CODES drift: missing={missing:?}, extra={extra:?}, \
expected={expected:?}, found={help_codes:?}"
                ));
            }
        }

        // 3. ENV: section present (allowed to literally say "(none …)" but
        //    the header itself must exist so adopters can grep for env coupling).
        if !help.contains("ENV:") {
            failures.push(format!("`{path_display}` missing ENV: section"));
        }
    }

    if !failures.is_empty() {
        let joined = failures.join("\n  - ");
        panic!(
            "help-dictionary-quality lint failed ({} violation(s)):\n  - {joined}",
            failures.len()
        );
    }
}

#[test]
fn surface_json_is_readable() {
    // Sanity smoke: the surface JSON must remain readable + parseable for
    // the lint above to be meaningful. A separate test so a JSON shape
    // breakage surfaces as its own failure rather than masking the lint.
    let raw = std::fs::read_to_string(surface_json_path())
        .expect("cli-surface.json readable (regenerate via scripts/cli_surface_inventory.py)");
    let _surface: Surface = serde_json::from_str(&raw).expect("cli-surface.json parseable");
}
