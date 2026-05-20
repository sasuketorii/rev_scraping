// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.0.0 obscura integration
//! obscura inject glue.
//!
//! Wires a [`Fingerprint`] into a Chromium CDP session via three commands:
//!
//! 1. `Emulation.setUserAgentOverride` — UA string + `userAgentMetadata`
//!    (Sec-CH-UA brands / full_version_list / platform / model / mobile).
//! 2. `Emulation.setDeviceMetricsOverride` — viewport, deviceScaleFactor,
//!    mobile flag.
//! 3. `Emulation.setTouchEmulationEnabled` — touch surface for mobile FPs.
//! 4. `Page.addScriptToEvaluateOnNewDocument` — JS bootstrap produced by
//!    [`crate::patches::full_bootstrap`] (gated by [`StealthLevel`]).
//!
//! The actual obscura-bridge `CdpClient` adapter lives in Phase 2; here we
//! abstract over the CDP send path through [`CdpInjectTarget`] so this
//! crate stays decoupled and unit-testable.

use crate::{Fingerprint, Platform, StealthLevel};
use serde_json::{json, Value};

/// Object-safe CDP send abstraction. Implemented by obscura-bridge's
/// `CdpClient` in Phase 2; tests use a mock recorder.
#[async_trait::async_trait]
pub trait CdpInjectTarget: Send + Sync {
    /// Invoke a raw CDP JSON-RPC method on this target's session.
    async fn cdp_send(&self, method: &str, params: Value) -> anyhow::Result<Value>;
}

/// Build the `userAgentMetadata` payload mirrored from the Fingerprint.
fn build_ua_metadata(fp: &Fingerprint) -> Value {
    let platform = Platform::from_device_class(fp.device_class).as_ch_ua_platform();
    let brands: Vec<Value> = fp
        .ua_brands
        .iter()
        .map(|b| json!({ "brand": b.brand, "version": b.version }))
        .collect();
    // full_version_list mirrors brands but carries ua_full_version for the
    // primary (non-`Not?A_Brand`) entries.
    let full_version_list: Vec<Value> = fp
        .ua_brands
        .iter()
        .map(|b| {
            let version = if b.brand.contains("Not") {
                b.version.clone()
            } else {
                fp.ua_full_version.clone()
            };
            json!({ "brand": b.brand, "version": version })
        })
        .collect();
    json!({
        "brands": brands,
        "fullVersionList": full_version_list,
        "fullVersion": fp.ua_full_version,
        "platform": platform,
        "platformVersion": fp.ua_platform_version,
        "architecture": "",
        "model": fp.ua_model,
        "mobile": fp.ua_mobile,
        "bitness": "64",
        "wow64": false,
    })
}

