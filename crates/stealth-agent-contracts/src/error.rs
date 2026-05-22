// SPDX-License-Identifier: MIT
// Source: rev_scraping Lane C P1 (stealth-agent-contracts crate, original work)
//! Error envelope shared between stealth-cli and stealth-mcp.

use serde::{Deserialize, Serialize};

/// Closed enumeration of error categories surfaced across stealth-* boundaries.
///
/// Intentionally NOT marked `#[non_exhaustive]` because downstream consumers
/// (CLI, MCP, audit log) must exhaustively match on this enum at the contract
/// boundary. Adding a new variant is a breaking change by design.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// Acceptable Use Policy violation (site/robots/contract).
    Aup,
    /// Server-Side Request Forgery guard tripped.
    Ssrf,
    /// VPN / egress IP leak detected (real IP exposed).
    VpnLeak,
    /// Per-host or global rate limit exceeded.
    RateLimit,
    /// Operation exceeded its timeout budget.
    Timeout,
    /// Captcha challenge encountered (and not bypassable in current mode).
    Captcha,
    /// Authentication / authorization failure.
    Auth,
    /// Target resource not found.
    NotFound,
    /// Input validation failure.
    Validation,
    /// Lower-level network / transport failure.
    Network,
    /// Unclassified internal error (last resort).
    Internal,

    // ---- P4.3 expansion (15 additional variants → 26 closed total) -----
    /// Recipe lookup failed: the requested `domain` has no recipe on disk.
    RecipeNotFound,
    /// Recipe payload (TOML/JSON) failed schema or semantic validation.
    RecipeInvalid,
    /// `auth_login_complete` polled past `login_timeout` budget.
    AuthSessionExpired,
    /// `session_token` is unknown to the registry (never issued, GC'd, or
    /// already consumed).
    AuthSessionNotFound,
    /// `session_token` exists but login helper has not yet finished.
    AuthSessionPending,
    /// VPN rotation requested but no VPN backend is configured.
    VpnNotConfigured,
    /// VPN rotation tried every configured instance and none came up.
    VpnAllInstancesFailed,
    /// VPN egress is up but the resolved country does not match the
    /// requested `country` constraint.
    VpnCountryMismatch,
    /// Chrome DevTools Protocol returned an unexpected error code.
    CdpProtocol,
    /// CDP WebSocket disconnected before the operation completed.
    CdpDisconnected,
    /// Stealth JS injection into the target page failed.
    CdpInjectionFailed,
    /// Headless browser process crashed mid-operation.
    BrowserCrashed,
    /// Headless browser binary could not be located on PATH.
    BrowserNotFound,
    /// On-disk cookie store could not be decrypted (bad passphrase / corruption).
    CookieDecryptFailed,
    /// Operation cancelled by caller (e.g. shutdown signal).
    Aborted,
}

/// Wire-format error envelope returned across stealth-* IPC boundaries.
///
/// `retryable` and `retry_after_ms` give callers enough information to drive
/// a backoff loop without reparsing `message`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorEnvelope {
    /// Closed error category.
    pub kind: ErrorKind,
    /// Human-readable message (must be safe to log; no raw secrets).
    pub message: String,
    /// Whether a retry could plausibly succeed.
    pub retryable: bool,
    /// Optional operator hint (e.g. "rotate VPN", "check robots.txt").
    pub hint: Option<String>,
    /// Suggested backoff before retry, in milliseconds.
    pub retry_after_ms: Option<u64>,
}

/// Per-variant documentation metadata for `ErrorKind`.
///
/// Used by the `stealth-mcp` reference generator (`gen_reference`) to render
/// the deterministic `docs/MCP_REFERENCE.md` ErrorKind table. Kept alongside
/// the enum so a new variant must add a matching row at the same source site.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ErrorKindDoc {
    /// snake_case wire name (matches the serde rename used over the boundary).
    pub wire_name: &'static str,
    /// One-line description of when this variant is emitted.
    pub when_emitted: &'static str,
    /// Whether callers can plausibly retry without changing inputs.
    pub retriable: bool,
    /// Suggested operator hint or remediation pointer.
    pub hint: &'static str,
}

