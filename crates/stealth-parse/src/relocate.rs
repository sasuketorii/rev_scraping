// SPDX-License-Identifier: MIT
// Source: design adapted from Scrapling adaptive selector (BSD-3-Clause), https://github.com/D4Vinci/Scrapling

//! Adaptive relocation: exact CSS / xpath fallback / strsim-scored fuzzy match.

use crate::fingerprint::{
    build_fingerprint, build_node_ref, extract_attrs, hash_attrs, hash_neighbors, parent_tag,
    sibling_tags, similarity, NodeRef,
};
use crate::store::ParseStore;
use scraper::{ElementRef, Html, Selector};

#[derive(Debug)]
pub enum LocateOutcome {
    /// Cached css_path still matches exactly.
    ExactMatch(NodeRef),
    /// Found via strsim above threshold; both hash signals agree.
    FuzzyMatch { node: NodeRef, score: f32 },
    /// Score >= 0.85 but attrs_hash AND neighbor_hash both mismatch — caller must
    /// surface as exit code 10 per plan §S4.
    Ambiguous { candidates: Vec<(NodeRef, f32)> },
    /// No candidate above threshold.
    NotFound,
}

pub struct Relocator<'a> {
    store: &'a mut ParseStore,
}

impl<'a> Relocator<'a> {
    pub fn new(store: &'a mut ParseStore) -> Self {
        Self { store }
    }

    /// Adaptive locate.
    ///
    /// Strategy:
    /// 1. cached css_path exact match → ExactMatch
    /// 2. cached xpath fallback (parse via "tag:nth-of-type" reconstruction)
    /// 3. enumerate same-tag candidates, score; if best >= threshold:
    ///    - if attrs_hash AND neighbor_hash both mismatch → Ambiguous (with high-score candidates)
    ///    - else FuzzyMatch
    /// 4. otherwise NotFound
    pub async fn locate(
        &mut self,
        html: &str,
        stable_id: &str,
        url_fld: &str,
        threshold: f32,
    ) -> anyhow::Result<LocateOutcome> {
        let fp = match self.store.lookup(stable_id, url_fld)? {
            Some(f) => f,
            None => return Ok(LocateOutcome::NotFound),
        };
        let doc = Html::parse_document(html);

        // 1. Exact css_path
        if let Ok(sel) = Selector::parse(&fp.css_path) {
            if let Some(el) = doc.select(&sel).next() {
                return Ok(LocateOutcome::ExactMatch(build_node_ref(el)));
            }
        }

        // 2. Xpath fallback: convert xpath of form "/html[1]/body[1]/div[2]" into
        // equivalent css path and try again.
        if let Some(css_from_xpath) = xpath_to_css(&fp.xpath) {
            if let Ok(sel) = Selector::parse(&css_from_xpath) {
                if let Some(el) = doc.select(&sel).next() {
                    return Ok(LocateOutcome::ExactMatch(build_node_ref(el)));
                }
            }
        }

        // 3. Enumerate same-tag candidates, score similarity.
        let tag_sel = Selector::parse(&fp.tag_name)
            .map_err(|e| anyhow::anyhow!("bad tag selector {}: {e:?}", fp.tag_name))?;
        let mut scored: Vec<(ElementRef<'_>, NodeRef, f32)> = Vec::new();
        for el in doc.select(&tag_sel) {
            let node = build_node_ref(el);
            let s = similarity(&fp, &node);
            scored.push((el, node, s));
        }
        scored.sort_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal));

        if let Some((best_el, best_node, best_score)) = scored.first().cloned() {
            if best_score >= threshold {
                // Verify hash signals.
                let attrs = extract_attrs(best_el);
                let sibs = sibling_tags(best_el);
                let parent = parent_tag(best_el);
                let live_attrs_hash = hash_attrs(&attrs);
                let live_neighbor_hash = hash_neighbors(&parent, &sibs);
                let attrs_mismatch = live_attrs_hash != fp.attrs_hash;
                let neighbor_mismatch = live_neighbor_hash != fp.neighbor_hash;
                if attrs_mismatch && neighbor_mismatch {
                    let candidates: Vec<(NodeRef, f32)> = scored
                        .into_iter()
                        .filter(|(_, _, s)| *s >= threshold)
                        .map(|(_, n, s)| (n, s))
                        .collect();
                    return Ok(LocateOutcome::Ambiguous { candidates });
                }
                return Ok(LocateOutcome::FuzzyMatch {
                    node: best_node,
                    score: best_score,
                });
            }
        }
        Ok(LocateOutcome::NotFound)
    }

    /// Capture an element via css selector and persist its fingerprint.
    pub fn record(
        &mut self,
        html: &str,
        css: &str,
        stable_id: &str,
        url_fld: &str,
    ) -> anyhow::Result<()> {
        let doc = Html::parse_document(html);
        let sel = Selector::parse(css)
            .map_err(|e| anyhow::anyhow!("invalid css selector {css}: {e:?}"))?;
        let el = doc
            .select(&sel)
            .next()
            .ok_or_else(|| anyhow::anyhow!("selector {css} matched no element"))?;
        let fp = build_fingerprint(el, stable_id, url_fld);
        self.store.upsert(&fp)
    }
}

/// Convert a simple xpath of form `/html[1]/body[1]/div[2]/...` into the equivalent
/// css `:nth-of-type()` selector. Returns None on parse failure.
fn xpath_to_css(xpath: &str) -> Option<String> {
    let trimmed = xpath.trim_start_matches('/');
    let mut out: Vec<String> = Vec::new();
    for seg in trimmed.split('/') {
        if seg.is_empty() {
            continue;
        }
        let (tag, idx) = if let Some(open) = seg.find('[') {
            let close = seg.find(']')?;
            let idx: usize = seg[open + 1..close].parse().ok()?;
            (&seg[..open], idx)
        } else {
            (seg, 1usize)
        };
        out.push(format!("{tag}:nth-of-type({idx})"));
    }
    if out.is_empty() {
        None
    } else {
        Some(out.join(" > "))
    }
}