/// Inject a fingerprint into a CDP target.
///
/// Order:
/// 1. `Emulation.setUserAgentOverride`
/// 2. `Emulation.setDeviceMetricsOverride`
/// 3. `Emulation.setTouchEmulationEnabled`
/// 4. `Page.addScriptToEvaluateOnNewDocument` (skipped at [`StealthLevel::Off`])
pub async fn inject_into_cdp<T: CdpInjectTarget + ?Sized>(
    fp: &Fingerprint,
    level: StealthLevel,
    target: &T,
) -> anyhow::Result<()> {
    // 1. UA override + Sec-CH-UA metadata
    target
        .cdp_send(
            "Emulation.setUserAgentOverride",
            json!({
                "userAgent": fp.user_agent,
                "acceptLanguage": fp.language,
                "platform": fp.platform,
                "userAgentMetadata": build_ua_metadata(fp),
            }),
        )
        .await?;

    // 2. Viewport / DPR / mobile flag
    target
        .cdp_send(
            "Emulation.setDeviceMetricsOverride",
            json!({
                "width": fp.viewport.width,
                "height": fp.viewport.height,
                "deviceScaleFactor": fp.device_scale_factor,
                "mobile": fp.ua_mobile,
                "screenWidth": fp.screen.width,
                "screenHeight": fp.screen.height,
            }),
        )
        .await?;

    // 3. Touch
    target
        .cdp_send(
            "Emulation.setTouchEmulationEnabled",
            json!({
                "enabled": fp.max_touch_points > 0,
                "maxTouchPoints": fp.max_touch_points,
            }),
        )
        .await?;

    // 4. JS bootstrap (mobile-fp patches). Skipped only at `Off`.
    if level != StealthLevel::Off {
        let source = crate::patches::full_bootstrap(fp);
        target
            .cdp_send(
                "Page.addScriptToEvaluateOnNewDocument",
                json!({ "source": source }),
            )
            .await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{iphone_15_pro, pixel_9_pro};
    use std::sync::Mutex;

    /// Records every CDP send for assertions.
    #[derive(Default)]
    struct MockTarget {
        calls: Mutex<Vec<(String, Value)>>,
    }

    impl MockTarget {
        fn calls(&self) -> Vec<(String, Value)> {
            self.calls.lock().unwrap().clone()
        }
    }

    #[async_trait::async_trait]
    impl CdpInjectTarget for MockTarget {
        async fn cdp_send(&self, method: &str, params: Value) -> anyhow::Result<Value> {
            self.calls
                .lock()
                .unwrap()
                .push((method.to_string(), params));
            Ok(Value::Null)
        }
    }

    #[tokio::test]
    async fn test_inject_sends_set_user_agent_override_with_metadata() {
        let fp = iphone_15_pro();
        let target = MockTarget::default();
        inject_into_cdp(&fp, StealthLevel::High, &target)
            .await
            .unwrap();
        let calls = target.calls();
        let (method, params) = calls
            .iter()
            .find(|(m, _)| m == "Emulation.setUserAgentOverride")
            .expect("setUserAgentOverride must be called");
        assert_eq!(method, "Emulation.setUserAgentOverride");
        assert_eq!(params["userAgent"], fp.user_agent);
        let meta = &params["userAgentMetadata"];
        assert_eq!(meta["mobile"], true);
        assert_eq!(meta["platform"], "iOS");
        assert_eq!(meta["model"], "iPhone");
        assert!(meta["brands"].is_array());
        assert_eq!(
            meta["brands"][0]["brand"].as_str().unwrap(),
            fp.ua_brands[0].brand
        );
        assert!(meta["fullVersionList"].is_array());
    }

    #[tokio::test]
    async fn test_inject_sends_set_device_metrics_override_with_viewport() {
        let fp = pixel_9_pro();
        let target = MockTarget::default();
        inject_into_cdp(&fp, StealthLevel::High, &target)
            .await
            .unwrap();
        let calls = target.calls();
        let (_, params) = calls
            .iter()
            .find(|(m, _)| m == "Emulation.setDeviceMetricsOverride")
            .expect("setDeviceMetricsOverride must be called");
        assert_eq!(params["width"], fp.viewport.width);
        assert_eq!(params["height"], fp.viewport.height);
        assert_eq!(params["mobile"], fp.ua_mobile);
        // deviceScaleFactor is f32 — compare via f64.
        let dsf = params["deviceScaleFactor"].as_f64().unwrap();
        assert!((dsf - fp.device_scale_factor as f64).abs() < 1e-6);
    }

    #[tokio::test]
    async fn test_inject_sends_add_script_to_evaluate_on_new_document_full_bootstrap() {
        let fp = iphone_15_pro();
        let target = MockTarget::default();
        inject_into_cdp(&fp, StealthLevel::High, &target)
            .await
            .unwrap();
        let calls = target.calls();
        let (_, params) = calls
            .iter()
            .find(|(m, _)| m == "Page.addScriptToEvaluateOnNewDocument")
            .expect("addScriptToEvaluateOnNewDocument must be called");
        let expected = crate::patches::full_bootstrap(&fp);
        assert_eq!(params["source"].as_str().unwrap(), expected);
    }

    #[tokio::test]
    async fn test_inject_full_iphone15pro_preset_method_order() {
        let fp = iphone_15_pro();
        let target = MockTarget::default();
        inject_into_cdp(&fp, StealthLevel::High, &target)
            .await
            .unwrap();
        let methods: Vec<String> = target.calls().into_iter().map(|(m, _)| m).collect();
        assert_eq!(
            methods,
            vec![
                "Emulation.setUserAgentOverride",
                "Emulation.setDeviceMetricsOverride",
                "Emulation.setTouchEmulationEnabled",
                "Page.addScriptToEvaluateOnNewDocument",
            ],
            "CDP methods must be invoked in deterministic order"
        );
    }

    #[tokio::test]
    async fn test_inject_off_level_skips_js_bootstrap() {
        let fp = iphone_15_pro();
        let target = MockTarget::default();
        inject_into_cdp(&fp, StealthLevel::Off, &target)
            .await
            .unwrap();
        let methods: Vec<String> = target.calls().into_iter().map(|(m, _)| m).collect();
        assert!(!methods
            .iter()
            .any(|m| m == "Page.addScriptToEvaluateOnNewDocument"));
        assert_eq!(methods.len(), 3);
    }

    #[test]
    fn test_platform_from_device_class_mapping() {
        use crate::DeviceClass;
        assert_eq!(Platform::from_device_class(DeviceClass::Ios), Platform::Ios);
        assert_eq!(
            Platform::from_device_class(DeviceClass::Android),
            Platform::Android
        );
        assert_eq!(Platform::Ios.as_ch_ua_platform(), "iOS");
        assert_eq!(Platform::Android.as_ch_ua_platform(), "Android");
    }
}
