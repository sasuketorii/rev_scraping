// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! stealth-core
//!
//! Shared types and the chromiumoxide-backed stealth browser launcher for
//! the rev_stealth toolkit.
//!
//! Layered surface:
//!
//! * [`StealthError`] / [`Result`] / [`ExitCode`] — workspace-wide error
//!   taxonomy (CLI exit-code mapping is stable: 0=ok, 1=user, 2=transient,
//!   3=permanent, 4=auth-expired).
//! * [`StealthProfile`] / [`BrowserProfile`] — high-level "what kind of
//!   session do I want" knobs.
//! * [`browser`] — chromiumoxide launcher that materialises a
//!   [`mobile_fp::Fingerprint`] + CDP patch bundle into a live
//!   [`chromiumoxide::Browser`]. Gated behind the `browser` feature
//!   (default-on); disable to depend on this crate without dragging in
//!   chromiumoxide.

#![forbid(unsafe_code)]

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[cfg(feature = "browser")]
pub mod browser;

pub mod leak_guard;

/// Canonical CLI exit codes used by `rev-stealth` and any agent consumers
/// that parse process status to decide retry vs. escalate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExitCode {
    Ok = 0,
    UserError = 1,
    TransientError = 2,
    PermanentError = 3,
    /// Stored authentication is missing, expired, or unusable (Phase 9a).
    AuthExpired = 4,
    /// Fail-closed VPN leak detected (Phase 6c). Reserved 5–6 for future
    /// categories; 7 is stable across the agent/CLI contract.
    Leak = 7,
}

impl ExitCode {
    pub fn as_i32(self) -> i32 {
        self as i32
    }
}

/// Result alias used across the workspace.
pub type Result<T> = std::result::Result<T, StealthError>;

#[derive(Debug, Error)]
pub enum StealthError {
    #[error("user input error: {0}")]
    User(String),

    #[error("transient failure (retryable): {0}")]
    Transient(String),

    #[error("permanent failure: {0}")]
    Permanent(String),

    /// Stored authentication is missing, expired, or unusable. Maps to exit
    /// code 4, which was reserved before Phase 9a.
    #[error("auth expired: {0}")]
    AuthExpired(String),

    /// Fail-closed VPN leak detected (Phase 6c). Maps to exit code 7.
    #[error("vpn leak detected (fail-closed): {0}")]
    Leak(String),

    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl StealthError {
    pub fn exit_code(&self) -> ExitCode {
        match self {
            StealthError::User(_) => ExitCode::UserError,
            StealthError::Transient(_) => ExitCode::TransientError,
            StealthError::Permanent(_) => ExitCode::PermanentError,
            StealthError::AuthExpired(_) => ExitCode::AuthExpired,
            StealthError::Leak(_) => ExitCode::Leak,
            StealthError::Other(_) => ExitCode::PermanentError,
        }
    }
}

/// High-level browser profile selection. Mapped to a concrete
/// [`mobile_fp::PresetId`] inside the launcher.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum BrowserProfile {
    /// Plain desktop Chromium (no mobile fingerprint patches). Used for
    /// stealth-test against bot.sannysoft when a mobile profile is not
    /// the goal.
    Desktop,
    /// iOS Safari (iPhone 15 Pro). Default mobile profile.
    MobileIos,
    /// Android Chrome (Pixel 9 Pro).
    MobileAndroid,
    /// iPad Pro M4 (request-desktop UA + touch). Niche but useful for
    /// reCAPTCHA v3.
    Ipad,
    /// Android Galaxy S24 Ultra.
    GalaxyUltra,
}

impl BrowserProfile {
    pub fn as_slug(self) -> &'static str {
        match self {
            BrowserProfile::Desktop => "desktop",
            BrowserProfile::MobileIos => "mobile-ios",
            BrowserProfile::MobileAndroid => "mobile-android",
            BrowserProfile::Ipad => "ipad",
            BrowserProfile::GalaxyUltra => "galaxy-ultra",
        }
    }

    pub fn from_slug(slug: &str) -> Option<Self> {
        Some(match slug {
            "desktop" => BrowserProfile::Desktop,
            "mobile-ios" | "ios" | "iphone" => BrowserProfile::MobileIos,
            "mobile-android" | "android" | "pixel" => BrowserProfile::MobileAndroid,
            "ipad" => BrowserProfile::Ipad,
            "galaxy-ultra" | "galaxy" => BrowserProfile::GalaxyUltra,
            _ => return None,
        })
    }

    /// Map to the underlying mobile-fp preset. `Desktop` returns `None`
    /// — desktop sessions skip the mobile-FP bootstrap.
    pub fn preset(self) -> Option<mobile_fp::PresetId> {
        Some(match self {
            BrowserProfile::Desktop => return None,
            BrowserProfile::MobileIos => mobile_fp::PresetId::IPhone15Pro,
            BrowserProfile::MobileAndroid => mobile_fp::PresetId::Pixel9Pro,
            BrowserProfile::Ipad => mobile_fp::PresetId::IPadProM4,
            BrowserProfile::GalaxyUltra => mobile_fp::PresetId::GalaxyS24Ultra,
        })
    }
}

/// Stealth-level knob controlling how aggressively patches are applied.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StealthLevel {
    /// No JS patches — useful as an A/B baseline.
    Off,
    /// `navigator.webdriver` + `chrome.runtime` only. Cheapest, broadest.
    Basic,
    /// Every fingerprint-derived patch. Default.
    Full,
}

