//! L5 — Length clamp.
//!
//! Enforces per-field byte budget (`limits.per_field_max_bytes`) and a
//! total budget (`limits.total_max_bytes`) across all string leaves in
//! the JSON tree. When a field is over budget we keep the first 80% +
//! last 20% with a `[...TRUNCATED...]` marker between.
//!
//! Total-budget enforcement is best-effort: once the cumulative kept
//! bytes exceed `total_max_bytes`, subsequent strings are clamped to the
//! marker only. This matches the synthesis design and avoids unbounded
//! buffers for pathological payloads.

use serde_json::Value;

use crate::policy::LimitPolicy;

pub(crate) const TRUNCATED_MARKER: &str = "[...TRUNCATED...]";

#[derive(Debug, Default)]
pub(crate) struct Layer5Result {
    pub truncated: bool,
    pub bytes_kept: usize,
}

/// Apply L5 in place. Returns whether any clamp happened plus total
/// bytes kept across string leaves.
pub(crate) fn apply_l5(value: &mut Value, policy: &LimitPolicy) -> Layer5Result {
    let mut acc = Layer5Result::default();
    walk(value, policy, &mut acc);
    acc
}

fn walk(value: &mut Value, policy: &LimitPolicy, acc: &mut Layer5Result) {
    match value {
        Value::String(s) => {
            // Per-field clamp first.
            let per_field_limit = policy.per_field_max_bytes;
            if s.len() > per_field_limit {
                *s = head_tail_clamp(s, per_field_limit);
                acc.truncated = true;
            }
            // Total-budget enforcement.
            let remaining = policy.total_max_bytes.saturating_sub(acc.bytes_kept);
            if s.len() > remaining {
                // Hard-truncate: replace with marker only (or empty if marker
                // alone would still bust the budget).
                if remaining >= TRUNCATED_MARKER.len() {
                    *s = TRUNCATED_MARKER.to_string();
                } else {
                    *s = String::new();
                }
                acc.truncated = true;
            }
            acc.bytes_kept = acc.bytes_kept.saturating_add(s.len());
        }
        Value::Array(arr) => {
            for v in arr.iter_mut() {
                walk(v, policy, acc);
            }
        }
        Value::Object(map) => {
            for (_, v) in map.iter_mut() {
                walk(v, policy, acc);
            }
        }
        _ => {}
    }
}

/// Keep first 80% + marker + last 20% of `s` such that the result is
/// approximately `limit` bytes. Slices on UTF-8 char boundaries.
fn head_tail_clamp(s: &str, limit: usize) -> String {
    // Effective budget after the marker.
    let marker_len = TRUNCATED_MARKER.len();
    if limit <= marker_len {
        // Degenerate budget: return marker truncated to `limit`.
        return TRUNCATED_MARKER
            .chars()
            .take(limit)
            .collect();
    }
    let budget = limit - marker_len;
    let head_budget = (budget * 80) / 100;
    let tail_budget = budget - head_budget;

    let head_end = char_boundary_floor(s, head_budget);
    // Tail start = byte offset N from end, rounded UP to the next boundary.
    let tail_start = char_boundary_ceil(s, s.len().saturating_sub(tail_budget));
    // If head and tail overlap (small string, shouldn't happen because we
    // only enter clamp on > limit), just return the original.
    if head_end >= tail_start {
        return s.to_string();
    }
    let mut out = String::with_capacity(limit + 1);
    out.push_str(&s[..head_end]);
    out.push_str(TRUNCATED_MARKER);
    out.push_str(&s[tail_start..]);
    out
}

