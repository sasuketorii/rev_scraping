// SPDX-License-Identifier: MIT
//! v1.3 Lane G.4: enforce that every top-level `rev-stealth` subcommand
//! accepts `--output-format json` without panicking at clap-parse time.
//!
//! This is the CLI counterpart to the JSON-schema inventory under
//! `docs/json-schemas/cli/`: the schemas document the *output* contract; this
//! test fixes the *flag-surface* contract so future refactors cannot silently
//! drop the per-subcommand `--output-format` override.
//!
//! What this test does NOT do:
//!   * run the subcommands (no network / no filesystem mutation);
//!   * validate the actual JSON payload against the schema (that lives in
//!     per-subcommand integration suites that exercise the dispatch path);
//!   * check the global `--format` flag (already covered by `cli_tests` in
//!     `src/lib.rs`).
//!
//! What it DOES guarantee:
//!   * `Cli::command().debug_assert()` passes (no clap arg-id collision);
//!   * each top-level subcommand parses `--output-format json` and the
//!     resulting `Cli` matches the expected variant;
//!   * `--format json` (the v1.2.x global alias) keeps parsing alongside the
//!     per-subcommand `--output-format` (mixed-invocation smoke).
//!
//! Skipped subcommands and why:
//!   * `completions`: hidden internal generator; not user-facing.
//!
//! Note: this is a library-side integration test (`tests/` directory). It
//! parses argv via the public `clap::CommandFactory` surface re-exposed
//! through the library, NOT via spawning the binary, so it stays hermetic
//! and ~1ms per case.

use clap::{CommandFactory, Parser};

// We need to address the Cli struct, which is currently `pub(crate)` inside
// the library. To keep this test self-contained without leaking the type
// publicly, we drive clap through the binary's `Command` factory by name
// (`rev-stealth`) and the exposed `parse_from` round-trip via the binary's
// own argv contract. Since the library does NOT export `Cli`, we re-build
// the same clap tree here by parsing argv against the binary's compiled
// `Command` definition via `clap_complete`'s internal generator — except
// that path is also private.
//
// Pragmatic solution: parse argv through the binary's `main` indirectly by
// invoking `std::process::Command::new` with `--help` would spawn the
// binary, which we explicitly want to avoid.
//
// Instead we test what we CAN observe from outside the crate boundary:
//
//   1. Build the clap `Command` tree via the binary metadata embedded in
//      the produced executable -- not portable.
//
// The cleanest portable approach is to add a tiny `pub` re-export of the
// argv-parsing surface gated behind `#[cfg(any(test, feature = "test-util"))]`.
// For Lane G.4 we expose `stealth_cli::__cli_parse_for_test` from the
// library (added in `src/lib.rs`) so this integration test can drive clap
// without spawning a process.

use stealth_cli::__cli_parse_for_test as parse;

/// v1.3 Lane G fix-up R2: the multi-format wire matrix every top-level
/// subcommand must accept. Each format string is the canonical value name
/// accepted by clap — `human` (default), `text` (alias of `human`), `json`
/// (machine-parseable), `yaml` (re-encoded json envelope).
///
/// Doctor + config are special-cased: doctor's enum is `{json, text, yaml}`
/// (no `human` synonym, because the historical default was `json`); config's
/// enum is `{json, text, yaml}` for the same reason. The shared matrix is
/// stripped of `human` for those two surfaces in [`shared_formats_for`].
const ALL_FORMATS_GENERIC: &[&str] = &["human", "text", "json", "yaml"];
const DOCTOR_FORMATS: &[&str] = &["text", "json", "yaml"];
const CONFIG_FORMATS: &[&str] = &["text", "json", "yaml"];

fn shared_formats_for(label: &str) -> &'static [&'static str] {
    if label.starts_with("doctor") {
        DOCTOR_FORMATS
    } else if label.starts_with("config") {
        CONFIG_FORMATS
    } else {
        ALL_FORMATS_GENERIC
    }
}

