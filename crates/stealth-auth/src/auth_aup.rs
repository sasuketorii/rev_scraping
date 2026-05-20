// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9b (rev-auth binary)
//! Minimal auth-specific AUP enforcement for `rev-auth`.
//!
//! This intentionally duplicates the tiny `authorized.toml` parse instead of
//! depending on `stealth-cli`, which is currently a binary crate.

use regex::Regex;
use serde::Deserialize;
use std::path::{Path, PathBuf};

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

#[derive(Debug, PartialEq, Eq)]
pub enum AuthAupDecision {
    Allowed,
    Rejected { message: String },
}

pub fn default_allowlist_path() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".rev_scraping").join("authorized.toml"))
}

pub fn load_allowlist(path: &Path) -> anyhow::Result<Option<AuthorizedFile>> {
    if !path.exists() {
        return Ok(None);
    }
    let body = std::fs::read_to_string(path)?;
    Ok(Some(toml::from_str(&body)?))
}

pub fn decide(
    domain: &str,
    login_url: &str,
    allowlist: Option<&AuthorizedFile>,
) -> AuthAupDecision {
    let Some(list) = allowlist else {
        return AuthAupDecision::Rejected {
            message: "AUP allowlist not found at ~/.rev_scraping/authorized.toml".to_string(),
        };
    };

    for target in &list.targets {
        let regex = match Regex::new(&target.url_pattern) {
            Ok(regex) => regex,
            Err(error) => {
                return AuthAupDecision::Rejected {
                    message: format!(
                        "invalid url_pattern regex {:?}: {error}",
                        target.url_pattern
                    ),
                };
            }
        };
        if regex.is_match(login_url) || regex.is_match(domain) {
            if target.auth_allowed.unwrap_or(false) {
                return AuthAupDecision::Allowed;
            }
            return AuthAupDecision::Rejected {
                message: format!("AUP target matched {domain:?} but auth_allowed is not true"),
            };
        }
    }

    AuthAupDecision::Rejected {
        message: format!("domain {domain:?} matched no authorized.toml pattern"),
    }
}

pub fn enforce(domain: &str, login_url: &str) -> AuthAupDecision {
    let path = default_allowlist_path();
    let allowlist = match path.as_deref().map(load_allowlist) {
        Some(Ok(allowlist)) => allowlist,
        Some(Err(error)) => {
            return AuthAupDecision::Rejected {
                message: format!("failed to read AUP allowlist: {error}"),
            };
        }
        None => None,
    };
    decide(domain, login_url, allowlist.as_ref())
}
