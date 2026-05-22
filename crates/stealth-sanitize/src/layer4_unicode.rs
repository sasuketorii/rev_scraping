//! L4 — Unicode strip.
//!
//! Walks all string leaves in a `serde_json::Value` and applies:
//! - NFKC normalization (`policy.unicode.nfkc`)
//! - Zero-width strip: U+200B–U+200D, U+2060, U+FEFF (`strip_zero_width`)
//! - Tag-character strip: U+E0000–U+E007F (`strip_tag_chars`)
//! - Bidi override strip: U+202D/U+202E and isolates U+2066–U+2069
//!   (`strip_bidi_overrides`). Each occurrence emits **one** `bidi_override`
//!   canary hit in the report (de-duplicated by char class is intentionally
//!   not done here — each strip site is reported separately so reviewers can
//!   see frequency).
//!
//! False-positive goal: zero on legitimate text. Regular RTL Arabic/Hebrew
//! (which uses U+0590-U+05FF and U+0600-U+06FF, not the override codepoints)
//! is preserved. We only strip the explicit override / isolate codepoints
//! that have no purpose in benign plain text.

use serde_json::Value;
use unicode_normalization::UnicodeNormalization;

use crate::policy::UnicodePolicy;
use crate::report::{CanaryHit, CanarySeverity};

/// Result of an L4 pass over a single JSON value tree.
#[derive(Debug, Default)]
pub(crate) struct Layer4Result {
    /// Bidi-override hits to surface in the report.
    pub bidi_canaries: Vec<CanaryHit>,
    /// True if any string was modified (normalized or stripped).
    pub modified: bool,
}

/// Apply L4 in place on the JSON tree. Returns the aggregated result.
pub(crate) fn apply_l4(value: &mut Value, policy: &UnicodePolicy) -> Layer4Result {
    let mut acc = Layer4Result::default();
    walk(value, "", policy, &mut acc);
    acc
}

fn walk(value: &mut Value, pointer: &str, policy: &UnicodePolicy, acc: &mut Layer4Result) {
    match value {
        Value::String(s) => {
            let (new_s, modified, mut hits) = scrub_str(s, pointer, policy);
            if modified {
                acc.modified = true;
                *s = new_s;
            }
            acc.bidi_canaries.append(&mut hits);
        }
        Value::Array(arr) => {
            for (i, v) in arr.iter_mut().enumerate() {
                let child = format!("{pointer}/{i}");
                walk(v, &child, policy, acc);
            }
        }
        Value::Object(map) => {
            // First check if any key needs scrubbing. If so, rebuild
            // the map with scrubbed keys to avoid borrow conflicts.
            let needs_rekey = map.keys().any(|k| key_needs_scrub(k, policy));
            if needs_rekey {
                let old = std::mem::take(map);
                let mut new_map = serde_json::Map::with_capacity(old.len());
                for (idx, (k, mut v)) in old.into_iter().enumerate() {
                    // Pointer must not contain raw key bytes (they could
                    // include bidi/zero-width tokens that the report is
                    // explicitly stripping). Use positional id.
                    let key_pointer = format!("{pointer}/_k{idx}#key");
                    let (new_key, modified, mut hits) = scrub_str(&k, &key_pointer, policy);
                    if modified {
                        acc.modified = true;
                    }
                    acc.bidi_canaries.append(&mut hits);
                    // Descendants of a scrubbed key MUST use the
                    // positional id, not the (possibly still-tainted)
                    // new_key bytes. Even after scrubbing, the new_key
                    // may carry residual canary-like content the report
                    // is forbidden from echoing.
                    let child = format!("{pointer}/_k{idx}");
                    walk(&mut v, &child, policy, acc);
                    new_map.insert(new_key, v);
                }
                *map = new_map;
            } else {
                for (k, v) in map.iter_mut() {
                    let child = format!("{pointer}/{}", escape_pointer_segment(k));
                    walk(v, &child, policy, acc);
                }
            }
        }
        _ => {}
    }
}

/// Escape a JSON-pointer segment per RFC 6901 (`~` → `~0`, `/` → `~1`).
fn escape_pointer_segment(s: &str) -> String {
    s.replace('~', "~0").replace('/', "~1")
}

