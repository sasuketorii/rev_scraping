// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.2.0 (P5.1)

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum ConfigSchemaVersion {
    V1 = 1,
}

pub fn default_schema_version_v1() -> u32 {
    ConfigSchemaVersion::V1 as u32
}

pub trait KnownConfig {
    const SCHEMA_VERSION_FIELD: &'static str;

    fn supported_versions() -> &'static [u32];

    fn known_fields() -> &'static [&'static str];
}

/// Strict mirror of `aup::AuthorizedFile` used solely for config validation.
///
/// `aup::AuthorizedFile` is kept permissive at load time to preserve the
/// v1.1.0 runtime contract; this `AuthorizedSchema` adds `deny_unknown_fields`
/// plus a schema_version pin so `rev-stealth config validate authorized` can
/// give strict feedback without breaking existing loaders.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct AuthorizedSchema {
    #[serde(default = "default_schema_version_v1")]
    pub schema_version: u32,
    #[serde(default)]
    pub targets: Vec<AuthorizedTargetSchema>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct AuthorizedTargetSchema {
    pub url_pattern: String,
    #[serde(default)]
    pub auth_allowed: Option<bool>,
}

impl KnownConfig for AuthorizedSchema {
    const SCHEMA_VERSION_FIELD: &'static str = "schema_version";

    fn supported_versions() -> &'static [u32] {
        &[1]
    }

    fn known_fields() -> &'static [&'static str] {
        &["schema_version", "targets", "url_pattern", "auth_allowed"]
    }
}

impl AuthorizedSchema {
    /// Validate each `url_pattern` compiles as a regex. Returned errors carry
    /// the offending pattern and the underlying regex error so the validator
    /// can surface a `ValidationIssue` with file path context.
    pub fn validate_patterns(&self) -> Result<(), Vec<InvalidPattern>> {
        let mut errors = Vec::new();
        for (idx, t) in self.targets.iter().enumerate() {
            if let Err(e) = regex::Regex::new(&t.url_pattern) {
                errors.push(InvalidPattern {
                    index: idx,
                    pattern: t.url_pattern.clone(),
                    error: e.to_string(),
                });
            }
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors)
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvalidPattern {
    pub index: usize,
    pub pattern: String,
    pub error: String,
}
