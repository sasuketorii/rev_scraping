// SPDX-License-Identifier: MIT
//
// v1.3 Lane G.7: unified CLI error template.
//
// Every failure path emitted by `rev-stealth` (stdout JSON, stderr human,
// in-process or spawned subprocess) must surface the canonical
// `{kind, message, hint?, retry_after_ms?, doc_url}` shape so callers
// (Hermes / Codex / Claude / shell scripts) can branch on a closed
// taxonomy instead of regex-grepping a free-form `error` string.
//
// Wire shape (JSON mode, additive — legacy `error: <string>` field is
// preserved alongside for backward compat with v1.2.x consumers):
//
//   {
//     "ok": false,
//     "operation": "<op>",
//     "exit_code": <i32>,
//     "error": "<message>",                 // legacy, kept for v1.2.x
//     "kind": "<snake_case_wire_name>",     // 26 closed variants (Lane I)
//     "message": "<human-readable>",
//     "hint": "<operator hint>" | null,
//     "retry_after_ms": <u64> | null,
//     "doc_url": "<https://.../<PascalCase>.md>"   // Lane J
//   }
//
// `kind` aligns with `stealth-agent-contracts::ErrorKind` (26 variants,
// snake_case wire format). `doc_url` points at the per-variant
// reference page authored under `docs/book/src/en/errors/` (Lane J).
//
// IMPORTANT: this module is intentionally self-contained (no
// `stealth-agent-contracts` dependency edit in G.7 to avoid colliding
// with Lane H Slice B-3 workspace-Cargo.toml churn). The 26-variant
// table here is mirrored from `stealth-agent-contracts::ErrorKind`
// and is guarded by a compile-time arity test below.

use serde_json::{json, Value};

use crate::OutputFormat;

/// Base URL for per-variant error reference pages (Lane J).
///
/// Resolves to a stable `https://github.com/.../docs/book/src/en/errors/<Variant>.md`
/// link. The page filename is the PascalCase Rust variant name (NOT the
/// snake_case wire name) because Lane J authored the pages with PascalCase
/// filenames; see `docs/book/src/en/errors/`.
pub const DOC_URL_BASE: &str =
    "https://github.com/sasuketorii/rev_scraping/blob/main/docs/book/src/en/errors/";

/// Closed enumeration of CLI error categories.
///
/// 1:1 mirror of `stealth-agent-contracts::ErrorKind` (26 variants). Kept
/// here as a small standalone type so `stealth-cli` can emit canonical
/// error envelopes without taking a new workspace dependency in G.7
/// (Lane H Slice B-3 is concurrently editing Cargo.toml / workspace
/// deps and the slice contract forbids touching those files here).
///
/// Wire format is `snake_case` (via [`CliErrorKind::wire_name`]). Doc
/// URL uses the PascalCase variant name (via [`CliErrorKind::pascal_name`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CliErrorKind {
    // P1 (11)
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
    // P4.3 expansion (15) → 26 closed total
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
}