/// Return all 26 `ErrorKind` variants paired with documentation, in the
/// canonical order used everywhere else in the codebase (P1 11 variants
/// first, then the P4.3 expansion of 15). The order is deliberate and is
/// the input to deterministic reference generation.
///
/// The match expression is exhaustive and forbids wildcard patterns, so a
/// 27th variant added to `ErrorKind` is a compile error here until it is
/// documented.
pub fn all_error_kind_docs() -> [(ErrorKind, ErrorKindDoc); 26] {
    use ErrorKind::*;
    // Helper to keep the table readable without re-stating the variant.
    #[forbid(unreachable_patterns)]
    fn doc_for(k: &ErrorKind) -> ErrorKindDoc {
        match k {
            Aup => ErrorKindDoc {
                wire_name: "aup",
                when_emitted: "Acceptable Use Policy violation (site / robots / contract).",
                retriable: false,
                hint: "Confirm target is on the AUP allowlist and robots.txt allows the path.",
            },
            Ssrf => ErrorKindDoc {
                wire_name: "ssrf",
                when_emitted: "Server-Side Request Forgery guard tripped (private/internal target).",
                retriable: false,
                hint: "Do not request loopback / RFC1918 / link-local targets.",
            },
            VpnLeak => ErrorKindDoc {
                wire_name: "vpn_leak",
                when_emitted: "VPN / egress IP leak detected — real IP would have been exposed.",
                retriable: true,
                hint: "Bring VPN up and re-run `doctor`; rotate via `vpn_rotate`.",
            },
            RateLimit => ErrorKindDoc {
                wire_name: "rate_limit",
                when_emitted: "Per-host or global rate limit exceeded.",
                retriable: true,
                hint: "Honor `retry_after_ms`; reduce per-host QPS.",
            },
            Timeout => ErrorKindDoc {
                wire_name: "timeout",
                when_emitted: "Operation exceeded its timeout budget.",
                retriable: true,
                hint: "Retry with a larger budget or after backoff.",
            },
            Captcha => ErrorKindDoc {
                wire_name: "captcha",
                when_emitted: "Captcha challenge encountered and not bypassable in current mode.",
                retriable: false,
                hint: "Switch to an authenticated flow or solve out-of-band.",
            },
            Auth => ErrorKindDoc {
                wire_name: "auth",
                when_emitted: "Authentication / authorization failure.",
                retriable: false,
                hint: "Re-run `auth_login_start` / refresh the profile.",
            },
            NotFound => ErrorKindDoc {
                wire_name: "not_found",
                when_emitted: "Target resource not found.",
                retriable: false,
                hint: "Verify the URL / recipe / profile name.",
            },
            Validation => ErrorKindDoc {
                wire_name: "validation",
                when_emitted: "Input validation failure.",
                retriable: false,
                hint: "Inspect `message` and fix the offending field.",
            },
            Network => ErrorKindDoc {
                wire_name: "network",
                when_emitted: "Lower-level network / transport failure.",
                retriable: true,
                hint: "Retry with backoff; check egress connectivity.",
            },
            Internal => ErrorKindDoc {
                wire_name: "internal",
                when_emitted: "Unclassified internal error (last resort).",
                retriable: false,
                hint: "Capture logs and file a bug; do not silently retry.",
            },
            RecipeNotFound => ErrorKindDoc {
                wire_name: "recipe_not_found",
                when_emitted: "Recipe lookup failed: the requested `domain` has no recipe on disk.",
                retriable: false,
                hint: "Run `recipe_list` to see available domains.",
            },
            RecipeInvalid => ErrorKindDoc {
                wire_name: "recipe_invalid",
                when_emitted: "Recipe payload (TOML/JSON) failed schema or semantic validation.",
                retriable: false,
                hint: "Fix the recipe and re-import.",
            },
            AuthSessionExpired => ErrorKindDoc {
                wire_name: "auth_session_expired",
                when_emitted: "`auth_login_complete` polled past `login_timeout` budget.",
                retriable: true,
                hint: "Re-run `auth_login_start` to obtain a fresh session_token.",
            },
            AuthSessionNotFound => ErrorKindDoc {
                wire_name: "auth_session_not_found",
                when_emitted: "`session_token` is unknown to the registry (never issued, GC'd, or already consumed).",
                retriable: false,
                hint: "Start a new login flow with `auth_login_start`.",
            },
            AuthSessionPending => ErrorKindDoc {
                wire_name: "auth_session_pending",
                when_emitted: "`session_token` exists but the login helper has not yet finished.",
                retriable: true,
                hint: "Poll `auth_login_complete` again after a short delay.",
            },
            VpnNotConfigured => ErrorKindDoc {
                wire_name: "vpn_not_configured",
                when_emitted: "VPN rotation requested but no VPN backend is configured.",
                retriable: false,
                hint: "Configure Surfshark/Gluetun in policy.toml before requesting rotation.",
            },
            VpnAllInstancesFailed => ErrorKindDoc {
                wire_name: "vpn_all_instances_failed",
                when_emitted: "VPN rotation tried every configured instance and none came up.",
                retriable: true,
                hint: "Wait and retry; check VPN provider status.",
            },
            VpnCountryMismatch => ErrorKindDoc {
                wire_name: "vpn_country_mismatch",
                when_emitted: "VPN egress is up but the resolved country does not match the requested `country` constraint.",
                retriable: true,
                hint: "Retry rotation with a different region hint.",
            },
            CdpProtocol => ErrorKindDoc {
                wire_name: "cdp_protocol",
                when_emitted: "Chrome DevTools Protocol returned an unexpected error code.",
                retriable: true,
                hint: "Retry; if persistent, check Chrome version compatibility.",
            },
            CdpDisconnected => ErrorKindDoc {
                wire_name: "cdp_disconnected",
                when_emitted: "CDP WebSocket disconnected before the operation completed.",
                retriable: true,
                hint: "Retry; relaunch the browser if disconnects persist.",
            },
            CdpInjectionFailed => ErrorKindDoc {
                wire_name: "cdp_injection_failed",
                when_emitted: "Stealth JS injection into the target page failed.",
                retriable: true,
                hint: "Re-run; verify obscura binary version.",
            },
            BrowserCrashed => ErrorKindDoc {
                wire_name: "browser_crashed",
                when_emitted: "Headless browser process crashed mid-operation.",
                retriable: true,
                hint: "Retry; if reproducible, capture core dump and file a bug.",
            },
            BrowserNotFound => ErrorKindDoc {
                wire_name: "browser_not_found",
                when_emitted: "Headless browser binary could not be located on PATH.",
                retriable: false,
                hint: "Install Chrome/Chromium or set OBSCURA_BIN.",
            },
            CookieDecryptFailed => ErrorKindDoc {
                wire_name: "cookie_decrypt_failed",
                when_emitted: "On-disk cookie store could not be decrypted (bad passphrase / corruption).",
                retriable: false,
                hint: "Re-create the auth profile.",
            },
            Aborted => ErrorKindDoc {
                wire_name: "aborted",
                when_emitted: "Operation cancelled by caller (e.g. shutdown signal).",
                retriable: true,
                hint: "Resume the operation if still desired.",
            },
        }
    }

    let order: [ErrorKind; 26] = [
        Aup,
        Ssrf,
        VpnLeak,
        RateLimit,
        Timeout,
        Captcha,
        Auth,
        NotFound,
        Validation,
        Network,
        Internal,
        RecipeNotFound,
        RecipeInvalid,
        AuthSessionExpired,
        AuthSessionNotFound,
        AuthSessionPending,
        VpnNotConfigured,
        VpnAllInstancesFailed,
        VpnCountryMismatch,
        CdpProtocol,
        CdpDisconnected,
        CdpInjectionFailed,
        BrowserCrashed,
        BrowserNotFound,
        CookieDecryptFailed,
        Aborted,
    ];

    core::array::from_fn(|i| (order[i].clone(), doc_for(&order[i])))
}

