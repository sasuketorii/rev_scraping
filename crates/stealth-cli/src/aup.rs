// SPDX-License-Identifier: MIT
// Source: new file for rev_scraping v1.0.0 (Phase 2)
//! Acceptable-Use Policy (AUP) enforcement.
//!
//! Per plan §3.5 / §8 #13: every URL-accepting subcommand must verify the
//! target appears in `~/.rev_scraping/authorized.toml` before proceeding.
//!
//! Bypass paths:
//!   * Environment variable `REV_SCRAPING_AUP_ACK=<today_hash>` where
//!     `today_hash` is the first 8 hex chars of `SHA256("rev-scraping-aup:"
//!     + YYYYMMDD)` for the local-day. Only valid for the day it was minted.
//!   * `--i-have-authorization` CLI flag (logs a `warn` to stderr).

use chrono::Local;
use regex::Regex;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Result of running AUP enforcement.
#[derive(Debug, PartialEq, Eq)]
pub enum AupDecision {
    /// URL is allowed (either matched the allowlist, valid ack hash, or
    /// `--i-have-authorization`).
    Allowed { reason: AllowReason },
    /// URL must be rejected with exit code 1.
    Rejected { message: String },
}

#[derive(Debug, PartialEq, Eq)]
pub enum AllowReason {
    AllowlistMatch,
    AckHash,
    InlineFlag,
}

#[derive(Debug, Deserialize, Default)]
pub struct AuthorizedFile {
    #[serde(default)]
    pub targets: Vec<Target>,
}

#[derive(Debug, Deserialize)]
pub struct Target {
    pub url_pattern: String,
    #[serde(default)]
    pub auth_allowed: Option<bool>,
}

/// Path to the per-user allowlist.
pub fn default_allowlist_path() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".rev_scraping").join("authorized.toml"))
}

/// Load the TOML allowlist. Returns `Ok(None)` when the file is absent.
pub fn load_allowlist(path: &Path) -> anyhow::Result<Option<AuthorizedFile>> {
    if !path.exists() {
        return Ok(None);
    }
    let body = std::fs::read_to_string(path)?;
    let parsed: AuthorizedFile = toml::from_str(&body)?;
    Ok(Some(parsed))
}