fn char_boundary_floor(s: &str, idx: usize) -> usize {
    let mut i = idx.min(s.len());
    while i > 0 && !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

fn char_boundary_ceil(s: &str, idx: usize) -> usize {
    let mut i = idx.min(s.len());
    while i < s.len() && !s.is_char_boundary(i) {
        i += 1;
    }
    i
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn small_policy() -> LimitPolicy {
        // Tiny budgets to make tests easy to read.
        LimitPolicy {
            per_field_max_bytes: 100,
            total_max_bytes: 200,
        }
    }

    #[test]
    fn short_strings_untouched() {
        let mut v = json!({"a": "hello", "b": "world"});
        let r = apply_l5(&mut v, &small_policy());
        assert!(!r.truncated);
        assert_eq!(v["a"].as_str().unwrap(), "hello");
    }

    #[test]
    fn per_field_clamp_inserts_marker() {
        let long = "a".repeat(500);
        let mut v = json!(long);
        let r = apply_l5(&mut v, &small_policy());
        assert!(r.truncated);
        let out = v.as_str().unwrap();
        assert!(out.contains(TRUNCATED_MARKER));
        // Head + marker + tail ≈ limit. Allow ±2 for boundary rounding.
        assert!(out.len() <= small_policy().per_field_max_bytes + 4);
    }

    #[test]
    fn head_tail_keeps_first_and_last_bytes() {
        let s = format!("HEAD{}TAIL", "X".repeat(500));
        let mut v = json!(s);
        let _ = apply_l5(&mut v, &small_policy());
        let out = v.as_str().unwrap();
        assert!(out.starts_with("HEAD"), "starts with HEAD: {out}");
        assert!(out.ends_with("TAIL"), "ends with TAIL: {out}");
        assert!(out.contains(TRUNCATED_MARKER));
    }

    #[test]
    fn total_budget_truncates_subsequent_strings() {
        // Each string is 80B, per-field limit 100, total budget 200.
        // After 2 strings we are at 160; the third (80B) would push to 240
        // so it should be replaced with the marker (17B).
        let policy = LimitPolicy {
            per_field_max_bytes: 100,
            total_max_bytes: 200,
        };
        let s = "y".repeat(80);
        let mut v = json!({"a": s, "b": "y".repeat(80), "c": "y".repeat(80)});
        let r = apply_l5(&mut v, &policy);
        assert!(r.truncated);
        // bytes_kept must not exceed total_max_bytes by more than marker size.
        assert!(
            r.bytes_kept <= policy.total_max_bytes + TRUNCATED_MARKER.len(),
            "bytes_kept={} > budget+marker", r.bytes_kept
        );
    }

    #[test]
    fn utf8_char_boundary_respected() {
        // Each Japanese char is 3 bytes in UTF-8.
        let s = "あ".repeat(200); // 600 bytes
        let mut v = json!(s);
        let r = apply_l5(&mut v, &small_policy());
        assert!(r.truncated);
        let out = v.as_str().unwrap();
        // Must still be valid UTF-8 — String::as_str guarantees this; the real
        // check is that we did not panic during slicing.
        assert!(out.contains(TRUNCATED_MARKER));
    }

    #[test]
    fn idempotent_after_clamp() {
        let long = "z".repeat(1_000);
        let mut v = json!(long);
        let _ = apply_l5(&mut v, &small_policy());
        let after_one = v.clone();
        let _ = apply_l5(&mut v, &small_policy());
        assert_eq!(v, after_one, "second clamp pass must be a no-op");
    }

    #[test]
    fn nested_structures_walked() {
        let policy = LimitPolicy {
            per_field_max_bytes: 50,
            total_max_bytes: 10_000,
        };
        let mut v = json!({"arr": [{"deep": "q".repeat(200)}]});
        let r = apply_l5(&mut v, &policy);
        assert!(r.truncated);
        let inner = v["arr"][0]["deep"].as_str().unwrap();
        assert!(inner.contains(TRUNCATED_MARKER));
    }

    #[test]
    fn empty_string_unchanged() {
        let mut v = json!("");
        let r = apply_l5(&mut v, &small_policy());
        assert!(!r.truncated);
        assert_eq!(v.as_str().unwrap(), "");
    }

    #[test]
    fn marker_only_when_remaining_smaller_than_input() {
        // Pre-fill bytes_kept by clamping a big field first.
        let policy = LimitPolicy {
            per_field_max_bytes: 1000,
            total_max_bytes: 100,
        };
        let mut v = json!({"a": "x".repeat(90), "b": "y".repeat(90)});
        let r = apply_l5(&mut v, &policy);
        assert!(r.truncated);
        // The second field should be marker-only since remaining < its size.
        let b = v["b"].as_str().unwrap();
        assert!(
            b == TRUNCATED_MARKER || b.is_empty(),
            "expected marker or empty, got: {b}"
        );
    }

    #[test]
    fn budget_smaller_than_marker_truncates_to_empty_or_partial() {
        let policy = LimitPolicy {
            per_field_max_bytes: 5,
            total_max_bytes: 1_000,
        };
        let mut v = json!("x".repeat(20));
        let _ = apply_l5(&mut v, &policy);
        let out = v.as_str().unwrap();
        // Degenerate path: marker truncated to <= 5 chars.
        assert!(out.len() <= 5);
    }
}
