// SPDX-License-Identifier: MIT
// Source: rev_scraping Phase 9a (stealth-auth crate)

use crate::crypto;
use crate::errors::{AuthStoreError, Result};
use crate::keystore::{decode_salt, KeySource};
use crate::storage;
use crate::types::{BrowserReplayMetadata, Cookie, ProfileMeta, ProfileStatus};
use chrono::{DateTime, Utc};
use parking_lot::Mutex as ParkingMutex;
use publicsuffix::{List as PublicSuffixList, Psl};
use reqwest::header::HeaderValue;
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex as StdMutex;
use zeroize::Zeroizing;

pub struct AuthStore {
    dir: PathBuf,
    key_source: KeySource,
    write_lock: StdMutex<()>,
}

pub struct AuthCookieJar {
    inner: ParkingMutex<HashMap<String, Vec<Cookie>>>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct DiskProfileMeta {
    profile: String,
    domains: Vec<String>,
    created_at: DateTime<Utc>,
    last_used: DateTime<Utc>,
    cookie_name_sha256_prefixes: Vec<String>,
    cookie_expires: Vec<Option<DateTime<Utc>>>,
    passphrase_salt_b64: Option<String>,
    #[serde(default)]
    browser_replay: Option<BrowserReplayMetadata>,
}

impl AuthStore {
    pub fn open(dir: &Path) -> Result<Self> {
        Self::open_with_key_source(dir, KeySource::Keyring)
    }

    pub fn open_with_passphrase(dir: &Path, passphrase: SecretString) -> Result<Self> {
        Self::open_with_key_source(dir, KeySource::Passphrase(passphrase))
    }

    pub fn save(&self, profile: &str, cookies: &[Cookie], aad_context: &str) -> Result<()> {
        self.save_inner(profile, cookies, aad_context, None)
    }

    pub fn save_with_browser_replay(
        &self,
        profile: &str,
        cookies: &[Cookie],
        aad_context: &str,
        replay: BrowserReplayMetadata,
    ) -> Result<()> {
        self.save_inner(profile, cookies, aad_context, Some(replay))
    }

    pub fn browser_replay_metadata(&self, profile: &str) -> Result<Option<BrowserReplayMetadata>> {
        validate_profile(profile)?;
        self.read_disk_meta(profile).map(|meta| meta.browser_replay)
    }

    fn save_inner(
        &self,
        profile: &str,
        cookies: &[Cookie],
        aad_context: &str,
        replay: Option<BrowserReplayMetadata>,
    ) -> Result<()> {
        validate_profile(profile)?;
        // PHASE9B-TODO: replace the in-process mutex with cross-process file
        // locking before CLI/browser processes share the same auth directory.
        let _guard = self.write_lock.lock().map_err(|_| {
            AuthStoreError::Crypto("auth store write mutex was poisoned".to_string())
        })?;

        let existing = self.read_disk_meta(profile).ok();
        let salt_b64 = self.key_source.passphrase_salt_for_save(
            existing
                .as_ref()
                .and_then(|meta| meta.passphrase_salt_b64.as_deref()),
        )?;
        let salt = decode_salt(salt_b64.as_deref())?;
        let key = self.key_source.key_for_profile(profile, salt.as_deref())?;
        let plaintext = Zeroizing::new(serde_json::to_vec(cookies)?);
        let encrypted = crypto::encrypt(profile, aad_context, &key, plaintext.as_slice())?;

        storage::rotate_existing_to_trash(&self.dir, profile)?;
        storage::atomic_write(&storage::enc_path(&self.dir, profile), &encrypted)?;

        let now = Utc::now();
        let browser_replay = replay.or_else(|| {
            existing
                .as_ref()
                .and_then(|meta| meta.browser_replay.clone())
        });
        let meta = build_meta(
            profile,
            cookies,
            existing.as_ref(),
            salt_b64,
            browser_replay,
            now,
        );
        let meta_json = serde_json::to_vec_pretty(&meta)?;
        storage::atomic_write(&storage::meta_path(&self.dir, profile), &meta_json)?;
        Ok(())
    }