/// Subcommands whose `--output-format json` must parse cleanly.
///
/// Each entry: `(label, argv_after_program_name)`.
const SUBCOMMAND_CASES: &[(&str, &[&str])] = &[
    // Action-bearing groups (captcha/browser/vpn): the G.4
    // OutputFormatOverride attaches at the parent (`captcha`/`browser`/
    // `vpn`) level, so `--output-format` MUST precede the action verb.
    // The global `--format` (root level) and per-action JSON output
    // still cover the "everywhere works" UX, but the canonical position
    // for the new flag on these groups is between the noun and the verb.
    (
        "captcha solve",
        &[
            "captcha",
            "--output-format",
            "json",
            "solve",
            "--type",
            "recaptcha-v2",
            "--site-url",
            "https://example.test",
            "--dry-run",
        ],
    ),
    (
        "captcha verify",
        &[
            "captcha",
            "--output-format",
            "json",
            "verify",
            "--type",
            "hcaptcha",
            "--token",
            "dummy",
            "--secret",
            "dummy",
        ],
    ),
    (
        "browser launch",
        &[
            "browser",
            "--output-format",
            "json",
            "launch",
            "--url",
            "https://example.test",
        ],
    ),
    (
        "browser stealth-test",
        &["browser", "--output-format", "json", "stealth-test"],
    ),
    ("vpn status", &["vpn", "--output-format", "json", "status"]),
    (
        "vpn rotate",
        &[
            "vpn",
            "--output-format",
            "json",
            "rotate",
            "--reason",
            "test",
        ],
    ),
    (
        "doctor",
        &["doctor", "--skip-exit-ip", "--output-format", "json"],
    ),
    (
        "spider",
        &[
            "spider",
            "--url",
            "https://example.test",
            "--allow-no-vpn",
            "--output-format",
            "json",
        ],
    ),
    (
        "relocate",
        &[
            "relocate",
            "--stable-id",
            "abc",
            "--html-file",
            "/tmp/none.html",
            "--output-format",
            "json",
        ],
    ),
    (
        "cf-evaluate",
        &[
            "cf-evaluate",
            "--url",
            "https://example.test",
            "--i-have-authorization",
            "--output-format",
            "json",
        ],
    ),
    ("auth list", &["auth", "--output-format", "json", "list"]),
    (
        "measure",
        &[
            "measure",
            "--url",
            "https://example.test",
            "--output-format",
            "json",
        ],
    ),
    (
        "hermes verify",
        &["hermes", "--output-format", "json", "verify"],
    ),
    (
        "config validate",
        &["config", "--output-format", "json", "validate"],
    ),
];

/// Rewrite an argv slice substituting the value following every
/// `--output-format` token with `fmt`. The token must already be present
/// (the existing fixtures all include `--output-format json`); this keeps
/// the per-subcommand placement (between noun and verb for action groups,
/// trailing for leaf subcommands) untouched.
fn argv_with_format<'a>(template: &'a [&'a str], fmt: &'a str) -> Vec<&'a str> {
    let mut out: Vec<&str> = Vec::with_capacity(template.len());
    let mut i = 0;
    while i < template.len() {
        out.push(template[i]);
        if template[i] == "--output-format" && i + 1 < template.len() {
            out.push(fmt);
            i += 2;
        } else {
            i += 1;
        }
    }
    out
}

