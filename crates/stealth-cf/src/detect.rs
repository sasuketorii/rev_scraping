// SPDX-License-Identifier: MIT
// Source: design adapted from Scrapling (BSD-3-Clause), https://github.com/D4Vinci/Scrapling
// No verbatim code copy; only the detection/click/polling algorithm pattern is adapted.

use crate::types::ChallengeType;
use regex::Regex;
use std::sync::OnceLock;

fn turnstile_script_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"(?is)<script[^>]+src\s*=\s*["'][^"']*challenges\.cloudflare\.com/turnstile/v[^"']*["']"#,
        )
        .expect("turnstile regex")
    })
}

fn interstitial_title_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?is)<title[^>]*>\s*Just a moment\.\.\.\s*</title>").expect("title regex")
    })
}

fn js_challenge_markers() -> &'static [&'static str] {
    &[
        "cf-mitigated",
        "cf-chl-bypass",
        "cf_chl_opt",
        "/cdn-cgi/challenge-platform/",
    ]
}

/// Classify the Cloudflare challenge that a page is presenting from raw HTML.
///
/// Heuristics (in priority order):
///   1. Turnstile widget script tag.
///   2. "Just a moment..." interstitial title.
///   3. Legacy JS challenge markers (`cf-mitigated`, `cf-chl-bypass`, ...).
pub fn detect_from_html(html: &str) -> ChallengeType {
    if turnstile_script_re().is_match(html) {
        return ChallengeType::Turnstile;
    }
    if interstitial_title_re().is_match(html) {
        return ChallengeType::Interstitial;
    }
    for marker in js_challenge_markers() {
        if html.contains(marker) {
            return ChallengeType::JsChallenge;
        }
    }
    ChallengeType::None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_turnstile_from_html_script() {
        let html = r#"
            <html><head>
              <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async></script>
            </head><body><div id="cf-turnstile"></div></body></html>
        "#;
        assert_eq!(detect_from_html(html), ChallengeType::Turnstile);
    }

    #[test]
    fn test_detect_interstitial_from_title() {
        let html =
            "<html><head><title>Just a moment...</title></head><body>Checking your browser</body></html>";
        assert_eq!(detect_from_html(html), ChallengeType::Interstitial);
    }

    #[test]
    fn test_detect_none_for_normal_page() {
        let html = "<html><head><title>Hello</title></head><body>Welcome</body></html>";
        assert_eq!(detect_from_html(html), ChallengeType::None);
    }

    #[test]
    fn test_detect_js_challenge_marker() {
        let html = r#"<html><body><meta name="cf-chl-bypass" content="/x"></body></html>"#;
        assert_eq!(detect_from_html(html), ChallengeType::JsChallenge);
    }
}
