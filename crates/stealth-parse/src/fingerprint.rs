// SPDX-License-Identifier: MIT
// Source: design adapted from Scrapling adaptive selector (BSD-3-Clause), https://github.com/D4Vinci/Scrapling

//! Element fingerprinting and similarity scoring.

use ego_tree::NodeRef as EgoNode;
use scraper::{ElementRef, Html, Node, Selector};
use serde::{Deserialize, Serialize};
use std::time::SystemTime;
use xxhash_rust::xxh3::xxh3_64;

/// A persistent description of a DOM element used to relocate it after structural changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ElementFingerprint {
    /// Logical name for the element (e.g. "product.price").
    pub stable_id: String,
    /// First-level domain scope.
    pub url_fld: String,
    pub css_path: String,
    pub xpath: String,
    /// Whitespace-normalized text.
    pub text_norm: String,
    pub tag_name: String,
    /// JSON of attribute map.
    pub attrs_json: String,
    /// xxh3 hash of attribute key=value pairs.
    pub attrs_hash: u64,
    /// xxh3 hash of neighbor structure (parent tag + sibling tag list).
    pub neighbor_hash: u64,
    #[serde(with = "systime_secs")]
    pub last_seen: SystemTime,
}

/// Lightweight reference to a node in the parsed DOM.
#[derive(Debug, Clone)]
pub struct NodeRef {
    pub css_path: String,
    pub text: String,
    pub attrs: Vec<(String, String)>,
}

mod systime_secs {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    pub fn serialize<S: Serializer>(t: &SystemTime, s: S) -> Result<S::Ok, S::Error> {
        let ms = t
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        ms.serialize(s)
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<SystemTime, D::Error> {
        let s = i64::deserialize(d)?;
        Ok(UNIX_EPOCH + Duration::from_secs(s.max(0) as u64))
    }
}

pub(crate) fn normalize_text(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub(crate) fn sorted_attrs_string(attrs: &[(String, String)]) -> String {
    let mut v: Vec<String> = attrs.iter().map(|(k, val)| format!("{k}={val}")).collect();
    v.sort();
    v.join("|")
}

pub(crate) fn hash_attrs(attrs: &[(String, String)]) -> u64 {
    xxh3_64(sorted_attrs_string(attrs).as_bytes())
}

pub(crate) fn hash_neighbors(parent_tag: &str, sibling_tags: &[String]) -> u64 {
    xxh3_64(format!("{parent_tag}>{}", sibling_tags.join(",")).as_bytes())
}

fn element_of<'a>(n: EgoNode<'a, Node>) -> Option<ElementRef<'a>> {
    ElementRef::wrap(n)
}

fn nth_of_type_index(el: ElementRef<'_>) -> usize {
    let tag = el.value().name();
    let mut idx = 1usize;
    let mut sib = el.prev_sibling();
    while let Some(s) = sib {
        if let Some(e) = element_of(s) {
            if e.value().name() == tag {
                idx += 1;
            }
        }
        sib = s.prev_sibling();
    }
    idx
}

/// CSS path of `el`, descending from `html`.
pub(crate) fn css_path_of(el: ElementRef<'_>) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut cur = Some(el);
    while let Some(e) = cur {
        let tag = e.value().name();
        let idx = nth_of_type_index(e);
        parts.push(format!("{tag}:nth-of-type({idx})"));
        cur = e.parent().and_then(element_of);
    }
    parts.reverse();
    parts.join(" > ")
}

pub(crate) fn xpath_of(el: ElementRef<'_>) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut cur = Some(el);
    while let Some(e) = cur {
        let tag = e.value().name();
        let idx = nth_of_type_index(e);
        parts.push(format!("{tag}[{idx}]"));
        cur = e.parent().and_then(element_of);
    }
    parts.reverse();
    format!("/{}", parts.join("/"))
}

