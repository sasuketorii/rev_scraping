// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! mobile-fp
//!
//! Mobile fingerprint presets for stealth browser sessions.
//!
//! Six presets are provided, ported from the upstream contact-form automation
//! research project (`contact_dev/contact_sender_v2/sidecar/src/captcha-pro/stealth/fingerprint/presets-mobile.ts`):
//!
//! - `iPhone15Pro` / `iPhone15ProMax` (iOS 17.5 Safari)
//! - `iPadProM4` (iPadOS 17.5; ships a Mac UA per Safari "Request Desktop Site" default)
//! - `Pixel9Pro` / `Pixel8a` (Android 14 Chrome 130-131)
//! - `GalaxyS24Ultra` (Android 14 One UI 6.1 Chrome 131)
//!
//! The data is plain Rust constants — no runtime dependencies beyond `serde`.
//! Consumers feed [`Fingerprint`] into a CDP / chromiumoxide bootstrap layer
//! (see `crates/stealth-core::browser`) which materialises UA / viewport /
//! touch / screen / WebGL / Sec-CH-UA / connection state on the page.

#![forbid(unsafe_code)]

pub mod obscura_inject;
pub mod patches;

use serde::{Deserialize, Serialize};

/// Stealth strength selector for the obscura inject glue.
///
/// Added for rev_scraping v1.0.0 Phase 1d (obscura integration).
/// Higher levels apply more JS patches via
/// [`patches::full_bootstrap`]; `Off` skips JS bootstrap entirely (CDP
/// UA / viewport / touch overrides are still applied).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StealthLevel {
    Off,
    Low,
    Medium,
    #[default]
    High,
}

/// Coarse platform classification used by callers wiring the obscura
/// inject glue (added for rev_scraping v1.0.0 Phase 1d).
///
/// Derived from [`DeviceClass`] via [`Platform::from_device_class`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Ios,
    Android,
}

impl Platform {
    pub fn from_device_class(d: DeviceClass) -> Self {
        match d {
            DeviceClass::Ios => Platform::Ios,
            DeviceClass::Android => Platform::Android,
        }
    }

    /// Sec-CH-UA `platform` token (the value emitted by real Chromium
    /// in `Emulation.setUserAgentOverride.userAgentMetadata.platform`).
    pub fn as_ch_ua_platform(self) -> &'static str {
        match self {
            Platform::Ios => "iOS",
            Platform::Android => "Android",
        }
    }
}

