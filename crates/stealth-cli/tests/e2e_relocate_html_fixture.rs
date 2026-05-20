// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 4 E2E)
//! E2E #2 (relocate with html-file fixture): exercise the full
//! `rev-stealth relocate --html-file <fixture> --stable-id <id>` path.
//!
//! No obscura binary, no network — pure ParseStore + Relocator.
//! Confirms exit code 0/JSON schema on first-time fingerprint registration
//! (NotFound on empty store maps to exit 9, which is also an acceptable
//! deterministic path the schema documents).
//!
//! Tagged `#[ignore]` per Phase 4 LGTM.

use std::io::Write;
use std::process::Command;

fn rev_stealth_bin() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_rev-stealth"))
}

#[test]
#[ignore]
fn relocate_with_html_file_emits_well_formed_json() {
    let tmp = tempfile::tempdir().expect("tempdir");

    // Minimal HTML fixture containing the element our stable_id points at.
    let html = r#"<!doctype html>
<html><head><title>fixture</title></head>
<body>
  <div id="root">
    <span class="price" data-test="price">$42.00</span>
    <h1 class="title">rev_scraping fixture</h1>
  </div>
</body></html>"#;
    let html_path = tmp.path().join("page.html");
    let mut f = std::fs::File::create(&html_path).unwrap();
    f.write_all(html.as_bytes()).unwrap();

    // Use a tmp parse store so we don't touch ~/.rev_scraping.
    let store = tmp.path().join("parse.sqlite");

    let out = Command::new(rev_stealth_bin())
        .args([
            "--format",
            "json",
            "relocate",
            "--stable-id",
            "page.title",
            "--html-file",
            html_path.to_str().unwrap(),
            "--parse-store",
            store.to_str().unwrap(),
            "--threshold",
            "0.85",
        ])
        .output()
        .expect("must spawn rev-stealth");

    // Acceptable: 0 (exact/fuzzy) or 9 (not_found because the store is fresh).
    // All other exits indicate a regression.
    let code = out.status.code().unwrap_or(-1);
    assert!(
        code == 0 || code == 9,
        "unexpected exit {code}\nstderr: {}\nstdout: {}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout),
    );

    // JSON output schema: must contain "operation":"relocate".
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("\"operation\":\"relocate\""),
        "missing operation field in stdout: {stdout}"
    );
}
