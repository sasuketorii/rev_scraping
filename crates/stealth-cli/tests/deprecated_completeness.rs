//! Lane I.6 — `#[deprecated(...)]` lint enforced as a workspace test.
//!
//! Every `#[deprecated(...)]` attribute on a `pub` item in `crates/*/src/`
//! must populate four pieces of metadata so callers can act on the warning:
//!
//! 1. `since = "<version>"` — when the deprecation landed (semver string).
//! 2. `note = "..."` — a non-empty explanation.
//! 3. Inside `note`, a replacement hint: either `replace_with = ` (the
//!    spelling we standardize on), or the words `Use` / `use ` / `replaced
//!    by` so AI-assisted migration tools can extract the suggested API.
//! 4. R2 addition: a `removal_target_version = "<semver>"` declaration so
//!    "silent indefinite deprecation" cannot ship. The token may live in
//!    one of two places:
//!      a. Inside the `note` value, as the substring
//!         `removal_target_version = "X.Y.Z"` (matches the `replace_with`
//!         precedent — `#[deprecated]` itself does not natively accept a
//!         `removal_target_version` key, so we encode it in `note`).
//!      b. As a single-line comment of the form
//!         `// removal_target_version = "X.Y.Z"` placed IMMEDIATELY above
//!         the `#[deprecated(...)]` attribute. This escape hatch lets
//!         contributors keep the rendered `note` short while still
//!         declaring the removal target at the source site.
//!    The captured target MUST be a valid semver triple
//!    (`<major>.<minor>.<patch>`, optional `-prerelease`). Without this
//!    field a deprecation can drift indefinitely past its intended removal
//!    cliff (docs/compat.md guarantees 2-major-version visibility but does
//!    not by itself force a removal target into source).
//!
//! Rationale: a `#[deprecated]` attribute with no `since`/`note`/replacement
//! /removal_target is invisible to anyone reading clippy output — it just
//! says "this is deprecated, sorry." The v1.3 ExecPlan (Lane I.6) requires
//! the attribute to be actionable, and the most portable way to enforce
//! that across the workspace is a textual test rather than a custom clippy
//! lint (which would require a nightly toolchain on every contributor's
//! machine).
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

/// Loose semver triple matcher: `<digits>.<digits>.<digits>` with optional
/// `-prerelease` / `+build` suffix. Intentionally permissive enough to accept
/// `1.0.0`, `1.0.0-alpha.1`, `2.0.0+rc1` without depending on the `semver`
/// crate for a test.
fn looks_like_semver(s: &str) -> bool {
    let s = s.trim();
    let main = s.split(['-', '+']).next().unwrap_or(s);
    let parts: Vec<&str> = main.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}

/// Extract the value of a `<key> = "value"` pair anywhere inside a `note`
/// string. Used to recover the R2 `removal_target_version` field, which is
/// not a native `#[deprecated]` key. Returns `None` when the key is absent
/// or its quoted value cannot be recovered.
fn note_field_value(note: &str, key: &str) -> Option<String> {
    let bytes = note.as_bytes();
    let key_bytes = key.as_bytes();
    let mut i = 0usize;
    while i + key_bytes.len() <= bytes.len() {
        if &bytes[i..i + key_bytes.len()] == key_bytes {
            let prev_ok = i == 0
                || !(bytes[i - 1].is_ascii_alphanumeric() || bytes[i - 1] == b'_');
            let next_ok = bytes
                .get(i + key_bytes.len())
                .is_none_or(|c| !(c.is_ascii_alphanumeric() || *c == b'_'));
            if prev_ok && next_ok {
                let mut j = i + key_bytes.len();
                while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                    j += 1;
                }
                if j >= bytes.len() || bytes[j] != b'=' {
                    i += 1;
                    continue;
                }
                j += 1;
                while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                    j += 1;
                }
                // The note value reaches us as the raw text between the
                // OUTER `note = "..."` quotes; any inner `"` characters
                // arrive escaped as `\"`. Accept either a bare `"` or
                // a `\"` here so both `removal_target_version = "X.Y.Z"`
                // and the source-form `removal_target_version = \"X.Y.Z\"`
                // are recognized.
                if j < bytes.len() && bytes[j] == b'\\' && j + 1 < bytes.len() && bytes[j + 1] == b'"' {
                    j += 1;
                }
                if j >= bytes.len() || bytes[j] != b'"' {
                    i += 1;
                    continue;
                }
                j += 1;
                let val_start = j;
                while j < bytes.len() {
                    if bytes[j] == b'\\' && j + 1 < bytes.len() {
                        // Closing `\"` ends the value.
                        if bytes[j + 1] == b'"' {
                            break;
                        }
                        j += 2;
                        continue;
                    }
                    if bytes[j] == b'"' {
                        break;
                    }
                    j += 1;
                }
                return Some(String::from_utf8_lossy(&bytes[val_start..j]).into_owned());
            }
        }
        i += 1;
    }
    None
}

