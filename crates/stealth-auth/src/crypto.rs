// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9a (stealth-auth crate)

use crate::errors::{AuthStoreError, Result};
use chacha20poly1305::aead::{Aead, Payload};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce};
use rand::{rngs::OsRng, RngCore};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

const MAGIC: &[u8; 8] = b"REVAUTH1";
const VERSION: u16 = 1;
const PROFILE_HASH_LEN: usize = 32;
const NONCE_LEN: usize = 24;
const HEADER_LEN: usize = 8 + 2 + PROFILE_HASH_LEN + NONCE_LEN;

#[derive(Debug, Clone)]
pub struct EncryptedJarEnvelopeV1 {
    pub profile_hash: [u8; PROFILE_HASH_LEN],
    pub nonce: [u8; NONCE_LEN],
    pub ciphertext: Vec<u8>,
}

pub fn aad(profile: &str, aad_context: &str) -> Vec<u8> {
    if aad_context.is_empty() {
        format!("rev_scraping:stealth-auth:v1:{profile}").into_bytes()
    } else {
        format!("rev_scraping:stealth-auth:v1:{profile}:{aad_context}").into_bytes()
    }
}

pub fn profile_hash(profile: &str) -> [u8; PROFILE_HASH_LEN] {
    Sha256::digest(profile.as_bytes()).into()
}

pub fn sha256_prefix_8(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    let mut out = String::with_capacity(8);
    for byte in &digest[..4] {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

pub fn encrypt(
    profile: &str,
    aad_context: &str,
    key: &[u8; 32],
    plaintext: &[u8],
) -> Result<Vec<u8>> {
    let cipher = XChaCha20Poly1305::new_from_slice(key)
        .map_err(|error| AuthStoreError::Crypto(error.to_string()))?;
    let mut nonce = [0_u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);
    let aad = aad(profile, aad_context);
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|error| AuthStoreError::Crypto(error.to_string()))?;
    encode(&EncryptedJarEnvelopeV1 {
        profile_hash: profile_hash(profile),
        nonce,
        ciphertext,
    })
}

pub fn decrypt(
    profile: &str,
    aad_context: &str,
    key: &[u8; 32],
    encoded: &[u8],
) -> Result<Zeroizing<Vec<u8>>> {
    let envelope = decode_for_profile(profile, encoded)?;
    let cipher = XChaCha20Poly1305::new_from_slice(key)
        .map_err(|error| AuthStoreError::Crypto(error.to_string()))?;
    let aad = aad(profile, aad_context);
    let plaintext = cipher
        .decrypt(
            XNonce::from_slice(&envelope.nonce),
            Payload {
                msg: &envelope.ciphertext,
                aad: &aad,
            },
        )
        .map_err(|_| AuthStoreError::BadKeyOrTamper)?;
    Ok(Zeroizing::new(plaintext))
}

pub fn decode_for_profile(profile: &str, encoded: &[u8]) -> Result<EncryptedJarEnvelopeV1> {
    let envelope = decode(encoded)?;
    if envelope.profile_hash != profile_hash(profile) {
        return Err(AuthStoreError::ProfileHashMismatch);
    }
    Ok(envelope)
}

fn encode(envelope: &EncryptedJarEnvelopeV1) -> Result<Vec<u8>> {
    let ciphertext_len = envelope.ciphertext.len();
    let mut encoded = Vec::with_capacity(HEADER_LEN + ciphertext_len);
    encoded.extend_from_slice(MAGIC);
    encoded.extend_from_slice(&VERSION.to_le_bytes());
    encoded.extend_from_slice(&envelope.profile_hash);
    encoded.extend_from_slice(&envelope.nonce);
    encoded.extend_from_slice(&envelope.ciphertext);
    Ok(encoded)
}

fn decode(encoded: &[u8]) -> Result<EncryptedJarEnvelopeV1> {
    if encoded.len() < HEADER_LEN {
        return Err(AuthStoreError::BadKeyOrTamper);
    }
    if &encoded[..8] != MAGIC {
        return Err(AuthStoreError::BadKeyOrTamper);
    }
    let version = u16::from_le_bytes([encoded[8], encoded[9]]);
    if version != VERSION {
        return Err(AuthStoreError::BadKeyOrTamper);
    }
    let mut profile_hash = [0_u8; PROFILE_HASH_LEN];
    profile_hash.copy_from_slice(&encoded[10..42]);
    let mut nonce = [0_u8; NONCE_LEN];
    nonce.copy_from_slice(&encoded[42..66]);
    Ok(EncryptedJarEnvelopeV1 {
        profile_hash,
        nonce,
        ciphertext: encoded[HEADER_LEN..].to_vec(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let key = [7_u8; 32];
        let blob = encrypt("work", "route-a", &key, b"hello").unwrap();
        let plaintext = decrypt("work", "route-a", &key, &blob).unwrap();
        assert_eq!(&*plaintext, b"hello");
    }

    #[test]
    fn wrong_aad_fails() {
        let key = [7_u8; 32];
        let blob = encrypt("work", "route-a", &key, b"hello").unwrap();
        let err = decrypt("work", "route-b", &key, &blob).unwrap_err();
        assert!(matches!(err, AuthStoreError::BadKeyOrTamper));
    }

    #[test]
    fn wrong_key_fails() {
        let key = [7_u8; 32];
        let wrong_key = [8_u8; 32];
        let blob = encrypt("work", "route-a", &key, b"hello").unwrap();
        let err = decrypt("work", "route-a", &wrong_key, &blob).unwrap_err();
        assert!(matches!(err, AuthStoreError::BadKeyOrTamper));
    }

    #[test]
    fn profile_hash_mismatch_fails() {
        let key = [7_u8; 32];
        let blob = encrypt("work", "route-a", &key, b"hello").unwrap();
        let err = decrypt("personal", "route-a", &key, &blob).unwrap_err();
        assert!(matches!(err, AuthStoreError::ProfileHashMismatch));
    }
}