impl ErrorEnvelope {
    /// Construct a minimal non-retryable envelope.
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            retryable: false,
            hint: None,
            retry_after_ms: None,
        }
    }

    /// Mark this envelope as retryable, optionally with a backoff hint.
    pub fn retryable(mut self, retry_after_ms: Option<u64>) -> Self {
        self.retryable = true;
        self.retry_after_ms = retry_after_ms;
        self
    }

    /// Attach an operator hint.
    pub fn with_hint(mut self, hint: impl Into<String>) -> Self {
        self.hint = Some(hint.into());
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_envelope_serde_round_trip() {
        let original = ErrorEnvelope::new(ErrorKind::RateLimit, "throttled by host")
            .retryable(Some(2_500))
            .with_hint("reduce per_host_qps");
        let json = serde_json::to_string(&original).expect("serialize");
        let decoded: ErrorEnvelope = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(original, decoded);
        // Verify snake_case wire format for kind.
        assert!(json.contains("\"rate_limit\""));
    }

    /// All 26 P4.3 ErrorKind variants. Centralized so the round-trip and
    /// arity tests cannot drift apart.
    fn all_kinds() -> [ErrorKind; 26] {
        [
            // P1 (11)
            ErrorKind::Aup,
            ErrorKind::Ssrf,
            ErrorKind::VpnLeak,
            ErrorKind::RateLimit,
            ErrorKind::Timeout,
            ErrorKind::Captcha,
            ErrorKind::Auth,
            ErrorKind::NotFound,
            ErrorKind::Validation,
            ErrorKind::Network,
            ErrorKind::Internal,
            // P4.3 (15)
            ErrorKind::RecipeNotFound,
            ErrorKind::RecipeInvalid,
            ErrorKind::AuthSessionExpired,
            ErrorKind::AuthSessionNotFound,
            ErrorKind::AuthSessionPending,
            ErrorKind::VpnNotConfigured,
            ErrorKind::VpnAllInstancesFailed,
            ErrorKind::VpnCountryMismatch,
            ErrorKind::CdpProtocol,
            ErrorKind::CdpDisconnected,
            ErrorKind::CdpInjectionFailed,
            ErrorKind::BrowserCrashed,
            ErrorKind::BrowserNotFound,
            ErrorKind::CookieDecryptFailed,
            ErrorKind::Aborted,
        ]
    }

    #[test]
    fn error_kind_closed_enum_no_invalid_variant() {
        // Unknown variant must be rejected (closed enum contract).
        let bad = r#""definitely_not_a_real_variant""#;
        let parsed: Result<ErrorKind, _> = serde_json::from_str(bad);
        assert!(parsed.is_err(), "closed enum must reject unknown variants");
    }

    /// Exhaustive guard coupled to the enum definition. Any variant added
    /// to `ErrorKind` MUST be added here too — the compiler enforces this
    /// via `forbid(unreachable_patterns)` + no wildcard arm. Adding a 27th
    /// variant without updating this match is a compile error.
    #[forbid(unreachable_patterns)]
    fn variant_index(k: &ErrorKind) -> usize {
        match k {
            ErrorKind::Aup => 0,
            ErrorKind::Ssrf => 1,
            ErrorKind::VpnLeak => 2,
            ErrorKind::RateLimit => 3,
            ErrorKind::Timeout => 4,
            ErrorKind::Captcha => 5,
            ErrorKind::Auth => 6,
            ErrorKind::NotFound => 7,
            ErrorKind::Validation => 8,
            ErrorKind::Network => 9,
            ErrorKind::Internal => 10,
            ErrorKind::RecipeNotFound => 11,
            ErrorKind::RecipeInvalid => 12,
            ErrorKind::AuthSessionExpired => 13,
            ErrorKind::AuthSessionNotFound => 14,
            ErrorKind::AuthSessionPending => 15,
            ErrorKind::VpnNotConfigured => 16,
            ErrorKind::VpnAllInstancesFailed => 17,
            ErrorKind::VpnCountryMismatch => 18,
            ErrorKind::CdpProtocol => 19,
            ErrorKind::CdpDisconnected => 20,
            ErrorKind::CdpInjectionFailed => 21,
            ErrorKind::BrowserCrashed => 22,
            ErrorKind::BrowserNotFound => 23,
            ErrorKind::CookieDecryptFailed => 24,
            ErrorKind::Aborted => 25,
        }
    }

    #[test]
    fn error_kind_has_exactly_26_variants() {
        // P4.3 closed-enum contract: must be exactly 26 variants. Adding
        // or removing one is a deliberate, breaking change.
        //
        // Arity is enforced two ways:
        //   1. `variant_index` is an exhaustive no-wildcard match on
        //      `ErrorKind`. A 27th variant fails to compile here.
        //   2. The unique indices below must span exactly 0..26.
        let all = all_kinds();
        assert_eq!(all.len(), 26);

        let mut indices: Vec<usize> = all.iter().map(variant_index).collect();
        indices.sort();
        indices.dedup();
        assert_eq!(
            indices,
            (0..26).collect::<Vec<_>>(),
            "all_kinds() must list each ErrorKind variant exactly once"
        );

        // Wire-name uniqueness as a secondary safety net.
        let mut wire: Vec<String> = all
            .iter()
            .map(|k| serde_json::to_string(k).unwrap())
            .collect();
        wire.sort();
        wire.dedup();
        assert_eq!(wire.len(), 26, "duplicate ErrorKind wire names");
    }

    #[test]
    fn error_kind_serde_round_trip_all_26() {
        for k in all_kinds() {
            let j = serde_json::to_string(&k).unwrap();
            let back: ErrorKind = serde_json::from_str(&j).unwrap();
            assert_eq!(k, back, "round-trip failed for {k:?} (wire={j})");
        }
        // Spot-check a few wire names use snake_case as advertised.
        assert_eq!(
            serde_json::to_string(&ErrorKind::RecipeNotFound).unwrap(),
            "\"recipe_not_found\""
        );
        assert_eq!(
            serde_json::to_string(&ErrorKind::AuthSessionExpired).unwrap(),
            "\"auth_session_expired\""
        );
        assert_eq!(
            serde_json::to_string(&ErrorKind::VpnAllInstancesFailed).unwrap(),
            "\"vpn_all_instances_failed\""
        );
    }

    #[test]
    fn error_envelope_round_trip_includes_all_fields() {
        let env = ErrorEnvelope::new(
            ErrorKind::AuthSessionExpired,
            "login_window_timeout after 600s",
        )
        .retryable(Some(1_000))
        .with_hint("re-run auth_login_start");
        let j = serde_json::to_string(&env).unwrap();
        let back: ErrorEnvelope = serde_json::from_str(&j).unwrap();
        assert_eq!(env, back);
        // All five fields land in the wire payload.
        for needle in [
            "\"kind\":",
            "\"message\":",
            "\"retryable\":",
            "\"hint\":",
            "\"retry_after_ms\":",
        ] {
            assert!(j.contains(needle), "missing field on wire: {needle}");
        }
        assert!(j.contains("\"auth_session_expired\""));
    }
}