pub(crate) fn extract_attrs(el: ElementRef<'_>) -> Vec<(String, String)> {
    el.value()
        .attrs()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

pub(crate) fn sibling_tags(el: ElementRef<'_>) -> Vec<String> {
    let Some(parent) = el.parent() else {
        return Vec::new();
    };
    parent
        .children()
        .filter_map(element_of)
        .map(|c| c.value().name().to_string())
        .collect()
}

pub(crate) fn parent_tag(el: ElementRef<'_>) -> String {
    el.parent()
        .and_then(element_of)
        .map(|p| p.value().name().to_string())
        .unwrap_or_default()
}

/// Build a fingerprint for the first element matching the css selector in `html`.
pub fn fingerprint_from_html(
    html: &str,
    css: &str,
    stable_id: &str,
    url_fld: &str,
) -> anyhow::Result<ElementFingerprint> {
    let doc = Html::parse_document(html);
    let sel =
        Selector::parse(css).map_err(|e| anyhow::anyhow!("invalid css selector {css}: {e:?}"))?;
    let el = doc
        .select(&sel)
        .next()
        .ok_or_else(|| anyhow::anyhow!("selector {css} matched no element"))?;
    Ok(build_fingerprint(el, stable_id, url_fld))
}

pub(crate) fn build_fingerprint(
    el: ElementRef<'_>,
    stable_id: &str,
    url_fld: &str,
) -> ElementFingerprint {
    let attrs = extract_attrs(el);
    let sibs = sibling_tags(el);
    let parent = parent_tag(el);
    let attrs_json = serde_json::to_string(&attrs).unwrap_or_else(|_| "[]".to_string());
    ElementFingerprint {
        stable_id: stable_id.to_string(),
        url_fld: url_fld.to_string(),
        css_path: css_path_of(el),
        xpath: xpath_of(el),
        text_norm: normalize_text(&el.text().collect::<String>()),
        tag_name: el.value().name().to_string(),
        attrs_json,
        attrs_hash: hash_attrs(&attrs),
        neighbor_hash: hash_neighbors(&parent, &sibs),
        last_seen: SystemTime::now(),
    }
}

pub(crate) fn build_node_ref(el: ElementRef<'_>) -> NodeRef {
    NodeRef {
        css_path: css_path_of(el),
        text: normalize_text(&el.text().collect::<String>()),
        attrs: extract_attrs(el),
    }
}

/// Tag-sequence (stripped) of a css_path string.
fn tag_sequence(css_path: &str) -> String {
    css_path
        .split(" > ")
        .map(|seg| seg.split(':').next().unwrap_or("").to_string())
        .collect::<Vec<_>>()
        .join(">")
}

/// Compute weighted similarity score (0.0..=1.0) between a stored fingerprint and a live node.
///
/// Weights:
/// - tag match: 0.15 (binary on derived live tag from css_path tail)
/// - text strsim (jaro_winkler): 0.30
/// - attrs strsim (sorted "k=v" join): 0.25
/// - css_path strsim: 0.15
/// - neighbor / tag-sequence strsim: 0.15
pub fn similarity(a: &ElementFingerprint, b: &NodeRef) -> f32 {
    let live_tag = b
        .css_path
        .rsplit(" > ")
        .next()
        .and_then(|s| s.split(':').next())
        .unwrap_or("");
    let tag_score = if live_tag == a.tag_name { 1.0 } else { 0.0 };

    let text_score = strsim::jaro_winkler(&a.text_norm, &b.text) as f32;
    let live_attrs = sorted_attrs_string(&b.attrs);
    let stored_attrs: Vec<(String, String)> =
        serde_json::from_str(&a.attrs_json).unwrap_or_default();
    let stored_attrs_s = sorted_attrs_string(&stored_attrs);
    let attrs_score = if stored_attrs_s.is_empty() && live_attrs.is_empty() {
        1.0
    } else if stored_attrs_s.is_empty() || live_attrs.is_empty() {
        0.0
    } else {
        strsim::jaro_winkler(&stored_attrs_s, &live_attrs) as f32
    };
    let css_score = strsim::jaro_winkler(&a.css_path, &b.css_path) as f32;
    let neighbor_score =
        strsim::jaro_winkler(&tag_sequence(&a.css_path), &tag_sequence(&b.css_path)) as f32;

    0.15 * tag_score
        + 0.30 * text_score
        + 0.25 * attrs_score
        + 0.15 * css_score
        + 0.15 * neighbor_score
}