impl StealthLevel {
    pub fn from_slug(slug: &str) -> Option<Self> {
        Some(match slug {
            "off" | "none" => StealthLevel::Off,
            "basic" => StealthLevel::Basic,
            "full" => StealthLevel::Full,
            _ => return None,
        })
    }
}

/// Applied at launch time. `id` is the human-readable label that surfaces
/// in logs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StealthProfile {
    pub id: String,
    pub browser_profile: BrowserProfile,
    pub stealth_level: StealthLevel,
    /// When `true`, run with no chrome window. Default `true`.
    pub headless: bool,
    /// When `Some`, override the chromium-binary path resolution.
    pub chrome_executable: Option<std::path::PathBuf>,
}

impl Default for StealthProfile {
    fn default() -> Self {
        Self {
            id: "default-mobile-ios".into(),
            browser_profile: BrowserProfile::MobileIos,
            stealth_level: StealthLevel::Full,
            headless: true,
            chrome_executable: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_codes_are_stable() {
        assert_eq!(ExitCode::Ok.as_i32(), 0);
        assert_eq!(ExitCode::UserError.as_i32(), 1);
        assert_eq!(ExitCode::TransientError.as_i32(), 2);
        assert_eq!(ExitCode::PermanentError.as_i32(), 3);
        assert_eq!(ExitCode::AuthExpired.as_i32(), 4);
        assert_eq!(ExitCode::Leak.as_i32(), 7);
    }

    #[test]
    fn test_exit_code_auth_expired_is_4() {
        assert_eq!(ExitCode::AuthExpired as i32, 4);
        assert_eq!(ExitCode::AuthExpired.as_i32(), 4);
    }

    #[test]
    fn test_exit_code_leak_is_7() {
        assert_eq!(ExitCode::Leak as i32, 7);
        assert_eq!(ExitCode::Leak.as_i32(), 7);
    }

    #[test]
    fn stealth_error_to_exit_code_is_total() {
        assert_eq!(
            StealthError::User("x".into()).exit_code(),
            ExitCode::UserError
        );
        assert_eq!(
            StealthError::Transient("x".into()).exit_code(),
            ExitCode::TransientError
        );
        assert_eq!(
            StealthError::Permanent("x".into()).exit_code(),
            ExitCode::PermanentError
        );
        assert_eq!(
            StealthError::AuthExpired("x".into()).exit_code(),
            ExitCode::AuthExpired
        );
        assert_eq!(StealthError::Leak("x".into()).exit_code(), ExitCode::Leak);
        let other: StealthError = anyhow::anyhow!("boom").into();
        assert_eq!(other.exit_code(), ExitCode::PermanentError);
    }

    #[test]
    fn test_stealth_error_auth_expired_maps_to_exit_4() {
        let e = StealthError::AuthExpired("profile missing".into());
        assert_eq!(e.exit_code().as_i32(), 4);
        let s = format!("{e}");
        assert!(
            s.contains("auth expired"),
            "display should mention auth: {s}"
        );
    }

    #[test]
    fn test_stealth_error_leak_maps_to_exit_7() {
        let e = StealthError::Leak("kill-switch off".into());
        assert_eq!(e.exit_code().as_i32(), 7);
        let s = format!("{e}");
        assert!(s.contains("leak"), "display should mention leak: {s}");
    }

    #[test]
    fn browser_profile_slug_round_trip() {
        for p in [
            BrowserProfile::Desktop,
            BrowserProfile::MobileIos,
            BrowserProfile::MobileAndroid,
            BrowserProfile::Ipad,
            BrowserProfile::GalaxyUltra,
        ] {
            assert_eq!(BrowserProfile::from_slug(p.as_slug()), Some(p));
        }
        // Aliases
        assert_eq!(
            BrowserProfile::from_slug("ios"),
            Some(BrowserProfile::MobileIos)
        );
        assert_eq!(
            BrowserProfile::from_slug("android"),
            Some(BrowserProfile::MobileAndroid)
        );
        assert_eq!(BrowserProfile::from_slug("nonexistent"), None);
    }

    #[test]
    fn browser_profile_maps_to_correct_preset() {
        assert!(BrowserProfile::Desktop.preset().is_none());
        assert_eq!(
            BrowserProfile::MobileIos.preset(),
            Some(mobile_fp::PresetId::IPhone15Pro)
        );
        assert_eq!(
            BrowserProfile::MobileAndroid.preset(),
            Some(mobile_fp::PresetId::Pixel9Pro)
        );
        assert_eq!(
            BrowserProfile::Ipad.preset(),
            Some(mobile_fp::PresetId::IPadProM4)
        );
        assert_eq!(
            BrowserProfile::GalaxyUltra.preset(),
            Some(mobile_fp::PresetId::GalaxyS24Ultra)
        );
    }

    #[test]
    fn stealth_level_from_slug() {
        assert_eq!(StealthLevel::from_slug("off"), Some(StealthLevel::Off));
        assert_eq!(StealthLevel::from_slug("basic"), Some(StealthLevel::Basic));
        assert_eq!(StealthLevel::from_slug("full"), Some(StealthLevel::Full));
        assert_eq!(StealthLevel::from_slug("none"), Some(StealthLevel::Off));
        assert_eq!(StealthLevel::from_slug("xyz"), None);
    }

    #[test]
    fn default_stealth_profile_is_mobile_ios_full_headless() {
        let p = StealthProfile::default();
        assert_eq!(p.browser_profile, BrowserProfile::MobileIos);
        assert_eq!(p.stealth_level, StealthLevel::Full);
        assert!(p.headless);
        assert!(p.chrome_executable.is_none());
    }
}