/// Compute the deterministic ack hash for a given local-date string
/// (`YYYYMMDD`). Returns the first 8 lowercase hex chars of the SHA256.
pub fn ack_hash_for(date_yyyymmdd: &str) -> String {
    let mut h = Sha256::new();
    h.update(b"rev-scraping-aup:");
    h.update(date_yyyymmdd.as_bytes());
    let digest = h.finalize();
    let mut out = String::with_capacity(8);
    for b in &digest[..4] {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// Today's ack hash, computed from the local clock.
pub fn ack_hash_today() -> String {
    let today = Local::now().format("%Y%m%d").to_string();
    ack_hash_for(&today)
}

/// Pure decision function. Tests inject the allowlist, env var, and flag.
pub fn decide(
    url: &str,
    allowlist: Option<&AuthorizedFile>,
    env_ack: Option<&str>,
    have_authorization_flag: bool,
    today_hash: &str,
) -> AupDecision {
    if have_authorization_flag {
        return AupDecision::Allowed {
            reason: AllowReason::InlineFlag,
        };
    }
    if let Some(ack) = env_ack {
        if ack == today_hash {
            return AupDecision::Allowed {
                reason: AllowReason::AckHash,
            };
        }
        return AupDecision::Rejected {
            message: "REV_SCRAPING_AUP_ACK does not match today's hash".into(),
        };
    }
    let Some(list) = allowlist else {
        return AupDecision::Rejected {
            message: format!(
                "AUP allowlist not found at ~/.rev_scraping/authorized.toml; \
                 add a [[targets]] entry whose url_pattern matches {url:?} \
                 (or set REV_SCRAPING_AUP_ACK / --i-have-authorization)"
            ),
        };
    };
    for t in &list.targets {
        let _auth_allowed = t.auth_allowed;
        match Regex::new(&t.url_pattern) {
            Ok(re) if re.is_match(url) => {
                return AupDecision::Allowed {
                    reason: AllowReason::AllowlistMatch,
                };
            }
            Ok(_) => continue,
            Err(e) => {
                return AupDecision::Rejected {
                    message: format!("invalid url_pattern regex {:?}: {e}", t.url_pattern),
                };
            }
        }
    }
    AupDecision::Rejected {
        message: format!("URL {url:?} matched no authorized.toml pattern"),
    }
}

/// Convenience wrapper used by the subcommand layer.
pub fn enforce(url: &str, have_authorization_flag: bool) -> AupDecision {
    let path = default_allowlist_path();
    let list = match path.as_deref().map(load_allowlist) {
        Some(Ok(opt)) => opt,
        Some(Err(e)) => {
            return AupDecision::Rejected {
                message: format!("failed to read AUP allowlist: {e}"),
            };
        }
        None => None,
    };
    let env_ack = std::env::var("REV_SCRAPING_AUP_ACK").ok();
    decide(
        url,
        list.as_ref(),
        env_ack.as_deref(),
        have_authorization_flag,
        &ack_hash_today(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_toml(body: &str) -> tempfile::NamedTempFile {
        let mut f = tempfile::NamedTempFile::new().unwrap();
        f.write_all(body.as_bytes()).unwrap();
        f
    }

    #[test]
    fn test_aup_loads_authorized_toml() {
        let f = write_toml(
            r#"
[[targets]]
url_pattern = "^https://example\\.com/"
[[targets]]
url_pattern = "^https://test\\.local/"
"#,
        );
        let list = load_allowlist(f.path()).unwrap().expect("present");
        assert_eq!(list.targets.len(), 2);
        assert_eq!(list.targets[0].url_pattern, r"^https://example\.com/");
    }

    #[test]
    fn test_aup_rejects_non_matching_url() {
        let list = AuthorizedFile {
            targets: vec![Target {
                url_pattern: r"^https://example\.com/".into(),
                auth_allowed: None,
            }],
        };
        let d = decide(
            "https://evil.example.org/",
            Some(&list),
            None,
            false,
            "deadbeef",
        );
        assert!(matches!(d, AupDecision::Rejected { .. }));
    }

    #[test]
    fn test_aup_accepts_matching_url() {
        let list = AuthorizedFile {
            targets: vec![Target {
                url_pattern: r"^https://example\.com/".into(),
                auth_allowed: None,
            }],
        };
        let d = decide(
            "https://example.com/path",
            Some(&list),
            None,
            false,
            "deadbeef",
        );
        assert_eq!(
            d,
            AupDecision::Allowed {
                reason: AllowReason::AllowlistMatch
            }
        );
    }

    #[test]
    fn test_aup_ack_env_var_bypass_today() {
        let hash = ack_hash_for("20260101");
        let d = decide(
            "https://blocked.example.com/",
            None,
            Some(&hash),
            false,
            &hash,
        );
        assert_eq!(
            d,
            AupDecision::Allowed {
                reason: AllowReason::AckHash
            }
        );
    }

    #[test]
    fn test_aup_ack_env_var_rejects_wrong_hash() {
        let today = ack_hash_for("20260101");
        let yesterday = ack_hash_for("20251231");
        assert_ne!(today, yesterday);
        let d = decide(
            "https://blocked.example.com/",
            None,
            Some(&yesterday),
            false,
            &today,
        );
        assert!(matches!(d, AupDecision::Rejected { .. }));
    }

    #[test]
    fn test_inline_flag_bypasses_allowlist() {
        let d = decide("https://anything", None, None, true, "deadbeef");
        assert_eq!(
            d,
            AupDecision::Allowed {
                reason: AllowReason::InlineFlag
            }
        );
    }

    #[test]
    fn test_ack_hash_is_8_hex_chars() {
        let h = ack_hash_for("20260512");
        assert_eq!(h.len(), 8);
        assert!(h.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
