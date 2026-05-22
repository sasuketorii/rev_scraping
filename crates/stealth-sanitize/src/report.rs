//! Report types surfaced as `_meta.sanitize` on every sanitized response.
//!
//! The report shape is what LLM-visible callers see. Two invariants:
//! 1. `canary_hits` MUST NOT contain raw matched bytes from the source
//!    payload. Storing the matched substring would re-introduce the
//!    injection string into the agent-visible response — defeating the
//!    point of sanitizing. We store only `canary_id` + severity + offset.
//! 2. The report shape is additive-only across versions; existing fields
//!    keep their semantics so downstream consumers can pin
//!    `schema_version`.

use serde::{Deserialize, Serialize};

use crate::policy::Mode;

/// Severity tier for an L3 canary match.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CanarySeverity {
    /// Triggers fail-closed under `Enforce`; logged under `Warn`.
    Critical,
    /// Always replaced with a safe placeholder.
    High,
    /// Reported only; payload unchanged.
    Suspicious,
}

/// A single canary detection. Intentionally does NOT carry the matched
/// bytes — see invariant 1 in the module doc.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CanaryHit {
    /// Stable identifier for the canary rule (e.g. `"c01"`).
    pub canary_id: String,
    pub severity: CanarySeverity,
    /// Byte offset into the post-L4 (post-normalize) buffer where the
    /// match starts. The display-buffer offset is recovered via the
    /// L4 dual-buffer table; that mapping is internal.
    pub offset: usize,
    /// Length of the match in the post-L4 buffer.
    pub length: usize,
    /// JSON pointer (RFC 6901) to the field where the match was found,
    /// e.g. `/results/0/text`. Empty when the entire payload is a string.
    pub pointer: String,
}

/// Per-response report attached as `_meta.sanitize`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SanitizationReport {
    pub schema_version: u32,
    pub policy_name: &'static str,
    pub mode: Mode,
    pub bytes_in: usize,
    pub bytes_out: usize,
    pub truncated: bool,
    pub aborted: bool,
    /// Stable layer identifiers in execution order, e.g.
    /// `["L4:unicode", "L5:clamp", "L3:canary", "L2:envelope", "L7:meta"]`.
    pub layers_applied: Vec<&'static str>,
    pub canary_hits: Vec<CanaryHit>,
    /// 64-bit hex nonce echoed into the L2 envelope markers. Reused as a
    /// stable id for this sanitize pass.
    pub sanitize_id: String,
}

/// Wraps a sanitized payload together with its report. Callers attach
/// the report at `_meta.sanitize` on the outgoing JSON-RPC response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SanitizedEnvelope {
    pub payload: serde_json::Value,
    pub report: SanitizationReport,
}

/// Minimal error-envelope shape sanitized by
/// [`super::sanitize_error_envelope`]. Mirrors the existing
/// `stealth-mcp` error JSON contract without depending on it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorEnvelope {
    pub code: i32,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canary_hit_does_not_carry_matched_bytes_field() {
        let hit = CanaryHit {
            canary_id: "c01".into(),
            severity: CanarySeverity::Critical,
            offset: 0,
            length: 12,
            pointer: "/text".into(),
        };
        let json = serde_json::to_string(&hit).unwrap();
        assert!(!json.contains("matched_bytes"));
        assert!(!json.contains("matched"));
        // Serialization shape sanity.
        assert!(json.contains("\"canary_id\":\"c01\""));
        assert!(json.contains("\"severity\":\"critical\""));
    }

    #[test]
    fn error_envelope_round_trips_without_data() {
        let env = ErrorEnvelope {
            code: -32000,
            message: "boom".into(),
            data: None,
        };
        let s = serde_json::to_string(&env).unwrap();
        // `data: None` must be omitted so existing schema callers don't
        // see a surprise null field.
        assert!(!s.contains("\"data\""));
    }
}
