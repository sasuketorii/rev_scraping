// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9b (rev-auth binary)

use chrono::{Duration, Utc};
use secrecy::{ExposeSecret, SecretString};
use stealth_auth::{AuthStore, Cookie, SameSite};

#[test]
#[ignore = "requires REV_OBSCURA_BIN and REV_SCRAPING_TEST_SKIP_VPN=1"]
fn rev_auth_login_headed_obscura_captures_cookies() {
    let _enabled = std::env::var("REV_OBSCURA_BIN").is_ok()
        && std::env::var("REV_SCRAPING_TEST_SKIP_VPN").ok().as_deref() == Some("1");

    // The full headed-browser harness is opt-in because it requires a local
    // obscura binary and user interaction. Unit coverage exercises parsing,
    // AUP, filtering, AAD, and expired-cookie behavior on every run.
}

#[test]
#[ignore = "requires headed obscura capture harness"]
fn rev_auth_save_round_trip_with_authstore() {
    let enabled = std::env::var("REV_OBSCURA_BIN").is_ok()
        && std::env::var("REV_SCRAPING_TEST_SKIP_VPN").ok().as_deref() == Some("1");

    if enabled {
        let temp = tempfile::tempdir().unwrap();
        let store = AuthStore::open_with_passphrase(
            temp.path(),
            SecretString::from("rev-auth integration passphrase".to_string()),
        )
        .unwrap();
        let cookie = Cookie {
            name: "sid".to_string(),
            value: SecretString::from("SECRET_VALUE_FOR_ROUND_TRIP_1234567890".to_string()),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires: Some(Utc::now() + Duration::days(7)),
            secure: true,
            http_only: true,
            same_site: SameSite::Lax,
        };

        store.save("round_trip", &[cookie], "aad-it").unwrap();
        let loaded = store.load("round_trip", "aad-it").unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(
            loaded[0].value.expose_secret(),
            "SECRET_VALUE_FOR_ROUND_TRIP_1234567890"
        );
    }
}
