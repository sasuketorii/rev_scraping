// SPDX-License-Identifier: MIT
// Source: design adapted from Scrapling adaptive selector (BSD-3-Clause), https://github.com/D4Vinci/Scrapling

#![cfg(test)]

use crate::fingerprint::{build_node_ref, css_path_of, fingerprint_from_html, similarity, NodeRef};
use crate::relocate::{LocateOutcome, Relocator};
use crate::store::ParseStore;
use scraper::{Html, Selector};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tempfile::TempDir;

const FLD: &str = "example.com";

fn tmp_db() -> (TempDir, ParseStore) {
    let d = TempDir::new().unwrap();
    let path = d.path().join("sub/parse.db");
    let store = ParseStore::open(&path).unwrap();
    (d, store)
}

#[test]
fn test_store_open_creates_wal() {
    let (_d, store) = tmp_db();
    let mode = store.journal_mode().unwrap().to_lowercase();
    assert_eq!(mode, "wal", "expected WAL journal_mode, got {mode}");
}

#[test]
fn test_store_upsert_and_lookup() {
    let html = r#"<html><body><div><span class="p">10</span></div></body></html>"#;
    let fp = fingerprint_from_html(html, "span.p", "price", FLD).unwrap();
    let (_d, mut store) = tmp_db();
    store.upsert(&fp).unwrap();
    let got = store.lookup("price", FLD).unwrap().unwrap();
    assert_eq!(got.stable_id, "price");
    assert_eq!(got.tag_name, "span");
    assert!(got.css_path.contains("span:nth-of-type(1)"));
    assert!(got.text_norm.contains("10"));
}

#[test]
fn test_store_upsert_replaces_existing() {
    let (_d, mut store) = tmp_db();
    let html_a = r#"<html><body><span class="a">A</span></body></html>"#;
    let html_b = r#"<html><body><span class="b">B</span></body></html>"#;
    let fp_a = fingerprint_from_html(html_a, "span", "x", FLD).unwrap();
    let fp_b = fingerprint_from_html(html_b, "span", "x", FLD).unwrap();
    store.upsert(&fp_a).unwrap();
    store.upsert(&fp_b).unwrap();
    let got = store.lookup("x", FLD).unwrap().unwrap();
    assert_eq!(got.text_norm, "B");
    // Only one row exists.
    let count: i64 = store
        .db
        .query_row("SELECT COUNT(*) FROM fingerprints", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 1);
}

#[test]
fn test_store_concurrent_read_write() {
    let (_d, store) = tmp_db();
    let store = Arc::new(Mutex::new(store));
    let html = r#"<html><body><p>hi</p></body></html>"#;
    let fp = fingerprint_from_html(html, "p", "greet", FLD).unwrap();

    let writers: Vec<_> = (0..4)
        .map(|_| {
            let s = Arc::clone(&store);
            let fp = fp.clone();
            thread::spawn(move || {
                for _ in 0..20 {
                    s.lock().unwrap().upsert(&fp).unwrap();
                }
            })
        })
        .collect();
    let reader = {
        let s = Arc::clone(&store);
        thread::spawn(move || {
            for _ in 0..40 {
                let _ = s.lock().unwrap().lookup("greet", FLD).unwrap();
            }
        })
    };
    for w in writers {
        w.join().unwrap();
    }
    reader.join().unwrap();
    let got = store.lock().unwrap().lookup("greet", FLD).unwrap().unwrap();
    assert_eq!(got.text_norm, "hi");
}

#[test]
fn test_purge_older_than() {
    let (_d, mut store) = tmp_db();
    let html = r#"<html><body><p>stale</p></body></html>"#;
    let mut fp = fingerprint_from_html(html, "p", "stale_id", FLD).unwrap();
    // Force last_seen to 40 days ago.
    fp.last_seen = UNIX_EPOCH
        + Duration::from_secs(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs()
                .saturating_sub(40 * 86_400),
        );
    store.upsert(&fp).unwrap();
    // Insert a fresh one.
    let fp2 = fingerprint_from_html(html, "p", "fresh_id", FLD).unwrap();
    store.upsert(&fp2).unwrap();

    let n = store.purge_older_than_days(30).unwrap();
    assert_eq!(n, 1);
    assert!(store.lookup("stale_id", FLD).unwrap().is_none());
    assert!(store.lookup("fresh_id", FLD).unwrap().is_some());
}

fn first_node(html: &str, css: &str) -> NodeRef {
    let doc = Html::parse_document(html);
    let sel = Selector::parse(css).unwrap();
    let el = doc.select(&sel).next().unwrap();
    build_node_ref(el)
}

#[test]
fn test_similarity_identical_node_is_1() {
    let html = r#"<html><body><div><span class="p" id="x">$10.00</span></div></body></html>"#;
    let fp = fingerprint_from_html(html, "span", "price", FLD).unwrap();
    let node = first_node(html, "span");
    let s = similarity(&fp, &node);
    assert!(s > 0.99, "expected ~1.0, got {s}");
}