    pub fn load(&self, profile: &str, aad_context: &str) -> Result<Vec<Cookie>> {
        validate_profile(profile)?;
        let enc_path = storage::enc_path(&self.dir, profile);
        if !enc_path.exists() {
            return Err(AuthStoreError::NotFound(profile.to_string()));
        }
        let encrypted = fs::read(&enc_path)?;
        crypto::decode_for_profile(profile, &encrypted)?;

        let meta = self.read_disk_meta(profile).ok();
        let salt = decode_salt(
            meta.as_ref()
                .and_then(|meta| meta.passphrase_salt_b64.as_deref()),
        )?;
        let key = self.key_source.key_for_profile(profile, salt.as_deref())?;
        let plaintext = crypto::decrypt(profile, aad_context, &key, &encrypted)?;
        serde_json::from_slice::<Vec<Cookie>>(plaintext.as_slice()).map_err(AuthStoreError::from)
    }

    pub fn list_profiles(&self) -> Result<Vec<ProfileMeta>> {
        let mut profiles = Vec::new();
        for entry in fs::read_dir(&self.dir)? {
            let entry = entry?;
            let path = entry.path();
            let Some(file_name) = path.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            if !file_name.ends_with(".meta.json") {
                continue;
            }
            let meta = read_meta_path(&path)?;
            profiles.push(meta.into_public());
        }
        profiles.sort_by(|a, b| a.profile.cmp(&b.profile));
        Ok(profiles)
    }

    pub fn delete(&self, profile: &str) -> Result<()> {
        validate_profile(profile)?;
        let _guard = self.write_lock.lock().map_err(|_| {
            AuthStoreError::Crypto("auth store write mutex was poisoned".to_string())
        })?;
        storage::shred_delete(&storage::enc_path(&self.dir, profile))?;
        storage::shred_delete(&storage::meta_path(&self.dir, profile))?;
        self.key_source.delete_profile_key(profile);
        Ok(())
    }

    pub fn status(&self, profile: &str) -> ProfileStatus {
        if validate_profile(profile).is_err() {
            return ProfileStatus::Missing;
        }
        let Ok(meta) = self.read_disk_meta(profile) else {
            return ProfileStatus::Missing;
        };
        classify_status(&meta.cookie_expires, Utc::now())
    }

    fn open_with_key_source(dir: &Path, key_source: KeySource) -> Result<Self> {
        storage::ensure_auth_dir(dir)?;
        key_source.ensure_available()?;
        Ok(Self {
            dir: dir.to_path_buf(),
            key_source,
            write_lock: StdMutex::new(()),
        })
    }

    fn read_disk_meta(&self, profile: &str) -> Result<DiskProfileMeta> {
        read_meta_path(&storage::meta_path(&self.dir, profile))
    }
}

impl AuthCookieJar {
    pub fn from_store(store: &AuthStore, profile: &str, aad_context: &str) -> Result<Self> {
        store
            .load(profile, aad_context)
            .map(AuthCookieJar::from_cookies)
    }

    pub fn from_cookies(cookies: Vec<Cookie>) -> Self {
        let mut grouped: HashMap<String, Vec<Cookie>> = HashMap::new();
        for cookie in cookies {
            let key = normalize_domain(&cookie.domain);
            grouped.entry(key).or_default().push(cookie);
        }
        Self {
            inner: ParkingMutex::new(grouped),
        }
    }

    pub fn cookie_count(&self) -> usize {
        self.inner.lock().values().map(Vec::len).sum()
    }
}

impl reqwest::cookie::CookieStore for AuthCookieJar {
    fn set_cookies(
        &self,
        _cookie_headers: &mut dyn Iterator<Item = &HeaderValue>,
        _url: &url::Url,
    ) {
        // PHASE9-FUTURE: optional persist-set-cookie overlay belongs here.
    }

