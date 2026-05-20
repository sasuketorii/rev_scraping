// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9a (stealth-auth crate)

use chrono::{Duration, Utc};
use secrecy::{ExposeSecret, SecretString};
use std::fs;
use std::sync::{Arc, Mutex};
use stealth_auth::errors::AuthStoreError;
use stealth_auth::storage;
use stealth_auth::{AuthRedactionLayer, AuthStore, Cookie, ProfileStatus, SameSite};
use tracing_subscriber::prelude::*;

fn store(dir: &std::path::Path) -> AuthStore {
    AuthStore::open_with_passphrase(dir, SecretString::from("test passphrase".to_string())).unwrap()
}

fn cookie(name: &str, value: &str, expires: Option<chrono::DateTime<Utc>>) -> Cookie {
    Cookie {
        name: name.to_string(),
        value: SecretString::from(value.to_string()),
        domain: "example.com".to_string(),
        path: "/".to_string(),
        expires,
        secure: true,
        http_only: true,
        same_site: SameSite::Lax,
    }
}

#[test]
fn encrypt_decrypt_roundtrip() {
    let temp = tempfile::tempdir().unwrap();
    let store = store(temp.path());
    store
        .save(
            "work",
            &[cookie("sid", "SUPER_SECRET_VALUE_XYZ", None)],
            "proxy-a",
        )
        .unwrap();

    let loaded = store.load("work", "proxy-a").unwrap();
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].name, "sid");
    assert_eq!(loaded[0].value.expose_secret(), "SUPER_SECRET_VALUE_XYZ");
}

#[test]
fn wrong_aad_fails() {
    let temp = tempfile::tempdir().unwrap();
    let store = store(temp.path());
    store
        .save(
            "work",
            &[cookie("sid", "SUPER_SECRET_VALUE_XYZ", None)],
            "a",
        )
        .unwrap();

    let err = store.load("work", "b").unwrap_err();
    assert!(matches!(err, AuthStoreError::BadKeyOrTamper));
}

#[test]
fn wrong_key_fails() {
    let temp = tempfile::tempdir().unwrap();
    let store = store(temp.path());
    store
        .save(
            "work",
            &[cookie("sid", "SUPER_SECRET_VALUE_XYZ", None)],
            "ctx",
        )
        .unwrap();

    let wrong_store = AuthStore::open_with_passphrase(
        temp.path(),
        SecretString::from("wrong passphrase".to_string()),
    )
    .unwrap();
    let err = wrong_store.load("work", "ctx").unwrap_err();
    assert!(matches!(err, AuthStoreError::BadKeyOrTamper));
}

#[test]
fn tampered_ciphertext_fails() {
    let temp = tempfile::tempdir().unwrap();
    let store = store(temp.path());
    store
        .save(
            "work",
            &[cookie("sid", "SUPER_SECRET_VALUE_XYZ", None)],
            "ctx",
        )
        .unwrap();

    let path = storage::enc_path(temp.path(), "work");
    let mut blob = fs::read(&path).unwrap();
    let last = blob.last_mut().unwrap();
    *last ^= 0x01;
    fs::write(&path, blob).unwrap();

    let err = store.load("work", "ctx").unwrap_err();
    assert!(matches!(err, AuthStoreError::BadKeyOrTamper));
}

#[test]
fn profile_hash_mismatch_fails() {
    let temp = tempfile::tempdir().unwrap();
    let store = store(temp.path());
    store
        .save(
            "work",
            &[cookie("sid", "SUPER_SECRET_VALUE_XYZ", None)],
            "ctx",
        )
        .unwrap();
    fs::rename(
        storage::enc_path(temp.path(), "work"),
        storage::enc_path(temp.path(), "personal"),
    )
    .unwrap();

    let err = store.load("personal", "ctx").unwrap_err();
    assert!(matches!(err, AuthStoreError::ProfileHashMismatch));
}

#[cfg(unix)]
#[test]
fn file_permissions_0600() {
    use std::os::unix::fs::PermissionsExt;

    let temp = tempfile::tempdir().unwrap();
    let store = store(temp.path());
    store
        .save(
            "work",
            &[cookie("sid", "SUPER_SECRET_VALUE_XYZ", None)],
            "ctx",
        )
        .unwrap();

    let mode = fs::metadata(storage::enc_path(temp.path(), "work"))
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o600);
}

#[cfg(unix)]
#[test]
fn dir_permissions_0700() {
    use std::os::unix::fs::PermissionsExt;

    let temp = tempfile::tempdir().unwrap();
    let _store = store(temp.path());
    let mode = fs::metadata(temp.path()).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o700);
}

#[test]
fn list_profiles_no_value_leak() {
    let temp = tempfile::tempdir().unwrap();
    let store = store(temp.path());
    store
        .save(
            "work",
            &[cookie("sid", "SUPER_SECRET_VALUE_XYZ", None)],
            "ctx",
        )
        .unwrap();

    let profiles = store.list_profiles().unwrap();
    let serialized = serde_json::to_string(&profiles).unwrap();
    assert!(serialized.contains("work"));
    assert!(!serialized.contains("SUPER_SECRET_VALUE_XYZ"));
}

#[test]
fn expired_filter_status() {
    let temp = tempfile::tempdir().unwrap();
    let store = store(temp.path());
    let past = Utc::now() - Duration::hours(1);
    let future = Utc::now() + Duration::hours(1);

    store
        .save(
            "work",
            &[cookie("sid", "SUPER_SECRET_VALUE_XYZ", Some(past))],
            "ctx",
        )
        .unwrap();
    assert_eq!(store.status("work"), ProfileStatus::AllExpired);

    store
        .save(
            "work",
            &[
                cookie("sid", "SUPER_SECRET_VALUE_XYZ", Some(past)),
                cookie("pref", "SECOND_SECRET_VALUE_XYZ", Some(future)),
            ],
            "ctx",
        )
        .unwrap();
    assert_eq!(store.status("work"), ProfileStatus::PartiallyExpired);
}

#[test]
fn shred_on_delete() {
    let temp = tempfile::tempdir().unwrap();
    let store = store(temp.path());
    store
        .save(
            "work",
            &[cookie("sid", "SUPER_SECRET_VALUE_XYZ", None)],
            "ctx",
        )
        .unwrap();
    store.delete("work").unwrap();

    assert!(!storage::enc_path(temp.path(), "work").exists());
    assert!(!storage::meta_path(temp.path(), "work").exists());
}

#[test]
fn debug_redacts_cookie_value() {
    let rendered = format!("{:?}", cookie("sid", "SUPER_SECRET_VALUE_XYZ", None));
    assert!(!rendered.contains("SUPER_SECRET_VALUE_XYZ"));
    assert!(rendered.contains("<redacted>"));
}

#[test]
fn tracing_redaction_layer_redacts() {
    let captured = Arc::new(Mutex::new(String::new()));
    let captured_clone = Arc::clone(&captured);
    let subscriber =
        tracing_subscriber::registry().with(AuthRedactionLayer::with_sink(move |line| {
            captured_clone.lock().unwrap().push_str(&line);
        }));

    tracing::subscriber::with_default(subscriber, || {
        tracing::info!(
            cookie = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890=",
            secret = "SUPER_SECRET_VALUE_XYZ",
            "auth event"
        );
    });

    let output = captured.lock().unwrap().clone();
    assert!(!output.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890="));
    assert!(!output.contains("SUPER_SECRET_VALUE_XYZ"));
    assert!(output.contains("<redacted>"));
}