#[test]
fn test_similarity_class_renamed_is_high() {
    let html_a =
        r#"<html><body><div><span class="price-old" id="x">$10.00</span></div></body></html>"#;
    let html_b =
        r#"<html><body><div><span class="price-new" id="x">$10.00</span></div></body></html>"#;
    let fp = fingerprint_from_html(html_a, "span", "price", FLD).unwrap();
    let node = first_node(html_b, "span");
    let s = similarity(&fp, &node);
    assert!(s >= 0.85, "class-rename similarity too low: {s}");
}

#[test]
fn test_similarity_unrelated_is_low() {
    let html_a = r#"<html><body><span class="price-display-currency-usd" data-qa="price">$10.00 USD</span></body></html>"#;
    let html_b = r#"<html><body><footer><nav><a href="/zzz" rel="nofollow">Login</a></nav></footer></body></html>"#;
    let fp = fingerprint_from_html(html_a, "span", "price", FLD).unwrap();
    let node = first_node(html_b, "a");
    let s = similarity(&fp, &node);
    // Different tag, different text, different attrs, different structure.
    assert!(s < 0.4, "unrelated similarity too high: {s}");
}

#[tokio::test]
async fn test_locate_exact_css_match() {
    let html = r#"<html><body><div><span class="p">42</span></div></body></html>"#;
    let (_d, mut store) = tmp_db();
    {
        let mut rl = Relocator::new(&mut store);
        rl.record(html, "span", "price", FLD).unwrap();
    }
    let mut rl = Relocator::new(&mut store);
    let out = rl.locate(html, "price", FLD, 0.85).await.unwrap();
    match out {
        LocateOutcome::ExactMatch(n) => assert!(n.text.contains("42")),
        other => panic!("expected ExactMatch, got {other:?}"),
    }
}

#[tokio::test]
async fn test_locate_fuzzy_match_above_threshold() {
    let html_a = r#"<html><body>
        <div><span class="price-old">$10.00</span></div>
    </body></html>"#;
    // Wrap span in an extra div so css_path changes but content stays.
    let html_b = r#"<html><body>
        <section><div><span class="price-new">$10.00</span></div></section>
    </body></html>"#;
    let (_d, mut store) = tmp_db();
    {
        let mut rl = Relocator::new(&mut store);
        rl.record(html_a, "span", "price", FLD).unwrap();
    }
    let mut rl = Relocator::new(&mut store);
    let out = rl.locate(html_b, "price", FLD, 0.85).await.unwrap();
    match out {
        LocateOutcome::FuzzyMatch { node, score } => {
            assert!(score >= 0.85, "score {score}");
            assert!(node.text.contains("$10.00"));
        }
        LocateOutcome::ExactMatch(n) => {
            assert!(n.text.contains("$10.00"));
        }
        other => panic!("expected FuzzyMatch, got {other:?}"),
    }
}

#[tokio::test]
async fn test_locate_returns_ambiguous_when_hash_mismatch() {
    // Same text, completely different attrs AND neighbors → hash mismatch on both.
    let html_a = r#"<html><body><div class="orig"><span data-k="v" id="a">$10.00</span></div></body></html>"#;
    let html_b = r#"<html><body><main class="restructured"><article><span class="totally-different" role="text" aria-label="price">$10.00</span></article></main></body></html>"#;
    let (_d, mut store) = tmp_db();
    {
        let mut rl = Relocator::new(&mut store);
        rl.record(html_a, "span", "price", FLD).unwrap();
    }
    let mut rl = Relocator::new(&mut store);
    let out = rl.locate(html_b, "price", FLD, 0.5).await.unwrap();
    match out {
        LocateOutcome::Ambiguous { candidates } => {
            assert!(!candidates.is_empty());
        }
        other => panic!("expected Ambiguous, got {other:?}"),
    }
}

#[tokio::test]
async fn test_locate_not_found_when_below_threshold() {
    let html_a = r#"<html><body><span class="p">UNIQUE_TOKEN_AAA</span></body></html>"#;
    let html_b =
        r#"<html><body><span class="q">totally other content here xyz qqq</span></body></html>"#;
    let (_d, mut store) = tmp_db();
    {
        let mut rl = Relocator::new(&mut store);
        rl.record(html_a, "span", "price", FLD).unwrap();
    }
    let mut rl = Relocator::new(&mut store);
    let out = rl.locate(html_b, "price", FLD, 0.95).await.unwrap();
    matches!(out, LocateOutcome::NotFound);
}

#[test]
fn test_css_path_round_trip() {
    let html = r#"<html><body><div><p>1</p><p>2</p><p>3</p></div></body></html>"#;
    let fp = fingerprint_from_html(html, "p:nth-of-type(2)", "p2", FLD).unwrap();
    assert!(fp.css_path.ends_with("p:nth-of-type(2)"), "{}", fp.css_path);
    // Re-find via the recorded css_path.
    let doc = Html::parse_document(html);
    let sel = Selector::parse(&fp.css_path).unwrap();
    let el = doc.select(&sel).next().unwrap();
    assert_eq!(css_path_of(el), fp.css_path);
}