/// A complete mobile fingerprint snapshot. Field semantics mirror the
/// chromiumoxide / Playwright surface so a single struct drives both the
/// User-Agent string, viewport, screen, touch, Sec-CH-UA hints, and the
/// `navigator.connection` patch.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Fingerprint {
    pub user_agent: String,
    pub platform: String,
    pub language: String,
    pub languages: Vec<String>,
    pub timezone_id: String,
    pub locale: String,
    pub viewport: Viewport,
    pub device_scale_factor: f32,
    pub hardware_concurrency: u32,
    pub device_memory: u32,
    pub webgl_vendor: String,
    pub webgl_renderer: String,
    pub canvas_noise_seed: u32,
    pub audio_noise_seed: u32,
    pub ua_brands: Vec<UaBrand>,
    pub ua_full_version: String,
    pub ua_platform_version: String,
    pub ua_model: String,
    pub ua_mobile: bool,
    pub device_class: DeviceClass,
    pub max_touch_points: u32,
    pub screen: Viewport,
    pub orientation_type: OrientationType,
    pub connection: Connection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Viewport {
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UaBrand {
    pub brand: String,
    pub version: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DeviceClass {
    Ios,
    Android,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum OrientationType {
    PortraitPrimary,
    PortraitSecondary,
    LandscapePrimary,
    LandscapeSecondary,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Connection {
    pub effective_type: EffectiveType,
    pub downlink: f32,
    pub rtt: u32,
    pub save_data: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EffectiveType {
    Slow2g,
    #[serde(rename = "2g")]
    TwoG,
    #[serde(rename = "3g")]
    ThreeG,
    #[serde(rename = "4g")]
    FourG,
    #[serde(rename = "5g")]
    FiveG,
}

/// Stable identifier for each preset. Used by callers that select a preset
/// by name (CLI, agent skills, randomiser).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PresetId {
    IPhone15Pro,
    IPhone15ProMax,
    IPadProM4,
    Pixel9Pro,
    Pixel8a,
    GalaxyS24Ultra,
}

impl PresetId {
    /// Materialise the fingerprint for this preset id.
    pub fn fingerprint(self) -> Fingerprint {
        match self {
            PresetId::IPhone15Pro => iphone_15_pro(),
            PresetId::IPhone15ProMax => iphone_15_pro_max(),
            PresetId::IPadProM4 => ipad_pro_m4(),
            PresetId::Pixel9Pro => pixel_9_pro(),
            PresetId::Pixel8a => pixel_8a(),
            PresetId::GalaxyS24Ultra => galaxy_s24_ultra(),
        }
    }

    /// Human-readable kebab-case slug used by the CLI.
    pub fn as_slug(self) -> &'static str {
        match self {
            PresetId::IPhone15Pro => "iphone-15-pro",
            PresetId::IPhone15ProMax => "iphone-15-pro-max",
            PresetId::IPadProM4 => "ipad-pro-m4",
            PresetId::Pixel9Pro => "pixel-9-pro",
            PresetId::Pixel8a => "pixel-8a",
            PresetId::GalaxyS24Ultra => "galaxy-s24-ultra",
        }
    }

    /// Iterate every preset (deterministic order — used by tests and
    /// fingerprint randomiser).
    pub fn all() -> &'static [PresetId] {
        &[
            PresetId::IPhone15Pro,
            PresetId::IPhone15ProMax,
            PresetId::IPadProM4,
            PresetId::Pixel9Pro,
            PresetId::Pixel8a,
            PresetId::GalaxyS24Ultra,
        ]
    }

    /// Parse a slug into a preset. Used by the CLI argument parser.
    pub fn from_slug(slug: &str) -> Option<Self> {
        Self::all().iter().copied().find(|p| p.as_slug() == slug)
    }
}

const COMMON_LANGS_JP: &[&str] = &["ja-JP", "ja", "en-US", "en"];

fn jp_langs() -> Vec<String> {
    COMMON_LANGS_JP.iter().map(|s| (*s).to_string()).collect()
}

/* ===================== iOS ===================== */

/// iPhone 15 Pro — iOS 17.5, Safari (real iPhone UA, not iPad request-desktop).
///
/// Viewport 393x852 (CSS px), DPR 3, Apple A17 Pro GPU.
pub fn iphone_15_pro() -> Fingerprint {
    Fingerprint {
        user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) \
                     AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 \
                     Mobile/15E148 Safari/604.1"
            .to_string(),
        platform: "iPhone".into(),
        language: "ja-JP".into(),
        languages: jp_langs(),
        timezone_id: "Asia/Tokyo".into(),
        locale: "ja-JP".into(),
        viewport: Viewport {
            width: 393,
            height: 852,
        },
        device_scale_factor: 3.0,
        hardware_concurrency: 6,
        device_memory: 8,
        webgl_vendor: "Apple Inc.".into(),
        webgl_renderer: "Apple GPU".into(),
        canvas_noise_seed: 0,
        audio_noise_seed: 0,
        // iOS Safari does not emit Sec-CH-UA; keep an "empty-ish" list so a
        // Chromium-based stealth runtime that has to emit *something* still
        // looks plausible to passive sniffers.
        ua_brands: vec![UaBrand {
            brand: "Not?A_Brand".into(),
            version: "99".into(),
        }],
        ua_full_version: "17.5".into(),
        ua_platform_version: "17.5.0".into(),
        ua_model: "iPhone".into(),
        ua_mobile: true,
        device_class: DeviceClass::Ios,
        max_touch_points: 5,
        screen: Viewport {
            width: 393,
            height: 852,
        },
        orientation_type: OrientationType::PortraitPrimary,
        connection: Connection {
            effective_type: EffectiveType::FourG,
            downlink: 10.0,
            rtt: 50,
            save_data: false,
        },
    }
}

/// iPhone 15 Pro Max — iOS 17.5. Inherits iPhone 15 Pro and bumps viewport.
pub fn iphone_15_pro_max() -> Fingerprint {
    let mut fp = iphone_15_pro();
    fp.viewport = Viewport {
        width: 430,
        height: 932,
    };
    fp.screen = Viewport {
        width: 430,
        height: 932,
    };
    fp.ua_model = "iPhone".into();
    fp
}

/// iPad Pro M4 (13-inch, 2024) — iPadOS 17.5, Safari.
///
/// Real iPad Safari ships a Mac UA by default ("Request Desktop Site" is on),
/// so the fingerprint advertises macOS while keeping touch events and the
/// orientation API. The combination is rare but not contradictory and is
/// observed to be advantageous against reCAPTCHA v3 in practice.
pub fn ipad_pro_m4() -> Fingerprint {
    Fingerprint {
        user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
                     AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 \
                     Safari/605.1.15"
            .to_string(),
        platform: "MacIntel".into(),
        language: "ja-JP".into(),
        languages: jp_langs(),
        timezone_id: "Asia/Tokyo".into(),
        locale: "ja-JP".into(),
        viewport: Viewport {
            width: 1024,
            height: 1366,
        },
        device_scale_factor: 2.0,
        hardware_concurrency: 10,
        device_memory: 8,
        webgl_vendor: "Apple Inc.".into(),
        webgl_renderer: "Apple GPU".into(),
        canvas_noise_seed: 0,
        audio_noise_seed: 0,
        ua_brands: vec![UaBrand {
            brand: "Not?A_Brand".into(),
            version: "99".into(),
        }],
        ua_full_version: "17.5".into(),
        ua_platform_version: "17.5.0".into(),
        ua_model: "iPad".into(),
        ua_mobile: false, // request-desktop default
        device_class: DeviceClass::Ios,
        max_touch_points: 5,
        screen: Viewport {
            width: 1024,
            height: 1366,
        },
        orientation_type: OrientationType::PortraitPrimary,
        connection: Connection {
            effective_type: EffectiveType::FourG,
            downlink: 12.0,
            rtt: 40,
            save_data: false,
        },
    }
}

/* ===================== Android ===================== */

/// Pixel 9 Pro — Android 14, Chrome 131. Mali-G715 (Tensor G4).
pub fn pixel_9_pro() -> Fingerprint {
    Fingerprint {
        user_agent: "Mozilla/5.0 (Linux; Android 14; Pixel 9 Pro) \
                     AppleWebKit/537.36 (KHTML, like Gecko) \
                     Chrome/131.0.0.0 Mobile Safari/537.36"
            .to_string(),
        platform: "Linux armv8l".into(),
        language: "ja-JP".into(),
        languages: jp_langs(),
        timezone_id: "Asia/Tokyo".into(),
        locale: "ja-JP".into(),
        viewport: Viewport {
            width: 412,
            height: 915,
        },
        device_scale_factor: 2.625,
        hardware_concurrency: 8,
        device_memory: 8,
        webgl_vendor: "Google Inc. (ARM)".into(),
        webgl_renderer: "ANGLE (ARM, Mali-G715-Immortalis r41p0-01eac0, OpenGL ES 3.2)".into(),
        canvas_noise_seed: 0,
        audio_noise_seed: 0,
        ua_brands: vec![
            UaBrand {
                brand: "Google Chrome".into(),
                version: "131".into(),
            },
            UaBrand {
                brand: "Chromium".into(),
                version: "131".into(),
            },
            UaBrand {
                brand: "Not?A_Brand".into(),
                version: "24".into(),
            },
        ],
        ua_full_version: "131.0.6778.86".into(),
        ua_platform_version: "14.0.0".into(),
        ua_model: "Pixel 9 Pro".into(),
        ua_mobile: true,
        device_class: DeviceClass::Android,
        max_touch_points: 5,
        screen: Viewport {
            width: 412,
            height: 915,
        },
        orientation_type: OrientationType::PortraitPrimary,
        connection: Connection {
            effective_type: EffectiveType::FourG,
            downlink: 10.0,
            rtt: 50,
            save_data: false,
        },
    }
}

/// Pixel 8a — Android 14, Chrome 130. Mali-G715 (Tensor G3).
pub fn pixel_8a() -> Fingerprint {
    let mut fp = pixel_9_pro();
    fp.user_agent = "Mozilla/5.0 (Linux; Android 14; Pixel 8a) \
                     AppleWebKit/537.36 (KHTML, like Gecko) \
                     Chrome/130.0.0.0 Mobile Safari/537.36"
        .to_string();
    fp.webgl_renderer = "ANGLE (ARM, Mali-G715s MC10 r38p0-00eac0, OpenGL ES 3.2)".into();
    fp.ua_brands = vec![
        UaBrand {
            brand: "Google Chrome".into(),
            version: "130".into(),
        },
        UaBrand {
            brand: "Chromium".into(),
            version: "130".into(),
        },
        UaBrand {
            brand: "Not?A_Brand".into(),
            version: "99".into(),
        },
    ];
    fp.ua_full_version = "130.0.6723.117".into();
    fp.ua_model = "Pixel 8a".into();
    fp
}

/// Galaxy S24 Ultra — Android 14 (One UI 6.1), Chrome 131.
/// Adreno 750 (Snapdragon 8 Gen 3 for Galaxy).
pub fn galaxy_s24_ultra() -> Fingerprint {
    Fingerprint {
        user_agent: "Mozilla/5.0 (Linux; Android 14; SM-S928U) \
                     AppleWebKit/537.36 (KHTML, like Gecko) \
                     Chrome/131.0.0.0 Mobile Safari/537.36"
            .to_string(),
        platform: "Linux armv8l".into(),
        language: "ja-JP".into(),
        languages: jp_langs(),
        timezone_id: "Asia/Tokyo".into(),
        locale: "ja-JP".into(),
        viewport: Viewport {
            width: 384,
            height: 832,
        },
        device_scale_factor: 3.5,
        hardware_concurrency: 8,
        device_memory: 12,
        webgl_vendor: "Google Inc. (Qualcomm)".into(),
        webgl_renderer: "ANGLE (Qualcomm, Adreno (TM) 750, OpenGL ES 3.2)".into(),
        canvas_noise_seed: 0,
        audio_noise_seed: 0,
        ua_brands: vec![
            UaBrand {
                brand: "Google Chrome".into(),
                version: "131".into(),
            },
            UaBrand {
                brand: "Chromium".into(),
                version: "131".into(),
            },
            UaBrand {
                brand: "Not?A_Brand".into(),
                version: "24".into(),
            },
        ],
        ua_full_version: "131.0.6778.86".into(),
        ua_platform_version: "14.0.0".into(),
        ua_model: "SM-S928U".into(),
        ua_mobile: true,
        device_class: DeviceClass::Android,
        max_touch_points: 5,
        screen: Viewport {
            width: 384,
            height: 832,
        },
        orientation_type: OrientationType::PortraitPrimary,
        connection: Connection {
            effective_type: EffectiveType::FourG,
            downlink: 12.0,
            rtt: 40,
            save_data: false,
        },
    }
}

/// Return every mobile preset in deterministic order.
pub fn all_presets() -> Vec<Fingerprint> {
    PresetId::all().iter().map(|p| p.fingerprint()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iphone_15_pro_matches_upstream_data() {
        let fp = iphone_15_pro();
        assert!(fp.user_agent.contains("iPhone OS 17_5"));
        assert!(fp.user_agent.contains("Safari/604.1"));
        assert_eq!(fp.platform, "iPhone");
        assert_eq!(
            fp.viewport,
            Viewport {
                width: 393,
                height: 852
            }
        );
        assert_eq!(fp.device_scale_factor, 3.0);
        assert_eq!(fp.hardware_concurrency, 6);
        assert_eq!(fp.device_memory, 8);
        assert_eq!(fp.webgl_vendor, "Apple Inc.");
        assert_eq!(fp.webgl_renderer, "Apple GPU");
        assert!(fp.ua_mobile);
        assert_eq!(fp.device_class, DeviceClass::Ios);
        assert_eq!(fp.max_touch_points, 5);
        assert_eq!(fp.connection.effective_type, EffectiveType::FourG);
    }

    #[test]
    fn iphone_15_pro_max_inherits_then_overrides() {
        let base = iphone_15_pro();
        let big = iphone_15_pro_max();
        assert_eq!(big.user_agent, base.user_agent);
        assert_eq!(
            big.viewport,
            Viewport {
                width: 430,
                height: 932
            }
        );
        assert_eq!(
            big.screen,
            Viewport {
                width: 430,
                height: 932
            }
        );
    }

    #[test]
    fn ipad_pro_m4_advertises_mac_ua_and_keeps_touch() {
        let fp = ipad_pro_m4();
        assert!(fp.user_agent.contains("Macintosh"));
        assert_eq!(fp.platform, "MacIntel");
        // Crucial property: touch active even though UA reads as desktop Mac.
        assert!(fp.max_touch_points >= 1);
        assert!(!fp.ua_mobile, "iPad request-desktop default => mobile=?0");
        assert_eq!(fp.device_class, DeviceClass::Ios);
    }

    #[test]
    fn pixel_9_pro_matches_upstream_data() {
        let fp = pixel_9_pro();
        assert!(fp.user_agent.contains("Pixel 9 Pro"));
        assert!(fp.user_agent.contains("Chrome/131"));
        assert_eq!(
            fp.viewport,
            Viewport {
                width: 412,
                height: 915
            }
        );
        assert!((fp.device_scale_factor - 2.625).abs() < f32::EPSILON);
        assert_eq!(fp.webgl_vendor, "Google Inc. (ARM)");
        assert!(fp.ua_brands.iter().any(|b| b.brand == "Google Chrome"));
        assert_eq!(fp.ua_platform_version, "14.0.0");
    }

    #[test]
    fn pixel_8a_inherits_pixel_9_pro_with_overrides() {
        let nine = pixel_9_pro();
        let eight = pixel_8a();
        // Inherited:
        assert_eq!(nine.viewport, eight.viewport);
        assert_eq!(nine.device_scale_factor, eight.device_scale_factor);
        assert_eq!(nine.platform, eight.platform);
        // Overridden:
        assert!(eight.user_agent.contains("Pixel 8a"));
        assert!(eight.user_agent.contains("Chrome/130"));
        assert_eq!(eight.ua_full_version, "130.0.6723.117");
    }

    #[test]
    fn galaxy_s24_ultra_matches_upstream_data() {
        let fp = galaxy_s24_ultra();
        assert!(fp.user_agent.contains("SM-S928U"));
        assert_eq!(
            fp.viewport,
            Viewport {
                width: 384,
                height: 832
            }
        );
        assert!((fp.device_scale_factor - 3.5).abs() < f32::EPSILON);
        assert_eq!(fp.device_memory, 12);
        assert_eq!(fp.webgl_vendor, "Google Inc. (Qualcomm)");
        assert!(fp.webgl_renderer.contains("Adreno (TM) 750"));
    }

    #[test]
    fn preset_id_round_trip_via_slug() {
        for &p in PresetId::all() {
            assert_eq!(PresetId::from_slug(p.as_slug()), Some(p));
        }
        assert_eq!(PresetId::from_slug("nonexistent-device"), None);
    }

    #[test]
    fn preset_id_fingerprint_is_consistent_with_named_constructor() {
        assert_eq!(PresetId::IPhone15Pro.fingerprint(), iphone_15_pro());
        assert_eq!(PresetId::IPadProM4.fingerprint(), ipad_pro_m4());
        assert_eq!(PresetId::Pixel9Pro.fingerprint(), pixel_9_pro());
        assert_eq!(PresetId::GalaxyS24Ultra.fingerprint(), galaxy_s24_ultra());
    }

    #[test]
    fn all_presets_returns_six_distinct_devices() {
        let presets = all_presets();
        assert_eq!(presets.len(), 6);
        // The (UA, viewport, ua_full_version) triple distinguishes every
        // preset even when individual axes overlap (e.g. iPhone 15 Pro and
        // 15 Pro Max share the UA string; Pixel 9 Pro and 8a share viewport).
        let mut keys: Vec<_> = presets
            .iter()
            .map(|p| {
                (
                    p.user_agent.clone(),
                    (p.viewport.width, p.viewport.height),
                    p.ua_full_version.clone(),
                )
            })
            .collect();
        keys.sort();
        keys.dedup();
        assert_eq!(keys.len(), 6, "every preset must be uniquely identifiable");
    }

    #[test]
    fn fingerprint_is_serde_round_trippable() {
        let fp = pixel_9_pro();
        let json = serde_json::to_string(&fp).unwrap();
        let back: Fingerprint = serde_json::from_str(&json).unwrap();
        assert_eq!(fp, back);
    }

    #[test]
    fn jp_languages_have_the_expected_priority_order() {
        let fp = iphone_15_pro();
        assert_eq!(fp.languages, vec!["ja-JP", "ja", "en-US", "en"]);
        assert_eq!(fp.language, "ja-JP");
    }
}