/// Extract a `removal_target_version` declaration. Two source sites are
/// recognized:
///   1. Inside the `note` value, as the substring
///      `removal_target_version = "X.Y.Z"` (the canonical spelling).
///   2. As a `// removal_target_version = "X.Y.Z"` line comment placed
///      IMMEDIATELY above the `#[deprecated(...)]` attribute (skipping past
///      an optional `// I6-LINT: skip` marker).
/// Returns the captured semver string when found and parseable, else None.
fn extract_removal_target_version(
    note: Option<&str>,
    lines: &[&str],
    attr_index: usize,
) -> Option<String> {
    if let Some(n) = note {
        if let Some(captured) = note_field_value(n, "removal_target_version") {
            if looks_like_semver(&captured) {
                return Some(captured);
            }
        }
    }
    if attr_index == 0 {
        return None;
    }
    let mut idx = attr_index;
    while idx > 0 {
        idx -= 1;
        let trimmed = lines[idx].trim();
        if trimmed == "// I6-LINT: skip" {
            continue;
        }
        if trimmed.starts_with("// removal_target_version") {
            if let Some(eq) = trimmed.find('=') {
                let rhs = trimmed[eq + 1..].trim();
                let captured = rhs.trim_matches('"').trim_matches('\'').to_string();
                if looks_like_semver(&captured) {
                    return Some(captured);
                }
            }
        }
        break;
    }
    None
}

/// Tokens that count as a replacement hint inside `note = "..."`.
const HINTS: &[&str] = &[
    "replace_with",
    "Use ",
    "use ",
    "replaced by",
    "Prefer ",
    "prefer ",
];

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
        while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
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
                reason: format!("#[deprecated] missing or empty `since = \"…\"` — block: {block}"),
            });
        }
        match note.as_deref() {
            None | Some("") => findings.push(Finding {
                path: path.to_path_buf(),
                line: start_line,
                reason: format!("#[deprecated] missing or empty `note = \"…\"` — block: {block}"),
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

        // R2: removal_target_version requirement. Accept either an inline
        // `removal_target_version = "X.Y.Z"` substring in the `note` value,
        // or a `// removal_target_version = "X.Y.Z"` comment immediately
        // above the attribute. The attribute's 0-based source index is
        // `start_line - 1` (start_line was captured before `i` advanced).
        let attr_index = start_line - 1;
        if extract_removal_target_version(note.as_deref(), &lines, attr_index).is_none() {
            findings.push(Finding {
                path: path.to_path_buf(),
                line: start_line,
                reason: format!(
                    "#[deprecated] missing `removal_target_version = \"X.Y.Z\"` (either inside `note` or as a `// removal_target_version = \"X.Y.Z\"` line comment immediately above). Silent indefinite deprecation is forbidden per docs/compat.md. block: {block}"
                ),
            });
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
                f.path.strip_prefix(&root).unwrap_or(&f.path).display(),
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

    // Case 4: well-formed attribute (note-encoded removal_target) should
    // produce zero findings under the R2 contract.
    let p4 = dir.path().join("ok.rs");
    fs::write(
        &p4,
        "#[deprecated(since = \"1.3.0\", note = \"Use rev_scraping::new_api instead; removal_target_version = \\\"2.0.0\\\"\")]\n\
         pub fn legacy4() {}\n",
    )
    .unwrap();
    let f4 = audit_file(&p4);
    assert!(
        f4.is_empty(),
        "well-formed attr should not fire, got {f4:?}"
    );

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

    // Case 6 (R2): missing removal_target_version is now a violation, even
    // when since + note + replacement hint are all present.
    let p6 = dir.path().join("no_removal_target.rs");
    fs::write(
        &p6,
        "#[deprecated(since = \"1.3.0\", note = \"Use rev_scraping::new_api instead\")]\n\
         pub fn legacy6() {}\n",
    )
    .unwrap();
    let f6 = audit_file(&p6);
    assert!(
        f6.iter().any(|f| f.reason.contains("removal_target_version")),
        "expected removal_target_version violation, got {f6:?}"
    );

    // Case 7 (R2): removal_target_version supplied via comment immediately
    // above the attribute is accepted.
    let p7 = dir.path().join("removal_target_via_comment.rs");
    fs::write(
        &p7,
        "// removal_target_version = \"2.0.0\"\n\
         #[deprecated(since = \"1.3.0\", note = \"Use new_api instead\")]\n\
         pub fn legacy7() {}\n",
    )
    .unwrap();
    let f7 = audit_file(&p7);
    assert!(
        f7.is_empty(),
        "comment-style removal_target should satisfy the lint, got {f7:?}"
    );

    // Case 8 (R2): non-semver removal_target_version is rejected (treated
    // as missing — the value must be a parseable triple).
    let p8 = dir.path().join("bad_semver.rs");
    fs::write(
        &p8,
        "#[deprecated(since = \"1.3.0\", note = \"Use new_api instead; removal_target_version = \\\"someday\\\"\")]\n\
         pub fn legacy8() {}\n",
    )
    .unwrap();
    let f8 = audit_file(&p8);
    assert!(
        f8.iter().any(|f| f.reason.contains("removal_target_version")),
        "non-semver removal_target value must be rejected, got {f8:?}"
    );
}
