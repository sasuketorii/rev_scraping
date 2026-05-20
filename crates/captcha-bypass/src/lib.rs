// SPDX-License-Identifier: MIT
// Source: vendored from rev_stealth crates @ 6fc38fd
//! captcha-bypass
//!
//! reCAPTCHA / hCaptcha / Turnstile bypass research toolkit.
//!
//! ## Surface
//!
//! - [`CaptchaKind`] — the four supported challenge types.
//! - [`SolveRequest`] / [`SolveResponse`] — solver request/response.
//! - [`solve`] — async entry point. With `dry_run = true`, returns a
//!   synthetic token suitable for CI smoke tests. With the `sidecar`
//!   feature enabled, dispatches to the Node.js sidecar at
//!   `sidecar/captcha-bypass/dist/cli.mjs`.
//! - [`verify`] — provider-side verify endpoint.
//!
//! Wave 2.1 ships the Rust surface plus the dry-run path. Wave 2.2 ports
//! the upstream contact_dev `captcha-pro` audio / score / behavioural
//! stack into the sidecar and wires the bridge.

#![forbid(unsafe_code)]

use std::time::Instant;

use serde::{Deserialize, Serialize};
use stealth_core::{Result, StealthError};

#[cfg(feature = "sidecar")]
pub mod bridge;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CaptchaKind {
    RecaptchaV2,
    RecaptchaV3,
    HCaptcha,
    Turnstile,
}

impl CaptchaKind {
    pub fn as_slug(self) -> &'static str {
        match self {
            CaptchaKind::RecaptchaV2 => "recaptcha-v2",
            CaptchaKind::RecaptchaV3 => "recaptcha-v3",
            CaptchaKind::HCaptcha => "hcaptcha",
            CaptchaKind::Turnstile => "turnstile",
        }
    }

    pub fn from_slug(slug: &str) -> Option<Self> {
        Some(match slug {
            "recaptcha-v2" | "recaptcha_v2" | "v2" => CaptchaKind::RecaptchaV2,
            "recaptcha-v3" | "recaptcha_v3" | "v3" => CaptchaKind::RecaptchaV3,
            "hcaptcha" => CaptchaKind::HCaptcha,
            "turnstile" | "cf-turnstile" => CaptchaKind::Turnstile,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SolveRequest {
    pub kind: CaptchaKind,
    pub site_url: String,
    pub site_key: Option<String>,
    /// reCAPTCHA v3 action label (ignored for v2 / hCaptcha / Turnstile).
    pub action: String,
    /// Skip the live solver and return a synthetic token. Used by CI to
    /// exercise the CLI plumbing without running a real Chromium + ASR.
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SolveResponse {
    pub token: String,
    pub solver: &'static str,
    pub elapsed_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerifyReport {
    pub valid: bool,
    pub score: Option<f32>,
    pub action: Option<String>,
    pub errors: Vec<String>,
}

/// Solve a CAPTCHA challenge.
pub async fn solve(req: SolveRequest) -> Result<SolveResponse> {
    let start = Instant::now();
    if req.dry_run {
        let synthetic = format!(
            "dryrun-{}-{}-{}",
            req.kind.as_slug(),
            req.site_key.as_deref().unwrap_or("auto"),
            unix_nanos()
        );
        return Ok(SolveResponse {
            token: synthetic,
            solver: "dry-run",
            elapsed_ms: start.elapsed().as_millis() as u64,
        });
    }

    #[cfg(feature = "sidecar")]
    {
        return bridge::solve_via_sidecar(req).await;
    }

    #[allow(unreachable_code)]
    Err(StealthError::Permanent(
        "captcha-bypass: live solver requires the `sidecar` feature (Wave 2.2)".into(),
    ))
}

/// Verify a CAPTCHA token against the provider's siteverify endpoint.
pub async fn verify(_kind: CaptchaKind, _token: &str, _secret: &str) -> Result<VerifyReport> {
    #[cfg(feature = "sidecar")]
    {
        return bridge::verify_via_sidecar(_kind, _token, _secret).await;
    }
    #[allow(unreachable_code)]
    Err(StealthError::Permanent(
        "captcha-bypass: verify() requires the `sidecar` feature (Wave 2.2)".into(),
    ))
}

fn unix_nanos() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captcha_kind_round_trip() {
        for k in [
            CaptchaKind::RecaptchaV2,
            CaptchaKind::RecaptchaV3,
            CaptchaKind::HCaptcha,
            CaptchaKind::Turnstile,
        ] {
            assert_eq!(CaptchaKind::from_slug(k.as_slug()), Some(k));
        }
        assert_eq!(CaptchaKind::from_slug("v2"), Some(CaptchaKind::RecaptchaV2));
        assert_eq!(CaptchaKind::from_slug("v3"), Some(CaptchaKind::RecaptchaV3));
        assert_eq!(
            CaptchaKind::from_slug("cf-turnstile"),
            Some(CaptchaKind::Turnstile)
        );
        assert_eq!(CaptchaKind::from_slug("nope"), None);
    }

    #[tokio::test]
    async fn dry_run_returns_synthetic_token() {
        let req = SolveRequest {
            kind: CaptchaKind::RecaptchaV3,
            site_url: "https://example.com".into(),
            site_key: Some("abcdef".into()),
            action: "submit".into(),
            dry_run: true,
        };
        let resp = solve(req).await.unwrap();
        assert!(resp.token.starts_with("dryrun-recaptcha-v3-abcdef-"));
        assert_eq!(resp.solver, "dry-run");
    }

    #[tokio::test]
    async fn live_solve_without_sidecar_feature_returns_permanent_error() {
        let req = SolveRequest {
            kind: CaptchaKind::RecaptchaV2,
            site_url: "https://example.com".into(),
            site_key: None,
            action: "submit".into(),
            dry_run: false,
        };
        let err = solve(req).await.unwrap_err();
        assert!(matches!(err, StealthError::Permanent(_)));
        assert_eq!(err.exit_code(), stealth_core::ExitCode::PermanentError);
    }
}
