// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9a (stealth-auth crate)

use stealth_core::StealthError;

pub type Result<T> = std::result::Result<T, AuthStoreError>;

#[derive(thiserror::Error, Debug)]
pub enum AuthStoreError {
    #[error("profile not found: {0}")]
    NotFound(String),
    #[error("decryption failed (bad key or tampered blob)")]
    BadKeyOrTamper,
    #[error("profile hash mismatch (file renamed?)")]
    ProfileHashMismatch,
    #[error("keyring unavailable: {0}")]
    KeyringUnavailable(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("serde: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("crypto: {0}")]
    Crypto(String),
}

impl From<AuthStoreError> for StealthError {
    fn from(value: AuthStoreError) -> Self {
        match value {
            AuthStoreError::NotFound(profile) => {
                StealthError::AuthExpired(format!("profile not found: {profile}"))
            }
            AuthStoreError::KeyringUnavailable(message) => StealthError::Permanent(format!(
                "keyring unavailable; pass passphrase or enable keyring: {message}"
            )),
            AuthStoreError::Io(error) => StealthError::Permanent(format!("auth store io: {error}")),
            AuthStoreError::Serde(error) => {
                StealthError::Permanent(format!("auth store metadata: {error}"))
            }
            other @ AuthStoreError::BadKeyOrTamper
            | other @ AuthStoreError::ProfileHashMismatch
            | other @ AuthStoreError::Crypto(_) => StealthError::Permanent(other.to_string()),
        }
    }
}
