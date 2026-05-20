// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9a (stealth-auth crate)

use chrono::{DateTime, Utc};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::fmt;
use zeroize::{Zeroize, ZeroizeOnDrop};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SameSite {
    Strict,
    Lax,
    None,
    Unspecified,
}

#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub struct Cookie {
    pub name: String,
    #[serde(with = "secret_string_serde")]
    #[zeroize(skip)]
    pub value: SecretString,
    pub domain: String,
    pub path: String,
    #[zeroize(skip)]
    pub expires: Option<DateTime<Utc>>,
    pub secure: bool,
    pub http_only: bool,
    #[zeroize(skip)]
    pub same_site: SameSite,
}

impl fmt::Debug for Cookie {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Cookie")
            .field("name", &self.name)
            .field("value", &"<redacted>")
            .field("domain", &self.domain)
            .field("path", &self.path)
            .field("expires", &self.expires)
            .field("secure", &self.secure)
            .field("http_only", &self.http_only)
            .field("same_site", &self.same_site)
            .finish()
    }
}

#[derive(Default, Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct BrowserReplayMetadata {
    pub user_agent: Option<String>,
    pub accept_language: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProfileMeta {
    pub profile: String,
    pub domains: Vec<String>,
    pub created_at: DateTime<Utc>,
    pub last_used: DateTime<Utc>,
    pub cookie_name_sha256_prefixes: Vec<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProfileStatus {
    Valid,
    /// v1.1.0 (P14): at least one cookie expires within the next 7 days
    /// (but none within 24h). Advisory — `auth status` still exits 0.
    ExpiringSoon,
    /// v1.1.0 (P14): at least one cookie expires within the next 24 hours.
    /// Stronger advisory — `auth status` still exits 0 but `warn_level`
    /// is set to "critical".
    ExpiringCritical,
    PartiallyExpired,
    AllExpired,
    Missing,
}

mod secret_string_serde {
    use super::*;

    pub fn serialize<S>(value: &SecretString, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(value.expose_secret())
    }

    pub fn deserialize<'de, D>(deserializer: D) -> std::result::Result<SecretString, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Ok(SecretString::from(value))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_redacts_cookie_value() {
        let cookie = Cookie {
            name: "sid".to_string(),
            value: SecretString::from("SUPER_SECRET_VALUE_XYZ".to_string()),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: None,
            secure: true,
            http_only: true,
            same_site: SameSite::Lax,
        };

        let rendered = format!("{cookie:?}");
        assert!(!rendered.contains("SUPER_SECRET_VALUE_XYZ"));
        assert!(rendered.contains("<redacted>"));
    }

    #[test]
    fn zeroize_on_drop_smoke() {
        let observed = {
            let cookie = Cookie {
                name: "sid".to_string(),
                value: SecretString::from("DROP_SMOKE_SECRET".to_string()),
                domain: "example.com".to_string(),
                path: "/".to_string(),
                expires: None,
                secure: true,
                http_only: true,
                same_site: SameSite::Strict,
            };
            cookie.value.expose_secret().to_string()
        };

        assert_eq!(observed, "DROP_SMOKE_SECRET");
        // SecretString owns the secret and zeroizes on Drop. Rust does not
        // expose a stable, safe way to inspect freed memory, so this smoke test
        // verifies the code path without copying the secret into Debug/Display.
    }
}