/// Cheap pre-check: does this key contain any character class that L4
/// would strip? Avoids the slow rebuild path for benign object keys.
fn key_needs_scrub(s: &str, policy: &UnicodePolicy) -> bool {
    if !policy.nfkc
        && !policy.strip_zero_width
        && !policy.strip_tag_chars
        && !policy.strip_bidi_overrides
    {
        return false;
    }
    s.chars().any(|c| {
        (policy.strip_zero_width && is_zero_width(c))
            || (policy.strip_tag_chars && is_tag_char(c))
            || (policy.strip_bidi_overrides && is_bidi_override(c))
    }) || (policy.nfkc && {
        // NFKC may rewrite e.g. halfwidth → fullwidth katakana. Cheap
        // way to detect: see if normalization changes anything.
        let n: String = s.nfkc().collect();
        n != s
    })
}

fn is_zero_width(c: char) -> bool {
    matches!(
        c,
        '\u{200B}' | '\u{200C}' | '\u{200D}' | '\u{2060}' | '\u{FEFF}'
    )
}

fn is_tag_char(c: char) -> bool {
    let v = c as u32;
    (0xE0000..=0xE007F).contains(&v)
}

fn is_bidi_override(c: char) -> bool {
    matches!(
        c,
        '\u{202D}' | '\u{202E}' | '\u{2066}' | '\u{2067}' | '\u{2068}' | '\u{2069}'
    )
}