impl CliErrorKind {
    /// snake_case wire name — matches `stealth-agent-contracts::ErrorKind`
    /// serde rename. Used as the `kind` field on the wire.
    #[forbid(unreachable_patterns)]
    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::Aup => "aup",
            Self::Ssrf => "ssrf",
            Self::VpnLeak => "vpn_leak",
            Self::RateLimit => "rate_limit",
            Self::Timeout => "timeout",
            Self::Captcha => "captcha",
            Self::Auth => "auth",
            Self::NotFound => "not_found",
            Self::Validation => "validation",
            Self::Network => "network",
            Self::Internal => "internal",
            Self::RecipeNotFound => "recipe_not_found",
            Self::RecipeInvalid => "recipe_invalid",
            Self::AuthSessionExpired => "auth_session_expired",
            Self::AuthSessionNotFound => "auth_session_not_found",
            Self::AuthSessionPending => "auth_session_pending",
            Self::VpnNotConfigured => "vpn_not_configured",
            Self::VpnAllInstancesFailed => "vpn_all_instances_failed",
            Self::VpnCountryMismatch => "vpn_country_mismatch",
            Self::CdpProtocol => "cdp_protocol",
            Self::CdpDisconnected => "cdp_disconnected",
            Self::CdpInjectionFailed => "cdp_injection_failed",
            Self::BrowserCrashed => "browser_crashed",
            Self::BrowserNotFound => "browser_not_found",
            Self::CookieDecryptFailed => "cookie_decrypt_failed",
            Self::Aborted => "aborted",
        }
    }

    /// PascalCase Rust variant name — matches the per-variant reference
    /// page filename under `docs/book/src/en/errors/` (Lane J).
    #[forbid(unreachable_patterns)]
    pub const fn pascal_name(self) -> &'static str {
        match self {
            Self::Aup => "Aup",
            Self::Ssrf => "Ssrf",
            Self::VpnLeak => "VpnLeak",
            Self::RateLimit => "RateLimit",
            Self::Timeout => "Timeout",
            Self::Captcha => "Captcha",
            Self::Auth => "Auth",
            Self::NotFound => "NotFound",
            Self::Validation => "Validation",
            Self::Network => "Network",
            Self::Internal => "Internal",
            Self::RecipeNotFound => "RecipeNotFound",
            Self::RecipeInvalid => "RecipeInvalid",
            Self::AuthSessionExpired => "AuthSessionExpired",
            Self::AuthSessionNotFound => "AuthSessionNotFound",
            Self::AuthSessionPending => "AuthSessionPending",
            Self::VpnNotConfigured => "VpnNotConfigured",
            Self::VpnAllInstancesFailed => "VpnAllInstancesFailed",
            Self::VpnCountryMismatch => "VpnCountryMismatch",
            Self::CdpProtocol => "CdpProtocol",
            Self::CdpDisconnected => "CdpDisconnected",
            Self::CdpInjectionFailed => "CdpInjectionFailed",
            Self::BrowserCrashed => "BrowserCrashed",
            Self::BrowserNotFound => "BrowserNotFound",
            Self::CookieDecryptFailed => "CookieDecryptFailed",
            Self::Aborted => "Aborted",
        }
    }

    /// Fully-resolved doc URL for this variant.
    pub fn doc_url(self) -> String {
        format!("{DOC_URL_BASE}{}.md", self.pascal_name())
    }

    /// Canonical ordering — used by tests and the doc reference generator.
    pub const fn all() -> &'static [CliErrorKind; 26] {
        &[
            Self::Aup,
            Self::Ssrf,
            Self::VpnLeak,
            Self::RateLimit,
            Self::Timeout,
            Self::Captcha,
            Self::Auth,
            Self::NotFound,
            Self::Validation,
            Self::Network,
            Self::Internal,
            Self::RecipeNotFound,
            Self::RecipeInvalid,
            Self::AuthSessionExpired,
            Self::AuthSessionNotFound,
            Self::AuthSessionPending,
            Self::VpnNotConfigured,
            Self::VpnAllInstancesFailed,
            Self::VpnCountryMismatch,
            Self::CdpProtocol,
            Self::CdpDisconnected,
            Self::CdpInjectionFailed,
            Self::BrowserCrashed,
            Self::BrowserNotFound,
            Self::CookieDecryptFailed,
            Self::Aborted,
        ]
    }
}

/// Build the canonical error fields block as a JSON object containing
/// `kind`, `message`, `hint`, `retry_after_ms`, and `doc_url`.
///
/// This is the **single source of truth** for the G.7 envelope shape:
/// every `emit_err` / `emit_error` helper across the CLI delegates here
/// so the wire contract cannot drift per subcommand.
#[allow(dead_code)] // exposed for future callers that build envelopes manually
pub fn build_error_fields(
    kind: CliErrorKind,
    message: &str,
    hint: Option<&str>,
    retry_after_ms: Option<u64>,
) -> Value {
    json!({
        "kind": kind.wire_name(),
        "message": message,
        "hint": hint,
        "retry_after_ms": retry_after_ms,
        "doc_url": kind.doc_url(),
    })
}

/// Emit a canonical G.7 error envelope and return `exit`.
///
/// JSON mode: prints (to stdout) the legacy `{ok, operation, exit_code, error}`
/// envelope **plus** the G.7 fields (`kind`, `message`, `hint`, `retry_after_ms`,
/// `doc_url`) as siblings. Keeping the legacy `error: <string>` field preserves
/// schema compatibility for v1.2.x consumers while the structured taxonomy
/// becomes the canonical surface for v1.3+.
///
/// Human mode: writes a `[ERROR] <op>: <message>` line to stderr followed by
/// `see <doc_url>` for operator readability.
///
/// The 5 G.7 fields are also added by [`augment_with_g7_fields`] to any
/// pre-built error envelope (e.g. spider's leak-shutdown path) so all
/// failure surfaces converge on the same shape.
pub fn emit_err_envelope(
    format: OutputFormat,
    op: &str,
    exit: i32,
    kind: CliErrorKind,
    message: &str,
    hint: Option<&str>,
    retry_after_ms: Option<u64>,
) -> i32 {
    let doc_url = kind.doc_url();
    let envelope = json!({
        "ok": false,
        "operation": op,
        "exit_code": exit,
        "error": message,
        "kind": kind.wire_name(),
        "message": message,
        "hint": hint,
        "retry_after_ms": retry_after_ms,
        "doc_url": doc_url,
    });
    match format {
        OutputFormat::Json => {
            println!("{envelope}");
        }
        OutputFormat::Yaml => {
            // v1.3 Lane G fix-up R2: yaml mirrors JSON envelope verbatim
            // (same field set, different encoding). The JSON-schema docs
            // remain the single source of truth for the envelope shape.
            match serde_yaml::to_string(&envelope) {
                Ok(s) => print!("{s}"),
                Err(e) => {
                    eprintln!("# yaml-encode-error: {e}");
                    println!("{envelope}");
                }
            }
        }
        OutputFormat::Human => {
            eprintln!("[ERROR] {op}: {message}");
            if let Some(h) = hint {
                eprintln!("  hint: {h}");
            }
            if let Some(r) = retry_after_ms {
                eprintln!("  retry_after_ms: {r}");
            }
            eprintln!("  see: {doc_url}");
        }
    }
    exit
}

