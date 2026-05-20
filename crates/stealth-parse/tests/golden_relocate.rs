// SPDX-License-Identifier: MIT
// Source: design adapted from Scrapling adaptive selector (BSD-3-Clause), https://github.com/D4Vinci/Scrapling

//! Golden HTML relocation tests.
//!
//! Records fingerprints from `static.html` (baseline), then attempts to relocate
//! the same logical elements in two mutated DOMs:
//!
//! - `class_renamed.html`: pure class-name churn  → expect ≥ 95% success
//! - `restructured.html`: extra wrapper divs       → expect ≥ 85% success
//!
//! On `static.html` itself: 100% success.

use scraper::{Html, Selector};
use std::path::PathBuf;
use stealth_parse::{LocateOutcome, ParseStore, Relocator};
use tempfile::TempDir;

const FLD: &str = "acme.example";

fn fixture(name: &str) -> String {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("tests");
    p.push("fixtures");
    p.push(name);
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("read {}: {e}", p.display()))
}

/// Returns every `data-stable-id` value and the matching css selector that picks it.
fn stable_ids(html: &str) -> Vec<(String, String)> {
    let doc = Html::parse_document(html);
    let sel = Selector::parse("[data-stable-id]").unwrap();
    doc.select(&sel)
        .map(|el| {
            let id = el.value().attr("data-stable-id").unwrap().to_string();
            // selector that uniquely picks this attribute occurrence
            let css = format!("[data-stable-id=\"{id}\"]");
            (id, css)
        })
        .collect()
}

fn record_baseline(store: &mut ParseStore, baseline_html: &str) -> Vec<String> {
    let ids = stable_ids(baseline_html);
    let mut rl = Relocator::new(store);
    for (id, css) in &ids {
        rl.record(baseline_html, css, id, FLD).unwrap();
    }
    ids.into_iter().map(|(id, _)| id).collect()
}

/// Compute the expected text for each stable_id from `baseline_html`.
fn expected_text(baseline: &str) -> Vec<(String, String)> {
    let doc = Html::parse_document(baseline);
    let sel = Selector::parse("[data-stable-id]").unwrap();
    doc.select(&sel)
        .map(|el| {
            let id = el.value().attr("data-stable-id").unwrap().to_string();
            let text = el
                .text()
                .collect::<String>()
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            (id, text)
        })
        .collect()
}

async fn run_against(target_html: &str, baseline: &str, threshold: f32) -> (usize, usize) {
    let dir = TempDir::new().unwrap();
    let mut store = ParseStore::open(&dir.path().join("p.db")).unwrap();
    let ids = record_baseline(&mut store, baseline);
    let want: std::collections::HashMap<String, String> =
        expected_text(baseline).into_iter().collect();
    let mut rl = Relocator::new(&mut store);
    let mut hits = 0usize;
    for id in &ids {
        let outcome = rl.locate(target_html, id, FLD, threshold).await.unwrap();
        let text = match outcome {
            LocateOutcome::ExactMatch(n) => Some(n.text),
            LocateOutcome::FuzzyMatch { node, .. } => Some(node.text),
            LocateOutcome::Ambiguous { candidates } => {
                // count only if the top candidate text matches expected
                candidates.first().map(|(n, _)| n.text.clone())
            }
            LocateOutcome::NotFound => None,
        };
        if let Some(got) = text {
            if got.trim() == want.get(id).map(String::as_str).unwrap_or("").trim() {
                hits += 1;
            }
        }
    }
    (hits, ids.len())
}

#[tokio::test]
async fn golden_static_100_percent() {
    let html = fixture("static.html");
    let (hits, total) = run_against(&html, &html, 0.85).await;
    assert_eq!(hits, total, "static: {hits}/{total}");
}

#[tokio::test]
async fn golden_class_renamed_95_percent() {
    let baseline = fixture("static.html");
    let target = fixture("class_renamed.html");
    let (hits, total) = run_against(&target, &baseline, 0.85).await;
    let ratio = hits as f32 / total as f32;
    assert!(
        ratio >= 0.95,
        "class_renamed: hits={hits}/{total} = {ratio:.2} < 0.95"
    );
}

#[tokio::test]
async fn golden_restructured_85_percent() {
    let baseline = fixture("static.html");
    let target = fixture("restructured.html");
    let (hits, total) = run_against(&target, &baseline, 0.80).await;
    let ratio = hits as f32 / total as f32;
    assert!(
        ratio >= 0.85,
        "restructured: hits={hits}/{total} = {ratio:.2} < 0.85"
    );
}