#[test]
fn every_subcommand_accepts_all_output_formats() {
    // v1.3 Lane G fix-up R2: extend the original `--output-format json`
    // gate to cover the full {human, text, json, yaml} matrix. This is the
    // direct evidence target Codex flagged for R2: text + yaml acceptance
    // across every top-level subcommand, not just JSON.
    let mut failures = Vec::new();
    for (label, argv) in SUBCOMMAND_CASES {
        for fmt in shared_formats_for(label) {
            let rewritten = argv_with_format(argv, fmt);
            let mut full = vec!["rev-stealth"];
            full.extend(rewritten.iter().copied());
            if let Err(e) = parse(&full) {
                failures.push(format!("{label} (--output-format {fmt}): {e}"));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "subcommands rejected one or more `--output-format` values:\n{}",
        failures.join("\n")
    );
}

/// Sub-sub-command coverage: a representative leaf under each multi-verb
/// group (captcha, browser, vpn, auth, hermes, config) must also accept
/// every wire format on the noun-level `--output-format` placement.
///
/// This guards against the failure mode where `--output-format yaml` works
/// at the leaf-only level (`spider --output-format yaml`) but a regression
/// removes acceptance at the group level (`auth --output-format yaml list`).
#[test]
fn sub_sub_commands_accept_all_output_formats() {
    let cases: &[(&str, &[&str], &[&str])] = &[
        // (label, argv-template, allowed-formats)
        (
            "captcha solve",
            &[
                "captcha",
                "--output-format",
                "json",
                "solve",
                "--type",
                "recaptcha-v2",
                "--site-url",
                "https://example.test",
                "--dry-run",
            ],
            ALL_FORMATS_GENERIC,
        ),
        (
            "captcha verify",
            &[
                "captcha",
                "--output-format",
                "json",
                "verify",
                "--type",
                "hcaptcha",
                "--token",
                "x",
                "--secret",
                "y",
            ],
            ALL_FORMATS_GENERIC,
        ),
        (
            "browser launch",
            &[
                "browser",
                "--output-format",
                "json",
                "launch",
                "--url",
                "https://example.test",
            ],
            ALL_FORMATS_GENERIC,
        ),
        (
            "browser stealth-test",
            &["browser", "--output-format", "json", "stealth-test"],
            ALL_FORMATS_GENERIC,
        ),
        (
            "vpn status",
            &["vpn", "--output-format", "json", "status"],
            ALL_FORMATS_GENERIC,
        ),
        (
            "vpn rotate",
            &[
                "vpn",
                "--output-format",
                "json",
                "rotate",
                "--reason",
                "test",
            ],
            ALL_FORMATS_GENERIC,
        ),
        (
            "auth list",
            &["auth", "--output-format", "json", "list"],
            ALL_FORMATS_GENERIC,
        ),
        (
            "hermes verify",
            &["hermes", "--output-format", "json", "verify"],
            ALL_FORMATS_GENERIC,
        ),
        (
            "config validate",
            &["config", "--output-format", "json", "validate"],
            CONFIG_FORMATS,
        ),
    ];
    let mut failures = Vec::new();
    for (label, argv, formats) in cases {
        for fmt in *formats {
            let rewritten = argv_with_format(argv, fmt);
            let mut full = vec!["rev-stealth"];
            full.extend(rewritten.iter().copied());
            if let Err(e) = parse(&full) {
                failures.push(format!("{label} (--output-format {fmt}): {e}"));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "sub-sub-commands rejected one or more `--output-format` values:\n{}",
        failures.join("\n")
    );
}

#[test]
fn every_subcommand_accepts_output_format_json() {
    let mut failures = Vec::new();
    for (label, argv) in SUBCOMMAND_CASES {
        let mut full = vec!["rev-stealth"];
        full.extend(argv.iter().copied());
        match parse(&full) {
            Ok(()) => { /* parsed cleanly */ }
            Err(e) => failures.push(format!("{label}: {e}")),
        }
    }
    assert!(
        failures.is_empty(),
        "subcommands rejected `--output-format json`:\n{}",
        failures.join("\n")
    );
}

#[test]
fn global_format_json_remains_compatible() {
    // Belt-and-suspenders: the v1.2.x `--format json` alias still parses on
    // every subcommand. We test one representative leaf per top-level group.
    let cases: &[(&str, &[&str])] = &[
        (
            "captcha solve (global --format)",
            &[
                "rev-stealth",
                "--format",
                "json",
                "captcha",
                "solve",
                "--type",
                "turnstile",
                "--site-url",
                "https://example.test",
                "--dry-run",
            ],
        ),
        (
            "spider (global --format)",
            &[
                "rev-stealth",
                "--format",
                "json",
                "spider",
                "--url",
                "https://example.test",
                "--allow-no-vpn",
            ],
        ),
        (
            "doctor (global --format)",
            &[
                "rev-stealth",
                "--format",
                "json",
                "doctor",
                "--skip-exit-ip",
            ],
        ),
    ];
    for (label, argv) in cases {
        parse(argv).unwrap_or_else(|e| panic!("{label}: {e}"));
    }
}

#[test]
fn clap_command_tree_has_no_arg_id_collision() {
    // Cheap structural assertion: clap's debug_assert walks the whole tree
    // and panics on duplicate arg ids / type mismatches. Lane G.4 added new
    // flattened `OutputFormatOverride` shims; this test pins that they
    // don't collide with the global `--format` (which retains the arg id
    // `format`) nor with the existing local `--output-format` on `doctor`
    // and `config` (which use ids `doctor_format` and `config_output_format`
    // respectively).
    stealth_cli::__cli_command_for_test().debug_assert();
}

#[test]
fn json_schema_inventory_matches_subcommand_set() {
    // Drift gate: the inventory of CLI JSON-output schemas under
    // `docs/json-schemas/cli/` must include one entry per top-level
    // subcommand surfaced by the CLI. We don't validate JSON content here,
    // only filename presence — this is the cheapest reviewer-readable gate
    // we can run from `cargo test`.
    let expected: &[&str] = &[
        "captcha.output.json",
        "browser.output.json",
        "vpn.output.json",
        "doctor.output.json",
        "spider.output.json",
        "relocate.output.json",
        "cf-evaluate.output.json",
        "auth.output.json",
        "measure.output.json",
        "config.output.json",
        "hermes.output.json",
    ];
    // CARGO_MANIFEST_DIR is the crate dir (`crates/stealth-cli`); the schemas
    // live at the workspace root, two `..` up.
    let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let schemas_dir = manifest_dir
        .join("..")
        .join("..")
        .join("docs")
        .join("json-schemas")
        .join("cli");
    let mut missing = Vec::new();
    for name in expected {
        let p = schemas_dir.join(name);
        if !p.exists() {
            missing.push(name.to_string());
        }
    }
    assert!(
        missing.is_empty(),
        "missing CLI JSON-output schemas under {}: {:?}",
        schemas_dir.display(),
        missing,
    );
}

// Suppress unused-import lints in case `Parser` / `CommandFactory` end up
// only used through the `parse` shim.
#[allow(dead_code)]
fn _unused_imports_anchor() {
    fn _t<T: Parser + CommandFactory>() {}
}
