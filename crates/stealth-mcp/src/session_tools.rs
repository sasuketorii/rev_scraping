// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.2.0 (P9.1 — session_show MCP tool)
//
//! In-process MCP tool handler for `session_show`. Reads the persisted
//! `session_id -> {instance, ts_unix}` record written by
//! `vpn_rotate::InstancePool::persist_session` under
//! `~/.rev_scraping/sessions/<session_id>.json` and projects it onto the
//! `session_show.output` envelope (`{session_id, vpn_instance,
//! recipe_hits[], auth_profile?, started_at}`).
//!
//! The recipe_hits and auth_profile fields are reserved for future
//! enrichment (P9.2+); today they surface as `[]` and `null` respectively
//! so the wire contract is stable.

use std::path::{Path, PathBuf};

use serde_json::{json, Value};
use stealth_agent_contracts::{ErrorEnvelope, ErrorKind};

/// Set of in-process tool names handled by this module.
pub const SESSION_TOOLS: &[&str] = &["session_show"];

pub fn is_session_tool(name: &str) -> bool {
    SESSION_TOOLS.contains(&name)
}

/// Default session dir: `~/.rev_scraping/sessions/`. Falls back to
/// `./.rev_scraping/sessions/` when HOME is unset.
pub fn default_session_dir() -> PathBuf {
    dirs::home_dir()
        .map(|h| h.join(".rev_scraping").join("sessions"))
        .unwrap_or_else(|| PathBuf::from(".rev_scraping/sessions"))
}

#[derive(Debug)]
pub enum SessionError {
    MissingField(&'static str),
    InvalidSessionId(String),
    NotFound(String),
    ReadError(String),
    ParseError(String),
}

impl SessionError {
    pub fn to_envelope(&self) -> ErrorEnvelope {
        let msg = self.to_string();
        match self {
            SessionError::MissingField(_) | SessionError::InvalidSessionId(_) => {
                ErrorEnvelope::new(ErrorKind::Validation, msg)
            }
            SessionError::NotFound(_) => ErrorEnvelope::new(ErrorKind::NotFound, msg)
                .with_hint("session id may have been GC'd or never issued"),
            SessionError::ReadError(_) | SessionError::ParseError(_) => {
                ErrorEnvelope::new(ErrorKind::Internal, msg)
            }
        }
    }
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SessionError::MissingField(k) => write!(f, "missing required argument: {k}"),
            SessionError::InvalidSessionId(s) => write!(f, "invalid session_id: {s}"),
            SessionError::NotFound(s) => write!(f, "session not found: {s}"),
            SessionError::ReadError(e) => write!(f, "session read error: {e}"),
            SessionError::ParseError(e) => write!(f, "session parse error: {e}"),
        }
    }
}

/// Validate a session id: must be 1..=128 chars, ASCII, and contain only
/// `[A-Za-z0-9_-]`. Rejects path separators / `..` / `.` so the operator
/// cannot trick the handler into reading outside the session dir.
fn validate_session_id(s: &str) -> Result<(), SessionError> {
    if s.is_empty() {
        return Err(SessionError::InvalidSessionId("empty".into()));
    }
    if s.len() > 128 {
        return Err(SessionError::InvalidSessionId("exceeds 128 chars".into()));
    }
    for ch in s.chars() {
        if !(ch.is_ascii_alphanumeric() || ch == '_' || ch == '-') {
            return Err(SessionError::InvalidSessionId(format!(
                "contains forbidden char `{ch}`"
            )));
        }
    }
    if s == "." || s == ".." {
        return Err(SessionError::InvalidSessionId("dot path".into()));
    }
    Ok(())
}

/// Dispatch the `session_show` tool against `session_dir`.
pub fn handle_session_tool(
    name: &str,
    args: &Value,
    session_dir: &Path,
) -> Result<Value, SessionError> {
    match name {
        "session_show" => {
            let id = args
                .get("session_id")
                .and_then(|v| v.as_str())
                .ok_or(SessionError::MissingField("session_id"))?;
            validate_session_id(id)?;
            let path = session_dir.join(format!("{id}.json"));
            if !path.exists() {
                return Err(SessionError::NotFound(id.to_string()));
            }
            let raw = std::fs::read_to_string(&path)
                .map_err(|e| SessionError::ReadError(e.to_string()))?;
            let v: Value =
                serde_json::from_str(&raw).map_err(|e| SessionError::ParseError(e.to_string()))?;
            // Map persisted shape `{session_id, instance, ts_unix}` onto
            // the session_show.output envelope. Future fields
            // (recipe_hits, auth_profile) default to empty/null until the
            // persistence layer starts recording them.
            let vpn_instance = v.get("instance").cloned().unwrap_or(Value::Null);
            let started_at = v.get("ts_unix").and_then(|x| x.as_u64()).unwrap_or(0);
            let recipe_hits = v
                .get("recipe_hits")
                .cloned()
                .unwrap_or_else(|| Value::Array(vec![]));
            let auth_profile = v.get("auth_profile").cloned().unwrap_or(Value::Null);
            Ok(json!({
                "session_id": id,
                "vpn_instance": vpn_instance,
                "recipe_hits": recipe_hits,
                "auth_profile": auth_profile,
                "started_at": started_at,
            }))
        }
        _ => Err(SessionError::MissingField("unknown session tool")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn write_session(dir: &Path, id: &str, body: &str) {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join(format!("{id}.json")), body).unwrap();
    }

    #[test]
    fn session_show_returns_session_metadata() {
        let dir = tempdir().unwrap();
        let id = "sess-42";
        write_session(
            dir.path(),
            id,
            r#"{"session_id":"sess-42","instance":"vpn-2","ts_unix":1700000000}"#,
        );
        let out =
            handle_session_tool("session_show", &json!({"session_id": id}), dir.path()).unwrap();
        assert_eq!(out["session_id"], "sess-42");
        assert_eq!(out["vpn_instance"], "vpn-2");
        assert_eq!(out["started_at"], 1700000000u64);
        assert_eq!(out["recipe_hits"], json!([]));
        assert_eq!(out["auth_profile"], Value::Null);
    }

    #[test]
    fn session_show_unknown_session_returns_kind_not_found() {
        let dir = tempdir().unwrap();
        let err = handle_session_tool(
            "session_show",
            &json!({"session_id": "missing-id"}),
            dir.path(),
        )
        .unwrap_err();
        let env = err.to_envelope();
        assert_eq!(env.kind, ErrorKind::NotFound);
        assert!(env.message.contains("missing-id"));
    }

    #[test]
    fn session_show_rejects_path_traversal_in_id() {
        let dir = tempdir().unwrap();
        for bad in &["../etc", "a/b", "a\\b", ".", "..", "with space"] {
            let err = handle_session_tool("session_show", &json!({"session_id": bad}), dir.path())
                .unwrap_err();
            match err {
                SessionError::InvalidSessionId(_) => {}
                other => panic!("expected InvalidSessionId for `{bad}`, got {other:?}"),
            }
        }
    }

    #[test]
    fn session_show_missing_session_id_arg() {
        let dir = tempdir().unwrap();
        let err = handle_session_tool("session_show", &json!({}), dir.path()).unwrap_err();
        match err {
            SessionError::MissingField("session_id") => {}
            other => panic!("expected MissingField(session_id), got {other:?}"),
        }
    }
}
