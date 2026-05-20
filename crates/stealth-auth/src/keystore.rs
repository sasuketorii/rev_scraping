// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9a (stealth-auth crate)

use crate::errors::{AuthStoreError, Result};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use rand::{rngs::OsRng, RngCore};
use secrecy::{ExposeSecret, SecretString};
use zeroize::Zeroizing;

const SERVICE_NAME: &str = "rev_scraping.stealth_auth";
const KEY_LEN: usize = 32;
const SALT_LEN: usize = 16;
const ARGON2_M_COST_KIB: u32 = 64 * 1024;
const ARGON2_T_COST: u32 = 3;
const ARGON2_P_COST: u32 = 1;

#[derive(Clone)]
pub enum KeySource {
    Keyring,
    Passphrase(SecretString),
}

impl KeySource {
    pub fn ensure_available(&self) -> Result<()> {
        match self {
            KeySource::Keyring => ensure_keyring_available(),
            KeySource::Passphrase(_) => Ok(()),
        }
    }

    pub fn key_for_profile(
        &self,
        profile: &str,
        salt: Option<&[u8]>,
    ) -> Result<Zeroizing<[u8; KEY_LEN]>> {
        match self {
            KeySource::Keyring => keyring_key(profile),
            KeySource::Passphrase(passphrase) => {
                let salt = salt.ok_or_else(|| {
                    AuthStoreError::Crypto("passphrase salt missing from metadata".to_string())
                })?;
                derive_passphrase_key(passphrase, salt)
            }
        }
    }

    pub fn passphrase_salt_for_save(&self, existing: Option<&str>) -> Result<Option<String>> {
        match self {
            KeySource::Keyring => Ok(None),
            KeySource::Passphrase(_) => {
                if let Some(existing) = existing {
                    return Ok(Some(existing.to_string()));
                }
                let mut salt = [0_u8; SALT_LEN];
                OsRng.fill_bytes(&mut salt);
                Ok(Some(STANDARD.encode(salt)))
            }
        }
    }

    pub fn delete_profile_key(&self, profile: &str) {
        if matches!(self, KeySource::Keyring) {
            let _ = delete_keyring_key(profile);
        }
    }
}

pub fn decode_salt(encoded: Option<&str>) -> Result<Option<Vec<u8>>> {
    encoded
        .map(|value| {
            STANDARD.decode(value).map_err(|error| {
                AuthStoreError::Crypto(format!("invalid passphrase salt: {error}"))
            })
        })
        .transpose()
}

pub fn derive_passphrase_key(
    passphrase: &SecretString,
    salt: &[u8],
) -> Result<Zeroizing<[u8; KEY_LEN]>> {
    if salt.len() != SALT_LEN {
        return Err(AuthStoreError::Crypto(format!(
            "passphrase salt must be {SALT_LEN} bytes"
        )));
    }
    let params = Params::new(
        ARGON2_M_COST_KIB,
        ARGON2_T_COST,
        ARGON2_P_COST,
        Some(KEY_LEN),
    )
    .map_err(|error| AuthStoreError::Crypto(error.to_string()))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut out = Zeroizing::new([0_u8; KEY_LEN]);
    argon2
        .hash_password_into(passphrase.expose_secret().as_bytes(), salt, &mut *out)
        .map_err(|error| AuthStoreError::Crypto(error.to_string()))?;
    Ok(out)
}

#[cfg(not(feature = "passphrase-only"))]
fn keyring_key(profile: &str) -> Result<Zeroizing<[u8; KEY_LEN]>> {
    let entry = keyring::Entry::new(SERVICE_NAME, &account(profile))
        .map_err(|error| AuthStoreError::KeyringUnavailable(error.to_string()))?;
    match entry.get_password() {
        Ok(encoded) => decode_keyring_key(&encoded),
        Err(keyring::Error::NoEntry) => {
            let mut key = [0_u8; KEY_LEN];
            OsRng.fill_bytes(&mut key);
            entry
                .set_password(&STANDARD.encode(key))
                .map_err(|error| AuthStoreError::KeyringUnavailable(error.to_string()))?;
            Ok(Zeroizing::new(key))
        }
        Err(error) => Err(AuthStoreError::KeyringUnavailable(error.to_string())),
    }
}

#[cfg(feature = "passphrase-only")]
fn keyring_key(_profile: &str) -> Result<Zeroizing<[u8; KEY_LEN]>> {
    Err(AuthStoreError::KeyringUnavailable(
        "crate built with passphrase-only feature".to_string(),
    ))
}

#[cfg(not(feature = "passphrase-only"))]
fn delete_keyring_key(profile: &str) -> Result<()> {
    let entry = keyring::Entry::new(SERVICE_NAME, &account(profile))
        .map_err(|error| AuthStoreError::KeyringUnavailable(error.to_string()))?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(AuthStoreError::KeyringUnavailable(error.to_string())),
    }
}

#[cfg(feature = "passphrase-only")]
fn delete_keyring_key(_profile: &str) -> Result<()> {
    Ok(())
}

fn decode_keyring_key(encoded: &str) -> Result<Zeroizing<[u8; KEY_LEN]>> {
    let decoded = STANDARD
        .decode(encoded)
        .map_err(|error| AuthStoreError::KeyringUnavailable(error.to_string()))?;
    if decoded.len() != KEY_LEN {
        return Err(AuthStoreError::KeyringUnavailable(format!(
            "stored key must be {KEY_LEN} bytes"
        )));
    }
    let mut key = [0_u8; KEY_LEN];
    key.copy_from_slice(&decoded);
    Ok(Zeroizing::new(key))
}

fn account(profile: &str) -> String {
    format!("cookie-jar:{profile}")
}

#[cfg(not(feature = "passphrase-only"))]
fn ensure_keyring_available() -> Result<()> {
    let entry = keyring::Entry::new(SERVICE_NAME, "cookie-jar:__probe__")
        .map_err(|error| AuthStoreError::KeyringUnavailable(error.to_string()))?;
    match entry.get_password() {
        Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(AuthStoreError::KeyringUnavailable(error.to_string())),
    }
}

#[cfg(feature = "passphrase-only")]
fn ensure_keyring_available() -> Result<()> {
    Err(AuthStoreError::KeyringUnavailable(
        "crate built with passphrase-only feature".to_string(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn argon2id_is_deterministic_for_same_salt() {
        let passphrase = SecretString::from("correct horse battery staple".to_string());
        let salt = [9_u8; SALT_LEN];
        let a = derive_passphrase_key(&passphrase, &salt).unwrap();
        let b = derive_passphrase_key(&passphrase, &salt).unwrap();
        assert_eq!(&*a, &*b);
    }

    #[test]
    fn argon2id_changes_with_salt() {
        let passphrase = SecretString::from("correct horse battery staple".to_string());
        let a = derive_passphrase_key(&passphrase, &[1_u8; SALT_LEN]).unwrap();
        let b = derive_passphrase_key(&passphrase, &[2_u8; SALT_LEN]).unwrap();
        assert_ne!(&*a, &*b);
    }
}