    fn cookies(&self, url: &url::Url) -> Option<HeaderValue> {
        let now = Utc::now();
        let mut pairs = Vec::new();
        for cookies in self.inner.lock().values() {
            for cookie in cookies {
                if !cookie_matches_url(cookie, url, now) {
                    continue;
                }
                let mut pair = String::with_capacity(cookie.name.len() + 1);
                pair.push_str(&cookie.name);
                pair.push('=');
                pair.push_str(cookie.value.expose_secret());
                pairs.push(pair);
            }
        }
        if pairs.is_empty() {
            return None;
        }
        HeaderValue::from_str(&pairs.join("; ")).ok()
    }
}

impl DiskProfileMeta {
    fn into_public(self) -> ProfileMeta {
        ProfileMeta {
            profile: self.profile,
            domains: self.domains,
            created_at: self.created_at,
            last_used: self.last_used,
            cookie_name_sha256_prefixes: self.cookie_name_sha256_prefixes,
        }
    }
}

fn read_meta_path(path: &Path) -> Result<DiskProfileMeta> {
    let bytes = fs::read(path)?;
    serde_json::from_slice(&bytes).map_err(AuthStoreError::from)
}

fn build_meta(
    profile: &str,
    cookies: &[Cookie],
    existing: Option<&DiskProfileMeta>,
    passphrase_salt_b64: Option<String>,
    browser_replay: Option<BrowserReplayMetadata>,
    now: DateTime<Utc>,
) -> DiskProfileMeta {
    let mut domains = BTreeSet::new();
    let mut prefixes = BTreeSet::new();
    let mut expires = Vec::with_capacity(cookies.len());
    for cookie in cookies {
        domains.insert(cookie.domain.clone());
        prefixes.insert(crypto::sha256_prefix_8(&cookie.name));
        expires.push(cookie.expires);
    }
    DiskProfileMeta {
        profile: profile.to_string(),
        domains: domains.into_iter().collect(),
        created_at: existing.map_or(now, |meta| meta.created_at),
        last_used: now,
        cookie_name_sha256_prefixes: prefixes.into_iter().collect(),
        cookie_expires: expires,
        passphrase_salt_b64,
        browser_replay,
    }
}

fn normalize_domain(domain: &str) -> String {
    domain
        .trim()
        .trim_start_matches('.')
        .trim_end_matches('.')
        .to_ascii_lowercase()
}

fn cookie_matches_url(cookie: &Cookie, url: &url::Url, now: DateTime<Utc>) -> bool {
    if cookie.expires.is_some_and(|expires| expires <= now) {
        return false;
    }
    if cookie.secure && url.scheme() != "https" {
        return false;
    }
    let Some(host) = url.host_str().map(normalize_domain) else {
        return false;
    };
    let cookie_domain = normalize_domain(&cookie.domain);
    if cookie_domain.is_empty() || !domain_matches(&host, &cookie_domain) {
        return false;
    }
    let request_path = url.path();
    let cookie_path = if cookie.path.is_empty() {
        "/"
    } else {
        cookie.path.as_str()
    };
    request_path == cookie_path
        || (request_path.starts_with(cookie_path)
            && (cookie_path.ends_with('/')
                || request_path
                    .as_bytes()
                    .get(cookie_path.len())
                    .is_some_and(|b| *b == b'/')))
}

fn domain_matches(host: &str, cookie_domain: &str) -> bool {
    if host == cookie_domain {
        return true;
    }
    let psl = PublicSuffixList::new();
    if let (Some(host_reg), Some(cookie_reg)) = (
        psl.domain(host.as_bytes()),
        psl.domain(cookie_domain.as_bytes()),
    ) {
        if host_reg.as_bytes() != cookie_reg.as_bytes() {
            return false;
        }
    }
    host.ends_with(&format!(".{cookie_domain}"))
}

fn classify_status(expires: &[Option<DateTime<Utc>>], now: DateTime<Utc>) -> ProfileStatus {
    if expires.is_empty() {
        return ProfileStatus::Valid;
    }
    let expired_count = expires
        .iter()
        .filter(|expires| expires.is_some_and(|expires| expires <= now))
        .count();
    if expired_count == expires.len() {
        return ProfileStatus::AllExpired;
    }
    if expired_count > 0 {
        return ProfileStatus::PartiallyExpired;
    }
    // v1.1.0 (P14): all live, but warn if any expires within the
    // advisory window. 24h takes precedence over 7d.
    let soon_24h = chrono::Duration::hours(24);
    let soon_7d = chrono::Duration::days(7);
    let mut min_remaining: Option<chrono::Duration> = None;
    for e in expires.iter().flatten() {
        let remaining = *e - now;
        if remaining <= chrono::Duration::zero() {
            continue;
        }
        min_remaining = Some(match min_remaining {
            Some(prev) if prev < remaining => prev,
            _ => remaining,
        });
    }
    match min_remaining {
        Some(r) if r <= soon_24h => ProfileStatus::ExpiringCritical,
        Some(r) if r <= soon_7d => ProfileStatus::ExpiringSoon,
        _ => ProfileStatus::Valid,
    }
}

fn validate_profile(profile: &str) -> Result<()> {
    if profile.is_empty()
        || profile == "."
        || profile == ".."
        || profile.contains('/')
        || profile.contains('\\')
    {
        return Err(AuthStoreError::Crypto(format!(
            "invalid profile name: {profile:?}"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::SameSite;
    use reqwest::cookie::CookieStore;
    use secrecy::ExposeSecret;

    fn cookie(value: &str, expires: Option<DateTime<Utc>>) -> Cookie {
        Cookie {
            name: "sid".to_string(),
            value: SecretString::from(value.to_string()),
            domain: "example.com".to_string(),
            path: "/".to_string(),
            expires,
            secure: true,
            http_only: true,
            same_site: SameSite::Lax,
        }
    }

    fn cookie_for(
        name: &str,
        value: &str,
        domain: &str,
        path: &str,
        secure: bool,
        expires: Option<DateTime<Utc>>,
    ) -> Cookie {
        Cookie {
            name: name.to_string(),
            value: SecretString::from(value.to_string()),
            domain: domain.to_string(),
            path: path.to_string(),
            expires,
            secure,
            http_only: true,
            same_site: SameSite::Lax,
        }
    }

    #[test]
    fn save_load_roundtrip_with_passphrase() {
        let temp = tempfile::tempdir().unwrap();
        let store = AuthStore::open_with_passphrase(
            temp.path(),
            SecretString::from("integration passphrase".to_string()),
        )
        .unwrap();
        store
            .save("work", &[cookie("SUPER_SECRET_VALUE_XYZ", None)], "proxy-a")
            .unwrap();
        let loaded = store.load("work", "proxy-a").unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].value.expose_secret(), "SUPER_SECRET_VALUE_XYZ");
    }

    #[test]
    fn invalid_profile_is_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let store = AuthStore::open_with_passphrase(
            temp.path(),
            SecretString::from("integration passphrase".to_string()),
        )
        .unwrap();
        let err = store.save("../work", &[], "ctx").unwrap_err();
        assert!(matches!(err, AuthStoreError::Crypto(_)));
    }

    #[test]
    fn auth_jar_from_store_loads_cookies() {
        let temp = tempfile::tempdir().unwrap();
        let store = AuthStore::open_with_passphrase(
            temp.path(),
            SecretString::from("integration passphrase".to_string()),
        )
        .unwrap();
        store
            .save("work", &[cookie("secret", None)], "ctx")
            .unwrap();
        let jar = AuthCookieJar::from_store(&store, "work", "ctx").unwrap();
        assert_eq!(jar.cookie_count(), 1);
    }

    #[test]
    fn auth_jar_filters_by_domain() {
        let jar = AuthCookieJar::from_cookies(vec![cookie_for(
            "sid",
            "secret",
            "example.com",
            "/",
            true,
            None,
        )]);
        let yes = url::Url::parse("https://sub.example.com/path").unwrap();
        let no = url::Url::parse("https://not-example.test/path").unwrap();
        assert!(jar.cookies(&yes).is_some());
        assert!(jar.cookies(&no).is_none());
    }

    #[test]
    fn auth_jar_filters_by_path() {
        let jar = AuthCookieJar::from_cookies(vec![cookie_for(
            "sid",
            "secret",
            "example.com",
            "/account",
            true,
            None,
        )]);
        let yes = url::Url::parse("https://example.com/account/settings").unwrap();
        let no = url::Url::parse("https://example.com/cart").unwrap();
        assert!(jar.cookies(&yes).is_some());
        assert!(jar.cookies(&no).is_none());
    }

    #[test]
    fn auth_jar_respects_secure_flag() {
        let jar = AuthCookieJar::from_cookies(vec![cookie_for(
            "sid",
            "secret",
            "example.com",
            "/",
            true,
            None,
        )]);
        let http = url::Url::parse("http://example.com/").unwrap();
        let https = url::Url::parse("https://example.com/").unwrap();
        assert!(jar.cookies(&http).is_none());
        assert!(jar.cookies(&https).is_some());
    }

    #[test]
    fn auth_jar_skips_expired_cookies() {
        let jar = AuthCookieJar::from_cookies(vec![cookie_for(
            "sid",
            "secret",
            "example.com",
            "/",
            false,
            Some(Utc::now() - chrono::Duration::minutes(1)),
        )]);
        let url = url::Url::parse("http://example.com/").unwrap();
        assert!(jar.cookies(&url).is_none());
    }

    #[test]
    fn auth_jar_discards_incoming_set_cookie_by_default() {
        let jar = AuthCookieJar::from_cookies(vec![]);
        let url = url::Url::parse("https://example.com/").unwrap();
        let headers = [HeaderValue::from_static("sid=secret; Path=/")];
        jar.set_cookies(&mut headers.iter(), &url);
        assert_eq!(jar.cookie_count(), 0);
        assert!(jar.cookies(&url).is_none());
    }

    #[test]
    fn save_preserves_browser_replay_metadata() {
        let temp = tempfile::tempdir().unwrap();
        let store = AuthStore::open_with_passphrase(
            temp.path(),
            SecretString::from("integration passphrase".to_string()),
        )
        .unwrap();
        let replay = BrowserReplayMetadata {
            user_agent: Some("UA-A".to_string()),
            accept_language: Some("ja,en;q=0.9".to_string()),
        };
        store
            .save_with_browser_replay("work", &[cookie("secret", None)], "ctx", replay.clone())
            .unwrap();
        store.save("work", &[cookie("next", None)], "ctx").unwrap();
        assert_eq!(store.browser_replay_metadata("work").unwrap(), Some(replay));
    }

    // ---- P14 SHOULD: cookie expiry warning ----

    #[test]
    fn classify_status_expiring_soon_when_within_7_days() {
        let now = Utc::now();
        let in_3d = Some(now + chrono::Duration::days(3));
        let in_30d = Some(now + chrono::Duration::days(30));
        let s = classify_status(&[in_3d, in_30d], now);
        assert_eq!(s, ProfileStatus::ExpiringSoon);
    }

    #[test]
    fn classify_status_expiring_critical_when_within_24h() {
        let now = Utc::now();
        let in_2h = Some(now + chrono::Duration::hours(2));
        let in_8d = Some(now + chrono::Duration::days(8));
        let s = classify_status(&[in_2h, in_8d], now);
        // The 2h-from-now cookie dominates → critical.
        assert_eq!(s, ProfileStatus::ExpiringCritical);
    }

    #[test]
    fn classify_status_boundary_7_days_inclusive() {
        let now = Utc::now();
        // Exactly 7 days from now → still ExpiringSoon (inclusive boundary).
        let at_7d = Some(now + chrono::Duration::days(7));
        let s = classify_status(&[at_7d], now);
        assert_eq!(s, ProfileStatus::ExpiringSoon);
        // Strictly > 7 days → Valid.
        let past_7d = Some(now + chrono::Duration::days(7) + chrono::Duration::seconds(1));
        let s = classify_status(&[past_7d], now);
        assert_eq!(s, ProfileStatus::Valid);
    }

    #[test]
    fn classify_status_boundary_24h_inclusive_critical_over_soon() {
        let now = Utc::now();
        // Exactly 24h → Critical (inclusive boundary).
        let at_24h = Some(now + chrono::Duration::hours(24));
        let s = classify_status(&[at_24h], now);
        assert_eq!(s, ProfileStatus::ExpiringCritical);
        // 24h + 1s → ExpiringSoon (no longer critical).
        let past_24h = Some(now + chrono::Duration::hours(24) + chrono::Duration::seconds(1));
        let s = classify_status(&[past_24h], now);
        assert_eq!(s, ProfileStatus::ExpiringSoon);
    }

    #[test]
    fn classify_status_expired_still_takes_precedence_over_warning() {
        let now = Utc::now();
        // One cookie already expired, another fresh → PartiallyExpired
        // overrides any ExpiringSoon/Critical signal.
        let expired = Some(now - chrono::Duration::hours(1));
        let fresh = Some(now + chrono::Duration::hours(2));
        let s = classify_status(&[expired, fresh], now);
        assert_eq!(s, ProfileStatus::PartiallyExpired);
    }
}
