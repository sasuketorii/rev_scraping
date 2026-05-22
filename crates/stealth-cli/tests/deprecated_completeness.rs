//! Lane I.6 — `#[deprecated(...)]` lint enforced as a workspace test.
//!
//! Every `#[deprecated(...)]` attribute on a `pub` item in `crates/*/src/`
//! must populate three pieces of metadata so callers can act on the warning:
//!
//! 1. `since = "<version>"` — when the deprecation landed (semver string).
//! 2. `note = "..."` — a non-empty explanation.
//! 3. Inside `note`, a replacement hint: either `replace_with = ` (the
//!    spelling we standardize on), or the words `Use` / `use ` / `replaced
//!    by` so AI-assisted migration tools can extract the suggested API.
//!
//! Rationale: a `#[deprecated]` attribute with no `since`/`note`/replacement
//! is invisible to anyone reading clippy output — it just says "this is
//! deprecated, sorry." The v1.3 ExecPlan (Lane I.6) requires the attribute
//! to be actionable, and the most portable way to enforce that across the
//! workspace is a textual test rather than a custom clippy lint (which would
//! require a nightly toolchain on every contributor's machine).
//!
//! This test runs from `cargo test -p stealth-cli` and walks every other
//! workspace crate's `src/` tree. The walk skips `target/`, `vendor/`,
//! `_refs/`, and any file under a `tests/` directory (test code is allowed
//! to use bare `#[deprecated]` for its own assertions).
//!
//! False-positive escape hatch: a deprecated attribute that lives inside a
//! `// I6-LINT: skip` annotated block (single line containing exactly that
//! marker immediately preceding the attribute) is exempted. Use sparingly
//! and only for vendored / generated code.

use std::fs;
use std::path::{Path, PathBuf};

fn workspace_root() -> PathBuf {
    // CARGO_MANIFEST_DIR = crates/stealth-cli. Go up two levels.
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .and_then(|p| p.parent())
        .expect("workspace root resolvable from CARGO_MANIFEST_DIR")
        .to_path_buf()
}

fn list_rust_sources(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let skip_dir_names = ["target", "vendor", "_refs", "node_modules", ".git", "tests"];
    let mut stack = vec![root.join("crates")];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for ent in entries.flatten() {
            let path = ent.path();
            if path.is_dir() {
                let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
                if skip_dir_names.iter().any(|s| *s == name) {
                    continue;
                }
                stack.push(path);
            } else if path.extension().and_then(|s| s.to_str()) == Some("rs") {
                out.push(path);
            }
        }
    }
    out
}

/// Tokens that count as a replacement hint inside `note = "..."`.
const HINTS: &[&str] = &["replace_with", "Use ", "use ", "replaced by", "Prefer ", "prefer "];

#[derive(Debug)]
struct Finding {
    path: PathBuf,
    line: usize,
    reason: String,
}