/// Augment an already-constructed error envelope (e.g. spider's
/// `emit_leak_exit` payload that carries a `vpn_monitor` block) with the
/// G.7 canonical fields. Mutates `envelope` in place when it is a JSON
/// object; no-op otherwise.
///
/// `message` defaults to the existing `error` string if present so
/// callers do not have to restate the same text. Pass `Some(...)` to
/// override.
pub fn augment_with_g7_fields(
    envelope: &mut Value,
    kind: CliErrorKind,
    message: Option<&str>,
    hint: Option<&str>,
    retry_after_ms: Option<u64>,
) {
    let Some(obj) = envelope.as_object_mut() else {
        return;
    };
    let msg = message
        .map(str::to_string)
        .or_else(|| {
            obj.get("error")
                .and_then(|v| v.as_str())
                .map(str::to_string)
        })
        .unwrap_or_default();
    obj.insert("kind".to_string(), json!(kind.wire_name()));
    obj.insert("message".to_string(), json!(msg));
    obj.insert("hint".to_string(), json!(hint));
    obj.insert("retry_after_ms".to_string(), json!(retry_after_ms));
    obj.insert("doc_url".to_string(), json!(kind.doc_url()));
}

/// Heuristic classifier for legacy `emit_err(format, op, exit, msg)`
/// call sites that have not been migrated to pass an explicit
/// [`CliErrorKind`]. Maps common message prefixes / substrings to a
/// best-effort kind so the canonical envelope is populated even from
/// un-migrated callers.
///
/// New code should pass [`CliErrorKind`] explicitly via
/// [`emit_err_envelope`] instead of relying on this heuristic.
pub fn classify_legacy_message(msg: &str) -> CliErrorKind {
    let lower = msg.to_ascii_lowercase();
    // Order matters: most specific first.
    if lower.contains("aup:") || lower.starts_with("aup ") {
        CliErrorKind::Aup
    } else if lower.contains("ssrf") {
        CliErrorKind::Ssrf
    } else if lower.contains("vpn leak") || lower.contains("leak detected") {
        CliErrorKind::VpnLeak
    } else if lower.contains("vpn pool exhausted") || lower.contains("all instances failed") {
        CliErrorKind::VpnAllInstancesFailed
    } else if lower.contains("vpn") && lower.contains("not configured") {
        CliErrorKind::VpnNotConfigured
    } else if lower.contains("country mismatch") {
        CliErrorKind::VpnCountryMismatch
    } else if lower.contains("rate limit") || lower.contains("throttle") {
        CliErrorKind::RateLimit
    } else if lower.contains("timed out") || lower.contains("timeout") {
        CliErrorKind::Timeout
    } else if lower.contains("captcha") {
        CliErrorKind::Captcha
    } else if lower.contains("auth expired") || lower.contains("session expired") {
        CliErrorKind::AuthSessionExpired
    } else if lower.contains("session_token") && lower.contains("pending") {
        CliErrorKind::AuthSessionPending
    } else if lower.contains("session_token") && lower.contains("not found") {
        CliErrorKind::AuthSessionNotFound
    } else if lower.contains("recipe") && lower.contains("not found") {
        CliErrorKind::RecipeNotFound
    } else if lower.contains("recipe") && (lower.contains("invalid") || lower.contains("schema")) {
        CliErrorKind::RecipeInvalid
    } else if lower.contains("cdp") && lower.contains("disconnect") {
        CliErrorKind::CdpDisconnected
    } else if lower.contains("cdp") && lower.contains("inject") {
        CliErrorKind::CdpInjectionFailed
    } else if lower.contains("cdp") {
        CliErrorKind::CdpProtocol
    } else if lower.contains("browser") && lower.contains("crash") {
        CliErrorKind::BrowserCrashed
    } else if lower.contains("browser") && lower.contains("not found") {
        CliErrorKind::BrowserNotFound
    } else if lower.contains("cookie") && lower.contains("decrypt") {
        CliErrorKind::CookieDecryptFailed
    } else if lower.contains("auth") || lower.contains("login") || lower.contains("unauthorized") {
        CliErrorKind::Auth
    } else if lower.contains("not found") || lower.contains("no match") {
        CliErrorKind::NotFound
    } else if lower.starts_with("invalid") || lower.contains("validation") {
        CliErrorKind::Validation
    } else if lower.contains("network") || lower.contains("connect") || lower.contains("dns") {
        CliErrorKind::Network
    } else if lower.contains("user declined") || lower.contains("aborted") {
        CliErrorKind::Aborted
    } else {
        CliErrorKind::Internal
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arity_is_exactly_26() {
        assert_eq!(
            CliErrorKind::all().len(),
            26,
            "must mirror 26-variant Lane I ErrorKind"
        );
    }

    #[test]
    fn wire_names_are_unique_snake_case() {
        let mut names: Vec<&str> = CliErrorKind::all().iter().map(|k| k.wire_name()).collect();
        names.sort();
        names.dedup();
        assert_eq!(names.len(), 26, "wire names must be unique");
        for n in names {
            assert!(
                !n.is_empty()
                    && n.chars()
                        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'),
                "wire name must be snake_case: {n}"
            );
        }
    }

    #[test]
    fn pascal_names_are_unique() {
        let mut names: Vec<&str> = CliErrorKind::all()
            .iter()
            .map(|k| k.pascal_name())
            .collect();
        names.sort();
        names.dedup();
        assert_eq!(names.len(), 26, "PascalCase names must be unique");
    }

    #[test]
    fn doc_url_uses_lane_j_path() {
        let u = CliErrorKind::RateLimit.doc_url();
        assert!(u.starts_with("https://"));
        assert!(u.ends_with("/docs/book/src/en/errors/RateLimit.md"));
    }

    #[test]
    fn build_error_fields_contains_all_5_keys() {
        let v = build_error_fields(
            CliErrorKind::Timeout,
            "took too long",
            Some("retry"),
            Some(1_000),
        );
        let obj = v.as_object().expect("object");
        for k in ["kind", "message", "hint", "retry_after_ms", "doc_url"] {
            assert!(obj.contains_key(k), "missing key: {k}");
        }
        assert_eq!(obj["kind"], json!("timeout"));
        assert_eq!(
            obj["doc_url"].as_str().unwrap(),
            CliErrorKind::Timeout.doc_url()
        );
    }

    #[test]
    fn augment_preserves_existing_fields_and_adds_5() {
        let mut env = json!({
            "ok": false,
            "operation": "spider",
            "exit_code": 7,
            "error": "vpn leak detected: tunnel down",
            "vpn_monitor": { "running": false },
        });
        augment_with_g7_fields(
            &mut env,
            CliErrorKind::VpnLeak,
            None,
            Some("rotate VPN"),
            None,
        );
        let obj = env.as_object().unwrap();
        // Pre-existing fields untouched.
        assert_eq!(obj["operation"], json!("spider"));
        assert_eq!(
            obj["error"].as_str().unwrap(),
            "vpn leak detected: tunnel down"
        );
        assert!(obj.contains_key("vpn_monitor"));
        // New G.7 fields present.
        assert_eq!(obj["kind"], json!("vpn_leak"));
        assert_eq!(
            obj["message"].as_str().unwrap(),
            "vpn leak detected: tunnel down"
        );
        assert_eq!(obj["hint"].as_str().unwrap(), "rotate VPN");
        assert!(obj["retry_after_ms"].is_null());
        assert_eq!(
            obj["doc_url"].as_str().unwrap(),
            CliErrorKind::VpnLeak.doc_url()
        );
    }

    #[test]
    fn classify_legacy_message_smoke() {
        assert_eq!(
            classify_legacy_message("AUP: not authorized"),
            CliErrorKind::Aup
        );
        assert_eq!(
            classify_legacy_message("SSRF guard tripped"),
            CliErrorKind::Ssrf
        );
        assert_eq!(
            classify_legacy_message("vpn leak detected"),
            CliErrorKind::VpnLeak
        );
        assert_eq!(
            classify_legacy_message("vpn pool exhausted"),
            CliErrorKind::VpnAllInstancesFailed
        );
        assert_eq!(
            classify_legacy_message("invalid --url"),
            CliErrorKind::Validation
        );
        assert_eq!(
            classify_legacy_message("connect: refused"),
            CliErrorKind::Network
        );
        assert_eq!(
            classify_legacy_message("user declined"),
            CliErrorKind::Aborted
        );
        assert_eq!(
            classify_legacy_message("unknown captcha type"),
            CliErrorKind::Captcha
        );
        // Fall-through to Internal.
        assert_eq!(classify_legacy_message("???"), CliErrorKind::Internal);
    }
}
