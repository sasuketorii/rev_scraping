// SPDX-License-Identifier: MIT
// Source: new crate for rev_scraping v1.0.0 (Phase 7a)

use std::collections::HashMap;

use url::Url;

use crate::error::{Result, SitesError};

/// Substitute `{key}` placeholders in `pattern` with URL-encoded values from
/// `params`, then parse the result as a [`Url`].
///
/// Only the simple `{key}` form is supported. Modifiers like `{key:type}` are
/// out of scope for Phase 7a. Unknown placeholders cause [`SitesError::MissingParam`].
pub fn render_url(pattern: &str, params: &HashMap<String, String>) -> Result<Url> {
    let mut out = String::with_capacity(pattern.len());
    let bytes = pattern.as_bytes();
    let mut i = 0usize;

    while i < bytes.len() {
        let c = bytes[i];
        if c == b'{' {
            // Find matching '}'.
            let Some(end_rel) = pattern[i + 1..].find('}') else {
                return Err(SitesError::InvalidUrl(format!(
                    "unterminated '{{' at byte {i} in pattern {pattern:?}"
                )));
            };
            let key = &pattern[i + 1..i + 1 + end_rel];
            let value = params
                .get(key)
                .ok_or_else(|| SitesError::MissingParam(key.to_string()))?;
            out.push_str(&urlencoding::encode(value));
            i = i + 1 + end_rel + 1;
        } else {
            // Find next '{' to copy a chunk efficiently.
            let next = pattern[i..]
                .find('{')
                .map(|n| i + n)
                .unwrap_or(pattern.len());
            out.push_str(&pattern[i..next]);
            i = next;
        }
    }

    Url::parse(&out).map_err(|e| SitesError::InvalidUrl(format!("{e}: {out}")))
}