/// Extract `key = "..."` pair values from a `#[deprecated(...)]` attribute
/// block. Returns `(since, note)` where each is `Some(value)` only if the
/// key appears as a top-level attribute argument with a non-empty string
/// literal value. The parser tracks string-literal boundaries so it ignores
/// any occurrence of `since` or `note` that appears inside another value.
fn parse_deprecated_attrs(block: &str) -> (Option<String>, Option<String>) {
    // Strip outer `#[deprecated(` ... `)]` so we only scan the argument list.
    let Some(start) = block.find("#[deprecated(") else {
        return (None, None);
    };
    let after = &block[start + "#[deprecated(".len()..];
    // Find the matching close paren at depth 1.
    let mut depth: i32 = 1;
    let mut in_string = false;
    let mut escape = false;
    let mut end = after.len();
    for (idx, c) in after.char_indices() {
        if escape {
            escape = false;
            continue;
        }
        if in_string {
            match c {
                '\\' => escape = true,
                '"' => in_string = false,
                _ => {}
            }
            continue;
        }
        match c {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    end = idx;
                    break;
                }
            }
            _ => {}
        }
    }
    let args = &after[..end];

    // Walk top-level `key = "value"` pairs (depth-0 inside `args`).
    let mut since: Option<String> = None;
    let mut note: Option<String> = None;
    let bytes = args.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        // Skip whitespace + commas.
        while i < bytes.len() && (bytes[i].is_ascii_whitespace() || bytes[i] == b',') {
            i += 1;
        }
        if i >= bytes.len() {
            break;
        }
        // Read identifier.
        let key_start = i;
        while i < bytes.len()
            && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_')
        {
            i += 1;
        }
        if key_start == i {
            i += 1;
            continue;
        }
        let key = std::str::from_utf8(&bytes[key_start..i]).unwrap_or("");
        // Skip whitespace then expect `=`.
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= bytes.len() || bytes[i] != b'=' {
            continue;
        }
        i += 1;
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if i >= bytes.len() || bytes[i] != b'"' {
            continue;
        }
        // Read string literal.
        i += 1;
        let val_start = i;
        let mut esc = false;
        while i < bytes.len() {
            let c = bytes[i];
            if esc {
                esc = false;
            } else if c == b'\\' {
                esc = true;
            } else if c == b'"' {
                break;
            }
            i += 1;
        }
        let value = std::str::from_utf8(&bytes[val_start..i]).unwrap_or("");
        i += 1; // past closing "
        match key {
            "since" if since.is_none() => since = Some(value.to_string()),
            "note" if note.is_none() => note = Some(value.to_string()),
            _ => {}
        }
    }
    (since, note)
}

fn audit_file(path: &Path) -> Vec<Finding> {
    let mut findings = Vec::new();
    let Ok(text) = fs::read_to_string(path) else {
        return findings;
    };
    let lines: Vec<&str> = text.lines().collect();

    // Coalesce multi-line `#[deprecated( ... )]` into a single logical block.
    let mut i = 0usize;
    while i < lines.len() {
        let line = lines[i];
        if !line.contains("#[deprecated") {
            i += 1;
            continue;
        }
        // Escape hatch.
        if i > 0 && lines[i - 1].trim() == "// I6-LINT: skip" {
            i += 1;
            continue;
        }

        // Accumulate balanced parens.
        let mut block = String::new();
        let mut depth: i32 = 0;
        let start_line = i + 1; // 1-based for human display
        let mut j = i;
        let mut saw_open = false;
        while j < lines.len() {
            block.push_str(lines[j]);
            for c in lines[j].chars() {
                match c {
                    '(' => {
                        depth += 1;
                        saw_open = true;
                    }
                    ')' => depth -= 1,
                    _ => {}
                }
            }
            j += 1;
            if saw_open && depth <= 0 {
                break;
            }
            // No-paren form is single-line; bail after the first line.
            if !saw_open {
                break;
            }
            block.push('\n');
        }
        i = j;

        // Bare `#[deprecated]` with no parens is a violation.
        let has_args = block.contains("#[deprecated(");
        if !has_args {
            findings.push(Finding {
                path: path.to_path_buf(),
                line: start_line,
                reason: "#[deprecated] without arguments — must declare since + note".into(),
            });
            continue;
        }

        // Parse the actual `key = "value"` pairs (not just substring presence).
        let (since, note) = parse_deprecated_attrs(&block);

        if since.as_deref().unwrap_or("").is_empty() {
            findings.push(Finding {
                path: path.to_path_buf(),
                line: start_line,
                reason: format!(
                    "#[deprecated] missing or empty `since = \"…\"` — block: {block}"
                ),
            });
        }
        match note.as_deref() {
            None | Some("") => findings.push(Finding {
                path: path.to_path_buf(),
                line: start_line,
                reason: format!(
                    "#[deprecated] missing or empty `note = \"…\"` — block: {block}"
                ),
            }),
            Some(note_value) => {
                let has_hint = HINTS.iter().any(|h| note_value.contains(h));
                if !has_hint {
                    findings.push(Finding {
                        path: path.to_path_buf(),
                        line: start_line,
                        reason: format!(
                            "#[deprecated] note lacks a replacement hint (expected one of {HINTS:?}) — note=\"{note_value}\""
                        ),
                    });
                }
            }
        }
    }

    findings
}