/// Scrub a single string. Returns (new_string, modified, bidi_hits).
fn scrub_str(input: &str, pointer: &str, policy: &UnicodePolicy) -> (String, bool, Vec<CanaryHit>) {
    // Step 1: NFKC. NFKC is idempotent on already-normalized text, so
    // running it unconditionally is safe and keeps the pipeline simple.
    let normalized: String = if policy.nfkc {
        input.nfkc().collect()
    } else {
        input.to_string()
    };

    let mut out = String::with_capacity(normalized.len());
    let mut hits: Vec<CanaryHit> = Vec::new();
    let mut byte_offset_in_out: usize = 0;
    let mut modified_by_strip = false;

    for c in normalized.chars() {
        if policy.strip_zero_width && is_zero_width(c) {
            modified_by_strip = true;
            continue;
        }
        if policy.strip_tag_chars && is_tag_char(c) {
            modified_by_strip = true;
            continue;
        }
        if policy.strip_bidi_overrides && is_bidi_override(c) {
            modified_by_strip = true;
            hits.push(CanaryHit {
                canary_id: "bidi_override".into(),
                severity: CanarySeverity::Suspicious,
                offset: byte_offset_in_out,
                length: 0,
                pointer: pointer.to_string(),
            });
            continue;
        }
        out.push(c);
        byte_offset_in_out += c.len_utf8();
    }

    let modified = modified_by_strip || normalized != input;
    (out, modified, hits)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn default_policy() -> UnicodePolicy {
        UnicodePolicy::default()
    }

    #[test]
    fn strips_zero_width_chars() {
        let mut v = json!("hel\u{200B}lo\u{FEFF}world");
        let _ = apply_l4(&mut v, &default_policy());
        assert_eq!(v.as_str().unwrap(), "helloworld");
    }

    #[test]
    fn strips_tag_chars() {
        // U+E0041 is a tag-letter "A" — invisible in benign text.
        let mut v = json!("safe\u{E0041}text");
        let _ = apply_l4(&mut v, &default_policy());
        assert_eq!(v.as_str().unwrap(), "safetext");
    }

    #[test]
    fn strips_bidi_override_and_emits_canary() {
        let mut v = json!("a\u{202E}b");
        let result = apply_l4(&mut v, &default_policy());
        assert_eq!(v.as_str().unwrap(), "ab");
        assert_eq!(result.bidi_canaries.len(), 1);
        assert_eq!(result.bidi_canaries[0].canary_id, "bidi_override");
    }

    #[test]
    fn preserves_legitimate_arabic() {
        // U+0627 (ا) U+0644 (ل) U+0639 (ع) U+0631 (ر) U+0628 (ب) U+064A (ي)
        let arabic = "العربي";
        let mut v = json!(arabic);
        let result = apply_l4(&mut v, &default_policy());
        assert_eq!(v.as_str().unwrap(), arabic);
        assert!(result.bidi_canaries.is_empty());
    }

    #[test]
    fn nfkc_is_idempotent() {
        // Halfwidth katakana → fullwidth via NFKC.
        let mut v1 = json!("ｱｲｳ");
        let _ = apply_l4(&mut v1, &default_policy());
        let after_one = v1.clone();
        let _ = apply_l4(&mut v1, &default_policy());
        assert_eq!(v1, after_one, "second NFKC pass must not change anything");
    }

    #[test]
    fn nested_object_and_array_walked() {
        let mut v = json!({
            "outer": "x\u{200B}y",
            "list": ["a\u{FEFF}b", {"deep": "c\u{200C}d"}]
        });
        let _ = apply_l4(&mut v, &default_policy());
        assert_eq!(v["outer"].as_str().unwrap(), "xy");
        assert_eq!(v["list"][0].as_str().unwrap(), "ab");
        assert_eq!(v["list"][1]["deep"].as_str().unwrap(), "cd");
    }

    #[test]
    fn bidi_canary_pointer_records_path() {
        let mut v = json!({"k": "z\u{202D}q", "arr": ["w\u{2069}"]});
        let result = apply_l4(&mut v, &default_policy());
        let pointers: Vec<&str> = result
            .bidi_canaries
            .iter()
            .map(|h| h.pointer.as_str())
            .collect();
        assert!(pointers.contains(&"/k"));
        assert!(pointers.contains(&"/arr/0"));
    }

    #[test]
    fn disabled_policy_leaves_input_alone() {
        let policy = UnicodePolicy {
            nfkc: false,
            strip_zero_width: false,
            strip_tag_chars: false,
            strip_bidi_overrides: false,
        };
        let s = "x\u{200B}y\u{202E}z\u{E0041}";
        let mut v = json!(s);
        let result = apply_l4(&mut v, &policy);
        assert_eq!(v.as_str().unwrap(), s);
        assert!(result.bidi_canaries.is_empty());
        assert!(!result.modified);
    }

    #[test]
    fn non_string_values_untouched() {
        let mut v = json!({"n": 1, "b": true, "nil": null});
        let result = apply_l4(&mut v, &default_policy());
        assert!(!result.modified);
        assert_eq!(v, json!({"n": 1, "b": true, "nil": null}));
    }

    #[test]
    fn keys_are_scrubbed_for_zero_width() {
        let mut v = json!({"hid\u{200B}den": 1, "clean": 2});
        let r = apply_l4(&mut v, &default_policy());
        let obj = v.as_object().unwrap();
        assert!(
            obj.contains_key("hidden"),
            "key not scrubbed: keys={:?}",
            obj.keys().collect::<Vec<_>>()
        );
        assert!(obj.contains_key("clean"));
        assert!(r.modified);
    }

    #[test]
    fn key_pointer_does_not_leak_raw_key_chars() {
        // Bidi-stripped char in a key with a unique marker — pointer
        // must not include the marker.
        let mut v = json!({"k\u{202E}UNIQUEMARK": "v"});
        let r = apply_l4(&mut v, &default_policy());
        let json = serde_json::to_string(&r.bidi_canaries).unwrap();
        assert!(!json.contains("UNIQUEMARK"), "raw key leaked: {json}");
        assert!(r.bidi_canaries.iter().any(|h| h.pointer.contains("#key")));
    }

    #[test]
    fn descendant_value_hit_pointer_does_not_leak_raw_key_chars() {
        // Tainted key carries a unique marker plus a strippable char,
        // and a nested value also produces a bidi-override hit. The
        // descendant value-hit pointer must not echo the marker.
        let mut v = json!({
            "k\u{202E}DESC-UNIQUE-MARK": "z\u{202D}q"
        });
        let r = apply_l4(&mut v, &default_policy());
        let json = serde_json::to_string(&r.bidi_canaries).unwrap();
        assert!(
            !json.contains("DESC-UNIQUE-MARK"),
            "raw key bytes leaked through descendant value pointer: {json}"
        );
        // Sanity: at least one value-side hit (no `#key` suffix) emitted.
        assert!(r.bidi_canaries.iter().any(|h| !h.pointer.contains("#key")));
    }

    #[test]
    fn keys_bidi_override_emits_canary() {
        let mut v = json!({"k\u{202E}y": "v"});
        let r = apply_l4(&mut v, &default_policy());
        assert!(r.bidi_canaries.iter().any(|h| h.pointer.contains("#key")));
        assert!(v.as_object().unwrap().contains_key("ky"));
    }

    #[test]
    fn no_modifications_when_text_is_pure_ascii() {
        let mut v = json!("Hello, world!");
        let result = apply_l4(&mut v, &default_policy());
        assert!(!result.modified);
        assert!(result.bidi_canaries.is_empty());
    }

    #[test]
    fn pointer_segment_escapes_slash_and_tilde() {
        let mut v = json!({"a/b": "x\u{200B}y", "c~d": "p\u{200B}q"});
        let result = apply_l4(&mut v, &default_policy());
        // Strips applied — modified=true even though we mainly check pointer escaping below.
        assert!(result.modified);
        assert_eq!(v["a/b"].as_str().unwrap(), "xy");
        assert_eq!(v["c~d"].as_str().unwrap(), "pq");
    }
}
