// SPDX-License-Identifier: MIT
// Source: rev_scraping Lane C P1 (stealth-agent-contracts crate, original work)
//! Opaque identifier newtypes shared across stealth-* boundaries.
//!
//! Both [`ProgressToken`] and [`SessionId`] wrap a [`uuid::Uuid`] and enforce
//! the v4 (random) invariant on both construction and deserialization. The
//! inner field is private to prevent callers from forging an arbitrary UUID
//! variant through struct-update syntax.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use uuid::{Uuid, Variant, Version};

/// Validate that `u` is a fully-conformant RFC 4122 / RFC 9562 UUID v4:
/// version nibble == 4 AND variant == RFC4122. This rejects e.g.
/// `00000000-0000-4000-0000-000000000000` which has a v4 version field but
/// the NCS variant bits.
fn is_strict_v4(u: &Uuid) -> bool {
    matches!(u.get_version(), Some(Version::Random)) && u.get_variant() == Variant::RFC4122
}

fn ensure_v4<E: serde::de::Error>(u: Uuid) -> Result<Uuid, E> {
    if !is_strict_v4(&u) {
        return Err(E::custom(format!(
            "expected RFC 4122 UUID v4, got version={:?} variant={:?}",
            u.get_version_num(),
            u.get_variant()
        )));
    }
    Ok(u)
}

/// Progress reporting token for long-running operations.
///
/// Wraps a UUID v4 so callers cannot cross-wire it with [`SessionId`].
/// Construction outside this crate is only possible via [`ProgressToken::new`],
/// [`ProgressToken::from_uuid`] (which validates), or serde deserialize (which
/// also validates the version).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ProgressToken(Uuid);

impl ProgressToken {
    /// Generate a fresh UUID v4 progress token.
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }

    /// Wrap an existing UUID, returning `None` if it is not v4.
    pub fn from_uuid(u: Uuid) -> Option<Self> {
        if is_strict_v4(&u) {
            Some(Self(u))
        } else {
            None
        }
    }

    /// Inner UUID accessor (read-only).
    pub fn as_uuid(&self) -> Uuid {
        self.0
    }
}

impl Default for ProgressToken {
    fn default() -> Self {
        Self::new()
    }
}

impl Serialize for ProgressToken {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        self.0.serialize(s)
    }
}

impl<'de> Deserialize<'de> for ProgressToken {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let u = Uuid::deserialize(d)?;
        ensure_v4(u).map(Self)
    }
}

/// Stealth agent session identifier.
///
/// Wraps a UUID v4 with identical v4 enforcement to [`ProgressToken`].
/// Sessions are stable across a single CLI/MCP invocation and are used to
/// correlate audit log entries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SessionId(Uuid);

impl SessionId {
    /// Generate a fresh UUID v4 session id.
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }

    /// Wrap an existing UUID, returning `None` if it is not v4.
    pub fn from_uuid(u: Uuid) -> Option<Self> {
        if is_strict_v4(&u) {
            Some(Self(u))
        } else {
            None
        }
    }

    /// Inner UUID accessor (read-only).
    pub fn as_uuid(&self) -> Uuid {
        self.0
    }
}

impl Default for SessionId {
    fn default() -> Self {
        Self::new()
    }
}

impl Serialize for SessionId {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        self.0.serialize(s)
    }
}

impl<'de> Deserialize<'de> for SessionId {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let u = Uuid::deserialize(d)?;
        ensure_v4(u).map(Self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn progress_token_uuid_v4_unique() {
        // Generate a batch and confirm uniqueness + v4 version field.
        let mut seen = HashSet::new();
        for _ in 0..128 {
            let t = ProgressToken::new();
            assert_eq!(t.as_uuid().get_version_num(), 4, "must be UUID v4");
            assert!(seen.insert(t.as_uuid()), "UUIDs must be unique");
        }

        // serde transparent: serializes as a bare UUID string.
        let t = ProgressToken::new();
        let j = serde_json::to_string(&t).unwrap();
        assert!(j.starts_with('"') && j.ends_with('"'));
        let back: ProgressToken = serde_json::from_str(&j).unwrap();
        assert_eq!(t, back);

        // SessionId parallel check.
        let s = SessionId::new();
        assert_eq!(s.as_uuid().get_version_num(), 4);
        let j2 = serde_json::to_string(&s).unwrap();
        let back2: SessionId = serde_json::from_str(&j2).unwrap();
        assert_eq!(s, back2);
    }

    #[test]
    fn token_rejects_non_v4_uuid_on_deserialize() {
        // UUID v1 (timestamp-based) literal: version nibble == 1.
        let v1 = "\"6ba7b810-9dad-11d1-80b4-00c04fd430c8\"";
        let r: Result<ProgressToken, _> = serde_json::from_str(v1);
        assert!(r.is_err(), "ProgressToken must reject non-v4 UUID");
        let r2: Result<SessionId, _> = serde_json::from_str(v1);
        assert!(r2.is_err(), "SessionId must reject non-v4 UUID");

        // from_uuid constructor must also reject non-v4.
        let parsed = Uuid::parse_str("6ba7b810-9dad-11d1-80b4-00c04fd430c8").unwrap();
        assert!(ProgressToken::from_uuid(parsed).is_none());
        assert!(SessionId::from_uuid(parsed).is_none());

        // v4 UUID must succeed through from_uuid.
        let v4 = Uuid::new_v4();
        assert!(ProgressToken::from_uuid(v4).is_some());
        assert!(SessionId::from_uuid(v4).is_some());
    }

    #[test]
    fn token_rejects_v4_version_with_wrong_variant() {
        // Version nibble == 4 but variant bits == NCS (top bit 0). Must be
        // rejected by strict RFC 4122 check.
        let malformed_str = "00000000-0000-4000-0000-000000000000";
        let malformed = Uuid::parse_str(malformed_str).unwrap();
        assert_eq!(malformed.get_version_num(), 4);
        assert_ne!(malformed.get_variant(), Variant::RFC4122);

        assert!(ProgressToken::from_uuid(malformed).is_none());
        assert!(SessionId::from_uuid(malformed).is_none());

        let json = format!("\"{malformed_str}\"");
        let r: Result<ProgressToken, _> = serde_json::from_str(&json);
        assert!(r.is_err(), "deserialize must reject malformed v4");
        let r2: Result<SessionId, _> = serde_json::from_str(&json);
        assert!(r2.is_err(), "deserialize must reject malformed v4");
    }
}
