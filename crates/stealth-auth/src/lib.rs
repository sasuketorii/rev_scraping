// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9a (stealth-auth crate)
//! Encrypted authentication cookie storage for `rev_scraping`.
//!
//! `AuthStore::save` and `AuthStore::load` bind encrypted blobs to the profile
//! name and to an additional caller-provided AAD suffix. The complete AAD is
//! `rev_scraping:stealth-auth:v1:<profile>` when `aad_context` is empty, or
//! `rev_scraping:stealth-auth:v1:<profile>:<aad_context>` otherwise. Callers
//! can use the suffix to bind cookies to a proxy route or other replay context
//! without re-keying.
//!
//! Cross-process file locking is intentionally deferred to Phase 9b/9d. This
//! crate serializes writes within one process with a mutex and uses
//! write-then-rename plus `fsync` for crash-safe replacement.

#![forbid(unsafe_code)]

pub mod audit;
pub mod auth_aup;
pub mod crypto;
pub mod errors;
pub mod jar;
pub mod keystore;
pub mod redact;
pub mod storage;
pub mod types;

pub use errors::{AuthStoreError, Result};
pub use jar::{AuthCookieJar, AuthStore};
pub use redact::{
    install as install_auth_redaction_layer, install_auth_panic_hook, AuthRedactionLayer,
};
pub use types::{BrowserReplayMetadata, Cookie, ProfileMeta, ProfileStatus, SameSite};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_store_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<AuthStore>();
    }
}