#[test]
fn every_deprecated_attribute_is_actionable() {
    let root = workspace_root();
    let sources = list_rust_sources(&root);
    assert!(
        !sources.is_empty(),
        "no .rs sources found under {}/crates — workspace layout changed?",
        root.display()
    );

    let mut all_findings = Vec::new();
    for path in &sources {
        all_findings.extend(audit_file(path));
    }

    if !all_findings.is_empty() {
        let mut msg = String::from(
            "\nLane I.6 deprecated-attr lint failed. Every #[deprecated(...)] must declare\n\
             `since`, `note`, and a replacement hint inside the note (one of: \
             replace_with, \"Use \", \"use \", \"replaced by\", \"Prefer \"). \
             See docs/compat.md.\n\nFindings:\n",
        );
        for f in &all_findings {
            msg.push_str(&format!(
                "  - {}:{} — {}\n",
                f.path
                    .strip_prefix(&root)
                    .unwrap_or(&f.path)
                    .display(),
                f.line,
                f.reason.replace('\n', " ")
            ));
        }
        panic!("{msg}");
    }
}

/// Self-test: the lint must actually flag malformed samples and accept
/// a fully-populated attribute. Each case is independent.
#[test]
fn lint_smoke_detects_missing_metadata() {
    let dir = tempfile::tempdir().expect("tempdir");

    // Case 1: bare `#[deprecated]` — missing args.
    let p1 = dir.path().join("bare.rs");
    fs::write(&p1, "#[deprecated]\npub fn legacy() {}\n").unwrap();
    let f1 = audit_file(&p1);
    assert!(
        f1.iter().any(|f| f.reason.contains("without arguments")),
        "expected bare-form violation, got {f1:?}"
    );

    // Case 2: empty note + missing replacement hint.
    let p2 = dir.path().join("nohint.rs");
    fs::write(
        &p2,
        "#[deprecated(since = \"1.0\", note = \"gone\")]\npub fn legacy2() {}\n",
    )
    .unwrap();
    let f2 = audit_file(&p2);
    assert!(
        f2.iter().any(|f| f.reason.contains("replacement hint")),
        "expected missing-hint violation, got {f2:?}"
    );

    // Case 3: missing since (only note).
    let p3 = dir.path().join("nosince.rs");
    fs::write(
        &p3,
        "#[deprecated(note = \"Use new_fn instead\")]\npub fn legacy3() {}\n",
    )
    .unwrap();
    let f3 = audit_file(&p3);
    assert!(
        f3.iter().any(|f| f.reason.contains("`since")),
        "expected missing-since violation, got {f3:?}"
    );

    // Case 4: well-formed attribute should produce zero findings.
    let p4 = dir.path().join("ok.rs");
    fs::write(
        &p4,
        "#[deprecated(since = \"1.3.0\", note = \"Use rev_scraping::new_api instead\")]\n\
         pub fn legacy4() {}\n",
    )
    .unwrap();
    let f4 = audit_file(&p4);
    assert!(f4.is_empty(), "well-formed attr should not fire, got {f4:?}");

    // Case 5: regression — `since` appearing inside the note value must NOT
    // satisfy the since check. This protects against the substring-presence
    // bug the previous implementation had.
    let p5 = dir.path().join("substring_bug.rs");
    fs::write(
        &p5,
        "#[deprecated(note = \"deprecated since v1.0; replace_with new_fn\")]\n\
         pub fn legacy5() {}\n",
    )
    .unwrap();
    let f5 = audit_file(&p5);
    assert!(
        f5.iter().any(|f| f.reason.contains("`since")),
        "substring 'since' inside note must NOT count as the since= attr, got {f5:?}"
    );
}
